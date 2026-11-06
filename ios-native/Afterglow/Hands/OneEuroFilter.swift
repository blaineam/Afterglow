import simd

/// The One Euro filter (Casiez, Roussel and Vogel, 2012): a low-pass filter whose cutoff rises with
/// speed, so a still hand holds steady and a moving one keeps up. The cutoff is minCutoff Hz at
/// rest and rises by beta Hz per unit per second of smoothed speed.
struct OneEuroFilter {
    let minCutoff: Float
    let beta: Float
    let derivativeCutoff: Float
    private var value = SIMD3<Float>.zero
    private var derivative = SIMD3<Float>.zero
    private var lastTime: Double = 0
    private var hasValue = false

    init(minCutoff: Float, beta: Float, derivativeCutoff: Float = 1) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func reset() { hasValue = false }

    mutating func filter(_ sample: SIMD3<Float>, time: Double) -> SIMD3<Float> {
        if !hasValue {
            value = sample
            derivative = .zero
            lastTime = time
            hasValue = true
            return sample
        }
        if time <= lastTime { return value }
        let dt = Float(time - lastTime)
        lastTime = time
        derivative = simd_mix(derivative, (sample - value) / dt, SIMD3(repeating: Self.alpha(derivativeCutoff, dt)))
        let cutoff = minCutoff + beta * simd_length(derivative)
        value = simd_mix(value, sample, SIMD3(repeating: Self.alpha(cutoff, dt)))
        return value
    }

    private static func alpha(_ cutoff: Float, _ dt: Float) -> Float {
        let tau = 1 / (2 * Float.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
