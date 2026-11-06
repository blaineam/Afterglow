import XCTest
import simd
@testable import Afterglow

/// The hand placement against what it must recover: a shape projected from a known position fits
/// back to that position; a flat shape has the palm size asked; the pinch detector's hysteresis.
final class HandGeometryTests: XCTestCase {
    let focal = SIMD2<Float>(1384, 1384)
    let principal = SIMD2<Float>(960, 720)

    // A hand-like shape: palm points on a 5 cm pentagon, fingers out along y.
    func shape() -> [SIMD3<Float>] {
        var s = [SIMD3<Float>](repeating: .zero, count: 21)
        s[0] = SIMD3(0, 0.04, 0)
        s[5] = SIMD3(-0.03, -0.01, 0); s[9] = SIMD3(-0.01, -0.02, 0.005); s[13] = SIMD3(0.01, -0.02, 0); s[17] = SIMD3(0.03, -0.01, -0.005)
        for finger in 0..<5 {
            let base = [1, 5, 9, 13, 17][finger]
            let root = finger == 0 ? SIMD3<Float>(-0.03, 0.02, 0) : s[base]
            for k in 0..<4 where finger == 0 || k > 0 {
                let i = base + k
                if i < 21 { s[i] = root + SIMD3(0, -0.02 * Float(k + 1), 0.002 * Float(k)) }
            }
        }
        return s
    }

    func project(_ points: [SIMD3<Float>], at t: SIMD3<Float>) -> [SIMD2<Float>] {
        points.map { p in
            let q = p + t
            return SIMD2(q.x, q.y) / q.z * focal + principal
        }
    }

    func testFitRecoversThePosition() {
        let t = SIMD3<Float>(0.05, -0.02, 0.35)
        let metric = shape()
        let image = project(metric, at: t)
        let fit = HandGeometry.fitPosition(imageLandmarks: image, metricLandmarks: metric, ids: HandGeometry.palm,
                                           focalLength: focal, principalPoint: principal)
        XCTAssertEqual(fit.position.x, t.x, accuracy: 1e-3)
        XCTAssertEqual(fit.position.y, t.y, accuracy: 1e-3)
        XCTAssertEqual(fit.position.z, t.z, accuracy: 2e-3)
        XCTAssertLessThan(fit.rmsError, 0.5)
        let joints = HandGeometry.placeJoints(imageLandmarks: image, metricLandmarks: metric, centerDepth: fit.position.z,
                                              focalLength: focal, principalPoint: principal)
        XCTAssertEqual(HandGeometry.palmDepth(joints), t.z, accuracy: 3e-3)
    }

    func testFlatShapeHasThePalmSizeAsked() {
        let image = project(shape(), at: SIMD3(0, 0, 0.4))
        let flat = HandGeometry.flatShape(imageLandmarks: image, palmSize: 0.055)
        // The average distance between palm points, in metres, is the size asked.
        var sum: Float = 0; var pairs = 0
        for a in 0..<5 { for b in (a + 1)..<5 { sum += simd_distance(flat[HandGeometry.palm[a]], flat[HandGeometry.palm[b]]); pairs += 1 } }
        XCTAssertEqual(sum / Float(pairs), 0.055, accuracy: 1e-4)
        XCTAssertTrue(flat.allSatisfy { $0.z == 0 })
        XCTAssertEqual(HandGeometry.palmSize(forDepth: 0.05, estimatedDepth: 0.4, measuredDepth: 0.3), 0.0375, accuracy: 1e-6)
    }

    func testFitFailsOnCollinearLandmarks() {
        let image = [SIMD2<Float>](repeating: SIMD2(960, 720), count: 21)
        let fit = HandGeometry.fitPosition(imageLandmarks: image, metricLandmarks: shape(), ids: HandGeometry.palm,
                                           focalLength: focal, principalPoint: principal)
        XCTAssertFalse(fit.rmsError.isFinite)
    }

    func testPinchHysteresis() {
        var pinch = PinchDetector()
        XCTAssertFalse(pinch.update(tipDistance: 0.03))
        XCTAssertFalse(pinch.update(tipDistance: 0.02))     // one close result is a hand passing through
        XCTAssertFalse(pinch.update(tipDistance: 0.02))
        XCTAssertFalse(pinch.update(tipDistance: 0.02))
        XCTAssertTrue(pinch.update(tipDistance: 0.02))      // four in a row is a pinch
        XCTAssertTrue(pinch.update(tipDistance: 0.04))      // still closed below the open distance
        XCTAssertTrue(pinch.update(tipDistance: 0.05))      // one result apart is not a release
        XCTAssertTrue(pinch.update(tipDistance: 0.10, tipsSure: false))   // a guessed tip changes nothing
        XCTAssertTrue(pinch.update(tipDistance: 0.05))
        XCTAssertFalse(pinch.update(tipDistance: 0.05))     // three in a row is
        XCTAssertFalse(pinch.update(tipDistance: 0.01, allowStart: false))
        XCTAssertFalse(pinch.update(tipDistance: 0.01, tipsSure: false))   // counts towards a start (the tip hides behind the thumb)
        // A start blocked midway (tips at different depths) begins the count again.
        XCTAssertFalse(pinch.update(tipDistance: 0.01, allowStart: false))
        XCTAssertFalse(pinch.update(tipDistance: 0.01))
        XCTAssertFalse(pinch.update(tipDistance: 0.01))
        XCTAssertFalse(pinch.update(tipDistance: 0.01))
        XCTAssertTrue(pinch.update(tipDistance: 0.01))
    }

    func testOneEuroFollowsAndSmooths() {
        var filter = OneEuroFilter(minCutoff: 1.5, beta: 8)
        _ = filter.filter(SIMD3(0, 0, 0), time: 0)
        let small = filter.filter(SIMD3(0.001, 0, 0), time: 1.0 / 30)
        XCTAssertLessThan(small.x, 0.001)            // jitter is damped
        var fast = OneEuroFilter(minCutoff: 1.5, beta: 8)
        _ = fast.filter(SIMD3(0, 0, 0), time: 0)
        let moved = fast.filter(SIMD3(0.3, 0, 0), time: 1.0 / 30)
        XCTAssertGreaterThan(moved.x, 0.15)          // a fast move is followed
    }
}
