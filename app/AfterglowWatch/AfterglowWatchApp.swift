import SwiftUI
import WatchConnectivity

/// The Apple Watch as a controller: one big button marked as the primary action, so watchOS's
/// Double Tap gesture (two pinches of the index finger and thumb) presses it without touching
/// the watch; each press reaches the phone over WatchConnectivity as a select, the same as a
/// pinch in front of the camera. The Digital Crown scrolls what is open: a page or a media grid.
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
                link.select()
            } label: {
                Text("Select")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, minHeight: 70)
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .handGestureShortcut(.primaryAction)
            Text(link.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .focusable()
        .digitalCrownRotation($crown, from: -1000, through: 1000, by: 1, sensitivity: .medium, isContinuous: true, isHapticFeedbackEnabled: false)
        .onChange(of: crown) { old, new in
            link.scroll(dy: (new - old) * 40)
        }
        .padding()
    }
}

@MainActor
final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchLink()
    private static let ready = "Ready: double tap to select"
    private static let openThePhoneApp = "Open Afterglow on your iPhone"

    @Published var status = "Connecting…"
    private var selects = 0

    override init() {
        super.init()
        #if DEBUG
        // The store screenshot: the app as it looks once the phone is connected, with no phone.
        if ProcessInfo.processInfo.environment["AFTERGLOW_WATCH_SHOT"] != nil { status = Self.ready; return }
        #endif
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        #if DEBUG
        if let presses = ProcessInfo.processInfo.environment["AFTERGLOW_WATCH_AUTOPRESS"].flatMap(Int.init) {
            Task { await self.autopress(presses) }
        }
        #endif
    }

    func select() {
        guard send(["action": "select"]) else { return }
        selects += 1
        status = "Selected \(selects)"
    }

    func scroll(dy: Double) {
        send(["action": "scroll", "dy": dy])
    }

    /// False, and says so on the screen, when the phone app isn't there to hear it.
    @discardableResult
    private func send(_ message: [String: Any]) -> Bool {
        guard WCSession.default.isReachable else { status = Self.openThePhoneApp; return false }
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: Self.sendFailed())
        return true
    }

    /// WatchConnectivity calls this on its own queue, so it can't be a main-actor closure: made
    /// inline in `send` it would stop the app the first time a send failed.
    private nonisolated static func sendFailed() -> @Sendable (Error) -> Void {
        { _ in Task { @MainActor in WatchLink.shared.status = WatchLink.openThePhoneApp } }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        let active = activationState == .activated
        Task { @MainActor in
            if !active { self.status = "Connecting…" } else { self.status = reachable ? Self.ready : Self.openThePhoneApp }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.status = reachable ? Self.ready : Self.openThePhoneApp }
    }

    #if DEBUG
    /// For Tools/test_watch_link.sh: once the phone is reachable, presses Select and turns the
    /// crown `presses` times, as if the wearer had.
    private func autopress(_ presses: Int) async {
        var done = 0
        for _ in 0..<120 where done < presses {
            try? await Task.sleep(for: .seconds(2))
            guard WCSession.default.isReachable else { continue }
            select()
            scroll(dy: 40)
            done += 1
        }
    }
    #endif
}
