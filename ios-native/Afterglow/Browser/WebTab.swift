@preconcurrency import WebKit
import Metal
import UIKit

/// One browser tab: a WKWebView kept in the window behind the Metal view (WebKit draws nothing
/// for a view outside a window), its page snapshotted into a Metal texture for the window in the
/// scene. Private tabs use a non-persistent data store and leave no history.
@MainActor
final class WebTab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let webView: WKWebView
    let isPrivate: Bool
    private(set) var texture: MTLTexture?
    private(set) var title = ""
    private(set) var url: URL?
    private(set) var pageSize = CGSize(width: 1280, height: 800)
    private var buffer: [UInt8] = []
    private var snapshotCount = 0
    private var snapshotMs: Double = 0
    private var lastLog: Double = 0
    private let device: MTLDevice
    /// Called when the page's URL or title changes.
    var onChange: ((WebTab) -> Void)?

    static func configuration(private isPrivate: Bool, userScripts: [WKUserScript], handler: WKScriptMessageHandler?, handlerNames: [String]) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = false
        let controller = WKUserContentController()
        for script in userScripts { controller.addUserScript(script) }
        if let handler { for name in handlerNames { controller.add(handler, name: name) } }
        configuration.userContentController = controller
        return configuration
    }

    /// 0-1 while a page loads, 1 when it is done; the chrome shows a loading pill under 1.
    private(set) var progress: Double = 1
    private var progressObservation: NSKeyValueObservation?

    init(device: MTLDevice, isPrivate: Bool, configuration: WKWebViewConfiguration, pageSize: CGSize) {
        self.device = device
        self.isPrivate = isPrivate
        self.pageSize = pageSize
        webView = WKWebView(frame: CGRect(origin: .zero, size: pageSize), configuration: configuration)
        webView.layer.anchorPoint = .zero
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = true
        webView.backgroundColor = .white
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated { guard let self else { return }; self.progress = view.isLoading ? view.estimatedProgress : 1; self.onChange?(self) }
        }
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1 Afterglow"
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// The layout size for a text scale: the page's size over the scale.
    func setTextScale(percent: Int) {
        let zoom = max(CGFloat(percent) / 100, 0.25)
        webView.frame = CGRect(origin: .zero, size: CGSize(width: pageSize.width / zoom, height: pageSize.height / zoom))
        webView.pageZoom = 1
    }

    /// Asks WebKit for the next picture of the page (`takeSnapshot`, rendered by the web process
    /// off the main thread; `drawHierarchy` cost the frame loop 145 ms a time) and uploads it when
    /// it lands. One in flight at a time.
    private var snapshotting = false

    func snapshot() {
        guard !snapshotting, webView.window != nil else { return }
        snapshotting = true
        let started = CACurrentMediaTime()
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        // snapshotWidth is in points and the image comes at the screen's scale: ask for the page's
        // pixel width over the scale, or the image is 3x the size (3840x2400, 37 MB a time).
        // The view is laid out at the page's size over the text scale (so a page that fills its
        // viewport fills the window) and the picture asked for at the page's size: the scale-up
        // is the text scale. pageZoom instead kept the layout at the view's size and scaled the
        // drawing, so a page sized to its viewport spilled past the window (owner, 2026-11-07).
        let scale = max(webView.traitCollection.displayScale, 1)
        configuration.snapshotWidth = NSNumber(value: Double(pageSize.width) / Double(scale))
        configuration.rect = webView.bounds
        webView.takeSnapshot(with: configuration) { [weak self] image, error in
            guard let self else { return }
            self.snapshotting = false
            guard let cgImage = image?.cgImage else {
                if let error, self.snapshotCount == 0 { log("[WebXR] Snapshot failed: \(error.localizedDescription)") }
                return
            }
            self.upload(cgImage)
            self.snapshotCount += 1
            self.snapshotMs += (CACurrentMediaTime() - started) * 1000
            let now = CACurrentMediaTime()
            if now - self.lastLog >= 5 {
                log(String(format: "[WebXR] Page snapshots %.1f/s, %.0f ms each in flight, %dx%d", Double(self.snapshotCount) / max(now - self.lastLog, 1),
                           self.snapshotMs / Double(max(self.snapshotCount, 1)), cgImage.width, cgImage.height))
                self.lastLog = now
                self.snapshotCount = 0
                self.snapshotMs = 0
            }
        }
    }

    private func upload(_ image: CGImage) {
        let width = image.width, height = image.height
        if texture == nil || texture!.width != width || texture!.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            texture = device.makeTexture(descriptor: d)
            texture?.label = "page"
            buffer = [UInt8](repeating: 0, count: width * height * 4)
        }
        guard let texture else { return }
        let bytesPerRow = width * 4
        buffer.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: bytesPerRow)
        }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        url = webView.url
        onChange?(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        url = webView.url
        title = webView.title ?? ""
        log("[WebXR] Loaded \(url?.absoluteString ?? "?")\(isPrivate ? " (private)" : "")")
        onChange?(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("[WebXR] Failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { log("[WebXR] Failed to load: \(error.localizedDescription)") }
    }

    // Links that want a new window open in this tab instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}
