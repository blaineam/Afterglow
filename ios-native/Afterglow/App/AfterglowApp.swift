import SwiftUI

@main
struct AfterglowApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
        }
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

    // The screen must not dim or lock in the viewer. Set at every activation rather than once at
    // launch: set in the App's init it did not hold, and the phone locked during a run (2026-11-06).
    func applicationDidBecomeActive(_ application: UIApplication) {
        application.isIdleTimerDisabled = true
        log("[Stereo] Idle timer off: the screen stays awake while the app is up")
    }
}
