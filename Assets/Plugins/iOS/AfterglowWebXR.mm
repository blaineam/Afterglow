// An in-app browser for WebXR pages. WebBrowser.cs is the C# side.
//
// Safari has no WebXR on iOS, so a WebXR page opened anywhere on this phone falls back to a flat
// view. The usual fix -- render a web view into a texture and composite it in the engine -- is not
// available either: there is no public API that gets a live WKWebView's pixels at headset frame
// rates. drawViewHierarchyInRect costs milliseconds on the main thread, and snapshotting is worse.
//
// So the web view goes *over* Unity's view instead, full screen, and the page draws its own stereo
// pair and its own lens distortion through the shim injected below. Unity keeps running underneath
// -- it still owns the camera, the head tracking and the hand tracking -- and pushes its fused pose
// into the page each frame. The page is the renderer; the app is the tracker.
//
// The cost of that split is one evaluateJavaScript per frame. It is a small string and the work is
// asynchronous, but it is not free, and it is why the pose call takes plain floats rather than
// anything that needs encoding.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

// Logs to the system and to the session log through Unity (AfterglowNativeLog.mm).
void AGLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

extern "C" UIViewController *UnityGetGLViewController();

// What the page has told us, picked up by C# on its own thread.
enum WebEvent { WebEventNone = 0, WebEventSessionStart = 1, WebEventSessionEnd = 2, WebEventClose = 3, WebEventClearHistory = 4, WebEventStartPage = 5 };

// Injected into every page at document start, so pointing, clicking and scrolling are three small
// calls rather than three long strings re-parsed on every use.
//
// All three take a point as 0-1 across and down the window the scene draws, because that is what
// the gaze knows. They turn it into client coordinates against documentElement.clientWidth rather
// than window.innerWidth: a page that lays itself out wider or narrower than the view is scaled to
// fit, and client coordinates -- which is what elementFromPoint and the events are in -- measure
// the layout, not the scaled result. innerWidth measures the scaled result, so on any page with a
// viewport that isn't the view's width it pointed somewhere else.
static const char *kHelperSource = R"JS(
(function () {
  'use strict';
  function post(body) {
    try { window.webkit.messageHandlers.afterglow.postMessage(body); } catch (e) { /* nothing to report to */ }
  }
  // The page's errors and warnings reach the app's log, which is the only way to see why a page
  // did what it did from the phone's log file.
  (function () {
    var native = { error: console.error, warn: console.warn, log: console.log };
    function forward(level) {
      return function () {
        var parts = [];
        for (var i = 0; i < arguments.length; i++) {
          var a = arguments[i];
          parts.push(a && a.stack ? String(a.stack) : (typeof a === 'object' ? (function () { try { return JSON.stringify(a); } catch (e) { return String(a); } })() : String(a)));
        }
        var text = parts.join(' ');
        try { native[level].apply(console, arguments); } catch (e) { /* no console */ }
        if (level !== 'log' || text.indexOf('[Afterglow]') === 0)
          post({ event: 'console', level: level, text: text.slice(0, 600) });
      };
    }
    console.error = forward('error');
    console.warn = forward('warn');
    console.log = forward('log');
    window.addEventListener('error', function (e) {
      post({ event: 'console', level: 'error', text: 'uncaught: ' + (e.message || '') + ' at ' + (e.filename || '') + ':' + (e.lineno || 0) });
    });
    window.addEventListener('unhandledrejection', function (e) {
      var r = e.reason;
      post({ event: 'console', level: 'error', text: 'unhandled rejection: ' + (r && r.stack ? r.stack : String(r)).slice(0, 400) });
    });
  })();

  // Every resize-like event the page gets, with the sizes it sees, so a page that reacts to
  // one at the start of a session can be told what it reacted to.
  (function () {
    function sizes() {
      var vv = window.visualViewport;
      return 'inner ' + window.innerWidth + 'x' + window.innerHeight +
        (vv ? ', visual ' + Math.round(vv.width) + 'x' + Math.round(vv.height) + ' scale ' + vv.scale.toFixed(2) : '') +
        ', dpr ' + (window.devicePixelRatio || 1);
    }
    window.addEventListener('resize', function () { post({ event: 'console', level: 'log', text: '[Afterglow] window resize: ' + sizes() }); });
    window.addEventListener('orientationchange', function () { post({ event: 'console', level: 'log', text: '[Afterglow] orientationchange: ' + sizes() }); });
    if (window.visualViewport) {
      window.visualViewport.addEventListener('resize', function () { post({ event: 'console', level: 'log', text: '[Afterglow] visualViewport resize: ' + sizes() }); });
      window.visualViewport.addEventListener('scroll', function () { post({ event: 'console', level: 'log', text: '[Afterglow] visualViewport scroll: ' + sizes() }); });
    }
    document.addEventListener('visibilitychange', function () { post({ event: 'console', level: 'log', text: '[Afterglow] visibility: ' + document.visibilityState }); });
    if (window.ResizeObserver) {
      var seen = 0;
      try {
        new ResizeObserver(function (entries) {
          if (++seen > 20) return;
          var e = entries[0];
          post({ event: 'console', level: 'log', text: '[Afterglow] body resized to ' + Math.round(e.contentRect.width) + 'x' + Math.round(e.contentRect.height) + ', ' + sizes() });
        }).observe(document.documentElement);
      } catch (e) { /* no observer */ }
    }
  })();

  // Logins: a form with a password field that is submitted hands its username and password to
  // the app, which offers to keep them in the phone's Keychain; a page that shows a password
  // field is announced, so the app can offer a saved login; __afterglowFill puts one in.
  function hostOf() { try { return location.host || ''; } catch (e) { return ''; } }
  function loginFields(root) {
    var pass = root.querySelector ? root.querySelector('input[type="password"]') : null;
    if (!pass) return null;
    var user = null;
    var inputs = (pass.form || root).querySelectorAll ? (pass.form || root).querySelectorAll('input') : [];
    for (var i = 0; i < inputs.length; i++) {
      if (inputs[i] === pass) break;
      var ty = (inputs[i].type || 'text').toLowerCase();
      if (ty === 'text' || ty === 'email' || ty === 'tel' || ty === 'username') user = inputs[i];
    }
    return { user: user, pass: pass };
  }
  function offerToSave(form) {
    var lf = loginFields(form);
    if (!lf || !lf.pass.value) return;
    post({ event: 'credentials', host: hostOf(), user: lf.user ? lf.user.value : '', pass: lf.pass.value });
  }
  document.addEventListener('submit', function (e) {
    if (e.target && e.target.querySelector) offerToSave(e.target);
  }, true);
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && e.target && e.target.type === 'password') offerToSave(e.target.form || document);
  }, true);
  var announced = false;
  function announceLogin() {
    if (announced || !document.querySelector('input[type="password"]')) return;
    announced = true;
    post({ event: 'login', host: hostOf() });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', announceLogin);
  else announceLogin();
  try { new MutationObserver(announceLogin).observe(document.documentElement, { childList: true, subtree: true }); } catch (e) { /* no observer */ }
  window.__afterglowFill = function (user, pass) {
    var lf = loginFields(document);
    if (!lf) return false;
    function set(el, v) {
      if (!el) return;
      var proto = Object.getPrototypeOf(el);
      var d = proto ? Object.getOwnPropertyDescriptor(proto, 'value') : null;
      if (d && d.set) d.set.call(el, v); else el.value = v;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    set(lf.user, user);
    set(lf.pass, pass);
    return true;
  };
  var SEL = 'a[href],button,input,select,textarea,summary,label,[role="button"],[role="link"],' +
            '[role="menuitem"],[role="tab"],[onclick],[contenteditable="true"],' +
            '[tabindex]:not([tabindex="-1"])';

  function viewport() {
    var d = document.documentElement;
    return [d.clientWidth || window.innerWidth, d.clientHeight || window.innerHeight];
  }

  // What is under a point, descending into same-origin frames. elementFromPoint stops at a
  // frame's own box, so without this every click inside an iframe landed on the iframe.
  function pick(u, v) {
    var vp = viewport();
    // A view with no size yet would make every coordinate NaN, and elementFromPoint throws on
    // those rather than returning nothing -- which would take the whole call down with it.
    if (!(vp[0] > 0) || !(vp[1] > 0)) return null;
    var x = Math.max(0, Math.min(vp[0] - 1, u * vp[0]));
    var y = Math.max(0, Math.min(vp[1] - 1, v * vp[1]));
    var offx = 0, offy = 0;
    var el = document.elementFromPoint(x, y);
    for (var depth = 0; el && el.tagName === 'IFRAME' && depth < 4; depth++) {
      var inner = null;
      try { inner = el.contentDocument; } catch (e) { inner = null; }
      if (!inner || !inner.elementFromPoint) break;
      var r = el.getBoundingClientRect();
      offx += r.left; offy += r.top;
      x -= r.left; y -= r.top;
      var next = inner.elementFromPoint(x, y);
      if (!next) break;
      el = next;
    }
    if (!el) return null;
    var act = el.closest ? el.closest(SEL) : null;
    return { el: act || el, x: x, y: y, offx: offx, offy: offy, actionable: !!act };
  }

  function overlay(id, css) {
    var e = document.getElementById(id);
    if (!e) {
      e = document.createElement('div');
      e.id = id;
      e.setAttribute('aria-hidden', 'true');
      e.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;' + css;
      (document.body || document.documentElement).appendChild(e);
    }
    return e;
  }

  // Where the gaze is and what a pinch would press, drawn into the page itself so the snapshot
  // carries them. Aiming by eye through a lens is imprecise enough without having to guess the
  // target, and a crosshair that comes back from the page is also the proof that the point the
  // scene sends and the point the page reads are the same one.
  window.__afterglowHover = function (u, v) {
    var vp = viewport();
    // A negative point means the gaze has left the window. Both marks go away, rather than
    // staying where the gaze last was, which would read as a crosshair that had stuck.
    if (u < 0 || v < 0) {
      var old = document.getElementById('__cxrDot');
      if (old) old.style.display = 'none';
      var oldBox = document.getElementById('__cxrBox');
      if (oldBox) oldBox.style.display = 'none';
      return;
    }
    var dot = overlay('__cxrDot',
      'width:14px;height:14px;margin:-7px 0 0 -7px;border-radius:50%;' +
      'background:rgba(255,63,164,.92);box-shadow:0 0 0 2px rgba(10,6,26,.8),0 0 14px #ff3fa4');
    dot.style.display = 'block';
    dot.style.left = (u * vp[0]) + 'px';
    dot.style.top = (v * vp[1]) + 'px';
    var box = overlay('__cxrBox',
      'border:3px solid #2de2e6;border-radius:5px;' +
      'box-shadow:0 0 0 2px rgba(10,6,26,.7),0 0 18px rgba(45,226,230,.7)');
    var hit = pick(u, v);
    if (!hit || !hit.actionable) { box.style.display = 'none'; return; }
    var r = hit.el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) { box.style.display = 'none'; return; }
    box.style.display = 'block';
    box.style.left = (r.left + hit.offx) + 'px';
    box.style.top = (r.top + hit.offy) + 'px';
    box.style.width = r.width + 'px';
    box.style.height = r.height + 'px';
  };

  window.__afterglowClick = function (u, v) {
    function say(hit, moved, note) {
      try {
        window.webkit.messageHandlers.afterglow.postMessage(
          { event: 'click', hit: hit, moved: !!moved, note: note || '' });
      } catch (e) { /* nothing to report to */ }
    }
    var p = pick(u, v);
    if (!p) { say('nothing', false, 'no element there'); return; }
    var t = p.el;
    var link = t.closest ? t.closest('a[href]') : null;
    var name = (t.tagName || '?').toLowerCase() + (p.actionable ? '' : ' (not actionable)');
    // Whose address bar this click is about. A link inside a frame moves that frame, so watching
    // -- and later setting -- the top page's URL would miss the navigation and then replace the
    // whole site with the frame's target.
    var win = window;
    try {
      var doc = (link || t).ownerDocument;
      if (doc && doc.defaultView) win = doc.defaultView;
    } catch (e) { win = window; }
    // Read the URL first. A click that navigates synchronously would otherwise be compared
    // against the page it had already reached and reported as having gone nowhere -- and then
    // the fallback below would follow the link a second time.
    var before = win.location.href;
    var o = { bubbles: true, cancelable: true, composed: true, clientX: p.x, clientY: p.y,
              view: window, button: 0, buttons: 1 };
    var po = Object.assign({ pointerId: 1, pointerType: 'touch', isPrimary: true,
                             width: 8, height: 8, pressure: 0.5 }, o);
    function up(base) { return Object.assign({}, base, { buttons: 0 }); }
    try {
      // Hover before pressing: a menu that opens on hover has nothing to click until it has
      // been pointed at, so the press alone did nothing on any site with a drop-down nav.
      t.dispatchEvent(new PointerEvent('pointerover', up(po)));
      t.dispatchEvent(new MouseEvent('mouseover', up(o)));
      t.dispatchEvent(new PointerEvent('pointermove', up(po)));
      t.dispatchEvent(new MouseEvent('mousemove', up(o)));
      t.dispatchEvent(new PointerEvent('pointerdown', po));
      t.dispatchEvent(new MouseEvent('mousedown', o));
      if (t.focus) t.focus({ preventScroll: true });
      t.dispatchEvent(new PointerEvent('pointerup', up(po)));
      t.dispatchEvent(new MouseEvent('mouseup', up(o)));
      t.dispatchEvent(new MouseEvent('click', up(o)));
    } catch (e) {
      say(name, false, 'events threw: ' + e);
      return;
    }
    setTimeout(function () {
      var now = before;
      try { now = win.location.href; } catch (e) { now = before; }
      if (now !== before) { say(name, true, 'the page moved'); return; }
      var href = link ? (link.getAttribute('href') || '') : '';
      // A plain link that did not take gets followed outright. A synthetic click carries
      // isTrusted false, which some handlers check, and target=_blank goes to the window
      // delegate rather than here.
      if (href && !/^javascript:/i.test(href) && href.charAt(0) !== '#') {
        say(name + ' link', true, 'followed the href');
        try { win.location.href = link.href; } catch (e) { location.href = link.href; }
        return;
      }
      var typable = /^(input|textarea)$/.test((t.tagName || '').toLowerCase()) || t.isContentEditable;
      say(name, false, typable ? 'focused a field, but there is no keyboard yet'
                     : href ? 'a link within the page' : 'nothing navigated');
    }, 80);
  };

  // Scrolls whatever is under the gaze. Most sites now put their content in an inner scroller,
  // and window.scrollBy does not move those at all -- which looked like a page that would not
  // scroll, and left every link below the fold unreachable.
  window.__afterglowScroll = function (u, v, dx, dy) {
    var p = pick(u, v);
    var node = p ? p.el : null;
    for (var depth = 0; node && depth < 12; node = node.parentElement, depth++) {
      if (node === document.body || node === document.documentElement) break;
      var style = null;
      try { style = getComputedStyle(node); } catch (e) { break; }
      var over = style.overflowY;
      if ((over === 'auto' || over === 'scroll') && node.scrollHeight > node.clientHeight + 1) {
        var was = node.scrollTop;
        node.scrollTop += dy;
        if (node.scrollTop !== was) return;
      }
    }
    window.scrollBy(dx, dy);
  };

  function tell(body) {
    try { window.webkit.messageHandlers.afterglow.postMessage(body); } catch (e) { /* no host */ }
  }

  // Which field, if any, the typing goes into -- following focus through same-origin frames,
  // since a site's search box is often in one.
  function focused() {
    var el = document.activeElement;
    for (var depth = 0; el && el.tagName === 'IFRAME' && depth < 4; depth++) {
      var inner = null;
      try { inner = el.contentDocument; } catch (e) { inner = null; }
      if (!inner) break;
      el = inner.activeElement;
    }
    if (!el) return null;
    if (el.isContentEditable) return el;
    var tag = (el.tagName || '').toLowerCase();
    if (tag === 'textarea') return el;
    // Focusable is not the same as typable: a checkbox or a button takes focus too.
    if (tag === 'input' && /^(text|search|url|email|tel|password|number|)$/i.test(el.type || ''))
      return el;
    return null;
  }

  // A page's own copy of the value is not kept in the DOM property. React and the rest track
  // changes through the property's own setter and keep their own state beside it, so a plain
  // assignment is invisible to them and gets overwritten on the next render. Going through the
  // prototype's setter is what makes the page notice it was typed into.
  function setValue(el, v) {
    var proto = (typeof HTMLTextAreaElement !== 'undefined' && el instanceof HTMLTextAreaElement)
      ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    var d = Object.getOwnPropertyDescriptor(proto, 'value');
    if (d && d.set) d.set.call(el, v); else el.value = v;
  }

  function valueOf(el) {
    return el.isContentEditable ? (el.textContent || '') : (el.value || '');
  }

  // input every keystroke, change only on commit, which is what the DOM promises and what
  // pages are written against.
  function fireInput(el, data, how) {
    try {
      el.dispatchEvent(new InputEvent('beforeinput',
        { bubbles: true, cancelable: true, data: data, inputType: how }));
    } catch (e) { /* older engines */ }
    try {
      el.dispatchEvent(new InputEvent('input', { bubbles: true, data: data, inputType: how }));
    } catch (e) {
      el.dispatchEvent(new Event('input', { bubbles: true }));
    }
  }

  function reportFocus() {
    var el = focused();
    tell({ event: 'focus', has: el ? 1 : 0,
           kind: el ? ((el.tagName || '').toLowerCase() + (el.type ? ':' + el.type : '')) : '',
           value: el ? valueOf(el) : '' });
  }
  document.addEventListener('focusin', reportFocus, true);
  // After the fact: at focusout the old element is still the active one.
  document.addEventListener('focusout', function () { setTimeout(reportFocus, 0); }, true);

  window.__afterglowType = function (text) {
    var el = focused();
    if (!el) { tell({ event: 'typed', ok: 0, note: 'nothing is focused' }); return; }
    if (el.isContentEditable) {
      // The only insert that fires an editable region's own events. The Selection API alone
      // moves the text but leaves the page unaware of it.
      var done = false;
      try { done = document.execCommand('insertText', false, text); } catch (e) { done = false; }
      if (!done) { el.textContent = (el.textContent || '') + text; fireInput(el, text, 'insertText'); }
    } else {
      var start = el.selectionStart, end = el.selectionEnd, v = el.value || '';
      if (typeof start === 'number' && typeof end === 'number') {
        setValue(el, v.slice(0, start) + text + v.slice(end));
        try { el.setSelectionRange(start + text.length, start + text.length); } catch (e) { }
      } else {
        setValue(el, v + text);
      }
      fireInput(el, text, 'insertText');
    }
    tell({ event: 'typed', ok: 1, value: valueOf(el) });
  };

  window.__afterglowKey = function (key) {
    var el = focused();
    if (!el) { tell({ event: 'key', ok: 0, note: 'nothing is focused', which: key }); return; }

    if (key === 'Backspace' || key === 'Clear') {
      if (el.isContentEditable) {
        var cmd = key === 'Clear' ? null : 'delete';
        if (cmd) { try { document.execCommand(cmd, false, null); } catch (e) { } }
        else { el.textContent = ''; fireInput(el, null, 'deleteContent'); }
      } else {
        var v = el.value || '', s = el.selectionStart, e2 = el.selectionEnd;
        if (key === 'Clear') {
          setValue(el, '');
        } else if (typeof s === 'number' && typeof e2 === 'number' && s !== e2) {
          setValue(el, v.slice(0, s) + v.slice(e2));
          try { el.setSelectionRange(s, s); } catch (e) { }
        } else if (typeof s === 'number' && s > 0) {
          setValue(el, v.slice(0, s - 1) + v.slice(s));
          try { el.setSelectionRange(s - 1, s - 1); } catch (e) { }
        } else {
          setValue(el, v.slice(0, -1));
        }
        fireInput(el, null, 'deleteContentBackward');
      }
      tell({ event: 'key', ok: 1, which: key, value: valueOf(el) });
      return;
    }

    // Enter commits. The key events go first, because a page that listens for them should get
    // its chance; if nothing came of it the form is submitted outright, since a search box
    // watching for a real keypress will not accept a synthetic one.
    var win = window;
    try {
      var doc = el.ownerDocument;
      if (doc && doc.defaultView) win = doc.defaultView;
    } catch (e) { win = window; }
    var before = win.location.href;
    ['keydown', 'keypress', 'keyup'].forEach(function (t) {
      try {
        el.dispatchEvent(new KeyboardEvent(t, { bubbles: true, cancelable: true,
          key: key, code: key, keyCode: key === 'Enter' ? 13 : 0, which: key === 'Enter' ? 13 : 0 }));
      } catch (e) { /* older engines */ }
    });
    if (key !== 'Enter') { tell({ event: 'key', ok: 1, which: key }); return; }
    el.dispatchEvent(new Event('change', { bubbles: true }));
    setTimeout(function () {
      var now = before;
      try { now = win.location.href; } catch (e) { now = before; }
      if (now !== before) { tell({ event: 'key', ok: 1, which: key, note: 'the page moved' }); return; }
      var form = el.form || (el.closest ? el.closest('form') : null);
      if (form) {
        try {
          // requestSubmit runs the page's validation and its submit handlers; submit() skips
          // both, which silently breaks any site that does its searching in one.
          if (form.requestSubmit) form.requestSubmit(); else form.submit();
          tell({ event: 'key', ok: 1, which: key, note: 'submitted the form' });
          return;
        } catch (e) { /* fall through to the report below */ }
      }
      tell({ event: 'key', ok: 1, which: key, note: form ? 'the form refused' : 'no form to submit' });
    }, 120);
  };
})();
)JS";

@interface AfterglowWebHost : NSObject <WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, assign) int pending;
// A submitted login waiting for the app to offer to keep it, and a page with a login form
// waiting for the app to offer a saved one. Read once each.
@property (nonatomic, strong) NSString *credentialHost;
@property (nonatomic, strong) NSString *credentialUser;
@property (nonatomic, strong) NSString *credentialPass;
@property (nonatomic, strong) NSString *loginHost;
// Windowed: the view lives behind Unity's, where it still renders but is never seen, and is
// snapshotted into a buffer the scene draws on a quad. Only an immersive session brings it to
// the front, because only that needs the frame rate.
@property (nonatomic, assign) BOOL windowed;
@property (nonatomic, strong) NSTimer *shots;
@property (nonatomic, assign) void *pixels;
@property (nonatomic, assign) int pixelWidth;
@property (nonatomic, assign) int pixelHeight;
@property (nonatomic, assign) BOOL freshPixels;
// Windowed, the web view sits inside this, and this is what is made almost invisible. The alpha
// cannot go on the web view itself: drawViewHierarchyInRect captures a view as displayed, so a
// nearly transparent view gives a nearly transparent snapshot.
@property (nonatomic, strong) UIView *veil;
// Whether the page has a field focused, so the keyboard knows whether it is typing into the page
// or into the address bar. Kept here because the page reports it as it changes: evaluateJavaScript
// cannot be asked for an answer on the spot, and the keyboard needs one every frame.
@property (nonatomic, assign) int focusHas;
- (void)capture;
@end

static AfterglowWebHost *g_Host = nil;

@implementation AfterglowWebHost

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    NSString *event = [message.body isKindOfClass:NSDictionary.class] ? message.body[@"event"] : nil;
    if ([event isEqualToString:@"sessionstart"]) self.pending = WebEventSessionStart;
    else if ([event isEqualToString:@"sessionend"])
    {
        self.pending = WebEventSessionEnd;
        NSString *why = [message.body isKindOfClass:NSDictionary.class] ? message.body[@"why"] : nil;
        if (why.length > 0)
            AGLog(@"[WebXR] session ended from: %@", why);
    }
    else if ([event isEqualToString:@"startpage"])
    {
        self.pending = WebEventStartPage;
        return;
    }
    else if ([event isEqualToString:@"console"])
    {
        NSDictionary *body = message.body;
        AGLog(@"[WebXR] page %@: %@", body[@"level"] ?: @"log", body[@"text"] ?: @"");
        return;
    }
    else if ([event isEqualToString:@"credentials"])
    {
        NSDictionary *body = message.body;
        self.credentialHost = body[@"host"];
        self.credentialUser = body[@"user"];
        self.credentialPass = body[@"pass"];
        AGLog(@"[WebXR] a login was submitted on %@", self.credentialHost ?: @"?");
        return;
    }
    else if ([event isEqualToString:@"login"])
    {
        NSDictionary *body = message.body;
        self.loginHost = body[@"host"];
        AGLog(@"[WebXR] login form on %@", self.loginHost ?: @"?");
        return;
    }
    else if ([event isEqualToString:@"close"]) self.pending = WebEventClose;
    else if ([event isEqualToString:@"click"])
    {
        NSDictionary *body = message.body;
        AGLog(@"[WebXR] clicked %@: %@ (%@)", body[@"hit"] ?: @"?",
              [body[@"moved"] boolValue] ? @"went somewhere" : @"stayed put",
              body[@"note"] ?: @"");
        return;
    }
    else if ([event isEqualToString:@"focus"])
    {
        NSDictionary *body = message.body;
        int has = [body[@"has"] intValue];
        if (has != self.focusHas)
            AGLog(@"[WebXR] %@", has ? [NSString stringWithFormat:@"typing goes to the page's %@",
                                        body[@"kind"] ?: @"field"]
                                    : @"no field focused; typing goes to the address bar");
        self.focusHas = has;
        return;
    }
    else if ([event isEqualToString:@"typed"] || [event isEqualToString:@"key"])
    {
        NSDictionary *body = message.body;
        if (![body[@"ok"] boolValue] || body[@"note"] != nil)
            AGLog(@"[WebXR] %@ %@: %@", event, body[@"which"] ?: @"", body[@"note"] ?: @"refused");
        return;
    }
    AGLog(@"[WebXR] page said %@", event ?: @"?");
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)nav withError:(NSError *)error
{
    AGLog(@"[WebXR] couldn't start loading: %@", error.localizedDescription);
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)nav withError:(NSError *)error
{
    AGLog(@"[WebXR] load failed partway: %@", error.localizedDescription);
}

// The app's own links on the start page (afterglow://clear-history) are commands for the app,
// not pages: they become events and never load.
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
        decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    NSURL *url = action.request.URL;
    if ([url.scheme isEqualToString:@"afterglow"])
    {
        if ([url.host isEqualToString:@"clear-history"])
            self.pending = WebEventClearHistory;
        AGLog(@"[WebXR] command %@", url.absoluteString);
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)nav
{
    AGLog(@"[WebXR] loading %@", webView.URL.absoluteString);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)nav
{
    AGLog(@"[WebXR] loaded %@ (back %@, forward %@)", webView.URL.absoluteString,
          webView.canGoBack ? @"yes" : @"no", webView.canGoForward ? @"yes" : @"no");
}

// A page asking for the motion sensors (a 360 player's look-around outside a session, say) is
// allowed: WebKit asks the app and, unanswered, refuses with "Permission was denied". The
// sensors are the phone's own, which the app already reads; nothing leaves the phone.
- (void)webView:(WKWebView *)webView
    requestDeviceOrientationAndMotionPermissionForOrigin:(WKSecurityOrigin *)origin
    initiatedByFrame:(WKFrameInfo *)frame
    decisionHandler:(void (^)(WKPermissionDecision))decisionHandler API_AVAILABLE(ios(15.0))
{
    AGLog(@"[WebXR] %@ asked for the motion sensors: allowed", origin.host);
    decisionHandler(WKPermissionDecisionGrant);
}

// A link asking for a new window gets this one: there are no tabs here, and without this a
// target=_blank link is simply dropped, which is one of the ways a page "didn't navigate".
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)action
                    windowFeatures:(WKWindowFeatures *)features
{
    if (action.targetFrame == nil || !action.targetFrame.isMainFrame)
    {
        AGLog(@"[WebXR] a link wanted a new window; following it here: %@",
              action.request.URL.absoluteString);
        [webView loadRequest:action.request];
    }
    return nil;
}

// Nobody can reach a system dialog from inside a viewer, and WKWebView stops the page's
// JavaScript until one is answered -- so an alert() would wedge the page for good.
- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler
{
    AGLog(@"[WebXR] page alert, dismissed: %@", message);
    completionHandler();
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler
{
    AGLog(@"[WebXR] page confirm, accepted: %@", message);
    completionHandler(YES);
}

- (void)webView:(WKWebView *)webView
    runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
                              defaultText:(NSString *)defaultText
                         initiatedByFrame:(WKFrameInfo *)frame
                        completionHandler:(void (^)(NSString *))completionHandler
{
    AGLog(@"[WebXR] page prompt, cancelled: %@", prompt);
    completionHandler(nil);
}

// Draws the page into a tightly packed BGRA buffer, which is what Unity's BGRA32 wants. Takes
// about as long as a page is complicated; at a dozen a second that is affordable, and a page being
// read does not need more. afterScreenUpdates is NO because YES forces a layout pass per frame and
// costs several times as much for a picture that is one frame staler.
- (void)capture
{
    WKWebView *web = self.web;
    if (web == nil || self.pixels == NULL || !self.windowed)
        return;

    const size_t w = (size_t)self.pixelWidth, h = (size_t)self.pixelHeight;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(self.pixels, w, h, 8, w * 4, space,
                                                 kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (context == NULL)
        return;

    // Unity's textures start at the bottom row and UIKit draws from the top.
    CGContextTranslateCTM(context, 0, h);
    CGContextScaleCTM(context, 1, -1);
    const CGFloat scale = w / MAX(web.bounds.size.width, (CGFloat)1);
    CGContextScaleCTM(context, scale, scale);

    UIGraphicsPushContext(context);
    [web drawViewHierarchyInRect:web.bounds afterScreenUpdates:NO];
    UIGraphicsPopContext();
    CGContextRelease(context);
    self.freshPixels = YES;

    // Whether anything was actually drawn. drawViewHierarchyInRect is the usual way to capture a
    // view that is not the one on screen, but it can come back empty, and an empty buffer and a
    // page that happens to be white look identical from Unity's side.
    static int reported = 0;
    if (reported < 3)
    {
        reported++;
        const unsigned char *px = (const unsigned char *)self.pixels;
        unsigned long lit = 0;
        const size_t step = (w * h) / 4000 + 1;
        size_t looked = 0;
        for (size_t i = 0; i < w * h; i += step, looked++)
            if (px[i * 4] || px[i * 4 + 1] || px[i * 4 + 2]) lit++;
        AGLog(@"[WebXR] Snapshot %zux%zu: %lu of %zu sampled pixels have colour", w, h, lit, looked);
    }
}

@end

// Opens `url` over Unity's view, with `configJson` and `shim` injected into every page it loads.
// Returns 1 if the view went up.
extern "C" int Afterglow_WebOpen(const char *url, const char *configJson, const char *shim,
                                   int windowed, int pixelWidth, int pixelHeight)
{
    if (url == nullptr || configJson == nullptr || shim == nullptr)
        return 0;
    if (g_Host != nil)
        return 1;

    UIViewController *root = UnityGetGLViewController();
    if (root == nil)
    {
        AGLog(@"[WebXR] no view controller to attach to");
        return 0;
    }

    NSURL *target = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
    if (target == nil)
    {
        AGLog(@"[WebXR] not a URL: %s", url);
        return 0;
    }

    AfterglowWebHost *host = [AfterglowWebHost new];

    WKUserContentController *content = [WKUserContentController new];
    [content addScriptMessageHandler:host name:@"afterglow"];
    // The config first, then the shim, both before the page's own scripts: a page that looks for
    // navigator.xr on load has to find it already there.
    NSString *config = [NSString stringWithFormat:@"window.__afterglowConfig = %s;",
                        configJson];
    [content addUserScript:[[WKUserScript alloc] initWithSource:config
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:NO]];
    [content addUserScript:[[WKUserScript alloc] initWithSource:[NSString stringWithUTF8String:shim]
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:NO]];
    // Pointing, clicking and scrolling. Main frame only: they reach into child frames themselves,
    // and evaluateJavaScript runs in the main frame.
    [content addUserScript:[[WKUserScript alloc] initWithSource:[NSString stringWithUTF8String:kHelperSource]
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:YES]];

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.userContentController = content;
    configuration.allowsInlineMediaPlayback = YES;
    configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;

    // Windowed, the view is laid out at the texture's size in points and drawn at 1x, so what the
    // page lays out for is what the scene shows; the shell's bounds would give a page shaped like
    // the phone, which is not the shape of a window you hang in a room.
    const CGRect frame = windowed != 0
        ? CGRectMake(0, 0, pixelWidth, pixelHeight)
        : root.view.bounds;
    WKWebView *web = [[WKWebView alloc] initWithFrame:frame configuration:configuration];
    web.navigationDelegate = host;
    web.UIDelegate = host;
    // Never resized by its parent: the page's size is its own (see Afterglow_WebSetWindowed).
    web.autoresizingMask = UIViewAutoresizingNone;
    web.opaque = YES;
    web.backgroundColor = UIColor.blackColor;
    web.scrollView.bounces = NO;
    // Left enabled on purpose. A disabled scroll view also refuses window.scrollBy, so the page
    // could not be scrolled at all and every link below the fold was out of reach. Nothing can
    // touch it by hand anyway: windowed, it sits inside a veil that takes no interaction.
    web.scrollView.scrollEnabled = YES;
    web.scrollView.showsVerticalScrollIndicator = NO;
    web.scrollView.showsHorizontalScrollIndicator = NO;
    if (@available(iOS 11.0, *))
        web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;

    host.web = web;
    host.windowed = windowed != 0;
    g_Host = host;
    if (host.windowed)
    {
        host.pixelWidth = pixelWidth;
        host.pixelHeight = pixelHeight;
        host.pixels = calloc((size_t)pixelWidth * pixelHeight, 4);
        // Unity draws into the view controller's own view, not a subview of it, so a subview is
        // always on top however low its index -- putting the page at index 0 did not hide it, it
        // just covered the app. It has to be made invisible rather than placed behind.
        //
        // A hidden view, or one at alpha 0, stops being drawn at all and snapshots empty; one
        // moved offscreen is throttled. So it keeps its own alpha and sits in a veil that has
        // almost none, which UIKit still renders and nobody can see.
        UIView *veil = [[UIView alloc] initWithFrame:frame];
        veil.alpha = 0.01;
        veil.userInteractionEnabled = NO;   // taps belong to the app, not the hidden page
        [veil addSubview:web];
        host.veil = veil;
        [root.view addSubview:veil];
        host.shots = [NSTimer scheduledTimerWithTimeInterval:1.0 / 12.0 repeats:YES
                                                     block:^(NSTimer *t) { [host capture]; }];
        AGLog(@"[WebXR] Windowed: page %dx%d behind a veil, snapshotting at 12 Hz", pixelWidth, pixelHeight);
    }
    else
    {
        [root.view addSubview:web];
        AGLog(@"[WebXR] Full screen over the app");
    }
    if (target.isFileURL)
    {
        // WKWebView refuses a file: URL given to loadRequest: it needs to be told which directory
        // the page may read from. The start page lives in StreamingAssets beside its own script.
        [web loadFileURL:target allowingReadAccessToURL:[target URLByDeletingLastPathComponent]];
    }
    else
    {
        [web loadRequest:[NSURLRequest requestWithURL:target]];
    }
    AGLog(@"[WebXR] opened %@", target.absoluteString);
    return 1;
}

extern "C" void Afterglow_WebClose()
{
    if (g_Host == nil)
        return;
    [g_Host.shots invalidate];
    g_Host.shots = nil;
    if (g_Host.pixels != NULL)
    {
        free(g_Host.pixels);
        g_Host.pixels = NULL;
    }
    WKWebView *web = g_Host.web;
    [web.configuration.userContentController removeScriptMessageHandlerForName:@"afterglow"];
    [web stopLoading];
    [web removeFromSuperview];
    [g_Host.veil removeFromSuperview];
    g_Host.veil = nil;
    g_Host.web = nil;
    g_Host = nil;
    AGLog(@"[WebXR] closed");
}

extern "C" int Afterglow_WebIsOpen() { return g_Host != nil ? 1 : 0; }

// The head pose, pushed in rather than read out: the app's fusion is better than anything the page
// could get for itself, and WKWebView cannot be asked synchronously.
extern "C" void Afterglow_WebPose(float px, float py, float pz, float qx, float qy, float qz, float qw)
{
    if (g_Host == nil || g_Host.web == nil)
        return;
    NSString *call = [NSString stringWithFormat:
        @"window.__afterglowPose&&window.__afterglowPose(%.5f,%.5f,%.5f,%.6f,%.6f,%.6f,%.6f)",
        px, py, pz, qx, qy, qz, qw];
    [g_Host.web evaluateJavaScript:call completionHandler:nil];
}

extern "C" void Afterglow_WebSelect()
{
    if (g_Host == nil || g_Host.web == nil)
        return;
    [g_Host.web evaluateJavaScript:@"window.__afterglowSelect&&window.__afterglowSelect()"
                 completionHandler:nil];
}

// Whatever the page last said, cleared as it is read.
extern "C" int Afterglow_WebTakeEvent()
{
    if (g_Host == nil)
        return WebEventNone;
    int event = g_Host.pending;
    g_Host.pending = WebEventNone;
    return event;
}

// The latest picture of the page, as tightly packed BGRA rows starting at the bottom. Returns 0
// when there is nothing new, so Unity only uploads a texture when the page has actually changed.
extern "C" int Afterglow_WebPixels(void **bytes, int *width, int *height)
{
    if (g_Host == nil || !g_Host.windowed || g_Host.pixels == NULL || !g_Host.freshPixels)
        return 0;
    g_Host.freshPixels = NO;
    if (bytes != nullptr) *bytes = g_Host.pixels;
    if (width != nullptr) *width = g_Host.pixelWidth;
    if (height != nullptr) *height = g_Host.pixelHeight;
    return 1;
}

// A click at a point on the page, given where the gaze met the window: 0-1 across and down, with
// the origin at the top left as the page sees it.
//
// Synthesised rather than a real touch, because UIKit has no public way to inject one. The work is
// in kHelperSource above; all this does is name the point.
extern "C" void Afterglow_WebClickAt(float u, float v)
{
    if (g_Host == nil || g_Host.web == nil)
        return;
    NSString *js = [NSString stringWithFormat:@"window.__afterglowClick&&window.__afterglowClick(%.5f,%.5f)", u, v];
    [g_Host.web evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
        if (error != nil)
            AGLog(@"[WebXR] click script failed: %@", error.localizedDescription);
    }];
}

// Draws the crosshair and outlines whatever a click would land on. Called a dozen times a second
// while the gaze is on the window, which is as often as the snapshot that carries it.
extern "C" void Afterglow_WebHoverAt(float u, float v)
{
    if (g_Host == nil || g_Host.web == nil || !g_Host.windowed)
        return;
    NSString *js = [NSString stringWithFormat:@"window.__afterglowHover&&window.__afterglowHover(%.5f,%.5f)", u, v];
    [g_Host.web evaluateJavaScript:js completionHandler:nil];
}

// Scrolls what is under the point rather than always the window, so pages that put their content
// in an inner scroller move too.
extern "C" void Afterglow_WebScrollAt(float u, float v, float dx, float dy)
{
    if (g_Host == nil || g_Host.web == nil)
        return;
    NSString *js = [NSString stringWithFormat:
        @"window.__afterglowScroll&&window.__afterglowScroll(%.5f,%.5f,%.2f,%.2f)", u, v, dx, dy];
    [g_Host.web evaluateJavaScript:js completionHandler:nil];
}

extern "C" void Afterglow_WebGoBack()
{
    if (g_Host != nil && g_Host.web != nil && g_Host.web.canGoBack)
        [g_Host.web goBack];
}

extern "C" void Afterglow_WebGoForward()
{
    if (g_Host != nil && g_Host.web != nil && g_Host.web.canGoForward)
        [g_Host.web goForward];
}

extern "C" void Afterglow_WebReload()
{
    if (g_Host != nil && g_Host.web != nil)
        [g_Host.web reload];
}

// A JavaScript string literal for arbitrary typed text. Hand-rolled escaping is where injection
// bugs live, so this goes through the JSON writer and then fixes the one place the two formats
// disagree: U+2028 and U+2029 are ordinary characters in JSON and line terminators in JavaScript,
// so a literal containing them would not parse.
static NSString *JsString(NSString *text)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[text ?: @""] options:0 error:nil];
    NSString *wrapped = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *literal = wrapped.length >= 4
        ? [wrapped substringWithRange:NSMakeRange(1, wrapped.length - 2)]
        : @"\"\"";
    literal = [literal stringByReplacingOccurrencesOfString:@" " withString:@"\\u2028"];
    return [literal stringByReplacingOccurrencesOfString:@" " withString:@"\\u2029"];
}

// Types text into whatever field the page has focused.
extern "C" void Afterglow_WebType(const char *text)
{
    if (g_Host == nil || g_Host.web == nil || text == nullptr)
        return;
    NSString *js = [NSString stringWithFormat:@"window.__afterglowType&&window.__afterglowType(%@)",
                    JsString([NSString stringWithUTF8String:text])];
    [g_Host.web evaluateJavaScript:js completionHandler:nil];
}

// Backspace, Clear or Enter, which commits.
extern "C" void Afterglow_WebKey(const char *key)
{
    if (g_Host == nil || g_Host.web == nil || key == nullptr)
        return;
    NSString *js = [NSString stringWithFormat:@"window.__afterglowKey&&window.__afterglowKey(%@)",
                    JsString([NSString stringWithUTF8String:key])];
    [g_Host.web evaluateJavaScript:js completionHandler:nil];
}

// Whether the page has a field focused, so the keyboard can say where the typing is going.
extern "C" int Afterglow_WebTextFocused()
{
    return g_Host != nil ? g_Host.focusHas : 0;
}

namespace
{
    // Copies a string into a buffer, emptying it when there's nothing.
    void CopyOut(NSString *value, char *buffer, int capacity)
    {
        if (buffer == nullptr || capacity <= 0)
            return;
        strlcpy(buffer, value != nil ? value.UTF8String : "", (size_t)capacity);
    }
}

// A login the page just submitted, once: 1 with the host, username and password, 0 if none.
extern "C" int Afterglow_WebTakeCredential(char *host, int hostLength, char *user, int userLength, char *pass, int passLength)
{
    if (g_Host == nil || g_Host.credentialHost == nil)
        return 0;
    CopyOut(g_Host.credentialHost, host, hostLength);
    CopyOut(g_Host.credentialUser, user, userLength);
    CopyOut(g_Host.credentialPass, pass, passLength);
    g_Host.credentialHost = nil;
    g_Host.credentialUser = nil;
    g_Host.credentialPass = nil;
    return 1;
}

// The host of a page that showed a login form, once: 1 with it, 0 if none.
extern "C" int Afterglow_WebTakeLoginHost(char *host, int hostLength)
{
    if (g_Host == nil || g_Host.loginHost == nil)
        return 0;
    CopyOut(g_Host.loginHost, host, hostLength);
    g_Host.loginHost = nil;
    return 1;
}

// Puts a saved login into the page's form.
extern "C" void Afterglow_WebFill(const char *user, const char *pass)
{
    if (g_Host == nil || g_Host.web == nil || user == nullptr || pass == nullptr)
        return;
    NSString *js = [NSString stringWithFormat:@"window.__afterglowFill&&window.__afterglowFill(%@,%@)",
                    JsString([NSString stringWithUTF8String:user]), JsString([NSString stringWithUTF8String:pass])];
    [g_Host.web evaluateJavaScript:js completionHandler:nil];
}

// Runs a script in the page (the start page takes its bookmarks and history this way).
extern "C" void Afterglow_WebRunScript(const char *script)
{
    if (g_Host == nil || g_Host.web == nil || script == nullptr)
        return;
    NSString *js = [NSString stringWithUTF8String:script];
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_Host.web evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
            if (error != nil)
                AGLog(@"[WebXR] script failed: %@", error.localizedDescription);
        }];
    });
}

extern "C" void Afterglow_WebLoadUrl(const char *url)
{
    if (g_Host == nil || g_Host.web == nil || url == nullptr)
        return;
    NSURL *target = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
    if (target == nil)
    {
        AGLog(@"[WebXR] not a URL: %s", url);
        return;
    }
    g_Host.focusHas = 0;
    [g_Host.web loadRequest:[NSURLRequest requestWithURL:target]];
    AGLog(@"[WebXR] going to %@", target.absoluteString);
}

// The current address, for the bar to show. Returns the length written, or what it would have
// needed if the buffer was too small.
extern "C" int Afterglow_WebCopyUrl(char *buffer, int capacity)
{
    if (g_Host == nil || g_Host.web == nil)
        return 0;
    NSString *url = g_Host.web.URL.absoluteString ?: @"";
    const char *utf8 = url.UTF8String;
    if (utf8 == NULL)
        return 0;
    const int length = (int)strlen(utf8);
    if (buffer != nullptr && capacity > 0)
    {
        const int room = length < capacity - 1 ? length : capacity - 1;
        memcpy(buffer, utf8, (size_t)room);
        buffer[room] = '\0';
    }
    return length;
}

// The page's title, for its tab, the same way.
extern "C" int Afterglow_WebCopyTitle(char *buffer, int capacity)
{
    if (g_Host == nil || g_Host.web == nil)
        return 0;
    NSString *title = g_Host.web.title ?: @"";
    const char *utf8 = title.UTF8String;
    if (utf8 == NULL)
        return 0;
    const int length = (int)strlen(utf8);
    if (buffer != nullptr && capacity > 0)
    {
        const int room = length < capacity - 1 ? length : capacity - 1;
        memcpy(buffer, utf8, (size_t)room);
        buffer[room] = '\0';
    }
    return length;
}

// An immersive session needs the frame rate a snapshot cannot give, so the view comes to the
// front and the scene stops drawing it on a quad. Ending the session puts it back.
extern "C" void Afterglow_WebSetWindowed(int windowed)
{
    if (g_Host == nil || g_Host.web == nil || g_Host.windowed == (windowed != 0))
        return;
    UIViewController *root = UnityGetGLViewController();
    g_Host.windowed = windowed != 0;
    // The web view never moves between superviews and never changes size: it lives inside its
    // veil from the start, laid out at the page's own size, and the veil is what changes. For
    // a session the veil is scaled onto the screen and shown; windowed, it sits at the page's
    // size, all but invisible, and the page is snapshotted from it. Resizing the web view, or
    // moving it to another view, reached the page as a window resize, and a page that rebuilds
    // its renderer on resize (a 360 player did) ended its session a third of a second in.
    const CGRect page = CGRectMake(0, 0, g_Host.pixelWidth, g_Host.pixelHeight);
    if (g_Host.veil == nil)
    {
        UIView *veil = [[UIView alloc] initWithFrame:page];
        veil.userInteractionEnabled = NO;
        veil.backgroundColor = UIColor.blackColor;
        g_Host.veil = veil;
        [veil addSubview:g_Host.web];
        [root.view addSubview:veil];
    }
    if (g_Host.web.superview != g_Host.veil)
        [g_Host.veil addSubview:g_Host.web];
    if (g_Host.veil.superview != root.view)
        [root.view addSubview:g_Host.veil];
    g_Host.web.frame = page;
    if (g_Host.windowed)
    {
        g_Host.veil.transform = CGAffineTransformIdentity;
        g_Host.veil.frame = page;
        g_Host.veil.alpha = 0.01;
    }
    else
    {
        const CGRect screen = root.view.bounds;
        g_Host.veil.transform = CGAffineTransformIdentity;
        g_Host.veil.frame = page;
        g_Host.veil.transform = CGAffineTransformMakeScale(screen.size.width / page.size.width,
                                                           screen.size.height / page.size.height);
        g_Host.veil.center = CGPointMake(CGRectGetMidX(screen), CGRectGetMidY(screen));
        g_Host.veil.alpha = 1.0;
        [root.view bringSubviewToFront:g_Host.veil];
    }
    AGLog(@"[WebXR] %@", g_Host.windowed ? @"back to a window in the scene" : @"full screen for an immersive session, the page kept at its size and in its view");
}
