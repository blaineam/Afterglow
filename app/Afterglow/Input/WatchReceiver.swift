import WatchConnectivity

/// The phone's side of the Watch link: a select or a scroll from the watch app's double tap and
/// Digital Crown. Logs [Watch].
///
/// WatchConnectivity calls the delegate on its own queue. The two callbacks are main-actor closures
/// and are only ever called on the main actor: as plain closures made in main-actor code they would
/// stop the app on the first message, the same trap as voice unlock's (2026-11-08).
final class WatchReceiver: NSObject, WCSessionDelegate, @unchecked Sendable {
    var onSelect: (@MainActor () -> Void)?
    var onScroll: (@MainActor (Float) -> Void)?
    private var selects = 0
    private var scrolls = 0

    func start() {
        guard WCSession.isSupported() else { log("[Watch] No Watch connectivity on this device"); return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        log("[Watch] Session \(activationState == .activated ? "active" : "inactive")\(session.isPaired ? ", a watch is paired" : ""), app \(session.isWatchAppInstalled ? "installed" : "not installed")")
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        switch message["action"] as? String {
        case "select":
            selects += 1
            if selects <= 3 { log("[Watch] Select") }
            if let onSelect { Task { @MainActor in onSelect() } }
        case "scroll":
            guard let dy = message["dy"] as? Double else { return }
            scrolls += 1
            if scrolls <= 3 { log("[Watch] Scroll \(Int(dy))") }
            if let onScroll { Task { @MainActor in onScroll(Float(dy)) } }
        default:
            break
        }
    }
}
