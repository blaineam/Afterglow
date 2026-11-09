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
    private var lastGravity = SIMD3<Double>.zero
    private var lastMotionCheck: Double = 0
    private var lastUnlockOrLock: Double = 0
    /// The passcode can be spoken: digits heard on the phone fill the dots (owner, 2026-11-08:
    /// the gaze keypad was hard to use). Nothing heard is logged or shown.
    private let dictation = Dictation()
    /// Why the voice entry can't run, shown on its button.
    private var voiceProblem: String?
    private var heardNothing = false

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
        // A head holds a viewer still only so still: ten seconds under 0.02 rad/s with gravity
        // unchanged is a phone on a table. The old "screen facing up or down" rule fired when
        // the wearer looked down at the dock (owner, 2026-11-07).
        let still = simd_length(rotationRate) < 0.02 && simd_length(gravity - lastGravity) < 0.01
        lastGravity = gravity
        if still { if stillSince == 0 { stillSince = time } } else { stillSince = 0 }
        if stillSince > 0 && time - stillSince > 10 { lock(reason: "perfectly still for ten seconds") }
        _ = flatSince
    }

    // MARK: The keypad

    private func layout() {
        var b: [ScenePanel.Button] = []
        let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "✕"]
        let listening = dictation.listening
        b.append(.init(id: "voice", rect: CGRect(x: 0.08, y: 0.17, width: 0.84, height: 0.13),
                       label: listening ? String(localized: "Listening… say the six digits") : (voiceProblem ?? (heardNothing ? String(localized: "Didn't catch six digits. Try again") : String(localized: "Say your passcode"))),
                       wide: true, icon: listening ? "waveform" : "mic.fill", style: .pill, accent: true))
        for (i, k) in keys.enumerated() {
            let col = i % 3, row = i / 3
            b.append(.init(id: "key:\(k)", rect: CGRect(x: 0.08 + CGFloat(col) * 0.29, y: 0.33 + CGFloat(row) * 0.16, width: 0.26, height: 0.145), label: k))
        }
        panel.set(buttons: b, version: "lock|\(entered.count)|\(settingNew)|\(wrong)|\(firstNew.isEmpty)|\(listening)|\(heardNothing)|\(voiceProblem ?? "")")
    }

    /// The digits in what was heard: numerals, and the spoken words for them.
    nonisolated static func digits(from text: String) -> String {
        let words: [String: Character] = ["zero": "0", "oh": "0", "o": "0", "one": "1", "won": "1", "two": "2", "to": "2", "too": "2",
                                          "three": "3", "tree": "3", "four": "4", "for": "4", "fore": "4", "five": "5", "six": "6",
                                          "seven": "7", "eight": "8", "ate": "8", "nine": "9"]
        // The other eight languages' digits. Chinese, Japanese and Korean run them together, so each
        // of their characters counts by itself.
        let spoken: [String: Character] = [
            "null": "0", "eins": "1", "ein": "1", "eine": "1", "zwei": "2", "zwo": "2", "drei": "3", "vier": "4", "fünf": "5", "sechs": "6", "sieben": "7", "acht": "8", "neun": "9",
            "cero": "0", "uno": "1", "una": "1", "dos": "2", "tres": "3", "cuatro": "4", "cinco": "5", "seis": "6", "siete": "7", "ocho": "8", "nueve": "9",
            "zéro": "0", "un": "1", "une": "1", "deux": "2", "trois": "3", "quatre": "4", "cinq": "5", "sept": "7", "huit": "8", "neuf": "9",
            "due": "2", "tre": "3", "quattro": "4", "cinque": "5", "sei": "6", "sette": "7", "otto": "8", "nove": "9",
            "um": "1", "uma": "1", "dois": "2", "duas": "2", "três": "3", "sete": "7", "oito": "8",
            "ゼロ": "0", "れい": "0", "いち": "1", "に": "2", "さん": "3", "よん": "4", "し": "4", "ご": "5", "ろく": "6", "なな": "7", "しち": "7", "はち": "8", "きゅう": "9", "く": "9",
        ]
        let characters: [Character: Character] = [
            "〇": "0", "零": "0", "幺": "1", "两": "2",
            "영": "0", "공": "0", "일": "1", "이": "2", "삼": "3", "사": "4", "오": "5", "육": "6", "칠": "7", "팔": "8", "구": "9",
        ]
        var out = ""
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if let d = words[String(token)] ?? spoken[String(token)] { out.append(d); continue }
            for ch in token {
                if let value = ch.wholeNumberValue, (0...9).contains(value) { out += String(value) }
                else if let d = characters[ch] { out.append(d) }
            }
        }
        return out
    }

    /// The voice button: listen (on the phone only) until six digits are heard, or stop.
    private func listen() {
        if dictation.listening { dictation.stop(); return }
        heardNothing = false
        voiceProblem = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.dictation.requestPermission() else {
                log("[Lock] Voice entry needs the microphone and speech recognition")
                self.voiceProblem = String(localized: "Allow the microphone and speech in Settings")
                self.layout()
                return
            }
            if let problem = self.dictation.privateEntryProblem {
                log("[Lock] Voice entry unavailable: \(problem)")
                self.voiceProblem = problem
                self.layout()
                return
            }
            self.entered = ""
            self.dictation.start(private: true) { [weak self] heard in
                guard let self else { return }
                let digits = String(Self.digits(from: heard).prefix(6))
                if digits.count == 6 { self.entered = digits; self.submit() }
                else { self.entered = ""; self.heardNothing = true; log("[Lock] Voice entry: \(digits.count) digits heard, not six") }
                self.layout()
            }
            self.layout()
        }
    }

    /// Six digits entered: a new passcode's two entries, or an unlock.
    private func submit() {
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

    func press(_ id: String) {
        if id == "voice" { listen(); layout(); return }
        guard id.hasPrefix("key:") else { return }
        let k = String(id.dropFirst(4))
        switch k {
        case "⌫": if !entered.isEmpty { entered.removeLast() }
        case "✕": entered = ""; if settingNew { settingNew = false; firstNew = ""; locked = false; onLocked?(false) }
        default:
            guard entered.count < 6 else { return }
            entered += k
            if entered.count == 6 { submit() }
        }
        layout()
    }

    var title: String {
        let dots = String(repeating: "●", count: entered.count) + String(repeating: "○", count: 6 - entered.count)
        if settingNew { return (firstNew.isEmpty ? String(localized: "New passcode") : String(localized: "Again")) + "  " + dots }
        if dictation.listening { return String(localized: "Listening") + "  " + dots }
        return (wrong > 0 ? String(localized: "Try again") : String(localized: "Passcode")) + "  " + dots
    }

    func render() {
        // While listening, the dots fill as digits are heard, and six stop the listening.
        if dictation.listening {
            let digits = String(Self.digits(from: dictation.text).prefix(6))
            if digits.count != entered.count { entered = digits; layout() }
            if digits.count == 6 { dictation.stop() }
        }
        panel.render(ButtonsView(size: CGSize(width: 1000, height: 1200), buttons: panel.buttons, hovered: panel.hovered, title: title, titleHighlight: wrong > 0))
    }
}
