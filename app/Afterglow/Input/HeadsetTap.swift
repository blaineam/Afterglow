import CoreMotion
import simd

/// A tap on the viewer, read off the accelerometer: a finger tap on the shell is a short, sharp
/// spike in the user's own acceleration (gravity removed) that a head turn never makes. Two
/// within a short interval are a double tap, which selects what the cursor was on when the first
/// tap landed (the owner's ask, 2026-11-06): the selection target is sampled at the first tap and
/// confirmed at the second, so the tap's own jolt does not move the cursor off it.
final class HeadsetTapDetector: @unchecked Sendable {
    /// The user acceleration magnitude, in g, that counts as a tap.
    var threshold: Float = 0.9
    /// Two taps closer than this are one tap's ringing; farther apart than `doubleTapSeconds`
    /// they are separate.
    private let debounceSeconds = 0.12
    private let doubleTapSeconds = 0.45
    private let lock = NSLock()
    private var lastTap: Double = -10
    private var pendingFirst: Double?
    private(set) var tapCount = 0
    private(set) var doubleTapCount = 0

    /// Feeds a motion sample. Returns 1 for a first tap (sample the target now), 2 for a double
    /// tap completing (select it), 0 otherwise.
    func feed(_ motion: CMDeviceMotion) -> Int {
        let a = motion.userAcceleration
        return feed(magnitude: Float(sqrt(a.x * a.x + a.y * a.y + a.z * a.z)), time: motion.timestamp)
    }

    /// The rule on its own, for tests: the user acceleration's magnitude in g at a time.
    func feed(magnitude: Float, time now: Double) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let first = pendingFirst, now - first > doubleTapSeconds {
            pendingFirst = nil
        }
        guard magnitude >= threshold, now - lastTap > debounceSeconds else { return 0 }
        lastTap = now
        tapCount += 1
        if let first = pendingFirst, now - first <= doubleTapSeconds {
            pendingFirst = nil
            doubleTapCount += 1
            return 2
        }
        pendingFirst = now
        return 1
    }
}
