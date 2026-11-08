import simd

/// Where the page hangs in the world: a flat pane of `widthMeters` across at `distance` ahead of
/// where the head was when it was placed (or recentred), facing the head. The gaze ray from the
/// head's midpoint along its forward hits the pane at a page point; that is the cursor.
struct BrowserWindow {
    var centre = SIMD3<Float>(0, 0, -1.3)
    var right = SIMD3<Float>(1, 0, 0)
    var up = SIMD3<Float>(0, 1, 0)
    var widthMeters: Float = 1.25
    var aspect: Float = 1280.0 / 800.0
    var heightMeters: Float { widthMeters / aspect }
    var normal: SIMD3<Float> { simd_cross(right, up) }

    /// Where a panel of this height hangs under this pane, tilted like a desk (its top edge away
    /// from the viewer): its top edge just under this pane's bottom edge and a little nearer, so
    /// the two never overlap from where the viewer stands (owner, 2026-11-08: the keyboard rode
    /// up over the window it types into).
    func hanging(height: Float, gap: Float = 0.025, tilt: Float = 0.35) -> (centre: SIMD3<Float>, up: SIMD3<Float>) {
        let tilted = simd_quatf(angle: -tilt, axis: right).act(up)
        let edge = centre - up * (heightMeters / 2 + gap) + normal * 0.02
        return (edge - tilted * (height / 2), tilted)
    }

    /// Places the pane `distance` ahead of a head transform, level, facing it.
    mutating func place(ahead head: simd_float4x4, distance: Float = 1.3) {
        let position = head.columns.3.xyz
        var forward = -head.columns.2.xyz
        forward.y = 0
        if simd_length(forward) < 1e-3 { forward = SIMD3(0, 0, -1) }
        forward = simd_normalize(forward)
        centre = position + forward * distance
        right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        up = SIMD3(0, 1, 0)
        log(String(format: "[WebXR] Window placed at (%.2f, %.2f, %.2f), %.2f x %.2f m", centre.x, centre.y, centre.z, widthMeters, heightMeters))
    }

    /// The pane's corners as two triangles with texture coordinates (origin top left).
    var quad: [QuadVertex] {
        let hw = right * (widthMeters / 2), hh = up * (heightMeters / 2)
        let tl = centre - hw + hh, tr = centre + hw + hh, bl = centre - hw - hh, br = centre + hw - hh
        return [QuadVertex(position: tl, uv: SIMD2(0, 0)), QuadVertex(position: tr, uv: SIMD2(1, 0)), QuadVertex(position: br, uv: SIMD2(1, 1)),
                QuadVertex(position: tl, uv: SIMD2(0, 0)), QuadVertex(position: br, uv: SIMD2(1, 1)), QuadVertex(position: bl, uv: SIMD2(0, 1))]
    }

    /// Where a ray from `origin` along `direction` hits the pane, as texture coordinates (0-1,
    /// origin top left) and the hit point, or nil when it misses or looks away.
    func hit(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (uv: SIMD2<Float>, point: SIMD3<Float>)? {
        let n = normal
        let denominator = simd_dot(direction, n)
        if abs(denominator) < 1e-5 { return nil }
        let t = simd_dot(centre - origin, n) / denominator
        if t <= 0 { return nil }
        let point = origin + direction * t
        let local = point - centre
        let x = simd_dot(local, right) / widthMeters + 0.5
        let y = 0.5 - simd_dot(local, up) / heightMeters
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return (SIMD2(x, y), point)
    }

    /// The gaze: the head's midpoint along its forward.
    func gaze(from head: simd_float4x4) -> (uv: SIMD2<Float>, point: SIMD3<Float>)? {
        hit(origin: head.columns.3.xyz, direction: -head.columns.2.xyz)
    }
}
