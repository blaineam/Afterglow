import SwiftUI

@main
struct AfterglowApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = SessionLog.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .preferredColorScheme(.dark)
                .onAppear { Self.keepAwake() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Self.keepAwake() }
        }
    }

    // The screen must not dim or lock in the viewer. Set whenever the scene becomes active: set
    // once in init it did not hold, and the app delegate's activation callback is not called in a
    // scene-based app, so the phone locked during runs (2026-11-06, twice).
    @MainActor
    static func keepAwake() {
        UIApplication.shared.isIdleTimerDisabled = true
        log("[Stereo] Idle timer off: the screen stays awake while the app is up (\(UIApplication.shared.isIdleTimerDisabled))")
    }
}

/// Locks the app to landscape right (home indicator and USB port on the right), the way the phone
/// sits in the viewer and the way ARKit's camera image comes. iOS 26 wants the plist to list every
/// orientation, so the lock is here rather than there.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .landscapeRight
    }
}
