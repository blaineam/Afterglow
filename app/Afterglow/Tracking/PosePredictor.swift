import CoreMotion
import simd

/// A camera pose ARKit delivered: when the image was taken and the camera's transform in the world
/// (x right, y up, -z forward in camera axes).
struct PoseSample: Sendable {
    var timestamp: Double
    var transform: simd_float4x4
}

/// Predicts the head pose ahead to the moment a frame will be on the screen. ARKit's pose is the
/// camera's at the time its image was taken, 30-50 ms before the frame built from it is displayed;
/// shown as it is, the picture lags a head turn by that much. The gyroscope runs at 100 Hz on a
/// clock ARKit shares (system uptime), so the rotation since the image is read off the device
/// motion attitude between the image's time and now, and the rest extrapolated from the latest
/// rotation rate. Position is extrapolated from the velocity between the last two ARKit poses.
///
/// CoreMotion's device axes (x along the short side, y along the long side towards the top, z out of
/// the screen) are turned into ARKit's camera axes, which are the device's held landscape right
/// (home button on the right): camera x = -device y, camera y = device x, camera z = device z.
/// Whether that mapping is right shows in the log: the predicted pose is checked against the pose
/// that then arrives, and `[Pose]` reports the error with and without prediction every five seconds.
final class PosePredictor: @unchecked Sendable {
    private struct MotionSample {
        var timestamp: Double
        var attitude: simd_quatd      // reference frame from device
        var rate: SIMD3<Double>       // rad/s in device axes
    }

    private let motion = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var samples: [MotionSample] = []
    private let capacity = 64

    // Rotation from device axes into camera axes: +90 degrees about z.
    private let cameraFromDevice = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 0, 1))

    // The last two ARKit poses, for velocity; and the prediction made for the next pose's time,
    // to score.
    private var previous: PoseSample?
    private var latest: PoseSample?
    private var velocity = SIMD3<Float>(repeating: 0)
    private var errorPredicted: Double = 0
    private var errorRaw: Double = 0
    private var scored = 0
    private var motionCount = 0

    var isRunning: Bool { motion.isDeviceMotionActive }
    /// Taps on the viewer, read off the same motion samples.
    let taps = HeadsetTapDetector()
    /// Called on the motion queue with 1 for a first tap and 2 for a double tap.
    var onTap: ((Int) -> Void)?
    /// Gravity and rotation rate, for the lock's reading of whether the viewer is still on.
    var onMotion: ((SIMD3<Double>, SIMD3<Double>, Double) -> Void)?

    // The 3DoF world: CoreMotion's reference frame (z up, x arbitrary) turned to y up, with the
    // heading at the first reading taken as straight ahead (-z), as ARKit's gravity alignment does.
    private let worldFromReference = simd_quatd(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
    private var headingCorrection: simd_quatd?

    func stop() {
        motion.stopDeviceMotionUpdates()
        lock.lock()
        samples.removeAll()
        latest = nil
        previous = nil
        headingCorrection = nil
        lock.unlock()
    }

    /// The camera's rotation in a y-up world at `time`, from the attitude alone (3DoF): the
    /// camera stays at the origin. Nil before the first motion sample.
    func attitudeCameraTransform(at time: Double) -> simd_float4x4? {
        lock.lock()
        defer { lock.unlock() }
        guard let attitude = attitudeLocked(at: time) else { return nil }
        // reference-from-camera = reference-from-device * device-from-camera.
        var worldFromCamera = worldFromReference * attitude * cameraFromDevice.inverse
        if headingCorrection == nil {
            // Turn the world so the camera's forward (-z) at the start points along -z.
            let forward = worldFromCamera.act(SIMD3(0, 0, -1))
            let yaw = atan2(forward.x, -forward.z)
            headingCorrection = simd_quatd(angle: -yaw, axis: SIMD3(0, 1, 0))
        }
        worldFromCamera = headingCorrection! * worldFromCamera
        let q = simd_quatf(vector: SIMD4<Float>(simd_normalize(worldFromCamera).vector))
        return simd_float4x4(q)
    }

    func start() {
        guard motion.isDeviceMotionAvailable else {
            log("[Pose] No device motion: head pose is not predicted ahead")
            return
        }
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        motion.deviceMotionUpdateInterval = 1.0 / 100.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] data, error in
            guard let self, let data else {
                if let error { log("[Pose] Device motion error: \(error.localizedDescription)") }
                return
            }
            let q = data.attitude.quaternion
            let sample = MotionSample(timestamp: data.timestamp,
                                      attitude: simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w),
                                      rate: SIMD3(data.rotationRate.x, data.rotationRate.y, data.rotationRate.z))
            self.lock.lock()
            self.samples.append(sample)
            if self.samples.count > self.capacity { self.samples.removeFirst() }
            self.motionCount += 1
            self.lock.unlock()
            let tap = self.taps.feed(data)
            if tap != 0 { self.onTap?(tap) }
            if self.motionCount % 25 == 0 {
                self.onMotion?(SIMD3(data.gravity.x, data.gravity.y, data.gravity.z), SIMD3(data.rotationRate.x, data.rotationRate.y, data.rotationRate.z), data.timestamp)
            }
        }
        log("[Pose] Device motion at 100 Hz drives head prediction; camera axes = device axes turned 90 degrees about z")
    }

    /// A new ARKit pose: scores the prediction that was possible for its time from the previous
    /// pose, and updates the velocity.
    func arrived(_ sample: PoseSample) {
        lock.lock()
        defer { lock.unlock() }
        if let last = latest, sample.timestamp > last.timestamp {
            let dt = Float(sample.timestamp - last.timestamp)
            let actualPosition = sample.transform.columns.3.xyz
            let lastPosition = last.transform.columns.3.xyz
            let v = (actualPosition - lastPosition) / max(dt, 1e-3)
            velocity = simd_mix(velocity, v, SIMD3(repeating: 0.5))

            // Score: rotate the last pose to this one's time with the gyro only.
            let predictedRotation = predictedRotationLocked(from: last, to: sample.timestamp)
            let actualRotation = simd_quatf(sample.transform.rotationOnly)
            let rawRotation = simd_quatf(last.transform.rotationOnly)
            let ep = Double(angleBetween(predictedRotation, actualRotation))
            let er = Double(angleBetween(rawRotation, actualRotation))
            errorPredicted += ep * ep
            errorRaw += er * er
            scored += 1
        }
        previous = latest
        latest = sample
    }

    /// The camera's transform predicted for `time`, from `sample`.
    func predict(_ sample: PoseSample, to time: Double) -> simd_float4x4 {
        lock.lock()
        defer { lock.unlock() }
        let rotation = predictedRotationLocked(from: sample, to: time)
        let dt = Float(min(max(time - sample.timestamp, 0), 0.1))
        // Velocity is only trusted for small steps; a jump between poses is not a walk.
        let speed = simd_length(velocity)
        let v = speed > 3 ? SIMD3<Float>(repeating: 0) : velocity
        let position = sample.transform.columns.3.xyz + v * dt
        var m = simd_float4x4(rotation)
        m.columns.3 = SIMD4(position, 1)
        return m
    }

    /// The error of predicting each pose from the one before, with the gyro and without, as
    /// `rms X deg predicted vs Y deg raw over N poses`; resets the tally.
    func statusAndReset() -> String {
        lock.lock()
        defer { lock.unlock() }
        let text: String
        if scored == 0 {
            text = "no poses scored"
        } else {
            let degrees = 180 / Double.pi
            text = String(format: "prediction rms %.2f deg vs %.2f deg unpredicted over %d poses, %d motion samples",
                          (errorPredicted / Double(scored)).squareRoot() * degrees,
                          (errorRaw / Double(scored)).squareRoot() * degrees, scored, motionCount)
        }
        errorPredicted = 0
        errorRaw = 0
        scored = 0
        motionCount = 0
        return text
    }

    // Rotation of the camera at `time`, from the gyro's turn since `sample.timestamp`.
    private func predictedRotationLocked(from sample: PoseSample, to time: Double) -> simd_quatf {
        let base = simd_quatf(sample.transform.rotationOnly)
        guard let atSample = attitudeLocked(at: sample.timestamp), let atTime = attitudeLocked(at: time) else {
            return base
        }
        // The device's turn between the two times, in device axes, then in camera axes.
        let deltaDevice = atSample.inverse * atTime
        let deltaCamera = cameraFromDevice * deltaDevice * cameraFromDevice.inverse
        let delta = simd_quatf(vector: SIMD4<Float>(deltaCamera.vector))
        return simd_normalize(base * delta)
    }

    // The attitude at a time: interpolated within the history, extrapolated past its end with the
    // latest rotation rate (integrated in the device frame).
    private func attitudeLocked(at time: Double) -> simd_quatd? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time <= first.timestamp { return first.attitude }
        if time >= last.timestamp {
            // Past the newest reading, the turn goes on at the last few readings' average rate:
            // one reading's rate is noisy, and a noisy rate carried 30-60 ms ahead shook the
            // world on a fast head (owner, 2026-11-08).
            let dt = min(time - last.timestamp, 0.15)
            let recent = samples.suffix(3)
            let rate = recent.reduce(SIMD3<Double>.zero) { $0 + $1.rate } / Double(recent.count)
            return last.attitude * rotation(rate: rate, seconds: dt)
        }
        // Binary search for the bracket.
        var lo = 0
        var hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].timestamp <= time { lo = mid } else { hi = mid }
        }
        let a = samples[lo]
        let b = samples[hi]
        let t = (time - a.timestamp) / max(b.timestamp - a.timestamp, 1e-6)
        return simd_slerp(a.attitude, b.attitude, t)
    }

    private func rotation(rate: SIMD3<Double>, seconds: Double) -> simd_quatd {
        let angle = simd_length(rate) * seconds
        if angle < 1e-9 { return simd_quatd(angle: 0, axis: SIMD3(0, 0, 1)) }
        return simd_quatd(angle: angle, axis: simd_normalize(rate))
    }

    private func angleBetween(_ a: simd_quatf, _ b: simd_quatf) -> Float {
        let d = abs(simd_dot(a.vector, b.vector))
        return 2 * acos(min(d, 1))
    }
}

extension simd_float4x4 {
    /// The upper-left rotation, as a 3x3 (assumes no scale).
    var rotationOnly: simd_float3x3 {
        simd_float3x3(columns.0.xyz, columns.1.xyz, columns.2.xyz)
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
