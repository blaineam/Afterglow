import SwiftUI
import WatchConnectivity

/// The Apple Watch as a controller: one big button marked as the primary action, so watchOS's
/// Double Tap gesture (two pinches of the index finger and thumb) presses it without touching
/// the watch; each press reaches the phone over WatchConnectivity as a select, the same as a
/// pinch in front of the camera or a double tap on the viewer. The Digital Crown scrolls a page.
@main
struct AfterglowWatchApp: App {
    var body: some Scene {
        WindowGroup { WatchView() }
    }
}

struct WatchView: View {
    @StateObject private var link = WatchLink.shared
    @State private var crown = 0.0

    var body: some View {
        VStack(spacing: 10) {
            Text("Afterglow").font(.headline)
            Button {
                link.send(["action": "select"])
            } label: {
                Text("Select")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, minHeight: 70)
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .handGestureShortcut(.primaryAction)
            Text(link.status).font(.footnote).foregroundStyle(.secondary)
        }
        .focusable()
        .digitalCrownRotation($crown, from: -1000, through: 1000, by: 1, sensitivity: .medium, isContinuous: true, isHapticFeedbackEnabled: false)
        .onChange(of: crown) { old, new in
            link.send(["action": "scroll", "dy": (new - old) * 40])
        }
        .padding()
    }
}

@MainActor
final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchLink()
    @Published var status = "Pair the phone app"
    private var sent = 0

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ message: [String: Any]) {
        guard WCSession.default.isReachable else { status = "Phone not reachable"; return }
        WCSession.default.sendMessage(message, replyHandler: nil) { _ in }
        sent += 1
        status = "Sent \(sent)"
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.status = activationState == .activated ? "Ready: double tap to select" : "Not active" }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.status = reachable ? "Ready: double tap to select" : "Phone not reachable" }
    }
}
