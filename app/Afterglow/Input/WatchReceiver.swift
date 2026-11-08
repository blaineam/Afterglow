import WatchConnectivity

/// The phone's side of the Watch link: a select or a scroll from the watch app's double tap and
/// Digital Crown. Logs [Watch].
final class WatchReceiver: NSObject, WCSessionDelegate, @unchecked Sendable {
    var onSelect: (() -> Void)?
    var onScroll: ((Float) -> Void)?
    private var received = 0

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
        received += 1
        switch message["action"] as? String {
        case "select": onSelect?(); if received <= 3 { log("[Watch] Select") }
        case "scroll": if let dy = message["dy"] as? Double { onScroll?(Float(dy)) }
        default: break
        }
    }
}
