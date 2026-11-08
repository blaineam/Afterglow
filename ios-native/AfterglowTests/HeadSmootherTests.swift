import XCTest
import simd
@testable import Afterglow

/// The head smoother: a fast shake is damped, a steady turn is followed, a jump is taken at once.
final class HeadSmootherTests: XCTestCase {
    func yaw(_ radians: Float) -> simd_quatf { simd_quatf(angle: radians, axis: SIMD3(0, 1, 0)) }
    func angle(_ q: simd_quatf) -> Float { 2 * atan2(q.imag.y, q.real) }

    func testShakeIsDampedAndTurnsFollowed() {
        var smoother = HeadSmoother()
        // A 12 Hz shake of 2 degrees at 60 frames a second.
        var worst: Float = 0
        for i in 0..<240 {
            let t = Double(i) / 60
            let out = smoother.filter(yaw(2 * .pi / 180 * Float(sin(2 * .pi * 12 * t))), time: t, percent: 50)
            if i > 60 { worst = max(worst, abs(angle(out))) }
        }
        XCTAssertLessThan(worst, 1 * .pi / 180, "a 2 degree shake comes through under 1 degree")

        // A steady 90 degree/s turn: the output trails by less than 3 degrees.
        smoother.reset()
        var last = yaw(0)
        for i in 0..<120 {
            let t = Double(i) / 60
            last = smoother.filter(yaw(.pi / 2 * Float(t)), time: t, percent: 50)
        }
        XCTAssertLessThan(abs(angle(last) - .pi / 2 * Float(119) / 60), 3 * .pi / 180)

        // A recentre is a jump, taken at once.
        let jumped = smoother.filter(yaw(-.pi / 2), time: 2.01, percent: 50)
        XCTAssertLessThan(abs(angle(jumped) + .pi / 2), 1e-3)

        // Off passes the rotation through.
        var off = HeadSmoother()
        _ = off.filter(yaw(0), time: 0, percent: 0)
        XCTAssertLessThan(abs(angle(off.filter(yaw(0.1), time: 1.0 / 60, percent: 0)) - 0.1), 1e-4)
        XCTAssertEqual(HeadSmoother.lead(percent: 0), 0)
    }
}
