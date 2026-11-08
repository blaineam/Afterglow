import Foundation

/// Whether a site may have the wearer's hand positions in a WebXR session. Hands are the app's own
/// use of the camera; a page gets them only when the wearer says so, per site: just this time, or
/// always, changeable from the hand button on the browser's bar (owner, 2026-11-08). A private
/// tab remembers nothing. Without them a page still gets the head pose and a plain select.
enum HandAccess: String, Sendable {
    case ask, always, never

    /// The hand button's cycle.
    var next: HandAccess {
        switch self {
        case .ask: .always
        case .always: .never
        case .never: .ask
        }
    }

    private static let key = "webxr.handAccess"

    static func policy(for host: String, in defaults: UserDefaults = .standard) -> HandAccess {
        let saved = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return saved[host].flatMap(HandAccess.init(rawValue:)) ?? .ask
    }

    static func set(_ policy: HandAccess, for host: String, in defaults: UserDefaults = .standard) {
        var saved = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        saved[host] = policy == .ask ? nil : policy.rawValue
        defaults.set(saved, forKey: key)
    }
}
