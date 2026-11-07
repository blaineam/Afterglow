import Foundation
import Metal
import QuartzCore
import CryptoKit
import Security
import CoreMotion
import simd

/// The six-digit passcode: kept as "salt$hash" (sixteen random bytes as hex, then SHA-256 of
/// salt + passcode as hex, the Unity app's format) in the Keychain, asked for at launch, after a
/// minute away, and when the viewer is taken off, which the motion sensors tell: the phone laid
/// flat (screen up or down) for two seconds, or held still for thirty. A gaze keypad unlocks.
/// Logs [Lock].
@MainActor
final class AppLock {
    private static let account = "app-passcode"
    private static let service = "com.wemiller.afterglow.lock"
    private(set) var locked = false
    private(set) var entered = ""
    private(set) var settingNew = false
    private var firstNew = ""
    private var wrong = 0
    private var backgroundedAt: Date?
    let panel: ScenePanel
    var onLocked: ((Bool) -> Void)?
    private var stillSince: Double = 0
    private var flatSince: Double = 0
    private var lastMotionCheck: Double = 0
    private var lastUnlockOrLock: Double = 0

    var isSet: Bool { Self.stored() != nil }

    init(device: MTLDevice) {
        panel = ScenePanel(device: device, pixelWidth: 1000, pixelHeight: 1200)
        panel.pane.widthMeters = 0.7
        layout()
        if isSet { lock(reason: "launch") }
    }

    // MARK: Store

    private static func stored() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hash(_ passcode: String, saltHex: String) -> String {
        let digest = SHA256.hash(data: Data((saltHex + passcode).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func encode(_ passcode: String) -> String {
        var salt = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        let saltHex = salt.map { String(format: "%02x", $0) }.joined()
        return saltHex + "$" + hash(passcode, saltHex: saltHex)
    }

    static func matches(_ passcode: String, record: String) -> Bool {
        let parts = record.split(separator: "$", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        return hash(passcode, saltHex: parts[0]) == parts[1]
    }

    func setPasscode(_ passcode: String?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account]
        SecItemDelete(query as CFDictionary)
        if let passcode {
            var add = query
            add[kSecValueData as String] = Data(Self.encode(passcode).utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
            log("[Lock] Passcode set")
        } else {
            log("[Lock] Passcode removed")
        }
    }

    // MARK: Locking

    func lock(reason: String) {
        guard isSet, !locked else { return }
        locked = true
        entered = ""
        lastUnlockOrLock = CACurrentMediaTime()
        log("[Lock] Locked (\(reason))")
        onLocked?(true)
        layout()
    }

    func beginSettingNew() {
        settingNew = true
        firstNew = ""
        entered = ""
        locked = true
        onLocked?(true)
        layout()
    }

    func removePasscode() { setPasscode(nil); locked = false; onLocked?(false) }

    private func unlock() {
        locked = false
        wrong = 0
        lastUnlockOrLock = CACurrentMediaTime()
        log("[Lock] Unlocked")
        onLocked?(false)
    }

    func backgrounded() { backgroundedAt = Date() }
    func foregrounded() {
        if let at = backgroundedAt, Date().timeIntervalSince(at) > 60 { lock(reason: "away for a minute") }
        backgroundedAt = nil
    }

    /// The motion sensors' reading of whether the viewer is still on: gravity along the device's
    /// long axis (the phone upright in landscape) and some movement.
    func motion(gravity: SIMD3<Double>, rotationRate: SIMD3<Double>, time: Double) {
        guard isSet, !locked, time - lastUnlockOrLock > 5 else { return }
        let flat = abs(gravity.z) > 0.8        // the screen facing up or down: put down
        let still = simd_length(rotationRate) < 0.02
        if flat { if flatSince == 0 { flatSince = time } } else { flatSince = 0 }
        if still { if stillSince == 0 { stillSince = time } } else { stillSince = 0 }
        if flatSince > 0 && time - flatSince > 2 { lock(reason: "the phone was put down") }
        else if stillSince > 0 && time - stillSince > 30 { lock(reason: "no movement for thirty seconds") }
    }

    // MARK: The keypad

    private func layout() {
        var b: [ScenePanel.Button] = []
        let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "✕"]
        for (i, k) in keys.enumerated() {
            let col = i % 3, row = i / 3
            b.append(.init(id: "key:\(k)", rect: CGRect(x: 0.08 + CGFloat(col) * 0.29, y: 0.3 + CGFloat(row) * 0.165, width: 0.26, height: 0.15), label: k))
        }
        panel.set(buttons: b, version: "lock|\(entered.count)|\(settingNew)|\(wrong)|\(firstNew.isEmpty)")
    }

    func press(_ id: String) {
        guard id.hasPrefix("key:") else { return }
        let k = String(id.dropFirst(4))
        switch k {
        case "⌫": if !entered.isEmpty { entered.removeLast() }
        case "✕": entered = ""; if settingNew { settingNew = false; firstNew = ""; locked = false; onLocked?(false) }
        default:
            guard entered.count < 6 else { return }
            entered += k
            if entered.count == 6 {
                if settingNew {
                    if firstNew.isEmpty { firstNew = entered; entered = "" }
                    else if firstNew == entered { setPasscode(entered); settingNew = false; firstNew = ""; unlock() }
                    else { firstNew = ""; entered = ""; wrong += 1 }
                } else if let record = Self.stored(), Self.matches(entered, record: record) {
                    unlock()
                } else {
                    wrong += 1
                    entered = ""
                    log("[Lock] Wrong passcode (\(wrong))")
                }
            }
        }
        layout()
    }

    var title: String {
        let dots = String(repeating: "●", count: entered.count) + String(repeating: "○", count: 6 - entered.count)
        if settingNew { return (firstNew.isEmpty ? "New passcode  " : "Again  ") + dots }
        return (wrong > 0 ? "Try again  " : "Passcode  ") + dots
    }

    func render() {
        panel.render(ButtonsView(size: CGSize(width: 1000, height: 1200), buttons: panel.buttons, hovered: panel.hovered, title: title, titleHighlight: wrong > 0))
    }
}
