import AVFoundation
import simd

/// A rhythm game to a bundled synthwave beat: neon shapes come at you in four lanes in time
/// with the music; punch or pinch one as it reaches the ring to score, miss it and it passes.
/// The beat and its lead are played by a small synthesiser (AVAudioEngine) so no music file or
/// MusicKit is needed; a beat map is generated from the pattern. Apple Music through MusicKit,
/// with beat maps from bundled tracks, is the roadmap's next step for this game.
@MainActor
final class RhythmGame: Game {
    let title = "🎵 Rhythm"
    private struct Note { var lane: Int; var time: Double; var hit: Bool; var missed: Bool }
    private var notes: [Note] = []
    private var startTime: Double = 0
    private var score = 0
    private var combo = 0
    private var best = 0
    private let bpm: Double = 112
    private let synth = Synth()
    private var started = false
    private let motion = HandMotionTracker()
    private var lastHit: [Bool: Double] = [:]
    var status: String { started ? "Score \(score), combo \(combo)" : "Starting…" }

    func reset() {
        notes.removeAll()
        score = 0; combo = 0
        started = false
        synth.stop()
    }

    private func begin(at time: Double) {
        startTime = time + 2
        let beat = 60 / bpm
        // Sixteen bars: a note every beat, a lane walk, with off-beat pairs every fourth bar.
        for bar in 0..<16 {
            for b in 0..<4 {
                let t = Double(bar * 4 + b) * beat
                notes.append(Note(lane: (bar + b) % 4, time: t, hit: false, missed: false))
                if bar % 4 == 3 && b % 2 == 0 { notes.append(Note(lane: (bar + b + 2) % 4, time: t + beat / 2, hit: false, missed: false)) }
            }
        }
        synth.start(bpm: bpm, leadIn: 2)
        started = true
        log("[Games] Rhythm: \(notes.count) notes at \(Int(bpm)) bpm")
    }

    private func laneX(_ lane: Int) -> Float { (Float(lane) - 1.5) * 0.45 }

    func update(_ c: GameContext) {
        if !started { begin(at: c.time); return }
        let now = c.time - startTime
        // A hit: a hand punching into a lane's ring (or a select with the gaze on it) within 0.15 s.
        let forward = simd_normalize(SIMD3(c.forward.x, 0, c.forward.z))
        let right = simd_cross(forward, SIMD3(0, 1, 0))
        var hitLanes: Set<Int> = []
        for hand in motion.motions(c.hands, time: c.time) {
            let local = hand.position - c.headPosition
            let x = simd_dot(local, right), z = -simd_dot(local, forward)
            if (simd_dot(hand.velocity, forward) > 1.2 || hand.pinched) && z < -0.3, c.time - (lastHit[hand.isRight] ?? 0) > 0.2 {
                let lane = Int(((x / 0.45) + 1.5).rounded())
                if (0...3).contains(lane) { hitLanes.insert(lane); lastHit[hand.isRight] = c.time }
            }
        }
        if c.select, c.hands.isEmpty {
            let x = simd_dot(c.forward, right)
            let lane = Int(((x / 0.3) + 1.5).rounded())
            if (0...3).contains(lane) { hitLanes.insert(lane) }
        }
        for i in notes.indices where !notes[i].hit && !notes[i].missed {
            let delta = notes[i].time - now
            if hitLanes.contains(notes[i].lane) && abs(delta) < 0.18 {
                notes[i].hit = true
                combo += 1
                score += 10 + min(combo, 10) * 2
                synth.pop()
            } else if delta < -0.25 {
                notes[i].missed = true
                combo = 0
            }
        }
        best = max(best, combo)
    }

    func draw(into overlay: inout HandOverlay, context c: GameContext) {
        guard started else { return }
        let now = c.time - startTime
        let eye = c.headPosition
        let forward = simd_normalize(SIMD3(c.forward.x, 0, c.forward.z))
        let right = simd_cross(forward, SIMD3(0, 1, 0))
        let base = SIMD3(eye.x, eye.y - 0.25, eye.z)
        // The rings the notes arrive at, 0.6 m ahead.
        for lane in 0..<4 {
            let p = base + forward * 0.6 + right * laneX(lane)
            overlay.addSquare(p, size: 0.16, eye: eye, color: SIMD4(0.3, 0.9, 1, 0.5))
        }
        // The notes, 4 m out at 3 s ahead.
        for note in notes where !note.hit {
            let delta = Float(note.time - now)
            if delta > 3 || delta < -0.4 { continue }
            let p = base + forward * (0.6 + delta * 1.3) + right * laneX(note.lane)
            let color: SIMD4<Float> = note.missed ? SIMD4(0.4, 0.4, 0.4, 1) : [SIMD4(1, 0.3, 0.8, 1), SIMD4(1, 0.85, 0.3, 1), SIMD4(0.5, 1, 0.4, 1), SIMD4(0.7, 0.4, 1, 1)][note.lane]
            overlay.addCube(p, size: 0.14, color: color)
        }
    }
}

/// A two-voice synthesiser on AVAudioEngine: a kick on every beat, a square-wave lead stepping a
/// pentatonic line, mixed in a source node. Enough to play a rhythm game to without a file.
final class Synth: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var phase: Double = 0
    private var sampleIndex: Double = 0
    private var bpm: Double = 112
    private var leadIn: Double = 2
    private var popAt: Double = -1
    private let rate: Double = 44100
    private let scale: [Double] = [220, 261.6, 293.7, 329.6, 392, 440, 523.3, 587.3]

    func start(bpm: Double, leadIn: Double) {
        self.bpm = bpm
        self.leadIn = leadIn
        sampleIndex = 0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let beat = 60 / self.bpm
            for frame in 0..<Int(frameCount) {
                let t = self.sampleIndex / self.rate - self.leadIn
                var sample = 0.0
                if t >= 0 {
                    let inBeat = t.truncatingRemainder(dividingBy: beat)
                    // Kick: a dropping sine, 80 ms.
                    if inBeat < 0.08 { sample += sin(2 * .pi * (120 - inBeat * 600) * inBeat) * (1 - inBeat / 0.08) * 0.5 }
                    // Lead: an eighth-note square on the pentatonic walk, soft.
                    let step = Int(t / (beat / 2))
                    let f = self.scale[(step * 3 + step / 7) % self.scale.count]
                    let env = 1 - (t.truncatingRemainder(dividingBy: beat / 2)) / (beat / 2)
                    sample += (sin(2 * .pi * f * t) > 0 ? 0.12 : -0.12) * env
                    // A pop on a hit.
                    if self.popAt >= 0 && t - self.popAt < 0.06 && t >= self.popAt { sample += sin(2 * .pi * 880 * (t - self.popAt)) * 0.3 }
                }
                for buffer in buffers {
                    let p = buffer.mData!.assumingMemoryBound(to: Float.self)
                    p[frame] = Float(sample)
                }
                self.sampleIndex += 1
            }
            return noErr
        }
        self.node = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        do { try engine.start() } catch { log("[Games] Synth failed: \(error.localizedDescription)") }
    }

    func pop() { popAt = sampleIndex / rate - leadIn }

    func stop() {
        engine.stop()
        if let node { engine.detach(node) }
        node = nil
    }
}
