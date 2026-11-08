import Foundation
import simd

/// Smooths the head's rotation before the frame is drawn: a low-pass on the predicted rotation,
/// so a fast or shaky head doesn't shake the world with it (owner, 2026-11-08: "the head
/// tracking is too responsive ... smooth it out"). The rotation still leads the camera image by
/// the prediction; half the filter's lag is predicted back (`lead`), so a steady turn keeps up.
/// A jump (a recentre, a tracking switch, a long gap) is taken at once.
struct HeadSmoother {
    private var rotation: simd_quatf?
    private var lastTime: Double = 0

    /// The filter's cutoff in hertz for a strength in percent (0 is off): 5.4 Hz at 50%, 2.4 at 100%.
    static func cutoff(percent: Int) -> Float? {
        percent <= 0 ? nil : 12 * pow(0.2, Float(min(percent, 100)) / 100)
    }

    /// Seconds of extra prediction that win back half the filter's lag.
    static func lead(percent: Int) -> Double {
        guard let fc = cutoff(percent: percent) else { return 0 }
        return 0.5 / (2 * .pi * Double(fc))
    }

    /// Turns bigger than this between frames are jumps, not head motion.
    static let jumpRadians: Float = .pi / 3

    mutating func filter(_ q: simd_quatf, time: Double, percent: Int) -> simd_quatf {
        guard let fc = Self.cutoff(percent: percent), let previous = rotation, time > lastTime, time - lastTime < 0.2 else {
            rotation = q
            lastTime = time
            return q
        }
        var target = q
        if simd_dot(previous.vector, target.vector) < 0 { target = simd_quatf(vector: -target.vector) }
        let turn = 2 * acos(min(abs(simd_dot(previous.vector, target.vector)), 1))
        if turn > Self.jumpRadians {
            rotation = q
            lastTime = time
            return q
        }
        let dt = Float(time - lastTime)
        let alpha = 1 - exp(-2 * .pi * fc * dt)
        let smoothed = simd_normalize(simd_slerp(previous, target, alpha))
        rotation = smoothed
        lastTime = time
        return smoothed
    }

    mutating func reset() { rotation = nil }
}
