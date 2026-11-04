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

@interface CardboardXRWebHost : NSObject <WKScriptMessageHandler, WKNavigationDelegate>
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
    NSLog(@"[WebXR] page said %@", event ?: @"?");
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)nav withError:(NSError *)error
{
    NSLog(@"[WebXR] couldn't load: %@", error.localizedDescription);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)nav
{
    NSLog(@"[WebXR] loaded %@", webView.URL.absoluteString);
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
    web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    web.opaque = YES;
    web.backgroundColor = UIColor.blackColor;
    web.scrollView.bounces = NO;
    // A viewer has no way to scroll, and a page that drifts under the lenses is worse than one
    // that cannot move at all.
    web.scrollView.scrollEnabled = NO;
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
// The click is dispatched in JavaScript rather than as a synthesised touch, because UIKit has no
// public way to inject one. That reaches links, buttons and anything listening for a click, which
// is most of browsing; it will not drive a page that only handles raw touch events.
extern "C" void CardboardXR_WebClickAt(float u, float v)
{
    if (g_Host == nil || g_Host.web == nil)
        return;
    NSString *js = [NSString stringWithFormat:
        @"(function(){var x=%f*window.innerWidth,y=%f*window.innerHeight;"
         "var e=document.elementFromPoint(x,y);if(!e)return;"
         "['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){"
         "e.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,clientX:x,clientY:y}));});"
         "if(e.focus)e.focus();})()", u, v];
    [g_Host.web evaluateJavaScript:js completionHandler:nil];
}

extern "C" void CardboardXR_WebScrollBy(float dx, float dy)
{
    if (g_Host == nil || g_Host.web == nil)
        return;
    NSString *js = [NSString stringWithFormat:@"window.scrollBy(%f,%f)", dx, dy];
    [g_Host.web evaluateJavaScript:js completionHandler:nil];
}

extern "C" void CardboardXR_WebGoBack()
{
    if (g_Host != nil && g_Host.web != nil && g_Host.web.canGoBack)
        [g_Host.web goBack];
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
