import XCTest
import simd
@testable import Afterglow

/// The optics port against the Unity app's numbers: its phone log reads
/// `Afterglow Viewer: screen 0.1584 x 0.0729 m ... left eye fov L60.0 R50.0 B57.6 T57.6`.
final class LensDistortionTests: XCTestCase {
    let lens = LensDistortion(viewer: .afterglowViewer, screenWidthMeters: 0.1584, screenHeightMeters: 0.0729)

    func testFieldOfViewMatchesTheUnityApp() {
        let fov = lens.fieldOfView(.left) * (180 / Float.pi)
        XCTAssertEqual(fov.x, 60.0, accuracy: 0.05)
        XCTAssertEqual(fov.y, 50.0, accuracy: 0.05)
        XCTAssertEqual(fov.z, 57.6, accuracy: 0.05)
        XCTAssertEqual(fov.w, 57.6, accuracy: 0.05)
        let right = lens.fieldOfView(.right) * (180 / Float.pi)
        XCTAssertEqual(right.x, 50.0, accuracy: 0.05)
        XCTAssertEqual(right.y, 60.0, accuracy: 0.05)
    }

    func testDistortionRoundTrips() {
        let d = PolynomialRadialDistortion(coefficients: [0.3358, 0.5535])
        for r: Float in [0.1, 0.4, 0.8, 1.2] {
            let p = SIMD2<Float>(r * 0.6, r * 0.8)
            let back = d.distortInverse(d.distort(p))
            XCTAssertEqual(back.x, p.x, accuracy: 1e-3)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-3)
        }
        XCTAssertEqual(d.distortRadius(1), 1 + 0.3358 + 0.5535, accuracy: 1e-6)
    }

    func testScreenAndTextureUvsRoundTrip() {
        for eye in Eye.allCases {
            for (u, v) in [(0.2, 0.3), (0.5, 0.5), (0.8, 0.9)] {
                let texture = SIMD2<Float>(Float(u), Float(v))
                let screen = lens.textureUvToScreenUv(texture, eye: eye)
                let back = lens.screenUvToTextureUv(screen, eye: eye)
                XCTAssertEqual(back.x, texture.x, accuracy: 2e-3)
                XCTAssertEqual(back.y, texture.y, accuracy: 2e-3)
            }
        }
    }

    func testEyesSitOnTheirHalvesOfTheScreen() {
        // The texture's centre lands near the lens's optical centre on the screen: a quarter in for
        // the left eye and three quarters for the right, both at mid height (centred lenses).
        let left = lens.textureUvToScreenUv(SIMD2(0.5, 0.5), eye: .left)
        let right = lens.textureUvToScreenUv(SIMD2(0.5, 0.5), eye: .right)
        XCTAssertLessThan(left.x, 0.5)
        XCTAssertGreaterThan(right.x, 0.5)
        XCTAssertEqual(left.y, right.y, accuracy: 1e-6)
        XCTAssertEqual(right.x - 0.5, 0.5 - left.x, accuracy: 1e-4)
        let mesh = lens.distortionMesh(.left)
        XCTAssertEqual(mesh.vertices.count, LensDistortion.meshResolution * LensDistortion.meshResolution)
        XCTAssertEqual(mesh.indices.count, (LensDistortion.meshResolution - 1) * (LensDistortion.meshResolution - 1) * 6)
        XCTAssertTrue(mesh.vertices.allSatisfy { $0.eye == 0 && $0.position.x <= 1.05 && $0.position.x >= -1.05 })
    }

    func testProjectionMapsNearAndFarToMetalDepth() {
        let p = lens.projectionMatrix(.left, near: 0.1, far: 100)
        let near = p * SIMD4<Float>(0, 0, -0.1, 1)
        let far = p * SIMD4<Float>(0, 0, -100, 1)
        XCTAssertEqual(near.z / near.w, 0, accuracy: 1e-5)
        XCTAssertEqual(far.z / far.w, 1, accuracy: 1e-4)
    }
}
