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
    /// The built-in music's styles, for playing without a song on the phone (owner, 2026-11-07).
    enum Style: Int, CaseIterable {
        case synthwave, techno, lofi, drumAndBass, chiptune
        var name: String { switch self { case .synthwave: return "Synthwave"; case .techno: return "Techno"; case .lofi: return "Lo-fi"; case .drumAndBass: return "Drum & bass"; case .chiptune: return "Chiptune" } }
        var bpm: Double { switch self { case .synthwave: return 112; case .techno: return 128; case .lofi: return 84; case .drumAndBass: return 172; case .chiptune: return 140 } }
    }
    private(set) var style = Style.synthwave
    func cycleStyle() {
        style = Style(rawValue: (style.rawValue + 1) % Style.allCases.count) ?? .synthwave
        bpm = style.bpm
        reset()
    }
    private(set) var bpm: Double = 112
    /// Apple Music, when the Music app has something playing: the notes run to its clock at the
    /// tempo set with the games panel's tempo buttons (no beat analysis is possible on a protected
    /// stream), the synth stays quiet.
    var music: MusicApp?
    private var usingMusic = false
    private let synth = Synth()
    private var started = false
    private let motion = HandMotionTracker()
    private var lastHit: [Bool: Double] = [:]
    private var hits: [(lane: Int, time: Double)] = []
    var status: String { started ? "Score \(score), combo \(combo) · \(Int(bpm)) bpm\(usingMusic ? " · Apple Music" : "")" : "Starting…" }

    /// The tempo, from the games panel; a change restarts the notes to it.
    func setTempo(_ value: Double) { bpm = min(max(value, 60), 200); reset() }

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
        usingMusic = music?.isPlaying ?? false
        if usingMusic {
            // The song's measured tempo, when its audio could be read; else the tempo set.
            if let measured = music?.currentTempo { bpm = measured }
            // The beat grid starts on the next whole beat of the song's clock.
            let t = music?.playbackTime ?? 0
            startTime = time + (beat - t.truncatingRemainder(dividingBy: beat))
        } else {
            synth.start(bpm: bpm, leadIn: 2, style: style)
        }
        started = true
        log("[Games] Rhythm: \(notes.count) notes at \(Int(bpm)) bpm\(usingMusic ? " to Apple Music" : " to the synth")")
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
                hits.append((notes[i].lane, c.time))
                if hits.count > 16 { hits.removeFirst() }
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

    func draw(into scene: inout Scene3D, context c: GameContext) {
        guard started else { return }
        let m = c.meshes
        let now = c.time - startTime
        let eye = c.headPosition
        let forward = G.flat(c.forward)
        let right = simd_cross(forward, SIMD3(0, 1, 0))
        let base = SIMD3(eye.x, eye.y - 0.25, eye.z)
        let colors: [SIMD4<Float>] = [SIMD4(1, 0.3, 0.8, 1), SIMD4(1, 0.85, 0.3, 1), SIMD4(0.5, 1, 0.4, 1), SIMD4(0.7, 0.4, 1, 1)]
        let beat = Float(fmod(now * Double(bpm) / 60, 1))
        // The target rings 0.6 m ahead, pulsing on the beat, with a lane rail running away.
        for lane in 0..<4 {
            let p = base + forward * 0.6 + right * laneX(lane)
            let pulse = 1 + 0.08 * (1 - beat)
            scene.add(m.torus, at: p, rotation: G.look(forward) * G.pitch(.pi / 2), scale: SIMD3(repeating: 0.1 * pulse), color: colors[lane], roughness: 0.2, metallic: 0.5, emissive: 0.6, shadow: false)
            scene.rod(m, p + forward * 0.2 - SIMD3(0, 0.12, 0), p + forward * 4.5 - SIMD3(0, 0.12, 0), radius: 0.006, color: colors[lane] * SIMD4(0.5, 0.5, 0.5, 1), emissive: 0.4)
        }
        // The notes: glossy gems travelling in, grey when missed, with a trail glow.
        for note in notes where !note.hit {
            let delta = Float(note.time - now)
            if delta > 3 || delta < -0.4 { continue }
            let p = base + forward * (0.6 + delta * 1.3) + right * laneX(note.lane)
            let color = note.missed ? SIMD4<Float>(0.4, 0.4, 0.4, 1) : colors[note.lane]
            scene.add(m.sphere, at: p, rotation: G.yaw(Float(now) * 2) * G.pitch(0.5), scale: SIMD3(0.06, 0.08, 0.06), color: color, roughness: 0.15, metallic: 0.4, emissive: note.missed ? 0 : 0.5, shadow: false)
            if !note.missed { scene.glow(p, size: 0.25, eye: eye, color: color * SIMD4(1, 1, 1, 0.3)) }
        }
        for hit in hits where c.time - hit.time < 0.4 {
            let t = Float(c.time - hit.time) / 0.4
            let p = base + forward * 0.6 + right * laneX(hit.lane)
            scene.glow(p, size: 0.15 + t * 0.4, eye: eye, color: colors[hit.lane] * SIMD4(1, 1, 1, (1 - t) * 0.8))
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
    private var style = RhythmGame.Style.synthwave

    func start(bpm: Double, leadIn: Double, style: RhythmGame.Style = .synthwave) {
        self.bpm = bpm
        self.leadIn = leadIn
        self.style = style
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
                    let beatIndex = Int(t / beat)
                    // Kick: a dropping sine, 80 ms; drum and bass skips the third beat and adds a
                    // snare, lo-fi a soft kick on one and three.
                    let kicks: Bool
                    switch self.style {
                    case .drumAndBass: kicks = beatIndex % 4 != 2
                    case .lofi: kicks = beatIndex % 2 == 0
                    default: kicks = true
                    }
                    if kicks && inBeat < 0.08 { sample += sin(2 * .pi * (120 - inBeat * 600) * inBeat) * (1 - inBeat / 0.08) * (self.style == .lofi ? 0.35 : 0.5) }
                    if (self.style == .drumAndBass || self.style == .techno) && beatIndex % 2 == 1 && inBeat < 0.05 {
                        // A snare: noise with a fast decay.
                        sample += (Double.random(in: -1...1)) * (1 - inBeat / 0.05) * 0.25
                    }
                    if self.style == .techno || self.style == .drumAndBass || self.style == .chiptune {
                        // Hats on the off-beats.
                        let inHalf = t.truncatingRemainder(dividingBy: beat / 2)
                        if inBeat >= beat / 2 && inHalf < 0.02 { sample += Double.random(in: -1...1) * (1 - inHalf / 0.02) * 0.08 }
                    }
                    // Lead: the pentatonic walk; eighths, or sixteenths for drum and bass and chiptune;
                    // a square (synthwave, chiptune), a saw (techno), a triangle (lo-fi), a sine (d&b).
                    let division = (self.style == .drumAndBass || self.style == .chiptune) ? beat / 4 : beat / 2
                    let step = Int(t / division)
                    let f = self.scale[(step * 3 + step / 7) % self.scale.count] * (self.style == .lofi ? 0.5 : 1)
                    let env = 1 - (t.truncatingRemainder(dividingBy: division)) / division
                    let phaseT = f * t
                    let wave: Double
                    switch self.style {
                    case .techno: wave = 2 * (phaseT - floor(phaseT + 0.5)) * 0.8
                    case .lofi: wave = (2 * abs(2 * (phaseT - floor(phaseT + 0.5))) - 1) * 0.9
                    case .drumAndBass: wave = sin(2 * .pi * phaseT) * 0.9
                    default: wave = sin(2 * .pi * phaseT) > 0 ? 1 : -1
                    }
                    sample += wave * 0.12 * env
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
