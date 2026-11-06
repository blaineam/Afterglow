import simd

enum Eye: Int, CaseIterable, Sendable {
    case left = 0
    case right = 1
}

/// Per-eye field of view, projection, eye offset and distortion mesh for a viewer on a screen of
/// known physical size (landscape, metres). Ported from the Cardboard SDK (sdk/lens_distortion.cc
/// and sdk/distortion_mesh.cc, Apache License 2.0) by way of the Unity app's `LensDistortion.cs`,
/// which it matches number for number so the two apps show the same picture through the lenses.
/// Screen UVs follow the SDK: 0-1 across the whole landscape screen, origin at the bottom left,
/// left eye on the left half.
struct LensDistortion: Sendable {
    static let meshResolution = 40

    /// Assumed bezel between the tray and the screen's lit area.
    private static let defaultBorderSizeMeters: Float = 0.003

    private struct Viewport {
        var width: Float
        var height: Float
        var xEyeOffset: Float
        var yEyeOffset: Float
    }

    /// Angles from the eye's optical axis to the edges of its view, in radians:
    /// (left, right, bottom, top).
    typealias FieldOfView = SIMD4<Float>

    let viewer: ViewerParams
    let distortion: PolynomialRadialDistortion
    let screenWidthMeters: Float
    let screenHeightMeters: Float
    private let fieldOfView: [FieldOfView]

    init(viewer: ViewerParams, screenWidthMeters: Float, screenHeightMeters: Float) {
        self.viewer = viewer
        self.distortion = PolynomialRadialDistortion(coefficients: viewer.distortionCoefficients)
        self.screenWidthMeters = screenWidthMeters
        self.screenHeightMeters = screenHeightMeters
        let left = Self.calculateFieldOfView(viewer: viewer, distortion: distortion,
                                             screenWidth: screenWidthMeters, screenHeight: screenHeightMeters)
        fieldOfView = [left, FieldOfView(left.y, left.x, left.z, left.w)]
    }

    /// Height of the lenses' optical centre above the bottom of the screen.
    var yEyeOffsetMeters: Float {
        Self.yEyeOffsetMeters(viewer: viewer, screenHeight: screenHeightMeters)
    }

    func fieldOfView(_ eye: Eye) -> FieldOfView { fieldOfView[eye.rawValue] }

    /// Eye position in head space, in metres: half the lens separation to either side.
    func eyeOffset(_ eye: Eye) -> SIMD3<Float> {
        SIMD3((eye == .left ? -0.5 : 0.5) * viewer.interLensDistance, 0, 0)
    }

    /// A right-handed projection for Metal (clip z from 0 at `near` to 1 at `far`), looking down -z.
    func projectionMatrix(_ eye: Eye, near: Float, far: Float) -> simd_float4x4 {
        let fov = fieldOfView[eye.rawValue]
        return Self.frustum(left: -tan(fov.x) * near, right: tan(fov.y) * near,
                            bottom: -tan(fov.z) * near, top: tan(fov.w) * near, near: near, far: far)
    }

    static func frustum(left l: Float, right r: Float, bottom b: Float, top t: Float, near n: Float, far f: Float) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(2 * n / (r - l), 0, 0, 0),
            SIMD4(0, 2 * n / (t - b), 0, 0),
            SIMD4((r + l) / (r - l), (t + b) / (t - b), f / (n - f), -1),
            SIMD4(0, 0, n * f / (n - f), 0)))
    }

    /// The eye texture UV seen through the lens at a screen UV (the SDK's DistortedUvForUndistortedUv).
    func screenUvToTextureUv(_ screenUv: SIMD2<Float>, eye: Eye) -> SIMD2<Float> {
        let (screen, texture) = viewports(eye)
        let tanAngle = SIMD2(screenUv.x * screen.width - screen.xEyeOffset,
                             screenUv.y * screen.height - screen.yEyeOffset)
        let distorted = distortion.distort(tanAngle)
        return SIMD2((distorted.x + texture.xEyeOffset) / texture.width,
                     (distorted.y + texture.yEyeOffset) / texture.height)
    }

    /// The screen UV where an eye texture UV appears (the SDK's UndistortedUvForDistortedUv).
    func textureUvToScreenUv(_ textureUv: SIMD2<Float>, eye: Eye) -> SIMD2<Float> {
        let (screen, texture) = viewports(eye)
        let tanAngle = SIMD2(textureUv.x * texture.width - texture.xEyeOffset,
                             textureUv.y * texture.height - texture.yEyeOffset)
        let undistorted = distortion.distortInverse(tanAngle)
        return SIMD2((undistorted.x + screen.xEyeOffset) / screen.width,
                     (undistorted.y + screen.yEyeOffset) / screen.height)
    }

    /// One vertex of the distortion mesh: a position in normalized device coordinates for the
    /// whole screen (-1..1, y up), the eye texture UV it shows (origin bottom left), and the eye.
    struct MeshVertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
        var eye: UInt32
    }

    /// A grid mesh that warps one eye's texture onto its part of the screen, as triangle-list
    /// indices into the vertices. The same grid as the Unity app's `CreateDistortionMesh`.
    func distortionMesh(_ eye: Eye) -> (vertices: [MeshVertex], indices: [UInt32]) {
        let n = Self.meshResolution
        var vertices = [MeshVertex]()
        vertices.reserveCapacity(n * n)
        for row in 0..<n {
            for col in 0..<n {
                let textureUv = SIMD2(Float(col) / Float(n - 1), Float(row) / Float(n - 1))
                let screenUv = textureUvToScreenUv(textureUv, eye: eye)
                vertices.append(MeshVertex(position: SIMD2(2 * screenUv.x - 1, 2 * screenUv.y - 1),
                                           uv: textureUv, eye: UInt32(eye.rawValue)))
            }
        }
        var indices = [UInt32]()
        indices.reserveCapacity((n - 1) * (n - 1) * 6)
        for row in 0..<(n - 1) {
            for col in 0..<(n - 1) {
                let index = UInt32(row * n + col)
                let stride = UInt32(n)
                indices += [index, index + stride, index + 1, index + 1, index + stride, index + stride + 1]
            }
        }
        return (vertices, indices)
    }

    private static func calculateFieldOfView(viewer: ViewerParams, distortion: PolynomialRadialDistortion,
                                             screenWidth: Float, screenHeight: Float) -> FieldOfView {
        let deviceFov = viewer.leftEyeFieldOfViewAngles
        let toLens = viewer.screenToLensDistance
        let outerDistance = (screenWidth - viewer.interLensDistance) / 2
        let innerDistance = viewer.interLensDistance / 2
        let bottomDistance = yEyeOffsetMeters(viewer: viewer, screenHeight: screenHeight)
        let topDistance = screenHeight - bottomDistance

        // The lens widens what the screen shows, so the visible angle to each screen edge is the
        // distorted tan-angle; the viewer's own limits clamp it.
        let outerAngle = atan(distortion.distort(SIMD2(outerDistance / toLens, 0)).x)
        let innerAngle = atan(distortion.distort(SIMD2(innerDistance / toLens, 0)).x)
        let bottomAngle = atan(distortion.distort(SIMD2(0, bottomDistance / toLens)).y)
        let topAngle = atan(distortion.distort(SIMD2(0, topDistance / toLens)).y)
        let degrees = Float.pi / 180
        return FieldOfView(min(outerAngle, deviceFov[0] * degrees),
                           min(innerAngle, deviceFov[1] * degrees),
                           min(bottomAngle, deviceFov[2] * degrees),
                           min(topAngle, deviceFov[3] * degrees))
    }

    private static func yEyeOffsetMeters(viewer: ViewerParams, screenHeight: Float) -> Float {
        switch viewer.verticalAlignment {
        case .bottom: return viewer.trayToLensDistance - defaultBorderSizeMeters
        case .top: return screenHeight - viewer.trayToLensDistance - defaultBorderSizeMeters
        case .center: return screenHeight / 2
        }
    }

    /// Screen and eye-texture extents in tan-angle units, with the optical centre's position.
    private func viewports(_ eye: Eye) -> (screen: Viewport, texture: Viewport) {
        let toLens = viewer.screenToLensDistance
        let eyeCenterMeters = eye == .left
            ? (screenWidthMeters - viewer.interLensDistance) / 2
            : (screenWidthMeters + viewer.interLensDistance) / 2
        let screen = Viewport(width: screenWidthMeters / toLens, height: screenHeightMeters / toLens,
                              xEyeOffset: eyeCenterMeters / toLens, yEyeOffset: yEyeOffsetMeters / toLens)
        let fov = fieldOfView[eye.rawValue]
        let texture = Viewport(width: tan(fov.x) + tan(fov.y), height: tan(fov.z) + tan(fov.w),
                               xEyeOffset: tan(fov.x), yEyeOffset: tan(fov.z))
        return (screen, texture)
    }
}
