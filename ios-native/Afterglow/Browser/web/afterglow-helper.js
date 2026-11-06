// The browser helper script, injected at document start into the main frame. Extracted verbatim
// from the Unity app's Assets/Plugins/iOS/AfterglowWebXR.mm (kHelperSource); keep the two the same.

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

  // Video stays in the page. An iPhone hands any <video> without the playsinline attribute to
  // its own full-screen player the moment it plays: a view over the whole window that hides the
  // stereo output, the page's own controls and the app's menu button alike, and leaves a
  // WebGL scene drawing to a texture nobody can see. A page that draws video into a sphere
  // never wants that, and a flat page is a window in the scene, so every video is marked inline
  // before it can play and the player's own entry point does nothing.
  (function () {
    function inline(v) {
      if (!v || v.tagName !== 'VIDEO' || v.hasAttribute('playsinline')) return;
      v.setAttribute('playsinline', '');
      v.setAttribute('webkit-playsinline', '');
      post({ event: 'console', level: 'log', text: '[Afterglow] video kept inline' });
    }
    function sweep(root) {
      if (!root) return;
      if (root.tagName === 'VIDEO') inline(root);
      if (!root.querySelectorAll) return;
      var vs = root.querySelectorAll('video');
      for (var i = 0; i < vs.length; i++) inline(vs[i]);
    }
    try {
      var play = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () { inline(this); return play.apply(this, arguments); };
    } catch (e) { /* no media */ }
    try {
      if (HTMLVideoElement.prototype.webkitEnterFullscreen) {
        HTMLVideoElement.prototype.webkitEnterFullscreen = function () {
          post({ event: 'console', level: 'log', text: '[Afterglow] video asked for the native player: refused' });
        };
      }
    } catch (e) { /* no video */ }
    try {
      new MutationObserver(function (ms) {
        for (var i = 0; i < ms.length; i++) {
          var added = ms[i].addedNodes;
          for (var j = 0; j < added.length; j++) sweep(added[j]);
        }
      }).observe(document.documentElement, { childList: true, subtree: true });
    } catch (e) { /* no observer */ }
    document.addEventListener('webkitbeginfullscreen', function () {
      post({ event: 'console', level: 'warn', text: '[Afterglow] a video went to the native player anyway' });
    }, true);
    sweep(document);
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
  // A sign-in that never submits a form: a button's click handler sends the request itself, as a
  // single-page app's does. A click on any button-like thing while a password field holds a
  // value is taken as the sign-in, and so is the page going away or the field being removed
  // with a value still in it.
  var lastLogin = null;
  function rememberLogin() {
    var lf = loginFields(document);
    if (lf && lf.pass.value) lastLogin = { host: hostOf(), user: lf.user ? lf.user.value : '', pass: lf.pass.value };
  }
  document.addEventListener('input', function (e) {
    if (e.target && (e.target.type === 'password' || (e.target.form && e.target.form.querySelector('input[type="password"]')))) rememberLogin();
  }, true);
  document.addEventListener('click', function (e) {
    var t = e.target && e.target.closest ? e.target.closest('button,[type="submit"],[role="button"],a') : null;
    if (!t) return;
    var lf = loginFields(document);
    if (lf && lf.pass.value) offerToSave(lf.pass.form || document);
  }, true);
  function offerLast() {
    if (!lastLogin) return;
    var sent = lastLogin;
    lastLogin = null;
    post({ event: 'credentials', host: sent.host, user: sent.user, pass: sent.pass });
  }
  window.addEventListener('pagehide', offerLast);
  try {
    new MutationObserver(function () {
      if (lastLogin && !document.querySelector('input[type="password"]')) offerLast();
    }).observe(document.documentElement, { childList: true, subtree: true });
  } catch (e) { /* no observer */ }
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
    // A saved password with no username leaves whatever username field there is alone.
    if (user) set(lf.user, user);
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
    moveMouse(hit, u * vp[0], v * vp[1]);
    report(hit, dot);
    if (!hit || !hit.actionable) { box.style.display = 'none'; return; }
    var r = hit.el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) { box.style.display = 'none'; return; }
    box.style.display = 'block';
    box.style.left = (r.left + hit.offx) + 'px';
    box.style.top = (r.top + hit.offy) + 'px';
    box.style.width = r.width + 'px';
    box.style.height = r.height + 'px';
  };

  // The gaze is the page's mouse: pointer and mouse moves go to what is under it, with over and
  // out as it crosses from one element to another. A video player hides its control bar two
  // seconds after the mouse last moved and takes the next click on the canvas beneath, so a
  // gaze that never "moved" could not press the bar's buttons once a video played.
  var hoverEl = null, hoverAt = 0;
  function moveMouse(hit, x, y) {
    var el = hit ? hit.el : null;
    var now = Date.now();
    if (el === hoverEl && now - hoverAt < 100) return;
    hoverAt = now;
    var o = { bubbles: true, cancelable: true, composed: true, clientX: hit ? hit.x : x, clientY: hit ? hit.y : y,
              view: window, button: 0, buttons: 0 };
    var po = Object.assign({ pointerId: 1, pointerType: 'mouse', isPrimary: true }, o);
    try {
      if (el !== hoverEl) {
        if (hoverEl) {
          hoverEl.dispatchEvent(new PointerEvent('pointerout', Object.assign({}, po, { relatedTarget: el })));
          hoverEl.dispatchEvent(new MouseEvent('mouseout', Object.assign({}, o, { relatedTarget: el })));
        }
        if (el) {
          el.dispatchEvent(new PointerEvent('pointerover', Object.assign({}, po, { relatedTarget: hoverEl })));
          el.dispatchEvent(new MouseEvent('mouseover', Object.assign({}, o, { relatedTarget: hoverEl })));
        }
        hoverEl = el;
      }
      if (el) {
        el.dispatchEvent(new PointerEvent('pointermove', po));
        el.dispatchEvent(new MouseEvent('mousemove', o));
      }
    } catch (e) { /* a page that refuses synthetic events still gets the click */ }
  }

  // What is under the gaze, and whether the page has put something over the app's own dot,
  // said once per change in the log: the way to see why a button can't be pressed.
  var reportedEl = null, reportedCovered = '';
  function describe(el) {
    if (!el) return 'nothing';
    var d = (el.tagName || '?').toLowerCase();
    if (el.id) d += '#' + el.id;
    var c = typeof el.className === 'string' ? el.className.trim().split(/\s+/).slice(0, 3).join('.') : '';
    if (c) d += '.' + c;
    return d;
  }
  function report(hit, dot) {
    var el = hit ? hit.el : null;
    var covered = '';
    try {
      dot.style.pointerEvents = 'auto';
      var top = document.elementFromPoint(parseFloat(dot.style.left), parseFloat(dot.style.top));
      dot.style.pointerEvents = 'none';
      if (top && top !== dot) covered = describe(top);
    } catch (e) { dot.style.pointerEvents = 'none'; }
    if (el === reportedEl && covered === reportedCovered) return;
    reportedEl = el; reportedCovered = covered;
    post({ event: 'console', level: 'log', text: '[Afterglow] under the gaze: ' + describe(el) +
      (hit && hit.actionable ? ' (actionable)' : '') + (covered ? '; the dot is covered by ' + covered : '') });
  }

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
