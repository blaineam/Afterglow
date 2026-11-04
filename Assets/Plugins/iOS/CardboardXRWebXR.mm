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

extern "C" UIViewController *UnityGetGLViewController();

// What the page has told us, picked up by C# on its own thread.
enum WebEvent { WebEventNone = 0, WebEventSessionStart = 1, WebEventSessionEnd = 2, WebEventClose = 3 };

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
  window.__cardboardxrHover = function (u, v) {
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

  window.__cardboardxrClick = function (u, v) {
    function say(hit, moved, note) {
      try {
        window.webkit.messageHandlers.cardboardxr.postMessage(
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
  window.__cardboardxrScroll = function (u, v, dx, dy) {
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
})();
)JS";

@interface CardboardXRWebHost : NSObject <WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, assign) int pending;
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
- (void)capture;
@end

static CardboardXRWebHost *g_Host = nil;

@implementation CardboardXRWebHost

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    NSString *event = [message.body isKindOfClass:NSDictionary.class] ? message.body[@"event"] : nil;
    if ([event isEqualToString:@"sessionstart"]) self.pending = WebEventSessionStart;
    else if ([event isEqualToString:@"sessionend"]) self.pending = WebEventSessionEnd;
    else if ([event isEqualToString:@"close"]) self.pending = WebEventClose;
    else if ([event isEqualToString:@"click"])
    {
        NSDictionary *body = message.body;
        NSLog(@"[WebXR] clicked %@: %@ (%@)", body[@"hit"] ?: @"?",
              [body[@"moved"] boolValue] ? @"went somewhere" : @"stayed put",
              body[@"note"] ?: @"");
        return;
    }
    NSLog(@"[WebXR] page said %@", event ?: @"?");
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)nav withError:(NSError *)error
{
    NSLog(@"[WebXR] couldn't start loading: %@", error.localizedDescription);
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)nav withError:(NSError *)error
{
    NSLog(@"[WebXR] load failed partway: %@", error.localizedDescription);
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)nav
{
    NSLog(@"[WebXR] loading %@", webView.URL.absoluteString);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)nav
{
    NSLog(@"[WebXR] loaded %@ (back %@, forward %@)", webView.URL.absoluteString,
          webView.canGoBack ? @"yes" : @"no", webView.canGoForward ? @"yes" : @"no");
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
        NSLog(@"[WebXR] a link wanted a new window; following it here: %@",
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
    NSLog(@"[WebXR] page alert, dismissed: %@", message);
    completionHandler();
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler
{
    NSLog(@"[WebXR] page confirm, accepted: %@", message);
    completionHandler(YES);
}

- (void)webView:(WKWebView *)webView
    runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
                              defaultText:(NSString *)defaultText
                         initiatedByFrame:(WKFrameInfo *)frame
                        completionHandler:(void (^)(NSString *))completionHandler
{
    NSLog(@"[WebXR] page prompt, cancelled: %@", prompt);
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
        NSLog(@"[WebXR] Snapshot %zux%zu: %lu of %zu sampled pixels have colour", w, h, lit, looked);
    }
}

@end

// Opens `url` over Unity's view, with `configJson` and `shim` injected into every page it loads.
// Returns 1 if the view went up.
extern "C" int CardboardXR_WebOpen(const char *url, const char *configJson, const char *shim,
                                   int windowed, int pixelWidth, int pixelHeight)
{
    if (url == nullptr || configJson == nullptr || shim == nullptr)
        return 0;
    if (g_Host != nil)
        return 1;

    UIViewController *root = UnityGetGLViewController();
    if (root == nil)
    {
        NSLog(@"[WebXR] no view controller to attach to");
        return 0;
    }

    NSURL *target = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
    if (target == nil)
    {
        NSLog(@"[WebXR] not a URL: %s", url);
        return 0;
    }

    CardboardXRWebHost *host = [CardboardXRWebHost new];

    WKUserContentController *content = [WKUserContentController new];
    [content addScriptMessageHandler:host name:@"cardboardxr"];
    // The config first, then the shim, both before the page's own scripts: a page that looks for
    // navigator.xr on load has to find it already there.
    NSString *config = [NSString stringWithFormat:@"window.__cardboardxrConfig = %s;",
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
    web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
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
        NSLog(@"[WebXR] Windowed: page %dx%d behind a veil, snapshotting at 12 Hz", pixelWidth, pixelHeight);
    }
    else
    {
        [root.view addSubview:web];
        NSLog(@"[WebXR] Full screen over the app");
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
    NSLog(@"[WebXR] opened %@", target.absoluteString);
    return 1;
}

extern "C" void CardboardXR_WebClose()
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
    [web.configuration.userContentController removeScriptMessageHandlerForName:@"cardboardxr"];
    [web stopLoading];
    [web removeFromSuperview];
    [g_Host.veil removeFromSuperview];
    g_Host.veil = nil;
    g_Host.web = nil;
    g_Host = nil;
    NSLog(@"[WebXR] closed");
}

extern "C" int CardboardXR_WebIsOpen() { return g_Host != nil ? 1 : 0; }

// The head pose, pushed in rather than read out: the app's fusion is better than anything the page
// could get for itself, and WKWebView cannot be asked synchronously.
extern "C" void CardboardXR_WebPose(float px, float py, float pz, float qx, float qy, float qz, float qw)
{
    if (g_Host == nil || g_Host.web == nil)
        return;
    NSString *call = [NSString stringWithFormat:
        @"window.__cardboardxrPose&&window.__cardboardxrPose(%.5f,%.5f,%.5f,%.6f,%.6f,%.6f,%.6f)",
        px, py, pz, qx, qy, qz, qw];
    [g_Host.web evaluateJavaScript:call completionHandler:nil];
}

extern "C" void CardboardXR_WebSelect()
{
    if (g_Host == nil || g_Host.web == nil)
        return;
    [g_Host.web evaluateJavaScript:@"window.__cardboardxrSelect&&window.__cardboardxrSelect()"
                 completionHandler:nil];
}

// Whatever the page last said, cleared as it is read.
extern "C" int CardboardXR_WebTakeEvent()
{
    if (g_Host == nil)
        return WebEventNone;
    int event = g_Host.pending;
    g_Host.pending = WebEventNone;
    return event;
}

// The latest picture of the page, as tightly packed BGRA rows starting at the bottom. Returns 0
// when there is nothing new, so Unity only uploads a texture when the page has actually changed.
extern "C" int CardboardXR_WebPixels(void **bytes, int *width, int *height)
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
extern "C" void CardboardXR_WebClickAt(float u, float v)
{
    if (g_Host == nil || g_Host.web == nil)
        return;
    NSString *js = [NSString stringWithFormat:@"window.__cardboardxrClick&&window.__cardboardxrClick(%.5f,%.5f)", u, v];
    [g_Host.web evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
        if (error != nil)
            NSLog(@"[WebXR] click script failed: %@", error.localizedDescription);
    }];
}

// Draws the crosshair and outlines whatever a click would land on. Called a dozen times a second
// while the gaze is on the window, which is as often as the snapshot that carries it.
extern "C" void CardboardXR_WebHoverAt(float u, float v)
{
    if (g_Host == nil || g_Host.web == nil || !g_Host.windowed)
        return;
    NSString *js = [NSString stringWithFormat:@"window.__cardboardxrHover&&window.__cardboardxrHover(%.5f,%.5f)", u, v];
    [g_Host.web evaluateJavaScript:js completionHandler:nil];
}

// Scrolls what is under the point rather than always the window, so pages that put their content
// in an inner scroller move too.
extern "C" void CardboardXR_WebScrollAt(float u, float v, float dx, float dy)
{
    if (g_Host == nil || g_Host.web == nil)
        return;
    NSString *js = [NSString stringWithFormat:
        @"window.__cardboardxrScroll&&window.__cardboardxrScroll(%.5f,%.5f,%.2f,%.2f)", u, v, dx, dy];
    [g_Host.web evaluateJavaScript:js completionHandler:nil];
}

extern "C" void CardboardXR_WebGoBack()
{
    if (g_Host != nil && g_Host.web != nil && g_Host.web.canGoBack)
        [g_Host.web goBack];
}

extern "C" void CardboardXR_WebGoForward()
{
    if (g_Host != nil && g_Host.web != nil && g_Host.web.canGoForward)
        [g_Host.web goForward];
}

extern "C" void CardboardXR_WebReload()
{
    if (g_Host != nil && g_Host.web != nil)
        [g_Host.web reload];
}

// An immersive session needs the frame rate a snapshot cannot give, so the view comes to the
// front and the scene stops drawing it on a quad. Ending the session puts it back.
extern "C" void CardboardXR_WebSetWindowed(int windowed)
{
    if (g_Host == nil || g_Host.web == nil || g_Host.windowed == (windowed != 0))
        return;
    UIViewController *root = UnityGetGLViewController();
    g_Host.windowed = windowed != 0;
    if (g_Host.windowed)
    {
        g_Host.web.frame = CGRectMake(0, 0, g_Host.pixelWidth, g_Host.pixelHeight);
        if (g_Host.veil == nil)
        {
            UIView *veil = [[UIView alloc] initWithFrame:g_Host.web.frame];
            veil.alpha = 0.01;
            veil.userInteractionEnabled = NO;
            g_Host.veil = veil;
        }
        g_Host.veil.frame = g_Host.web.frame;
        [g_Host.veil addSubview:g_Host.web];
        [root.view addSubview:g_Host.veil];
    }
    else
    {
        [g_Host.veil removeFromSuperview];
        g_Host.web.frame = root.view.bounds;
        [root.view addSubview:g_Host.web];
    }
    NSLog(@"[WebXR] %@", g_Host.windowed ? @"back to a window in the scene" : @"full screen for an immersive session");
}
