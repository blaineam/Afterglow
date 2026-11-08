import simd

/// Radial lens distortion p' = p (1 + K1 r^2 + K2 r^4 + ...), with r in tan-angle units: distance
/// on the screen divided by the distance from the eye to the screen. Ported from the Cardboard SDK
/// (sdk/polynomial_radial_distortion.cc, Apache License 2.0) by way of the Unity app's
/// `PolynomialRadialDistortion.cs`.
struct PolynomialRadialDistortion: Sendable {
    private static let maxInverseIterations = 100
    let coefficients: [Float]

    init(coefficients: [Float]) {
        self.coefficients = coefficients
    }

    func distortionFactor(radiusSquared: Float) -> Float {
        var radiusFactor: Float = 1
        var factor: Float = 1
        for coefficient in coefficients {
            radiusFactor *= radiusSquared
            factor += coefficient * radiusFactor
        }
        return factor
    }

    func distortRadius(_ radius: Float) -> Float {
        radius * distortionFactor(radiusSquared: radius * radius)
    }

    func distort(_ point: SIMD2<Float>) -> SIMD2<Float> {
        point * distortionFactor(radiusSquared: simd_length_squared(point))
    }

    /// Solves distort(result) = point for the radius with the secant method, like the SDK. The
    /// iteration cap only guards against coefficients that never converge.
    func distortInverse(_ point: SIMD2<Float>) -> SIMD2<Float> {
        let radius = simd_length(point)
        if radius < Float.ulpOfOne {
            return .zero
        }
        var r0 = radius / 2
        var r1 = radius / 3
        var dr0 = radius - distortRadius(r0)
        var i = 0
        while i < Self.maxInverseIterations && abs(r1 - r0) > 0.0001 {
            let dr1 = radius - distortRadius(r1)
            let r2 = r1 - dr1 * ((r1 - r0) / (dr1 - dr0))
            r0 = r1
            r1 = r2
            dr0 = dr1
            i += 1
        }
        return point * (r1 / radius)
    }
}
