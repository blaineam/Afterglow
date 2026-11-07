import ARKit
import Vision
import CoreImage
import simd

/// One hand as the app sees it, for drawing and interaction: its joints in the world, whether it is
/// pinching, and where.
struct TrackedHandState: Sendable {
    var joints: [SIMD3<Float>]         // 21, world space, metres
    var pinched: Bool
    var pinchPoint: SIMD3<Float>       // between the thumb and index tips
    var handedness: Float              // 0 left .. 1 right, blended over results
    var confidence: Float
    var distance: Float                // the palm from the camera, metres
    var isRight: Bool { handedness >= 0.5 }
}

/// Hands from Apple's Vision hand pose on the Neural Engine, the way the Unity app's `HandTracker`
/// does it on the iPhone: each camera image goes to `VNDetectHumanHandPoseRequest` (up to two
/// hands, 21 joints each, a confidence per joint and which hand it is), at most `handHz` images a
/// second and one at a time, so no work queues up that cannot be used. Each result's landmarks are
/// placed in 3D by `HandGeometry` as a flat hand at the learned palm size; where the phone has
/// LiDAR the scene depth at the palm teaches that size (25-70 cm, within the fit's trust). The
/// joints are smoothed with One Euro filters, held for 0.3 s through a missed image, and moved on
/// by the palm's speed for the time since their image. A pinch is the thumb and index tips within
/// 2.5 cm (open again past 4.5 cm), never started with a tip at the image's edge. Logs [Hands] and
/// [Pinch].
final class HandTracker: @unchecked Sendable {
    // The Unity app's constants.
    private static let minHandConfidence: Float = 0.3
    private static let graceSeconds = 0.6   // the Unity app's 0.3 showed a hand vanish while its tips crossed
    /// A hand Vision stops reporting while the other hand is right beside it is hidden behind
    /// (or clasped with) that hand, not gone: Vision gives one observation for two hands together
    /// (owner, 2026-11-06; the Unity app notes the same). It is kept this long, where it was.
    private static let overlapHoldSeconds = 2.0
    private static let overlapDistance: Float = 0.15
    private static let handednessBlend: Float = 0.1   // slower than the Unity app's 0.2: Vision's chirality flips more often than its landmarker's did
    private static let typicalPalmSize: Float = 0.055
    private static let minPalmSize: Float = 0.04
    private static let maxPalmSize: Float = 0.075
    private static let palmSizeRate: Float = 0.005   // slower than the Unity app's 0.02: a flat shape's span moves with the hand's tilt, and the size ran to its limits either way
    private static let minCalibrationDepth: Float = 0.25
    private static let maxCalibrationDepth: Float = 0.7
    private static let skinToJoints: Float = 0.01
    private static let maxReach: Float = 0.8
    private static let minHandDistance: Float = 0.05
    private static let predictionGain: Float = 0.8
    private static let maxPredictionSeconds = 0.15
    private static let maxSpeedGapSeconds = 0.2
    private static let speedBlend: Float = 0.5
    private static let edgeMargin: Float = 0.04   // of the image's width, where a pinch may not start
    private static let sureTipConfidence: Float = 0.4   // a fingertip Vision was less sure of was hidden, and guessed
    private static let seenTipConfidence: Float = 0.15  // below this a tip was not seen at all, so no pinch starts on it
    /// A palm reading smaller than this share of the hand's own flat-on size, at the measured
    /// depth, is edge-on: the fingers are in line with the camera, which sees only the thumb and
    /// guesses the index tip beside it, which read as a pinch (owner, 2026-11-06). No pinch starts.
    private static let edgeOnOpenness: Float = 0.4
    /// Fingertips whose LiDAR depths differ by more than this, metres, are apart along the camera's
    /// axis however close they look: a C-shaped hand turned so its tips cross in the image.
    private static let maxTipDepthGap: Float = 0.02
    /// Knuckle-to-tip over the bones' length, in the image, above which the index finger is straight.
    private static let maxStraightCurl: Float = 0.9
    /// Results the tips must have been level for: at the moment they cross in the image both read
    /// the nearer depth, so the gap before the crossing is what tells a turning C from a pinch.
    private static let levelResults = 5

    private final class Slot {
        var state: TrackedHandState?
        var imageTime: Double = 0
        var lastSeen: Double = 0
        var velocity = SIMD3<Float>.zero
        var jointFilters = (0..<HandGeometry.jointCount).map { _ in OneEuroFilter(minCutoff: 1.5, beta: 8) }
        var depthFilter = OneEuroFilter(minCutoff: 1, beta: 4)
        var pinch = PinchDetector()
        var handedness: Float = 0.5
        var acquiring = true
        /// The largest palm size seen for this hand at a measured depth, metres, decaying slowly so
        /// a one-off doesn't fix it for good.
        var palmSizeSeen: Float = 0
        /// When the hand was lost (its grace ran out), so a hand found soon after can be the same
        /// one back in view, with its pinch and handedness kept.
        var lostAt: Double = -1
        /// The last few results' depth gaps between the thumb and index tips, metres.
        var tipGaps: [Float] = []
        /// The wrist relative to the knuckles' centre, kept from results where the wrist was seen,
        /// for results where it is at the image's edge and guessed.
        var wristOffset: SIMD3<Float>?
        /// Set when the hand has just come back into view: the pinch is re-judged from the tips.
        var resumed = false
        /// The finger bones' lengths relative to the palm span, averaged over results, and how
        /// many results in a row have been rejected as impossible.
        var boneLengths: [Float] = []
        var boneResults = 0
        var lastSpan: Float = 0
        var rejectedRun = 0
    }

    /// Results that cannot be the same hand a few images later are dropped as a miss, and the
    /// hand keeps its last pose (owner, 2026-11-06: a hand drawn jumping to a pose no hand can
    /// take): the palm's span in the image changing by more than this share, a finger bone's
    /// length against its average by more than this share, for more than this many bones, or a
    /// joint moving more than this far in a tenth of a second. After this many rejections in a
    /// row the result is taken, since the hand really has changed.
    private static let maxSpanChange: Float = 0.4
    private static let maxBoneChange: Float = 0.6
    private static let maxBonesOff = 4
    private static let maxJointJump: Float = 0.25
    private static let maxRejectedRun = 3
    private static let fingerBones = Array(HandGeometry.bones.prefix(20))

    /// A hand found within this long of one being lost is that hand back in view: a pinch held out
    /// of the camera's view and brought back stays the same pinch (owner, 2026-11-06).
    private static let returnSeconds = 5.0

    private let queue = DispatchQueue(label: "afterglow.hands", qos: .userInteractive)
    private let request: VNDetectHumanHandPoseRequest
    private let lock = NSLock()
    private var busy = false
    private var nextImageTime: Double = 0
    /// Images a second, changeable while running.
    var hertz: Int {
        didSet { if hertz != oldValue { interval = 1.0 / Double(max(hertz, 1)) } }
    }
    private var interval: Double
    private let useDepth: Bool
    private var palmSize = HandTracker.typicalPalmSize
    private var slots = [Slot(), Slot()]
    private var ciContext: CIContext?
    private var useCIImage = false

    // For the five-second log.
    private var images = 0
    private var visionMs: Double = 0
    private var handsSeen = 0
    private var confidenceMin: Float = 1, confidenceMax: Float = 0
    private var distanceMin: Float = 100, distanceMax: Float = 0
    private var depthSamples = 0
    private var depthTaught = 0
    private var pinches = 0
    private var swaps = 0
    private var edgeOn = 0
    private var rejected = 0
    private var lastBlockedLog: Double = 0
    private var loggedDepth = false
    private var lastLog: Double = 0

    private static let jointOrder: [VNHumanHandPoseObservation.JointName] = [
        .wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    init(hertz: Int, useDepth: Bool) {
        self.hertz = hertz
        interval = 1.0 / Double(max(hertz, 1))
        self.useDepth = useDepth
        request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        log("[Hands] Vision hand pose on the Neural Engine finds the hands, up to \(hertz) images/s; a flat hand from its landmarks places each hand at the learned palm size\(useDepth ? ", taught by the scene depth" : "")")
    }

    /// The hands as of `time`: the latest results moved on by their speed.
    func hands(at time: Double) -> [TrackedHandState] {
        lock.lock()
        defer { lock.unlock() }
        var result: [TrackedHandState] = []
        for slot in slots {
            guard var state = slot.state else { continue }
            if time - slot.lastSeen > Self.graceSeconds {
                let other = slots.first { $0 !== slot && $0.state != nil && time - $0.lastSeen <= Self.graceSeconds }
                let overlapping = other.map { simd_distance($0.state!.joints[HandGeometry.wrist], state.joints[HandGeometry.wrist]) < Self.overlapDistance } ?? false
                if !(overlapping && time - slot.lastSeen <= Self.overlapHoldSeconds) {
                    slot.state = nil
                    slot.lostAt = time
                    continue
                }
                // Hidden behind the other hand: shown where it was, not moved on.
                result.append(state)
                continue
            }
            let dt = Float(min(max(time - slot.imageTime, 0), Self.maxPredictionSeconds)) * Self.predictionGain
            let shift = slot.velocity * dt
            if simd_length(shift) > 0 {
                state.joints = state.joints.map { $0 + shift }
                state.pinchPoint += shift
            }
            result.append(state)
        }
        return result
    }

    /// Offers a camera frame. Taken when the last request is done and `handHz` allows; refused
    /// otherwise, so the AR delegate never waits.
    func submit(_ frame: HandImage) {
        lock.lock()
        if busy || frame.timestamp < nextImageTime {
            lock.unlock()
            return
        }
        busy = true
        nextImageTime = frame.timestamp + interval
        lock.unlock()
        let boxed = Unchecked(frame)
        queue.async { [self] in
            process(boxed.value)
            lock.lock()
            busy = false
            lock.unlock()
        }
    }

    private func process(_ frame: HandImage) {
        let started = CACurrentMediaTime()
        let width = frame.width
        let height = frame.height
        var observations: [VNHumanHandPoseObservation] = []
        do {
            if !useCIImage {
                let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: .up, options: [:])
                try handler.perform([request])
            } else {
                try performThroughCoreImage(frame)
            }
            observations = request.results ?? []
        } catch {
            if !useCIImage {
                // A pixel format Vision will not take directly (the phone's 10-bit buffers, if so):
                // give it the image through Core Image instead.
                useCIImage = true
                log("[Hands] Vision refused the camera buffer (\(error.localizedDescription)); converting through Core Image")
                do {
                    try performThroughCoreImage(frame)
                    observations = request.results ?? []
                } catch {
                    log("[Hands] Vision failed: \(error.localizedDescription)")
                }
            } else {
                log("[Hands] Vision failed: \(error.localizedDescription)")
            }
        }
        let ms = (CACurrentMediaTime() - started) * 1000

        // Each observation as image pixels, MediaPipe order, x right and y down.
        struct Seen {
            var landmarks: [SIMD2<Float>]
            var confidences: [Float]
            var confidence: Float
            var chirality: VNChirality
        }
        var seen: [Seen] = []
        for observation in observations where observation.confidence >= Self.minHandConfidence {
            guard let points = try? observation.recognizedPoints(.all) else { continue }
            var landmarks: [SIMD2<Float>] = []
            var confidences: [Float] = []
            for name in Self.jointOrder {
                let p = points[name]
                landmarks.append(SIMD2(Float(p?.location.x ?? 0) * Float(width), (1 - Float(p?.location.y ?? 0)) * Float(height)))
                confidences.append(p?.confidence ?? 0)
            }
            seen.append(Seen(landmarks: landmarks, confidences: confidences, confidence: observation.confidence, chirality: observation.chirality))
        }

        let k = frame.intrinsics
        let focal = SIMD2(k.columns.0.x, k.columns.1.y)
        let principal = SIMD2(k.columns.2.x, k.columns.2.y)
        let cameraToWorld = frame.cameraTransform
        let now = frame.timestamp

        lock.lock()
        defer { lock.unlock() }
        images += 1
        visionMs += ms
        handsSeen += seen.count

        // Match each hand seen to a slot: the nearest tracked wrist in the image, generously (a
        // fast move at 20 images/s crosses a quarter of the image between results, and a hand that
        // missed its slot got a second one while the first lingered: drawn twice, 2026-11-06);
        // with one hand seen and one tracked, they are the same hand. A hand with no match takes a
        // free slot, and a tracked slot it left behind is dropped rather than kept for the grace.
        var assigned = [Int?](repeating: nil, count: seen.count)
        var used = Set<Int>()
        let trackedSlots = slots.indices.filter { slots[$0].state != nil }
        if seen.count == 1 && trackedSlots.count == 1 {
            assigned[0] = trackedSlots[0]
            used.insert(trackedSlots[0])
        } else {
            for (i, hand) in seen.enumerated() {
                var best: (Int, Float)?
                for (s, slot) in slots.enumerated() where !used.contains(s) {
                    guard let state = slot.state else { continue }
                    let wristWorld = state.joints[HandGeometry.wrist]
                    let inCamera = (cameraToWorld.inverse * SIMD4(wristWorld, 1)).xyz
                    guard inCamera.z < 0 else { continue }
                    let projected = SIMD2(inCamera.x, -inCamera.y) / -inCamera.z * focal + principal
                    let d = simd_distance(projected, hand.landmarks[HandGeometry.wrist])
                    if d < Float(width) * 0.4 && (best == nil || d < best!.1) { best = (s, d) }
                }
                if let best {
                    assigned[i] = best.0
                    used.insert(best.0)
                }
            }
        }
        for i in seen.indices where assigned[i] == nil {
            let free = slots.indices.filter { !used.contains($0) && slots[$0].state == nil }
            // A hand lost moments ago, by preference the one Vision's chirality matches: back in
            // view with its pinch and handedness. Otherwise a fresh hand.
            let seenRight: Float? = seen[i].chirality == .right ? 1 : seen[i].chirality == .left ? 0 : nil
            let returning = free.filter { now - slots[$0].lostAt < Self.returnSeconds }
                .sorted { a, b in
                    guard let seenRight else { return slots[a].lostAt > slots[b].lostAt }
                    return abs(slots[a].handedness - seenRight) < abs(slots[b].handedness - seenRight)
                }
            if let back = returning.first {
                assigned[i] = back
                used.insert(back)
                slots[back].acquiring = false
                slots[back].velocity = .zero
                for j in slots[back].jointFilters.indices { slots[back].jointFilters[j].reset() }
                slots[back].depthFilter.reset()
                slots[back].resumed = true
            } else if let fresh = free.first {
                assigned[i] = fresh
                used.insert(fresh)
                slots[fresh].acquiring = true
                slots[fresh].pinch.reset()
                slots[fresh].palmSizeSeen = 0
                slots[fresh].tipGaps = []
                slots[fresh].boneResults = 0
                slots[fresh].lastSpan = 0
                slots[fresh].rejectedRun = 0
            } else if let stale = slots.indices.first(where: { !used.contains($0) }) {
                // Every slot is tracked and this hand matched none: the unmatched slot is the stale
                // trace of a hand that moved, and this is where it went, so it keeps its pinch (a
                // reset here broke a pinch carried quickly through the air, 2026-11-06) and only
                // the filters start over at the new place.
                slots[stale].state = nil
                slots[stale].depthFilter.reset()
                for j in slots[stale].jointFilters.indices { slots[stale].jointFilters[j].reset() }
                assigned[i] = stale
                used.insert(stale)
            }
        }

        for (i, hand) in seen.enumerated() {
            guard let s = assigned[i] else { continue }
            let slot = slots[s]

            // Is this a pose the tracked hand can have taken since its last result?
            let span = HandGeometry.palmSpan(hand.landmarks)
            let bones = Self.fingerBones.map { simd_distance(hand.landmarks[$0.1], hand.landmarks[$0.0]) / max(span, 1) }
            if slot.state != nil, now - slot.imageTime < 0.1, slot.rejectedRun < Self.maxRejectedRun {
                var why: String?
                if slot.lastSpan > 0 && abs(span - slot.lastSpan) / slot.lastSpan > Self.maxSpanChange {
                    why = String(format: "palm span %.0f -> %.0f px", slot.lastSpan, span)
                } else if slot.boneResults >= 5 {
                    let off = zip(bones, slot.boneLengths).filter { abs($0 - $1) / max($1, 1e-3) > Self.maxBoneChange }.count
                    if off > Self.maxBonesOff { why = "\(off) finger bones changed length" }
                }
                if let why {
                    slot.rejectedRun += 1
                    rejected += 1
                    if rejected <= 3 { log("[Hands] Impossible pose dropped: \(why)") }
                    continue
                }
            }

            // Place: a flat hand at the palm size, fitted to the palm's pixels.
            let shape = HandGeometry.flatShape(imageLandmarks: hand.landmarks, palmSize: palmSize)
            let fit = HandGeometry.fitPosition(imageLandmarks: hand.landmarks, metricLandmarks: shape, ids: HandGeometry.palm,
                                               focalLength: focal, principalPoint: principal)
            guard fit.rmsError.isFinite, fit.position.z > Self.minHandDistance else { continue }
            var depth = fit.position.z
            if slot.acquiring && depth > Self.maxReach { continue }   // a stray "hand" far away

            // The scene depth at the palm places the hand where LiDAR saw it, and teaches the palm
            // size for when there is no depth (too close, or a phone without LiDAR). Placing by the
            // fit alone pinned the learned size at its floor: a flat shape foreshortens with the
            // hand's tilt, which the size then absorbs (2026-11-06).
            var measuredDepth: Float?
            if useDepth, let sceneDepth = frame.sceneDepth {
                var centre = SIMD2<Float>.zero
                for id in HandGeometry.palm { centre += hand.landmarks[id] }
                centre /= Float(HandGeometry.palm.count)
                let uv = SIMD2(centre.x / Float(width), centre.y / Float(height))
                if let measured = Self.sampleDepth(sceneDepth, at: uv) {
                    depthSamples += 1
                    let jointsDepth = measured + Self.skinToJoints
                    if jointsDepth >= 0.3 && jointsDepth <= 0.6 && fit.rmsError < 10 {
                        let taught = HandGeometry.palmSize(forDepth: palmSize, estimatedDepth: depth, measuredDepth: jointsDepth)
                        palmSize = min(max(palmSize + (taught - palmSize) * Self.palmSizeRate, Self.minPalmSize), Self.maxPalmSize)
                        depthTaught += 1
                    }
                    if jointsDepth >= 0.2 && jointsDepth <= 1.0 {
                        depth = jointsDepth
                        measuredDepth = jointsDepth
                    }
                }
                if !loggedDepth {
                    loggedDepth = true
                    log("[Hands] Scene depth \(CVPixelBufferGetWidth(sceneDepth.depthMap))x\(CVPixelBufferGetHeight(sceneDepth.depthMap)), \(sceneDepth.confidenceMap != nil ? "with" : "without") confidence, teaches the palm size")
                }
            }
            // How open to the camera the palm is: its size at the measured depth against the
            // largest this hand has shown, 1 when flat-on and small when edge-on.
            var openness: Float = 1
            if let measuredDepth, measuredDepth <= 0.8 {
                let apparent = HandGeometry.palmSpan(hand.landmarks) * measuredDepth / focal.x
                // The reference grows by at most 3% a result and decays by 0.5%, so one depth
                // sample off the background cannot set it high and leave every normal reading
                // "edge-on", which made a pinch impossible to release (owner, 2026-11-06).
                let ceiling = slot.palmSizeSeen > 0 ? slot.palmSizeSeen * 1.03 : apparent
                slot.palmSizeSeen = min(max(slot.palmSizeSeen * 0.995, apparent), ceiling)
                if slot.palmSizeSeen > 0 { openness = apparent / slot.palmSizeSeen }
            }
            depth = slot.depthFilter.filter(SIMD3(0, 0, depth), time: now).z
            let cameraJoints = HandGeometry.placeJoints(imageLandmarks: hand.landmarks, metricLandmarks: shape, centerDepth: depth,
                                                        focalLength: focal, principalPoint: principal)
            // Into ARKit's camera axes (x right, y up, -z forward), then the world at the image's pose.
            var rawJoints = cameraJoints.map { c in (cameraToWorld * SIMD4(c.x, -c.y, -c.z, 1)).xyz }
            // A wrist at the image's edge (or that Vision was unsure of) is a guess, and the guess
            // folds the hand forward at the wrist; it is held where the knuckles say it was last
            // seen (owner, 2026-11-07).
            let margin = Self.edgeMargin * Float(width)
            let wristPixel = hand.landmarks[HandGeometry.wrist]
            let wristInside = wristPixel.x > margin && wristPixel.x < Float(width) - margin && wristPixel.y > margin && wristPixel.y < Float(height) - margin
            let knuckles = [5, 9, 13, 17].reduce(SIMD3<Float>.zero) { $0 + rawJoints[$1] } / 4
            if wristInside && hand.confidences[HandGeometry.wrist] >= Self.sureTipConfidence {
                slot.wristOffset = rawJoints[HandGeometry.wrist] - knuckles
            } else if let offset = slot.wristOffset {
                rawJoints[HandGeometry.wrist] = knuckles + offset
                for t in [1, 2] where hand.confidences[t] < Self.sureTipConfidence {
                    // The thumb's base follows the wrist it hangs off.
                    rawJoints[t] = knuckles + offset + (rawJoints[t] - rawJoints[HandGeometry.wrist])
                }
            }
            if let previous = slot.state, now - slot.imageTime < 0.1, slot.rejectedRun < Self.maxRejectedRun {
                let jump = zip(rawJoints, previous.joints).map { simd_distance($0, $1) }.max() ?? 0
                if jump > Self.maxJointJump {
                    slot.rejectedRun += 1
                    rejected += 1
                    if rejected <= 3 { log(String(format: "[Hands] Impossible pose dropped: a joint moved %.0f cm", jump * 100)) }
                    continue
                }
            }
            var joints: [SIMD3<Float>] = []
            for (j, world) in rawJoints.enumerated() {
                joints.append(slot.jointFilters[j].filter(world, time: now))
            }
            slot.rejectedRun = 0
            slot.lastSpan = span
            if slot.boneLengths.count != bones.count { slot.boneLengths = bones; slot.boneResults = 0 }
            slot.boneLengths = zip(slot.boneLengths, bones).map { $0 + ($1 - $0) * 0.1 }
            slot.boneResults += 1

            // Speed from the palm, for moving the joints on between results.
            let palmNow = HandGeometry.palm.reduce(SIMD3<Float>.zero) { $0 + joints[$1] } / Float(HandGeometry.palm.count)
            if let previous = slot.state, now - slot.imageTime < Self.maxSpeedGapSeconds, now > slot.imageTime {
                let palmBefore = HandGeometry.palm.reduce(SIMD3<Float>.zero) { $0 + previous.joints[$1] } / Float(HandGeometry.palm.count)
                let v = (palmNow - palmBefore) / Float(now - slot.imageTime)
                slot.velocity = simd_mix(slot.velocity, v, SIMD3(repeating: Self.speedBlend))
            } else {
                slot.velocity = .zero
            }

            // Handedness: Vision's chirality, blended over results.
            let seenRight: Float? = hand.chirality == .right ? 1 : hand.chirality == .left ? 0 : nil
            if let seenRight {
                let before = slot.handedness >= 0.5
                slot.handedness = slot.acquiring ? seenRight : slot.handedness + (seenRight - slot.handedness) * Self.handednessBlend
                if !slot.acquiring && before != (slot.handedness >= 0.5) { swaps += 1 }
            }

            // Pinch. The tips' LiDAR depths, where there are any, say whether they really meet.
            let thumb = joints[HandGeometry.thumbTip]
            let index = joints[HandGeometry.indexTip]
            // Each tip's depth is the nearest reading in a small window round it: the finger is the
            // nearest thing there, and a median mixed finger and background. A tip with no reading
            // while the palm has one is at an edge or hidden, which is no place to start a pinch
            // (counted as level, the guard was never in the way: 2026-11-06).
            // The tips' readings, or failing them the next joints in (wider, less often hidden);
            // a result without either is left out, and the guard only speaks with at least two
            // readings in its window: fingertips often have no reading, and treating that as a
            // block stopped real pinches (log, 2026-11-06).
            var tipDepthGap: Float?
            if useDepth, let sceneDepth = frame.sceneDepth {
                func gap(_ a: Int, _ b: Int) -> Float? {
                    let pa = hand.landmarks[a], pb = hand.landmarks[b]
                    guard let da = Self.nearestDepth(sceneDepth, at: SIMD2(pa.x / Float(width), pa.y / Float(height))),
                          let db = Self.nearestDepth(sceneDepth, at: SIMD2(pb.x / Float(width), pb.y / Float(height))) else { return nil }
                    return abs(da - db)
                }
                tipDepthGap = gap(HandGeometry.thumbTip, HandGeometry.indexTip) ?? gap(3, 7)
            }
            slot.tipGaps.append(tipDepthGap ?? Float.nan)
            if slot.tipGaps.count > Self.levelResults { slot.tipGaps.removeFirst() }
            // The index finger must be bent for a pinch: the straight distance from its knuckle to
            // its tip against the length along its bones, in the image, is 1 for a straight finger
            // from any angle (the points stay in line) and about 0.6-0.85 in a pinch. A straight
            // index finger whose tip the thumb crosses in the image is the "perspective trick"
            // the depth gap was meant to catch and never did; the gap rule blocked real pinches
            // instead (LiDAR at 40 cm cannot tell two touching fingertips apart; log 2026-11-07).
            let along = simd_distance(hand.landmarks[5], hand.landmarks[6]) + simd_distance(hand.landmarks[6], hand.landmarks[7]) + simd_distance(hand.landmarks[7], hand.landmarks[8])
            let curl = along > 1 ? simd_distance(hand.landmarks[5], hand.landmarks[8]) / along : 1
            // From the headset's camera the index finger points at the lens in a pinch and its
            // joints project in a line too (curl 0.91-0.99 on every real pinch, log 2026-11-07),
            // so the curl is logged and not a gate: the tips' distance with its hysteresis decides.
            let indexBent = true
            _ = Self.maxStraightCurl
            let tipsInside = [hand.landmarks[HandGeometry.thumbTip], hand.landmarks[HandGeometry.indexTip]].allSatisfy {
                $0.x > margin && $0.x < Float(width) - margin && $0.y > margin && $0.y < Float(height) - margin
            }
            if slot.resumed {
                // Back in view: a pinch held through the gap stands only if the tips are still
                // together, else the hand is open (WebXR saw a hand pinched for good, 2026-11-07).
                slot.resumed = false
                let was = slot.pinch.isPinched
                slot.pinch.resume(tipDistance: simd_distance(thumb, index))
                if was != slot.pinch.isPinched { log("[Pinch] Hand back in view, released: tips apart") } else if was { log("[Pinch] Hand back in view, still pinched") }
            }
            let wasPinched = slot.pinch.isPinched
            let tipsSure = hand.confidences[HandGeometry.thumbTip] >= Self.sureTipConfidence
                && hand.confidences[HandGeometry.indexTip] >= Self.sureTipConfidence
            let tipsSeen = hand.confidences[HandGeometry.thumbTip] >= Self.seenTipConfidence
                && hand.confidences[HandGeometry.indexTip] >= Self.seenTipConfidence
            let isEdgeOn = openness < Self.edgeOnOpenness
            if isEdgeOn { edgeOn += 1 }
            // Edge-on only stops a pinch starting; a held one still follows the tips, so it can end.
            let tipDistance = simd_distance(thumb, index)
            let pinched = slot.pinch.update(tipDistance: tipDistance, allowStart: tipsInside && !isEdgeOn && indexBent && tipsSeen,
                                            tipsSure: tipsSure)
            // A pinch the tips are making that cannot start: say why, once a second, so a real pinch
            // that fails to register can be read off the log.
            if !pinched && tipDistance < 0.025 && !(tipsInside && !isEdgeOn && indexBent && tipsSeen) && now - lastBlockedLog > 1 {
                lastBlockedLog = now
                var reasons: [String] = []
                if !tipsInside { reasons.append("tips at the image's edge") }
                if isEdgeOn { reasons.append(String(format: "palm edge-on (%.0f%% open)", openness * 100)) }
                if curl > Self.maxStraightCurl { reasons.append(String(format: "(index finger straight %.2f)", curl)) }
                if !tipsSeen { reasons.append(String(format: "a tip not seen (%.2f, %.2f)", hand.confidences[HandGeometry.thumbTip], hand.confidences[HandGeometry.indexTip])) }
                log(String(format: "[Pinch] %@ hand's tips %.1f cm apart but no start: %@", slot.handedness >= 0.5 ? "right" : "left",
                           tipDistance * 100, reasons.joined(separator: ", ")))
            }
            if pinched != wasPinched {
                if pinched { pinches += 1 }
                let p = (thumb + index) / 2
                log(String(format: "[Pinch] %@ %@ hand at (%.2f, %.2f, %.2f), tips %.1f cm apart (confidence %.2f, %.2f, depth gap %@), palm %.0f%% open",
                           pinched ? "Pinch" : "Release", slot.handedness >= 0.5 ? "right" : "left", p.x, p.y, p.z,
                           simd_distance(thumb, index) * 100, hand.confidences[HandGeometry.thumbTip],
                           hand.confidences[HandGeometry.indexTip], tipDepthGap.map { String(format: "%.1f cm", $0 * 100) } ?? "none", openness * 100))
            }

            slot.state = TrackedHandState(joints: joints, pinched: pinched, pinchPoint: (thumb + index) / 2,
                                          handedness: slot.handedness, confidence: hand.confidence, distance: depth)
            slot.imageTime = now
            slot.lastSeen = now
            slot.acquiring = false
            confidenceMin = min(confidenceMin, hand.confidence)
            confidenceMax = max(confidenceMax, hand.confidence)
            distanceMin = min(distanceMin, depth)
            distanceMax = max(distanceMax, depth)
        }
        // Slots not seen this image keep their state until the grace runs out (hands(at:)).
        for (s, slot) in slots.enumerated() where !used.contains(s) && slot.state != nil {
            if now - slot.lastSeen > Self.graceSeconds {
                let other = slots.first { $0 !== slot && $0.state != nil && now - $0.lastSeen <= Self.graceSeconds }
                let overlapping = other.map { simd_distance($0.state!.joints[HandGeometry.wrist], slot.state!.joints[HandGeometry.wrist]) < Self.overlapDistance } ?? false
                if !(overlapping && now - slot.lastSeen <= Self.overlapHoldSeconds) {
                    slot.state = nil
                    slot.lostAt = now
                }
            }
        }

        if now - lastLog >= 5 {
            let elapsed = lastLog == 0 ? 5 : now - lastLog
            let tracked = slots.filter { $0.state != nil }.count
            var text = String(format: "[Hands] %.1f images/s, Vision %.1f ms, %d hands seen, %d tracked", Double(images) / elapsed,
                              images > 0 ? visionMs / Double(images) : 0, handsSeen, tracked)
            if handsSeen > 0 {
                text += String(format: ", confidence %.2f-%.2f, %.2f-%.2f m away", confidenceMin, confidenceMax, distanceMin, distanceMax)
            }
            text += String(format: ", palm %.1f cm (%d depth samples, %d taught), %d pinches, %d handedness swaps, %d edge-on results, %d impossible poses dropped", palmSize * 100,
                           depthSamples, depthTaught, pinches, swaps, edgeOn, rejected)
            log(text)
            lastLog = now
            images = 0; visionMs = 0; handsSeen = 0
            confidenceMin = 1; confidenceMax = 0; distanceMin = 100; distanceMax = 0
            depthSamples = 0; depthTaught = 0; pinches = 0; swaps = 0; edgeOn = 0; rejected = 0
        }
    }

    private func performThroughCoreImage(_ frame: HandImage) throws {
        if ciContext == nil { ciContext = CIContext(options: [.useSoftwareRenderer: false]) }
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        try handler.perform([request])
    }

    /// The nearest confident scene depth in a 3x3 window at a fraction of the way across and down
    /// the image; nil when none.
    private static func nearestDepth(_ sceneDepth: ARDepthData, at uv: SIMD2<Float>) -> Float? {
        let map = sceneDepth.depthMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        guard uv.x >= 0, uv.x < 1, uv.y >= 0, uv.y < 1 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        var confidenceBase: UnsafeMutableRawPointer?
        var confidenceRow = 0
        if let confidence = sceneDepth.confidenceMap {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            confidenceBase = CVPixelBufferGetBaseAddress(confidence)
            confidenceRow = CVPixelBufferGetBytesPerRow(confidence)
        }
        defer { if let confidence = sceneDepth.confidenceMap { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
        let cx = Int(uv.x * Float(width)), cy = Int(uv.y * Float(height))
        var nearest: Float?
        for y in max(0, cy - 1)...min(height - 1, cy + 1) {
            for x in max(0, cx - 1)...min(width - 1, cx + 1) {
                let d = base.load(fromByteOffset: y * rowBytes + x * 4, as: Float.self)
                guard d > 0.1, d.isFinite else { continue }
                if let confidenceBase, confidenceBase.load(fromByteOffset: y * confidenceRow + x, as: UInt8.self) < 1 { continue }
                if nearest == nil || d < nearest! { nearest = d }
            }
        }
        return nearest
    }

    /// The median scene depth in a 5x5 window at a fraction of the way across and down the image,
    /// of samples with at least medium confidence; nil when none.
    private static func sampleDepth(_ sceneDepth: ARDepthData, at uv: SIMD2<Float>, radius: Int = 2) -> Float? {
        let map = sceneDepth.depthMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        guard uv.x >= 0, uv.x < 1, uv.y >= 0, uv.y < 1 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        var confidenceBase: UnsafeMutableRawPointer?
        var confidenceRow = 0
        if let confidence = sceneDepth.confidenceMap {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            confidenceBase = CVPixelBufferGetBaseAddress(confidence)
            confidenceRow = CVPixelBufferGetBytesPerRow(confidence)
        }
        defer { if let confidence = sceneDepth.confidenceMap { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
        let cx = Int(uv.x * Float(width)), cy = Int(uv.y * Float(height))
        var samples: [Float] = []
        for y in max(0, cy - radius)...min(height - 1, cy + radius) {
            for x in max(0, cx - radius)...min(width - 1, cx + radius) {
                let d = base.load(fromByteOffset: y * rowBytes + x * 4, as: Float.self)
                guard d > 0, d.isFinite else { continue }
                if let confidenceBase, confidenceBase.load(fromByteOffset: y * confidenceRow + x, as: UInt8.self) < 1 { continue }
                samples.append(d)
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }
}

/// Carries a non-Sendable value across a queue hop that the caller knows is safe (one frame handed
/// to one worker at a time).
final class Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
