import Foundation
import UIKit

/// Times the phone's heating: each change of iOS's thermal state, logged with the time since
/// launch and how long the last state lasted, in the Unity app's `ThermalLog.cs` line shapes:
///
///     [Thermal] nominal at launch; battery 45%, discharging; timing the heating from cold
///     [Thermal] nominal -> fair at 3:21 after launch, 3:21 in nominal; battery 44%, discharging
///
/// A run only measures heating from cold if it started nominal, off the charger, and more than
/// fifteen minutes after the last run or the last charge, which are remembered in UserDefaults.
@MainActor
final class ThermalLog {
    private static let coolMinutes = 15.0
    private static let lastRunKey = "ThermalLastRun"
    private static let lastChargingKey = "ThermalLastCharging"

    private var state: String
    private var since: Double
    private var fromCold: Bool
    private var saveTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let launch = ProcessInfo.processInfo.systemUptime

    /// The current state's name as the Unity app logs it: nominal, fair, serious or critical.
    static var stateName: String { name(ProcessInfo.processInfo.thermalState) }

    var currentState: String { state }

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        state = Self.stateName
        since = launch
        var why: String? = state != "nominal" ? "not nominal" : Self.charging ? "charging" : Self.warmFrom()
        var vouched = ""
        if why != nil && state == "nominal" && !Self.charging && Settings.shared.assertedCold {
            vouched = " (\(why!), but the owner says it is cold)"
            why = nil
        }
        fromCold = why == nil
        log("[Thermal] \(state) at launch; \(Self.battery())" +
            (fromCold ? "; timing the heating from cold\(vouched)" : "; not a run from cold (\(why!)), so its times aren't comparable"))
        Self.save()

        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.paused() }
            })
        // Polled too: the notification is not always delivered promptly.
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private var ticks = 0

    private func check() {
        ticks += 1
        if ticks % 15 == 0 { Self.save() }
        let now = ProcessInfo.processInfo.systemUptime
        let newState = Self.stateName
        if newState == state { return }
        if Self.charging { fromCold = false }
        log("[Thermal] \(state) -> \(newState) at \(Self.clock(now - launch)) after launch, \(Self.clock(now - since)) in \(state); " +
            "\(Self.battery())\(fromCold ? "" : "; not from cold")")
        state = newState
        since = now
    }

    private func paused() {
        Self.save()
        if fromCold {
            fromCold = false
            log("[Thermal] Paused at \(Self.clock(ProcessInfo.processInfo.systemUptime - launch)), \(state): later times aren't from cold")
        }
    }

    private static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static var charging: Bool {
        let s = UIDevice.current.batteryState
        return s == .charging || s == .full
    }

    private static func battery() -> String {
        let level = UIDevice.current.batteryLevel
        let name: String
        switch UIDevice.current.batteryState {
        case .charging: name = "charging"
        case .full: name = "full"
        case .unplugged: name = "discharging"
        case .unknown: name = "unknown"
        @unknown default: name = "unknown"
        }
        return String(format: "battery %.0f%%, %@", level * 100, name)
    }

    private static func warmFrom() -> String? {
        func ago(_ key: String, _ what: String) -> String? {
            guard let then = UserDefaults.standard.object(forKey: key) as? Double else { return nil }
            let minutes = (Date().timeIntervalSince1970 - then) / 60
            return minutes >= 0 && minutes < coolMinutes ? String(format: "%@ %.0f min ago", what, minutes) : nil
        }
        return ago(lastRunKey, "last ran") ?? ago(lastChargingKey, "charging")
    }

    private static func save() {
        let now = Date().timeIntervalSince1970
        UserDefaults.standard.set(now, forKey: lastRunKey)
        if charging { UserDefaults.standard.set(now, forKey: lastChargingKey) }
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
