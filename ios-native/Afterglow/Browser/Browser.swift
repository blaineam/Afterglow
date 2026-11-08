@preconcurrency import WebKit
import Metal
import UIKit
import simd

/// The browser: tabs (each a web view of its own, so a tab keeps its scroll and forms), the page
/// hung in the scene as a window and snapshotted from a veiled web view, gaze hover and clicks
/// through the helper script, typing from the scene keyboard or dictation, logins saved to the
/// Keychain and offered back, history and bookmarks, and immersive WebXR sessions in which the
/// web view fills the screen and the app pushes the head pose and the hands into the page every
/// frame. The Unity app's `WebBrowserSession.cs` behaviour, on WebKit directly. Logs [WebXR].
@MainActor
final class Browser: NSObject, WKScriptMessageHandler, ObservableObject {
    enum Prompt: Equatable {
        case save(Credential)
        case fill(host: String, credentials: [Credential])
    }

    static let maxTabs = 6
    static let widths: [Float] = [0.8, 1.25, 1.9, 2.8]

    let device: MTLDevice
    let pageSize = CGSize(width: 1280, height: 800)
    private(set) var tabs: [WebTab] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var isImmersive = false
    @Published var typed = ""
    @Published private(set) var prompt: Prompt?
    @Published private(set) var fieldFocused = false
    @Published private(set) var keyboardShown = false
    @Published private(set) var placing = false
    var window = BrowserWindow()
    private(set) var state = BrowserStore.load()
    private var config: WebBridge.Config
    private var textScalePercent: Int
    private let veil = UIView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800))
    private var snapshotTimer: Timer?
    private var screenBounds = CGRect.zero
    private var lastHover: Double = 0
    private var hoverOff = false
    private var announcedHosts = Set<String>()
    private var lastHistoryCheck: Double = 0
    private var handsWereSent = false
    private var saveSoon: Task<Void, Never>?

    var current: WebTab? { tabs.indices.contains(currentIndex) ? tabs[currentIndex] : nil }
    var isOpen: Bool { !tabs.isEmpty }

    init(device: MTLDevice, config: WebBridge.Config, textScalePercent: Int) {
        self.device = device
        self.config = config
        self.textScalePercent = textScalePercent
        super.init()
        veil.alpha = 0.01
        veil.isUserInteractionEnabled = false
        veil.backgroundColor = .black
    }

    // MARK: Opening and closing

    /// Puts the veil in the window (snapshots need a view in a window) and opens the saved tabs,
    /// or the start page.
    func open(in uiWindow: UIWindow, head: simd_float4x4, launchURL: URL? = nil) {
        screenBounds = uiWindow.bounds
        if veil.superview == nil {
            uiWindow.addSubview(veil)
            layoutVeil()
        }
        if tabs.isEmpty {
            let saved = state.tabs.filter { !$0.url.isEmpty }
            if let launchURL {
                _ = newTab(private: false, url: launchURL)
            } else if saved.isEmpty {
                _ = newTab(private: false, url: nil)
            } else {
                for record in saved.prefix(Self.maxTabs) { _ = newTab(private: false, url: URL(string: record.url)) }
                switchTab(min(state.currentTab, tabs.count - 1))
            }
        }
        window.place(ahead: head)
        snapshotTimer?.invalidate()
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.current?.snapshot() }
        }
        log("[WebXR] Browser open: \(tabs.count) tabs, text scale \(textScalePercent)%")
    }

    func close() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        if isImmersive { endSession() }
        for tab in tabs { tab.webView.removeFromSuperview() }
        tabs.removeAll()
        veil.removeFromSuperview()
        persist()
        log("[WebXR] Browser closed")
    }

    private func layoutVeil() {
        veil.transform = .identity
        veil.frame = CGRect(origin: .zero, size: pageSize)
        veil.center = CGPoint(x: screenBounds.midX, y: screenBounds.midY)
    }

    // MARK: Tabs

    @discardableResult
    func newTab(private isPrivate: Bool, url: URL?) -> WebTab? {
        guard tabs.count < Self.maxTabs else { log("[WebXR] No more than \(Self.maxTabs) tabs"); return nil }
        let configuration = WebTab.configuration(private: isPrivate, userScripts: WebBridge.userScripts(config: config), handler: self,
                                                 handlerNames: [WebBridge.handlerName])
        let tab = WebTab(device: device, isPrivate: isPrivate, configuration: configuration, pageSize: pageSize)
        tab.setTextScale(percent: textScalePercent)
        tab.onChange = { [weak self] tab in self?.tabChanged(tab) }
        tabs.append(tab)
        switchTab(tabs.count - 1)
        if let url { tab.load(url) } else { loadStartPage(in: tab) }
        log("[WebXR] New \(isPrivate ? "private " : "")tab \(tabs.count)")
        return tab
    }

    func switchTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        for (i, tab) in tabs.enumerated() where i != index { tab.webView.removeFromSuperview() }
        currentIndex = index
        let tab = tabs[index]
        if tab.webView.superview !== veil {
            tab.setTextScale(percent: textScalePercent)
            veil.addSubview(tab.webView)
        }
        typed = ""
        persistSoon()
    }

    func closeTab() {
        guard let tab = current else { return }
        tab.webView.removeFromSuperview()
        tabs.remove(at: currentIndex)
        if tabs.isEmpty {
            close()
        } else {
            switchTab(min(currentIndex, tabs.count - 1))
        }
    }

    func cycleTab() {
        guard tabs.count > 1 else { return }
        switchTab((currentIndex + 1) % tabs.count)
    }

    private func loadStartPage(in tab: WebTab) {
        guard let page = WebBridge.startPage else { log("[WebXR] No start page in the bundle"); return }
        tab.webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    // MARK: Navigation

    func go(_ text: String) {
        let address = WebBridge.normalizeAddress(text)
        guard !address.isEmpty, let tab = current else { return }
        if address == WebBridge.startPageAddress { loadStartPage(in: tab); return }
        if let url = URL(string: address) { tab.load(url) }
        typed = ""
    }

    func back() { current?.webView.goBack() }
    func forward() { current?.webView.goForward() }
    func reload() { current?.webView.reload() }
    func home() { if let tab = current { loadStartPage(in: tab) } }

    func toggleBookmark() {
        guard let tab = current, let url = tab.url?.absoluteString, url.hasPrefix("http") else { return }
        let added = BrowserStore.toggleBookmark(BrowserRecord(url: url, title: tab.title), in: &state)
        log("[WebXR] \(added ? "Bookmarked" : "Unbookmarked") \(url)")
        persistSoon()
    }

    func isBookmarked() -> Bool {
        guard let url = current?.url?.absoluteString else { return false }
        return state.bookmarks.contains { $0.url == url }
    }

    func cycleSize() {
        let i = Self.widths.firstIndex { abs($0 - window.widthMeters) < 0.01 } ?? 1
        window.widthMeters = Self.widths[(i + 1) % Self.widths.count]
        log(String(format: "[WebXR] Window %.2f m wide", window.widthMeters))
    }

    func togglePlacing() { placing.toggle() }

    /// Scrolls the page at the gaze, or its middle, by `dy` CSS pixels (a controller's stick).
    func scroll(dy: Float) {
        run(WebBridge.scroll(0.5, 0.5, 0, dy))
    }

    /// The page's text size, applied live from the settings or the bar's buttons. Never during a
    /// WebXR session: a frame change there made a player end its session (2026-11-07).
    func setTextScale(_ percent: Int) {
        guard percent != textScalePercent, !isImmersive else { return }
        textScalePercent = percent
        for tab in tabs { tab.setTextScale(percent: percent) }
        log("[WebXR] Text scale \(percent)%")
    }
    func toggleKeyboard() { keyboardShown.toggle() }

    func clearHistory() {
        state.history.removeAll()
        persist()
        sendLists()
        log("[WebXR] History cleared")
    }

    // MARK: Typing

    /// Text from the scene keyboard, a Bluetooth keyboard or dictation: into the page's focused
    /// field, else the address bar.
    func type(_ text: String) {
        if fieldFocused { run(WebBridge.type(text)) } else { typed += text }
    }

    func key(_ name: String) {
        if fieldFocused {
            run(WebBridge.key(name))
            return
        }
        switch name {
        case "Backspace": if !typed.isEmpty { typed.removeLast() }
        case "Clear": typed = ""
        case "Enter": go(typed)
        default: break
        }
    }

    // MARK: Logins

    func answerPrompt(yes: Bool) {
        guard let prompt else { return }
        self.prompt = nil
        switch prompt {
        case .save(let credential):
            if yes {
                let ok = CredentialStore.save(credential)
                log("[WebXR] Password for \(credential.host) \(ok ? "saved" : "not saved")")
            }
        case .fill(_, let credentials):
            if yes, let first = credentials.first { run(WebBridge.fill(first.username, first.password)) }
        }
    }

    // MARK: Per frame

    /// What the gaze is on, for drawing the reticle: the page point, if the gaze is on the window.
    struct Gaze {
        var uv: SIMD2<Float>
        var point: SIMD3<Float>
    }

    /// Called every frame with the head and the hands. Pushes the pose during a session, hovers
    /// the page at the gaze, scrolls at the page's edges. `select` is a pinch starting or a
    /// double tap: a click on the page (windowed) or a select (immersive).
    func frame(head: simd_float4x4, hands: [TrackedHandState], select: Bool, time: Double, deltaTime: Float) -> Gaze? {
        guard let tab = current else { return nil }
        if isImmersive {
            // The page's world starts where the head is and faces where it faces: a page's
            // "forward" is -z, and the tracker's own zero (the motion sensor's, in 3DoF) can be
            // anywhere, which put one page's world behind the owner (2026-11-08).
            if xrOrigin == nil {
                let f = -head.columns.2.xyz
                let yaw = atan2(-f.x, -f.z)
                xrOrigin = simd_float4x4.translation(head.columns.3.xyz) * simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
                log(String(format: "[WebXR] Session world faces %.0f degrees", yaw * 180 / .pi))
            }
            let fromWorld = xrOrigin!.inverse
            let local = fromWorld * head
            let p = local.columns.3.xyz
            let q = simd_quatf(local.rotationOnly)
            run(WebBridge.pose(p, q))
            var values: [Float] = [Float(hands.count)]
            for hand in hands {
                values.append(hand.isRight ? 1 : 0)
                values.append(hand.pinched ? 1 : 0)
                for joint in hand.joints { let j = (fromWorld * SIMD4(joint, 1)).xyz; values += [j.x, j.y, j.z] }
            }
            if !hands.isEmpty || handsWereSent { run(WebBridge.hands(values)) }
            handsWereSent = !hands.isEmpty
            if select && hands.isEmpty { run(WebBridge.select) }
            return nil
        }
        if placing {
            window.place(ahead: head)
        }
        let gaze = window.gaze(from: head)
        if time - lastHover >= 1.0 / 12.0 {
            lastHover = time
            if let gaze {
                run(WebBridge.hover(gaze.uv.x, gaze.uv.y))
                hoverOff = false
                // Looking within the top or bottom 12% of the page scrolls it.
                let edge: Float = 0.12
                if gaze.uv.y < edge { run(WebBridge.scroll(gaze.uv.x, gaze.uv.y, 0, -900 * (edge - gaze.uv.y) / edge / 12)) }
                if gaze.uv.y > 1 - edge { run(WebBridge.scroll(gaze.uv.x, gaze.uv.y, 0, 900 * (gaze.uv.y - (1 - edge)) / edge / 12)) }
            } else if !hoverOff {
                hoverOff = true
                run(WebBridge.hover(-1, -1))
            }
        }
        if select, let gaze {
            run(WebBridge.click(gaze.uv.x, gaze.uv.y))
            log(String(format: "[WebXR] Click at (%.3f, %.3f)", gaze.uv.x, gaze.uv.y))
        }
        if time - lastHistoryCheck > 0.5 {
            lastHistoryCheck = time
            noteVisit(tab)
        }
        return gaze.map { Gaze(uv: $0.uv, point: $0.point) }
    }

    // MARK: Sessions

    /// The session's world in the tracker's: set from the head on the session's first frame, and
    /// again after a tracking switch (the 3DoF switch comes a moment into a session).
    private var xrOrigin: simd_float4x4?
    func recentreSession() { if isImmersive { xrOrigin = nil } }

    private func beginSession() {
        guard !isImmersive else { return }
        isImmersive = true
        xrOrigin = nil
        // The page zoom that makes text readable in the window would show the session's canvas
        // at 1.5x, one eye across the screen and the other off its edge: the page draws at 1:1
        // for the session and gets its zoom back after.
        // The view keeps its layout size: changing it here fired a resize the owner's player
        // answered by disposing its renderer, ending the session 0.2 s in (2026-11-07). The veil
        // is scaled from whatever size the view has to the screen; the shim sizes the session's
        // framebuffer itself.
        if let bounds = veil.window?.bounds { screenBounds = bounds }
        let layout = current?.webView.frame.size ?? pageSize
        veil.alpha = 1
        veil.transform = CGAffineTransform(scaleX: screenBounds.width / max(layout.width, 1), y: screenBounds.height / max(layout.height, 1))
        veil.center = CGPoint(x: screenBounds.midX, y: screenBounds.midY)
        veil.superview?.bringSubviewToFront(veil)
        handsWereSent = false
        log("[WebXR] Immersive session started: the page has the screen")
    }

    func endSession() {
        guard isImmersive else { return }
        run(WebBridge.endSession)
        sessionEnded(why: "the app ended it")
    }

    private func sessionEnded(why: String) {
        guard isImmersive else { return }
        isImmersive = false
        veil.alpha = 0.01
        layoutVeil()
        log("[WebXR] Session ended (\(why))")
    }

    // MARK: Messages from the page

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // WKScriptMessage is delivered on the main thread; read its body there.
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let event = body["event"] as? String else { return }
            self.handle(event, body)
        }
    }

    private func handle(_ event: String, _ body: [String: Any]) {
        switch event {
        case "sessionstart": beginSession()
        case "sessionend": sessionEnded(why: (body["why"] as? String).map { String($0.prefix(120)) } ?? "the page ended it")
        case "startpage": sendLists()
        case "console":
            let level = body["level"] as? String ?? "log"
            let text = body["text"] as? String ?? ""
            log("[WebXR] page \(level): \(text.prefix(300))")
        case "credentials":
            guard let host = body["host"] as? String, let pass = body["pass"] as? String, !pass.isEmpty else { return }
            let user = body["user"] as? String ?? ""
            let credential = Credential(host: host, username: user, password: pass)
            if !CredentialStore.credentials(for: host).contains(credential) {
                prompt = .save(credential)
                log("[WebXR] Offering to save the password for \(host)")
            }
        case "login":
            guard let host = body["host"] as? String, !announcedHosts.contains(host) else { return }
            announcedHosts.insert(host)
            let saved = CredentialStore.credentials(for: host)
            if !saved.isEmpty {
                prompt = .fill(host: host, credentials: saved)
                log("[WebXR] Offering the saved login for \(host)")
            }
        case "focus":
            let has = (body["has"] as? Int ?? 0) != 0
            fieldFocused = has
            if has { keyboardShown = true }
        case "click":
            log("[WebXR] page click: \(body["hit"] ?? "") \(body["note"] ?? "")")
        case "typed", "key":
            if let note = body["note"] as? String { log("[WebXR] page \(event): \(note)") }
        case "close":
            close()
        default:
            break
        }
    }

    // MARK: Store

    private func tabChanged(_ tab: WebTab) {
        if let url = tab.url?.absoluteString, url.hasPrefix("afterglow://") {
            if url == "afterglow://clear-history" { clearHistory() }
        }
        persistSoon()
    }

    private func noteVisit(_ tab: WebTab) {
        guard !tab.isPrivate, let url = tab.url?.absoluteString, url.hasPrefix("http") else { return }
        if let last = state.history.first, last.url == url, Date().timeIntervalSince(last.date) < 60 { return }
        BrowserStore.visited(BrowserRecord(url: url, title: tab.title), in: &state)
        persistSoon()
    }

    private func sendLists() {
        func items(_ records: [BrowserRecord]) -> [[String: Any]] {
            records.prefix(12).map { r in
                ["url": r.url, "label": r.title.isEmpty ? (URL(string: r.url)?.host ?? r.url) : r.title,
                 "host": URL(string: r.url)?.host ?? "", "when": ISO8601DateFormatter().string(from: r.date)]
            }
        }
        let lists: [String: Any] = ["bookmarks": items(state.bookmarks), "history": items(state.history)]
        if let data = try? JSONSerialization.data(withJSONObject: lists), let json = String(data: data, encoding: .utf8) {
            run(WebBridge.lists(json))
        }
    }

    private func persistSoon() {
        saveSoon?.cancel()
        saveSoon = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { persist() }
        }
    }

    private func persist() {
        state.tabs = tabs.filter { !$0.isPrivate }.map { BrowserRecord(url: $0.url?.absoluteString ?? WebBridge.startPageAddress, title: $0.title) }
            .map { $0.url.hasPrefix("file://") ? BrowserRecord(url: WebBridge.startPageAddress, title: "Start") : $0 }
        state.currentTab = currentIndex
        BrowserStore.save(state)
    }

    private func run(_ script: String) {
        current?.webView.evaluateJavaScript(script) { _, error in
            if let error, (error as NSError).code != WKError.javaScriptExceptionOccurred.rawValue {
                // Pages without the shim (file errors, blank) raise; nothing to do.
            }
        }
    }
}
