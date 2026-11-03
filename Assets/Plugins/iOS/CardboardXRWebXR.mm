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

@end

// Opens `url` over Unity's view, with `configJson` and `shim` injected into every page it loads.
// Returns 1 if the view went up.
extern "C" int CardboardXR_WebOpen(const char *url, const char *configJson, const char *shim)
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

    WKWebView *web = [[WKWebView alloc] initWithFrame:root.view.bounds configuration:configuration];
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
    g_Host = host;
    [root.view addSubview:web];
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
    WKWebView *web = g_Host.web;
    [web.configuration.userContentController removeScriptMessageHandlerForName:@"cardboardxr"];
    [web stopLoading];
    [web removeFromSuperview];
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
