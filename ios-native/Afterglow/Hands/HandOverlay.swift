import simd

/// Builds the triangles that draw the tracked hands (bones as thin ribbons facing the eyes, joints
/// as small squares) and the grab demo's cubes, in world space with a colour each, for the
/// overlay pipeline. Rebuilt every frame on the CPU: a few hundred vertices.
struct HandOverlay {
    private(set) var vertices: [OverlayVertex] = []

    static let handColor = SIMD4<Float>(0.2, 0.9, 1.0, 1)        // cyan
    static let pinchColor = SIMD4<Float>(1.0, 0.25, 0.85, 1)     // magenta
    static let rightTint = SIMD4<Float>(0.9, 1.0, 0.6, 1)

    mutating func clear() { vertices.removeAll(keepingCapacity: true) }

    /// A ribbon from a to b, `width` metres across, facing `eye`.
    mutating func addBone(_ a: SIMD3<Float>, _ b: SIMD3<Float>, width: Float, eye: SIMD3<Float>, color: SIMD4<Float>) {
        let along = b - a
        let toEye = eye - (a + b) / 2
        var side = simd_cross(along, toEye)
        let length = simd_length(side)
        if length < 1e-6 { return }
        side = side / length * (width / 2)
        let p0 = a - side, p1 = a + side, p2 = b + side, p3 = b - side
        vertices += [OverlayVertex(position: p0, color: color), OverlayVertex(position: p1, color: color), OverlayVertex(position: p2, color: color),
                     OverlayVertex(position: p0, color: color), OverlayVertex(position: p2, color: color), OverlayVertex(position: p3, color: color)]
    }

    /// A square of `size` metres at p, facing `eye`.
    mutating func addSquare(_ p: SIMD3<Float>, size: Float, eye: SIMD3<Float>, color: SIMD4<Float>) {
        let n = simd_normalize(eye - p)
        var up = SIMD3<Float>(0, 1, 0)
        if abs(simd_dot(n, up)) > 0.99 { up = SIMD3(1, 0, 0) }
        let right = simd_normalize(simd_cross(up, n)) * (size / 2)
        let upv = simd_normalize(simd_cross(n, right)) * (size / 2)
        let p0 = p - right - upv, p1 = p + right - upv, p2 = p + right + upv, p3 = p - right + upv
        vertices += [OverlayVertex(position: p0, color: color), OverlayVertex(position: p1, color: color), OverlayVertex(position: p2, color: color),
                     OverlayVertex(position: p0, color: color), OverlayVertex(position: p2, color: color), OverlayVertex(position: p3, color: color)]
    }

    /// A cube of `size` metres centred at c, each face shaded by its normal.
    mutating func addCube(_ c: SIMD3<Float>, size: Float, color: SIMD4<Float>) {
        let h = size / 2
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, Float)] = [
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0), 1.0),
            (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), 0.7),
            (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0), 0.85),
            (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0), 0.85),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1), 1.0),
            (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1), 0.5),
        ]
        for (n, r, u, shade) in faces {
            let centre = c + n * h
            let col = SIMD4(color.x * shade, color.y * shade, color.z * shade, color.w)
            let p0 = centre - r * h - u * h, p1 = centre + r * h - u * h, p2 = centre + r * h + u * h, p3 = centre - r * h + u * h
            vertices += [OverlayVertex(position: p0, color: col), OverlayVertex(position: p1, color: col), OverlayVertex(position: p2, color: col),
                         OverlayVertex(position: p0, color: col), OverlayVertex(position: p2, color: col), OverlayVertex(position: p3, color: col)]
        }
    }

    /// Draws a hand: bones, joints, and the pinch point when pinching.
    mutating func addHand(_ hand: TrackedHandState, eye: SIMD3<Float>) {
        let base = hand.isRight ? Self.handColor * Self.rightTint : Self.handColor
        for (a, b) in HandGeometry.bones {
            addBone(hand.joints[a], hand.joints[b], width: 0.006, eye: eye, color: base)
        }
        for (i, joint) in hand.joints.enumerated() {
            let tip = i == HandGeometry.thumbTip || i == HandGeometry.indexTip
            addSquare(joint, size: tip ? 0.014 : 0.009, eye: eye, color: tip && hand.pinched ? Self.pinchColor : base)
        }
        if hand.pinched {
            addSquare(hand.pinchPoint, size: 0.02, eye: eye, color: Self.pinchColor)
        }
    }
}

/// The grab demo: a pinch picks up a glowing cube (or makes one where nothing is within reach) and
/// carries it; the release leaves it there. A hand that leaves the camera's view keeps its cube
/// where it was until it is seen again open (or for ten seconds), as the Unity app does. Enough to
/// feel the hands before the games arrive.
struct GrabDemo {
    struct Cube {
        var position: SIMD3<Float>
        var color: SIMD4<Float>
    }
    private(set) var cubes: [Cube] = []
    private var held: [Int: Int] = [:]      // hand side (0 left, 1 right) -> cube index
    private var wasPinched = [false, false]
    private var lastSeen = [0.0, 0.0]
    private static let keepSeconds = 10.0
    private static let size: Float = 0.06
    private static let grabRange: Float = 0.08
    private static let colors: [SIMD4<Float>] = [SIMD4(1.0, 0.3, 0.8, 1), SIMD4(0.3, 0.9, 1.0, 1), SIMD4(1.0, 0.8, 0.3, 1), SIMD4(0.6, 0.4, 1.0, 1)]

    mutating func update(hands: [TrackedHandState], time: Double) {
        var pinchedNow = [false, false]
        var present = [false, false]
        for hand in hands {
            let side = hand.isRight ? 1 : 0
            pinchedNow[side] = hand.pinched
            present[side] = true
            lastSeen[side] = time
            if hand.pinched {
                if let index = held[side] {
                    cubes[index].position = hand.pinchPoint
                } else if !wasPinched[side] {
                    // A new pinch: take the nearest cube within reach, else make one.
                    if let nearest = cubes.indices.min(by: { simd_distance(cubes[$0].position, hand.pinchPoint) < simd_distance(cubes[$1].position, hand.pinchPoint) }),
                       simd_distance(cubes[nearest].position, hand.pinchPoint) < Self.grabRange, !held.values.contains(nearest) {
                        held[side] = nearest
                        log("[Hands] Grabbed cube \(nearest)")
                    } else {
                        cubes.append(Cube(position: hand.pinchPoint, color: Self.colors[cubes.count % Self.colors.count]))
                        held[side] = cubes.count - 1
                        log(String(format: "[Hands] Placed cube %d at (%.2f, %.2f, %.2f)", cubes.count - 1, hand.pinchPoint.x, hand.pinchPoint.y, hand.pinchPoint.z))
                    }
                }
            }
        }
        for side in 0..<2 where held[side] != nil {
            // Released when the hand is seen open, or has been gone too long; out of view it holds.
            let gone = !present[side] && time - lastSeen[side] > Self.keepSeconds
            if (present[side] && !pinchedNow[side]) || gone {
                log("[Hands] Released cube \(held[side]!)\(gone ? " (hand gone)" : "")")
                held[side] = nil
            }
        }
        for side in 0..<2 where present[side] { wasPinched[side] = pinchedNow[side] }
    }

    func draw(into overlay: inout HandOverlay) {
        for cube in cubes { overlay.addCube(cube.position, size: Self.size, color: cube.color) }
    }
}
