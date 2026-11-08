import simd

/// Places 21 hand landmarks in 3D in front of the camera, a port of the Unity app's tested
/// `HandGeometry.cs`. Landmarks come in image pixels (x right, y down) in MediaPipe's order; a 3D
/// shape in metres around the hand's centre is moved to where its palm projects best onto the
/// palm's pixels (linear least squares), which gives the hand's distance; each landmark then sits
/// on its own pixel's ray at the depth the shape gives it, so the joints line up with the image.
/// Camera frame here: x right, y down across the image, z forward, metres.
enum HandGeometry {
    static let jointCount = 21
    static let wrist = 0
    static let thumbTip = 4
    static let indexTip = 8
    /// The wrist and the four finger knuckles, which hold still relative to each other.
    static let palm = [0, 5, 9, 13, 17]
    static let all = Array(0..<21)
    /// Bones for drawing: parent to child along each finger.
    static let bones: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4),
        (0, 5), (5, 6), (6, 7), (7, 8),
        (0, 9), (9, 10), (10, 11), (11, 12),
        (0, 13), (13, 14), (14, 15), (15, 16),
        (0, 17), (17, 18), (18, 19), (19, 20),
        (5, 9), (9, 13), (13, 17),
    ]

    /// Where the shape's origin is for the chosen landmarks to project best onto their pixels, and
    /// how far those landmarks still miss, in pixels (infinite when the fit is impossible).
    static func fitPosition(imageLandmarks: [SIMD2<Float>], metricLandmarks: [SIMD3<Float>], ids: [Int],
                            focalLength: SIMD2<Float>, principalPoint: SIMD2<Float>) -> (position: SIMD3<Float>, rmsError: Float) {
        var sumA = 0.0, sumB = 0.0, sumSquares = 0.0, sumRx = 0.0, sumRy = 0.0, sumARx = 0.0, sumBRy = 0.0
        for i in ids {
            let m = metricLandmarks[i]
            let a = Double((imageLandmarks[i].x - principalPoint.x) / focalLength.x)
            let b = Double((imageLandmarks[i].y - principalPoint.y) / focalLength.y)
            let rx = a * Double(m.z) - Double(m.x)
            let ry = b * Double(m.z) - Double(m.y)
            sumA += a; sumB += b
            sumSquares += a * a + b * b
            sumRx += rx; sumRy += ry
            sumARx += a * rx; sumBRy += b * ry
        }
        let n = Double(ids.count)
        let spread = sumSquares - (sumA * sumA + sumB * sumB) / n
        if spread < 1e-12 { return (.zero, .infinity) }
        let tz = ((sumA * sumRx + sumB * sumRy) / n - sumARx - sumBRy) / spread
        let tx = (sumRx + sumA * tz) / n
        let ty = (sumRy + sumB * tz) / n
        let position = SIMD3<Float>(Float(tx), Float(ty), Float(tz))

        var squaredError: Double = 0
        for i in ids {
            let q = metricLandmarks[i] + position
            if q.z <= 0 { return (position, .infinity) }
            let projected = SIMD2(q.x, q.y) / q.z * focalLength + principalPoint
            squaredError += Double(simd_length_squared(projected - imageLandmarks[i]))
        }
        return (position, Float((squaredError / n).squareRoot()))
    }

    /// Each landmark in the camera frame, in metres, on its pixel's ray at the shape's depth for it.
    static func placeJoints(imageLandmarks: [SIMD2<Float>], metricLandmarks: [SIMD3<Float>], centerDepth: Float,
                            focalLength: SIMD2<Float>, principalPoint: SIMD2<Float>) -> [SIMD3<Float>] {
        (0..<jointCount).map { i in
            let z = centerDepth + metricLandmarks[i].z
            let p = imageLandmarks[i]
            return SIMD3((p.x - principalPoint.x) / focalLength.x * z, (p.y - principalPoint.y) / focalLength.y * z, z)
        }
    }

    /// The palm size that would have placed the palm at measuredDepth instead of estimatedDepth.
    static func palmSize(forDepth palmSize: Float, estimatedDepth: Float, measuredDepth: Float) -> Float {
        palmSize * measuredDepth / estimatedDepth
    }

    /// How far ahead of the camera the palm is, from placed joints.
    static func palmDepth(_ joints: [SIMD3<Float>]) -> Float {
        palm.reduce(Float(0)) { $0 + joints[$1].z } / Float(palm.count)
    }

    /// The palm's average width between its landmarks in the image, in pixels.
    static func palmSpan(_ imageLandmarks: [SIMD2<Float>]) -> Float {
        var sum: Float = 0
        var pairs = 0
        for a in 0..<palm.count {
            for b in (a + 1)..<palm.count {
                sum += simd_distance(imageLandmarks[palm[a]], imageLandmarks[palm[b]])
                pairs += 1
            }
        }
        return sum / Float(pairs)
    }

    /// A flat hand facing the camera, as a 3D shape in metres built from its landmarks in the image
    /// at the given palm size: each landmark where it is in the image relative to the palm's
    /// centre, at the scale that makes the palm palmSize across, and no depth.
    static func flatShape(imageLandmarks: [SIMD2<Float>], palmSize: Float) -> [SIMD3<Float>] {
        var centre = SIMD2<Float>.zero
        for id in palm { centre += imageLandmarks[id] }
        centre /= Float(palm.count)
        let span = palmSpan(imageLandmarks)
        let metersPerPixel: Float = span > 0 ? palmSize / span : 0
        return imageLandmarks.map { p in
            let across = (p - centre) * metersPerPixel
            return SIMD3(across.x, across.y, 0)
        }
    }

    /// The knuckles' frame in the image: their centre, the unit line from the index finger's
    /// knuckle to the little finger's, the unit direction across that line away from the fingers,
    /// and the knuckles' width in pixels. The fingers' side is where their middle joints are,
    /// which no bend of the knuckles can take across the line; nil when it cannot be told (a fist
    /// seen end on, or the knuckles in line with the camera).
    static func knuckleFrame(_ landmarks: [SIMD2<Float>]) -> (centre: SIMD2<Float>, along: SIMD2<Float>, away: SIMD2<Float>, width: Float)? {
        let centre = [5, 9, 13, 17].reduce(SIMD2<Float>.zero) { $0 + landmarks[$1] } / 4
        let line = landmarks[17] - landmarks[5]
        let width = simd_length(line)
        guard width > 1 else { return nil }
        let along = line / width
        let across = SIMD2(-along.y, along.x)
        let fingers = [6, 10, 14, 18].reduce(Float(0)) { $0 + simd_dot(landmarks[$1] - centre, across) } / 4
        guard abs(fingers) >= minFingerSide * width else { return nil }
        return (centre, along, fingers > 0 ? -across : across, width)
    }

    /// The fingers' middle joints must sit this far from the knuckle line, in knuckle widths, for
    /// their side to count; the wrist must sit at least this far on the other side.
    static let minFingerSide: Float = 0.15
    static let minWristAway: Float = 0.3
    /// Where the wrist sits for a hand never seen with a believable one, in knuckle widths.
    static let typicalWrist = SIMD2<Float>(0, 1.3)

    /// The wrist in the knuckles' frame, in knuckle widths: along the line, and away from the fingers.
    static func wristInKnuckles(_ landmarks: [SIMD2<Float>], frame: (centre: SIMD2<Float>, along: SIMD2<Float>, away: SIMD2<Float>, width: Float)) -> SIMD2<Float> {
        let w = landmarks[wrist] - frame.centre
        return SIMD2(simd_dot(w, frame.along), simd_dot(w, frame.away)) / frame.width
    }

    /// The wrist's pixel from its place in the knuckles' frame.
    static func wristPixel(_ offset: SIMD2<Float>, frame: (centre: SIMD2<Float>, along: SIMD2<Float>, away: SIMD2<Float>, width: Float)) -> SIMD2<Float> {
        frame.centre + (frame.along * offset.x + frame.away * offset.y) * frame.width
    }
}
