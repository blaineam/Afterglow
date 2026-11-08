import simd
import Foundation

// MARK: - Shared geometry helpers

enum G {
    static func yaw(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3(0, 1, 0)) }
    static func pitch(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3(1, 0, 0)) }
    static func roll(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3(0, 0, 1)) }
    /// A rotation whose -z faces `forward` with y as near up as it can.
    static func look(_ forward: SIMD3<Float>, up: SIMD3<Float> = SIMD3(0, 1, 0)) -> simd_quatf {
        // Right-handed: right = forward x up, up = right x forward, -z = forward. The first
        // version took up x forward, a reflection, which mirrored the golf felt against its
        // walls and turned the coaster's world upside down (2026-11-07).
        let f = simd_normalize(forward)
        var r = simd_cross(f, up)
        if simd_length(r) < 1e-4 { r = SIMD3(1, 0, 0) }
        r = simd_normalize(r)
        let u = simd_cross(r, f)
        return simd_quatf(simd_float3x3(columns: (r, u, -f)))
    }
    /// A rotation taking +y onto `direction` (for capsules and cylinders laid along a line).
    static func along(_ direction: SIMD3<Float>) -> simd_quatf {
        let d = simd_normalize(direction)
        let y = SIMD3<Float>(0, 1, 0)
        let c = simd_dot(y, d)
        if c > 0.9999 { return simd_quatf(angle: 0, axis: y) }
        if c < -0.9999 { return simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0)) }
        return simd_quatf(angle: acos(c), axis: simd_normalize(simd_cross(y, d)))
    }
    static func flat(_ v: SIMD3<Float>) -> SIMD3<Float> { let f = SIMD3(v.x, 0, v.z); return simd_length(f) < 1e-4 ? SIMD3(0, 0, -1) : simd_normalize(f) }
    static let white = SIMD4<Float>(1, 1, 1, 1)
    static let palette: [SIMD4<Float>] = [SIMD4(1, 0.3, 0.6, 1), SIMD4(0.25, 0.8, 1, 1), SIMD4(1, 0.8, 0.2, 1), SIMD4(0.5, 0.9, 0.35, 1), SIMD4(0.65, 0.45, 1, 1), SIMD4(1, 0.5, 0.2, 1)]
}

extension Scene3D {
    /// A capsule from a to b with the given radius.
    mutating func capsule(_ m: MeshLibrary, _ a: SIMD3<Float>, _ b: SIMD3<Float>, radius: Float, color: SIMD4<Float>, roughness: Float = 0.4, metallic: Float = 0, emissive: Float = 0, shadow: Bool = false) {
        let d = b - a
        let length = simd_length(d)
        guard length > 1e-4 else { return }
        // The unit capsule is 1 long between the hemisphere centres and radius 1: scale y by
        // length/..., the rest by the radius, so the caps keep their roundness.
        add(m.capsule, at: (a + b) / 2, rotation: G.along(d), scale: SIMD3(radius, length / 1, radius) * SIMD3(1, 1, 1), color: color, roughness: roughness, metallic: metallic, emissive: emissive, shadow: shadow)
    }
    /// A cylinder from a to b.
    mutating func rod(_ m: MeshLibrary, _ a: SIMD3<Float>, _ b: SIMD3<Float>, radius: Float, color: SIMD4<Float>, roughness: Float = 0.4, metallic: Float = 0, emissive: Float = 0, pattern: Float = 0, shadow: Bool = false) {
        let d = b - a
        let length = simd_length(d)
        guard length > 1e-4 else { return }
        add(m.cylinder, at: (a + b) / 2, rotation: G.along(d), scale: SIMD3(radius, length, radius), color: color, roughness: roughness, metallic: metallic, emissive: emissive, pattern: pattern, shadow: shadow)
    }
}

// MARK: - 3D painting

/// Pinch and move to paint in the air. The palette on the games panel picks the colour (or a
/// rainbow by the hand's height), the size, the brush (a glossy tube, a flat ribbon that faces
/// you, or a glowing bead trail) and dynamics (the stroke thins as the hand moves faster);
/// undo takes the last stroke. Sparks follow the brush.
@MainActor
final class PaintGame: Game {
    let title = "🎨 Paint"
    enum Brush: Int, CaseIterable { case tube, ribbon, glow
        var name: String { switch self { case .tube: return "Tube"; case .ribbon: return "Ribbon"; case .glow: return "Glow" } }
        var icon: String { switch self { case .tube: return "paintbrush.pointed.fill"; case .ribbon: return "scribble.variable"; case .glow: return "sparkles" } }
    }
    private struct Stroke { var color: SIMD4<Float>; var points: [SIMD3<Float>]; var radii: [Float]; var brush: Brush; var built = -1 }
    private var strokes: [Stroke] = []
    private var drawing: [Bool: Int] = [:]
    private var lastPoint: [Bool: (SIMD3<Float>, Double)] = [:]
    /// When each stroke last grew, so a pinch that flickers open for up to a second (the phone
    /// log showed re-pinches 0.7 s apart) or a hand whose side flips carries on the same stroke
    /// instead of leaving dots (owner, 2026-11-07).
    private var strokeGrewAt: [Int: Double] = [:]
    /// The brush point smoothed per hand (the flat hand fit jitters in depth when the hand moves
    /// fast, which painted jets into the distance, owner 2026-11-07); a jump past 30 cm between
    /// results is dropped as noise.
    private var brushFilters: [Bool: OneEuroFilter] = [:]
    private var lastRaw: [Bool: SIMD3<Float>] = [:]
    private var particles = ParticleSystem()
    static let swatches: [(String, SIMD4<Float>)] = [("🔴", SIMD4(1, 0.25, 0.25, 1)), ("🟠", SIMD4(1, 0.55, 0.15, 1)), ("🟡", SIMD4(1, 0.9, 0.2, 1)), ("🟢", SIMD4(0.3, 0.9, 0.4, 1)),
                                                     ("🔵", SIMD4(0.25, 0.55, 1, 1)), ("🟣", SIMD4(0.7, 0.4, 1, 1)), ("🩷", SIMD4(1, 0.4, 0.75, 1)), ("⚪", SIMD4(0.95, 0.95, 0.95, 1))]
    /// nil: the colour follows the hand's height, a rainbow from the floor up.
    private(set) var swatch: Int? = nil
    private(set) var sizeIndex = 1
    static let sizes: [Float] = [0.006, 0.012, 0.024]
    private(set) var brush = Brush.tube
    private(set) var dynamics = true
    var status: String { "\(strokes.count) strokes · \(brush.name) · " + (swatch.map { Self.swatches[$0].0 } ?? "🌈") }

    private var ignored = Set<Bool>()
    func reset() { strokes.removeAll(); drawing.removeAll(); strokeGrewAt.removeAll(); ignored.removeAll() }
    func undo() { if !strokes.isEmpty { strokes.removeLast() } }
    // Mesh names are by index, so a removed stroke's slot is rebuilt by the next stroke to take it (`built` differs).
    func pick(swatch index: Int?) { swatch = index }
    func cycleSize() { sizeIndex = (sizeIndex + 1) % Self.sizes.count }
    func cycleBrush() { brush = Brush(rawValue: (brush.rawValue + 1) % Brush.allCases.count) ?? .tube }
    func toggleDynamics() { dynamics.toggle() }

    private func color(forHeight h: Float) -> SIMD4<Float> {
        if let swatch { return Self.swatches[swatch].1 }
        let t = max(0, min(1, h / 1.8)) * 0.85
        let (r, g, b) = Self.hsv(t, 0.75, 1)
        return SIMD4(r, g, b, 1)
    }
    static func hsv(_ h: Float, _ s: Float, _ v: Float) -> (Float, Float, Float) {
        let i = Int(h * 6), f = h * 6 - Float(i)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    func update(_ c: GameContext) {
        for hand in c.hands {
            // A pinch that began on a button belongs to the button until it is released.
            if hand.pinched && drawing[hand.isRight] == nil && (c.pointerOnInterface || ignored.contains(hand.isRight)) {
                ignored.insert(hand.isRight)
                continue
            }
            if !hand.pinched { ignored.remove(hand.isRight) }
            let raw = hand.pinchPoint
            if let last = lastRaw[hand.isRight], simd_distance(raw, last) > 0.3 { lastRaw[hand.isRight] = raw; continue }
            lastRaw[hand.isRight] = raw
            var filter = brushFilters[hand.isRight] ?? OneEuroFilter(minCutoff: 1.0, beta: 0.3)
            let tip = filter.filter(raw, time: c.time)
            brushFilters[hand.isRight] = filter
            var speed: Float = 0
            if let (last, t) = lastPoint[hand.isRight], c.time > t { speed = simd_distance(tip, last) / Float(min(c.time - t, 0.1)) }
            lastPoint[hand.isRight] = (tip, c.time)
            let base = Self.sizes[sizeIndex]
            let radius = dynamics ? base * max(0.35, min(1.5, 1.4 - speed * 1.2)) : base
            if hand.pinched {
                if drawing[hand.isRight] == nil {
                    // A stroke that grew within half a second and ends within 10 cm continues.
                    if let i = strokes.indices.last, let grew = strokeGrewAt[i], c.time - grew < 1.0, let last = strokes[i].points.last, simd_distance(last, tip) < 0.15 {
                        drawing[hand.isRight] = i
                    } else {
                        strokes.append(Stroke(color: color(forHeight: tip.y - c.floorHeight), points: [tip], radii: [radius], brush: brush))
                        drawing[hand.isRight] = strokes.count - 1
                        strokeGrewAt[strokes.count - 1] = c.time
                    }
                }
                if let i = drawing[hand.isRight], strokes.indices.contains(i) {
                    if let last = strokes[i].points.last, simd_distance(last, tip) > 0.006 {
                        strokes[i].points.append(tip)
                        strokes[i].radii.append(radius)
                        strokeGrewAt[i] = c.time
                        particles.burst(at: tip, count: 2, speed: 0.3, color: strokes[i].color, life: 0.4, size: 0.012, gravity: 0.5)
                    }
                }
            } else {
                drawing[hand.isRight] = nil
            }
        }
        if c.select && !c.pointerOnInterface && c.hands.allSatisfy({ !$0.pinched }) && !strokes.isEmpty { strokes.removeLast() }
        particles.update(dt: c.dt)
    }

    func draw(into scene: inout Scene3D, context c: GameContext) {
        let m = c.meshes
        let eye = c.headPosition
        // Each stroke is one smooth mesh: a spline through its points with the diameter blending
        // along it (the earlier chain of capsules read as lumps, owner 2026-11-07); rebuilt only
        // while it grows. A ribbon is a flat strip facing where the painter stood; glow is a
        // thin emissive tube with sprites along it.
        for (s, stroke) in strokes.enumerated() {
            let name = "paint-\(s)"
            let stale = stroke.built != stroke.points.count
            var mesh: MeshLibrary.Mesh?
            if stale {
                let (v, i): ([MeshVertex], [UInt32])
                switch stroke.brush {
                case .tube: (v, i) = MeshLibrary.tube(points: stroke.points, radii: stroke.radii, sides: 12)
                case .ribbon: (v, i) = MeshLibrary.tube(points: stroke.points, radii: stroke.radii.map { $0 * 3 }, flat: true, facing: simd_normalize(eye - stroke.points[0]))
                case .glow: (v, i) = MeshLibrary.tube(points: stroke.points, radii: stroke.radii.map { $0 * 0.7 }, sides: 8)
                }
                mesh = m.dynamic(name, vertices: v, indices: i)
                strokes[s].built = stroke.points.count
            } else {
                mesh = m.existing(name)
            }
            guard let mesh, mesh.indexCount > 0 else { continue }
            switch stroke.brush {
            case .tube: scene.add(mesh, at: .zero, scale: SIMD3(repeating: 1), color: stroke.color, roughness: 0.2, shadow: false)
            case .ribbon: scene.add(mesh, at: .zero, scale: SIMD3(repeating: 1), color: stroke.color, roughness: 0.4, shadow: false)
            case .glow:
                scene.add(mesh, at: .zero, scale: SIMD3(repeating: 1), color: stroke.color, roughness: 0.1, emissive: 1.1, shadow: false)
                for (i, p) in stroke.points.enumerated() where i % 2 == 0 {
                    scene.glow(p, size: stroke.radii[i] * 7, eye: eye, color: stroke.color * SIMD4(1, 1, 1, 0.3))
                }
            }
        }
        for hand in c.hands {
            let p = hand.pinchPoint
            let color = color(forHeight: p.y - c.floorHeight)
            scene.add(m.smallSphere, at: p, scale: SIMD3(repeating: Self.sizes[sizeIndex] * 1.2), color: color, roughness: 0.1, emissive: 0.6, shadow: false)
            scene.glow(p, size: 0.06, eye: eye, color: color * SIMD4(1, 1, 1, 0.35))
        }
        particles.draw(into: &scene, eye: eye)
    }
}

// MARK: - Alien blob shooter

/// Blobs with big eyes squelch in from around the room in waves; a punch forward fires a
/// plasma bolt from the hand along the gaze. Hits splash goo; a blob that reaches you costs a
/// life. Every wave is faster and bigger.
@MainActor
final class BlobShooter: Game {
    let title = "👾 Blobs"
    private struct Blob { var position: SIMD3<Float>; var speed: Float; var phase: Float; var size: Float; var color: SIMD4<Float>; var hp: Int; var hurt: Float }
    private struct Bolt { var position: SIMD3<Float>; var velocity: SIMD3<Float>; var age: Float }
    private var blobs: [Blob] = []
    private var bolts: [Bolt] = []
    private var score = 0
    private var lives = 3
    private var wave = 1
    private var waveLeft = 6
    private var spawnTimer: Float = 0
    private var fireCooldown: [Bool: Double] = [:]
    private let motion = HandMotionTracker()
    private var particles = ParticleSystem()
    private var over = false
    private var flash: Float = 0
    private var shots = 0
    private var hits = 0
    private var popped = 0
    private var survived: Float = 0
    var status: String { over ? "Game over: \(score)" : "Wave \(wave) · Score \(score) · ♥ \(lives)" }

    var summary: GameSummary? {
        guard over else { return nil }
        let accuracy = shots > 0 ? Int((Float(hits) / Float(shots) * 100).rounded()) : 0
        return GameSummary(title: "Game over", lines: [
            ("Score", "\(score)"),
            ("Wave reached", "\(wave)"),
            ("Blobs popped", "\(popped)"),
            ("Accuracy", "\(accuracy)% of \(shots) shots"),
            ("Survived", String(format: "%d:%02d", Int(survived) / 60, Int(survived) % 60)),
        ])
    }

    func reset() {
        blobs.removeAll(); bolts.removeAll(); score = 0; lives = 3; over = false; spawnTimer = 0; wave = 1; waveLeft = 6
        shots = 0; hits = 0; popped = 0; survived = 0
    }

    func update(_ c: GameContext) {
        particles.update(dt: c.dt)
        flash = max(0, flash - c.dt * 3)
        guard !over else { return }
        survived += c.dt
        spawnTimer -= c.dt
        if spawnTimer <= 0 && blobs.count < 4 + wave && waveLeft > 0 {
            waveLeft -= 1
            spawnTimer = Float.random(in: 0.9...2.0) / (1 + Float(wave) * 0.15)
            let angle = Float.random(in: -1.0...1.0)
            let dir = G.yaw(angle).act(G.flat(c.forward))
            let size = Float.random(in: 0.2...0.36)
            blobs.append(Blob(position: c.headPosition + dir * Float.random(in: 4.5...6.5) + SIMD3(0, Float.random(in: -0.7...0.3), 0),
                              speed: Float.random(in: 0.3...0.55) * (1 + Float(wave) * 0.15), phase: Float.random(in: 0...6), size: size,
                              color: [SIMD4(0.45, 1, 0.3, 1), SIMD4(0.8, 0.4, 1, 1), SIMD4(0.3, 0.9, 1, 1)][Int.random(in: 0..<3)], hp: size > 0.25 ? 2 : 1, hurt: 0))
        }
        if waveLeft == 0 && blobs.isEmpty {
            wave += 1
            waveLeft = 5 + wave * 2
            log("[Games] Blobs: wave \(wave)")
        }
        for hand in motion.motions(c.hands, time: c.time) {
            let forwardSpeed = simd_dot(hand.velocity, c.forward)
            let last = fireCooldown[hand.isRight] ?? 0
            if forwardSpeed > 1.5 && c.time - last > 0.3 {
                fireCooldown[hand.isRight] = c.time
                bolts.append(Bolt(position: hand.position, velocity: c.forward * 10, age: 0))
                shots += 1
            }
        }
        if c.select, c.hands.isEmpty, !c.pointerOnInterface {
            bolts.append(Bolt(position: c.headPosition + c.forward * 0.3 - SIMD3(0, 0.1, 0), velocity: c.forward * 10, age: 0))
            shots += 1
        }
        for i in bolts.indices { bolts[i].position += bolts[i].velocity * c.dt; bolts[i].age += c.dt }
        bolts.removeAll { $0.age > 2 }
        for i in blobs.indices {
            let toHead = c.headPosition - SIMD3(0, 0.2, 0) - blobs[i].position
            let distance = simd_length(toHead)
            blobs[i].position += toHead / max(distance, 0.01) * blobs[i].speed * c.dt
            // A squelching hop: up on the beat, settling between.
            blobs[i].position.y += sin(Float(c.time) * 3 + blobs[i].phase) * 0.006
            blobs[i].hurt = max(0, blobs[i].hurt - c.dt * 4)
        }
        var dead = Set<Int>()
        for (bi, bolt) in bolts.enumerated() where bolt.age < 5 {
            for (i, blob) in blobs.enumerated() where simd_distance(bolt.position, blob.position) < blob.size + 0.1 {
                if bolts[bi].age < 10 { hits += 1 }
                bolts[bi].age = 10
                blobs[i].hp -= 1
                blobs[i].hurt = 1
                particles.burst(at: bolt.position, count: 18, speed: 1.6, color: blob.color, life: 0.7, size: 0.03)
                if blobs[i].hp <= 0 {
                    if !dead.contains(i) { popped += 1 }
                    dead.insert(i)
                    score += blob.size > 0.25 ? 25 : 10
                    particles.burst(at: blob.position, count: 40, speed: 2.2, color: blob.color, life: 0.9, size: 0.05)
                }
            }
        }
        blobs = blobs.enumerated().filter { !dead.contains($0.offset) }.map(\.element)
        let reached = blobs.filter { simd_distance($0.position, c.headPosition) < 0.55 }
        if !reached.isEmpty {
            lives -= reached.count
            flash = 1
            for b in reached { particles.burst(at: b.position, count: 30, speed: 1.5, color: SIMD4(1, 0.3, 0.3, 1)) }
            blobs.removeAll { simd_distance($0.position, c.headPosition) < 0.55 }
            if lives <= 0 { over = true; log("[Games] Blobs: game over at \(score)") }
        }
    }

    func draw(into scene: inout Scene3D, context c: GameContext) {
        let m = c.meshes
        let eye = c.headPosition
        for blob in blobs {
            let t = Float(c.time) * 3 + blob.phase
            let squash = 1 + 0.12 * sin(t)
            let body = blob.size
            let color = blob.hurt > 0 ? simd_mix(blob.color, G.white, SIMD4(repeating: blob.hurt)) : blob.color
            scene.add(m.sphere, at: blob.position, scale: SIMD3(body * (2 - squash) * 0.9, body * squash, body * (2 - squash) * 0.9), color: color, roughness: 0.25, pattern: 4)
            // Two eyes facing the player, with pupils, and a wobble of antennae.
            let toEye = simd_normalize(eye - blob.position)
            let right = simd_normalize(simd_cross(SIMD3(0, 1, 0), toEye))
            for side: Float in [-1, 1] {
                let eyePos = blob.position + toEye * body * 0.8 + right * side * body * 0.38 + SIMD3(0, body * 0.25, 0)
                scene.add(m.smallSphere, at: eyePos, scale: SIMD3(repeating: body * 0.22), color: G.white, roughness: 0.1, shadow: false)
                scene.add(m.smallSphere, at: eyePos + toEye * body * 0.14, scale: SIMD3(repeating: body * 0.1), color: SIMD4(0.05, 0.05, 0.08, 1), roughness: 0.1, shadow: false)
                let stalk = blob.position + SIMD3(0, body * squash, 0) + right * side * body * 0.3
                let tip = stalk + SIMD3(sin(t * 1.3) * 0.03, body * 0.45, cos(t) * 0.03)
                scene.rod(m, stalk, tip, radius: body * 0.05, color: color * 0.8 + SIMD4(0, 0, 0, 0.2))
                scene.add(m.smallSphere, at: tip, scale: SIMD3(repeating: body * 0.1), color: SIMD4(1, 0.9, 0.3, 1), emissive: 0.8, shadow: false)
            }
        }
        for bolt in bolts where bolt.age < 5 {
            let back = bolt.position - simd_normalize(bolt.velocity) * 0.3
            scene.capsule(m, back, bolt.position, radius: 0.025, color: SIMD4(1, 0.5, 0.95, 1), roughness: 0.1, emissive: 1.2)
            scene.glow(bolt.position, size: 0.14, eye: eye, color: SIMD4(1, 0.4, 0.9, 0.5))
            scene.streak(back - simd_normalize(bolt.velocity) * 0.4, bolt.position, width: 0.05, eye: eye, color: SIMD4(1, 0.4, 0.9, 0.25))
        }
        if flash > 0 { scene.glow(eye + c.forward * 0.5, size: 2, eye: eye, color: SIMD4(1, 0.1, 0.1, flash * 0.35)) }
        particles.draw(into: &scene, eye: eye)
    }
}

// MARK: - Vacuum the room

/// Dust bunnies lie over the floor (the detected floor, or a square round the player). Hold a
/// hand low and a glowing nozzle appears under it; what it passes over is sucked up in a swirl.
/// Walking over a pile cleans it too. Done when the last pile goes.
@MainActor
final class VacuumGame: Game {
    let title = "🧹 Vacuum"
    private struct Pile { var position: SIMD3<Float>; var size: Float; var seed: Float }
    private var piles: [SIMD2<Int>: Pile] = [:]
    private var floor: Float = -1.6
    private let spacing: Float = 0.3
    private var seeded = false
    private var cleaned = 0
    private var particles = ParticleSystem()
    private var elapsed: Float = 0
    var status: String { piles.isEmpty && seeded ? "All clean! \(cleaned) piles" : (seeded ? "\(piles.count) piles left" : "No floor yet") }

    var summary: GameSummary? {
        guard seeded, piles.isEmpty else { return nil }
        return GameSummary(title: "All clean!", lines: [
            ("Dust piles", "\(cleaned)"),
            ("Time", String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)),
            ("Piles a minute", String(format: "%.0f", Float(cleaned) / max(elapsed / 60, 0.1))),
        ], again: "More dust")
    }

    func reset() { piles.removeAll(); seeded = false; cleaned = 0; elapsed = 0 }

    private func seed(_ k: SIMD2<Int>) {
        let jitter = SIMD3(Float.random(in: -0.08...0.08), 0, Float.random(in: -0.08...0.08))
        piles[k] = Pile(position: SIMD3(Float(k.x) * spacing, floor, Float(k.y) * spacing) + jitter, size: Float.random(in: 0.04...0.09), seed: Float.random(in: 0...6))
    }

    func update(_ c: GameContext) {
        floor = c.floorHeight
        particles.update(dt: c.dt)
        if !piles.isEmpty { elapsed += c.dt }
        if !seeded {
            let floors = c.surfaces.filter { $0.isHorizontal && abs($0.center.y - c.floorHeight) < 0.15 }
            if floors.isEmpty {
                let o = c.headPosition
                for x in -6...6 { for z in -6...6 where Float.random(in: 0...1) < 0.7 { seed(SIMD2(Int(o.x / spacing) + x, Int(o.z / spacing) + z)) } }
            } else {
                for s in floors {
                    let cx = Int((s.center.x / spacing).rounded()), cz = Int((s.center.z / spacing).rounded())
                    let ex = Int(s.extent.x / spacing), ez = Int(s.extent.y / spacing)
                    for x in -ex...ex { for z in -ez...ez where Float.random(in: 0...1) < 0.7 { seed(SIMD2(cx + x, cz + z)) } }
                }
            }
            seeded = true
        }
        // The nozzle under a low hand cleans a 28 cm circle; the feet, under the head, a 45 cm
        // one (the owner walked over piles that stayed, 2026-11-07).
        var nozzles: [(SIMD3<Float>, Float)] = c.hands.map { $0.joints[HandGeometry.wrist] }.filter { $0.y - floor < 0.5 }.map { ($0, 0.28) }
        nozzles.append((SIMD3(c.headPosition.x, floor + 0.2, c.headPosition.z), 0.45))
        for (n, radius) in nozzles {
            for (k, pile) in piles where simd_distance(SIMD3(pile.position.x, 0, pile.position.z), SIMD3(n.x, 0, n.z)) < radius {
                piles[k] = nil
                cleaned += 1
                for _ in 0..<6 {
                    particles.burst(at: pile.position + SIMD3(0, 0.03, 0), count: 1, speed: 0.2, color: SIMD4(0.85, 0.75, 0.55, 1), life: 0.5, size: 0.025, gravity: -3)
                }
            }
        }
    }

    func draw(into scene: inout Scene3D, context c: GameContext) {
        let m = c.meshes
        let eye = c.headPosition
        for pile in piles.values where simd_distance(pile.position, eye) < 9 {
            // A dust bunny: three lumpy grey-brown spheres.
            let s = pile.size
            scene.add(m.smallSphere, at: pile.position + SIMD3(0, s * 0.5, 0), scale: SIMD3(s, s * 0.55, s * 0.9), color: SIMD4(0.72, 0.64, 0.5, 1), roughness: 1, pattern: 5)
            scene.add(m.smallSphere, at: pile.position + SIMD3(s * 0.5, s * 0.35, s * 0.2), scale: SIMD3(repeating: s * 0.5), color: SIMD4(0.6, 0.55, 0.45, 1), roughness: 1, pattern: 5, shadow: false)
            scene.add(m.smallSphere, at: pile.position + SIMD3(-s * 0.4, s * 0.4, -s * 0.3), scale: SIMD3(repeating: s * 0.45), color: SIMD4(0.78, 0.7, 0.58, 1), roughness: 1, pattern: 5, shadow: false)
        }
        // The feet: a ring on the floor under the head, so the player sees where walking counts.
        let feet = SIMD3(eye.x, floor + 0.01, eye.z)
        scene.add(m.ring, at: feet, scale: SIMD3(0.45, 1, 0.45), color: SIMD4(0.4, 0.9, 1, 1), roughness: 0.3, emissive: 0.8, shadow: false)
        scene.glow(feet, size: 0.9, eye: eye + SIMD3(0, 0.1, 0), color: SIMD4(0.4, 0.9, 1, 0.15))
        // The nozzle under a low hand: a chrome ring with a glow.
        for hand in c.hands where hand.joints[HandGeometry.wrist].y - floor < 0.5 {
            let w = hand.joints[HandGeometry.wrist]
            let foot = SIMD3(w.x, floor + 0.02, w.z)
            scene.add(m.torus, at: foot, scale: SIMD3(0.12, 0.12, 0.12), color: SIMD4(0.8, 0.85, 0.9, 1), roughness: 0.2, metallic: 0.8, shadow: false)
            scene.rod(m, foot + SIMD3(0, 0.02, 0), w, radius: 0.025, color: SIMD4(0.3, 0.3, 0.35, 1), roughness: 0.5, metallic: 0.3)
            scene.glow(foot, size: 0.3, eye: eye, color: SIMD4(0.4, 0.9, 1, 0.3))
        }
        particles.draw(into: &scene, eye: eye)
    }
}

// MARK: - Toy box

/// A toy box sits on the floor ahead with toys in it: cars, ducks, rockets, robots, planes,
/// balls and spinning tops. Pinch a toy to pick it up, let go to throw it; they fall, bounce and
/// stack. Pinch in empty space for another toy. Hidden at the bottom of the box is a big red
/// button: press it and every toy wakes up and goes about its business in the way its kind
/// would, until the button is pressed again.
@MainActor
final class ToyBox: Game {
    let title = "🧸 Toys"
    enum Kind: Int, CaseIterable { case car, duck, rocket, robot, plane, ball, top }
    struct Toy {
        var kind: Kind
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var yaw: Float
        var size: Float
        var color: SIMD4<Float>
        var phase: Float
        var spin: Float = 0
        var mode: Int = 0          // what a living toy is doing (the rocket's flight stage)
        var timer: Float = 0
        var target = SIMD3<Float>.zero
    }
    private(set) var toys: [Toy] = []
    private var held: [Bool: Int] = [:]
    private var wasPinched: [Bool: Bool] = [:]
    private let motion = HandMotionTracker()
    private var particles = ParticleSystem()
    private var placed = false
    private var boxCentre = SIMD3<Float>.zero
    private var boxYaw: Float = 0
    private(set) var awake = false
    private var buttonPress: Float = 0
    private var lastButton: Double = 0
    private var nextKind = 0
    private let boxSize = SIMD3<Float>(0.7, 0.35, 0.5)
    var status: String { awake ? "\(toys.count) toys, awake!" : "\(toys.count) toys" }

    func reset() { toys.removeAll(); held.removeAll(); placed = false; awake = false }

    /// The button sits on the box's lid, at its front edge facing the player.
    private var buttonPosition: SIMD3<Float> { boxCentre + SIMD3(0, boxSize.y + 0.03, 0) - boxFront * (boxSize.z / 2 - 0.08) }
    private var boxFront: SIMD3<Float> { SIMD3(sin(boxYaw), 0, -cos(boxYaw)) }
    /// The box's open top, where a pinch pulls out a new toy.
    private var boxTop: SIMD3<Float> { boxCentre + SIMD3(0, boxSize.y, 0) }

    /// The controls window's New toy: the next kind, out of the box.
    func newToy() {
        spawn(Kind.allCases[nextKind % Kind.allCases.count], at: boxTop + SIMD3(Float.random(in: -0.15...0.15), 0.3, Float.random(in: -0.1...0.1)))
        nextKind += 1
    }

    /// The controls window's Tidy up: every toy back in the box, asleep.
    func tidy() {
        held.removeAll()
        for i in toys.indices {
            let a = Float(i) / Float(max(toys.count, 1)) * 2 * .pi
            toys[i].position = boxTop + SIMD3(cos(a) * 0.2, 0.15 + Float(i % 3) * 0.08, sin(a) * 0.12)
            toys[i].velocity = .zero
            toys[i].mode = 0
        }
        if awake { awake = false; log("[Games] Toys: tidied away, asleep") }
    }

    private func spawn(_ kind: Kind, at p: SIMD3<Float>) {
        let size: Float
        switch kind {
        case .car: size = 0.12
        case .duck: size = 0.09
        case .rocket: size = 0.1
        case .robot: size = 0.11
        case .plane: size = 0.13
        case .ball: size = 0.08
        case .top: size = 0.08
        }
        toys.append(Toy(kind: kind, position: p, velocity: .zero, yaw: Float.random(in: 0...6.28), size: size,
                        color: G.palette[toys.count % G.palette.count], phase: Float.random(in: 0...6)))
    }

    private func place(_ c: GameContext) {
        let f = G.flat(c.forward)
        boxCentre = SIMD3(c.headPosition.x, c.floorHeight, c.headPosition.z) + f * 1.3
        boxYaw = atan2(f.x, -f.z)
        toys.removeAll()
        for (i, kind) in Kind.allCases.enumerated() {
            let a = Float(i) / Float(Kind.allCases.count) * 2 * .pi
            spawn(kind, at: boxCentre + SIMD3(cos(a) * 0.18, 0.25 + Float(i) * 0.06, sin(a) * 0.14))
        }
        placed = true
    }

    /// Wakes or sleeps every toy.
    func pressButton(time: Double) {
        guard time - lastButton > 0.6 else { return }
        lastButton = time
        awake.toggle()
        buttonPress = 1
        for i in toys.indices {
            toys[i].mode = 0
            toys[i].timer = Float.random(in: 0.5...2)
            if awake, toys[i].kind == .rocket { toys[i].mode = 0; toys[i].timer = Float.random(in: 1...3) }
        }
        particles.burst(at: buttonPosition, count: 40, speed: 1.5, color: awake ? SIMD4(1, 0.9, 0.3, 1) : SIMD4(0.5, 0.6, 1, 1), life: 1, size: 0.03, gravity: 1)
        log("[Games] Toys: \(awake ? "awake" : "asleep")")
    }

    func update(_ c: GameContext) {
        if !placed { place(c) }
        let floor = c.floorHeight
        particles.update(dt: c.dt)
        buttonPress = max(0, buttonPress - c.dt * 4)
        // The gaze on the button with a select presses it, before anything a hand would do with
        // the same pinch (owner, 2026-11-08: the button could not be pressed for new toys).
        if c.select, !c.pointerOnInterface {
            let to = buttonPosition - c.headPosition
            let along = simd_dot(to, c.forward)
            let miss = simd_length(to - c.forward * along)
            if along > 0, miss < max(0.2, along * 0.12) {
                pressButton(time: c.time)
                for hand in c.hands { wasPinched[hand.isRight] = true }
            }
        }
        // Hands: grab, carry, throw; pull a new toy from the box; or press the button.
        for hand in motion.motions(c.hands, time: c.time) {
            if c.pointerOnInterface && !(wasPinched[hand.isRight] ?? false) && hand.pinched && held[hand.isRight] == nil {
                wasPinched[hand.isRight] = true
                continue
            }
            let was = wasPinched[hand.isRight] ?? false
            if hand.pinched {
                if let i = held[hand.isRight], toys.indices.contains(i) {
                    toys[i].position = hand.position
                    toys[i].velocity = hand.velocity
                } else if !was {
                    if simd_distance(hand.position, buttonPosition) < 0.2 {
                        pressButton(time: c.time)
                    } else if let i = toys.indices.min(by: { simd_distance(toys[$0].position, hand.position) < simd_distance(toys[$1].position, hand.position) }),
                              simd_distance(toys[i].position, hand.position) < toys[i].size + 0.08 {
                        held[hand.isRight] = i
                    } else if simd_distance(SIMD3(hand.position.x, 0, hand.position.z), SIMD3(boxTop.x, 0, boxTop.z)) < 0.35,
                              hand.position.y - boxTop.y < 0.4 {
                        // A pinch at the box's open top pulls out a new toy; elsewhere a pinch is nothing.
                        spawn(Kind.allCases[nextKind % Kind.allCases.count], at: hand.position)
                        nextKind += 1
                        held[hand.isRight] = toys.count - 1
                    }
                }
            } else if let i = held[hand.isRight] {
                if toys.indices.contains(i) { toys[i].velocity = hand.velocity }
                held[hand.isRight] = nil
            }
            wasPinched[hand.isRight] = hand.pinched
        }
        let heldSet = Set(held.values)
        for i in toys.indices where !heldSet.contains(i) {
            if awake { live(&toys[i], c) } else { toys[i].spin = max(0, toys[i].spin - c.dt * 2) }
            let flying = awake && ((toys[i].kind == .plane && toys[i].mode == 1) || (toys[i].kind == .rocket && toys[i].mode == 1))
            if !flying {
                toys[i].velocity.y -= 9.8 * c.dt
                toys[i].position += toys[i].velocity * c.dt
                var ground = floor
                for s in c.surfaces where s.isHorizontal {
                    let local = (s.transform.inverse * SIMD4(toys[i].position, 1)).xyz
                    if abs(local.x) <= s.extent.x && abs(local.z) <= s.extent.y && s.center.y <= toys[i].position.y + toys[i].size && s.center.y > ground {
                        ground = s.center.y
                    }
                }
                // The box's floor, when inside its walls.
                let inBox = abs(toys[i].position.x - boxCentre.x) < boxSize.x / 2 && abs(toys[i].position.z - boxCentre.z) < boxSize.z / 2
                if inBox && toys[i].position.y < boxCentre.y + boxSize.y { ground = max(ground, boxCentre.y + 0.03) }
                let half = toys[i].size / 2
                if toys[i].position.y - half < ground {
                    let impact = -toys[i].velocity.y
                    toys[i].position.y = ground + half
                    toys[i].velocity.y = impact * (toys[i].kind == .ball ? 0.7 : 0.35)
                    toys[i].velocity.x *= 0.9
                    toys[i].velocity.z *= 0.9
                    if abs(toys[i].velocity.y) < 0.3 { toys[i].velocity.y = 0 }
                    if impact > 1.5 { particles.burst(at: toys[i].position - SIMD3(0, half, 0), count: 6, speed: 0.5, color: SIMD4(0.9, 0.9, 1, 0.6), life: 0.3, size: 0.015) }
                }
                if !awake { toys[i].velocity.x *= max(0, 1 - c.dt * 0.5); toys[i].velocity.z *= max(0, 1 - c.dt * 0.5) }
            } else {
                toys[i].position += toys[i].velocity * c.dt
            }
            for j in toys.indices where j != i {
                let d = toys[i].position - toys[j].position
                let minimum = (toys[i].size + toys[j].size) * 0.5
                let distance = simd_length(d)
                if distance < minimum && distance > 1e-4 {
                    toys[i].position += d / distance * (minimum - distance) * 0.5
                    toys[i].velocity += d / distance * 0.3
                }
            }
        }
    }

    /// One toy's behaviour while awake: physically plausible for its kind.
    private func live(_ t: inout Toy, _ c: GameContext) {
        let floor = c.floorHeight
        let onGround = t.position.y - t.size / 2 < floor + 0.02 || (abs(t.position.x - boxCentre.x) < boxSize.x / 2 && abs(t.position.z - boxCentre.z) < boxSize.z / 2 && t.position.y < boxCentre.y + boxSize.y + t.size)
        let home = boxCentre
        let fromHome = SIMD3(t.position.x - home.x, 0, t.position.z - home.z)
        t.timer -= c.dt
        func steerHome(_ strength: Float) {
            if simd_length(fromHome) > 2.5 { let want = atan2(-fromHome.x, fromHome.z); t.yaw += atan2(sin(want - t.yaw), cos(want - t.yaw)) * strength * c.dt }
        }
        switch t.kind {
        case .car:
            // Drives in arcs on the floor, steering towards home when far; stops when airborne.
            guard onGround else { return }
            if t.timer < 0 { t.timer = Float.random(in: 1...3); t.spin = Float.random(in: -1.2...1.2) }
            t.yaw += t.spin * c.dt
            steerHome(2)
            let forward = SIMD3(sin(t.yaw), 0, -cos(t.yaw))
            let speed: Float = 0.6
            t.velocity.x = forward.x * speed; t.velocity.z = forward.z * speed
            // Climbs out of the box over its rim.
            if t.position.y < boxCentre.y + boxSize.y && simd_length(fromHome) < boxSize.x / 2 + 0.05 && t.velocity.y == 0 { t.velocity.y = 2.4 }
        case .duck:
            // Waddles: short hops forward with a side to side roll, turning now and then.
            guard onGround else { return }
            if t.timer < 0 { t.timer = Float.random(in: 0.6...1.6); t.yaw += Float.random(in: -1.2...1.2) }
            steerHome(3)
            let forward = SIMD3(sin(t.yaw), 0, -cos(t.yaw))
            t.phase += c.dt * 7
            let hop = max(0, sin(t.phase)) * 0.25
            t.velocity.x = forward.x * hop; t.velocity.z = forward.z * hop
            if t.position.y < boxCentre.y + boxSize.y && simd_length(fromHome) < boxSize.x / 2 + 0.05 && t.velocity.y == 0 { t.velocity.y = 2.4 }
        case .rocket:
            // Counts down, lifts off on a flame, arcs over, and parachutes back down to land.
            switch t.mode {
            case 0:
                if t.timer < 0 && onGround { t.mode = 1; t.timer = 2.2; t.velocity = SIMD3(Float.random(in: -0.2...0.2), 1.5, Float.random(in: -0.2...0.2)) }
            case 1:
                t.velocity.y += 2.5 * c.dt
                t.velocity.x += (home.x - t.position.x) * 0.1 * c.dt
                t.velocity.z += (home.z - t.position.z) * 0.1 * c.dt
                particles.burst(at: t.position - SIMD3(0, t.size * 0.9, 0), count: 3, speed: 0.6, color: SIMD4(1, 0.6, 0.2, 1), life: 0.4, size: 0.025, gravity: -1)
                if t.timer < 0 || t.position.y > floor + 2.6 { t.mode = 2; t.velocity *= 0.3 }
            default:
                // Parachute: fall slowly, drift home.
                t.velocity.y = max(t.velocity.y, -0.45)
                t.velocity.x += (home.x - t.position.x) * 0.3 * c.dt
                t.velocity.z += (home.z - t.position.z) * 0.3 * c.dt
                if onGround { t.mode = 0; t.timer = Float.random(in: 2...5); t.velocity = .zero }
            }
        case .robot:
            // Marches in straight lines, turns a right angle at the end of each.
            guard onGround else { return }
            if t.timer < 0 { t.timer = Float.random(in: 1.5...3); t.yaw += (Bool.random() ? 1 : -1) * .pi / 2 }
            steerHome(2)
            let forward = SIMD3(sin(t.yaw), 0, -cos(t.yaw))
            t.phase += c.dt * 5
            t.velocity.x = forward.x * 0.3; t.velocity.z = forward.z * 0.3
            if t.position.y < boxCentre.y + boxSize.y && simd_length(fromHome) < boxSize.x / 2 + 0.05 && t.velocity.y == 0 { t.velocity.y = 2.4 }
        case .plane:
            // Takes off, then circles the room at head height, banking into the turn; lands when tired.
            switch t.mode {
            case 0:
                if t.timer < 0 && onGround { t.mode = 1; t.timer = Float.random(in: 12...20); t.velocity = SIMD3(sin(t.yaw), 0.8, -cos(t.yaw)) * 1.2 }
            case 1:
                let height = floor + 1.5 + sin(t.phase * 0.3) * 0.3
                t.phase += c.dt
                t.yaw += 0.9 * c.dt
                let forward = SIMD3(sin(t.yaw), 0, -cos(t.yaw))
                var v = forward * 1.4
                v.y = (height - t.position.y) * 1.5
                // Stay within 2.5 m of home.
                if simd_length(fromHome) > 2.2 { v -= fromHome / simd_length(fromHome) * 0.6 }
                t.velocity = v
                if t.timer < 0 { t.mode = 2 }
            default:
                t.velocity.y -= 3 * c.dt
                t.velocity.x *= 0.98; t.velocity.z *= 0.98
                t.position += t.velocity * c.dt * 0   // gravity branch moves it
                if onGround { t.mode = 0; t.timer = Float.random(in: 3...8); t.velocity = .zero }
            }
        case .ball:
            // Bounces about: a kick now and then.
            if t.timer < 0 && onGround { t.timer = Float.random(in: 1...3); t.velocity += SIMD3(Float.random(in: -0.8...0.8), 2.5, Float.random(in: -0.8...0.8)); steerHome(0) }
            if simd_length(fromHome) > 2.5 && onGround { t.velocity -= fromHome * 0.3 }
            t.spin += c.dt * simd_length(SIMD3(t.velocity.x, 0, t.velocity.z)) / max(t.size / 2, 0.01)
        case .top:
            // Spins, precessing in slow circles.
            t.spin = 25
            guard onGround else { return }
            t.phase += c.dt * 1.2
            t.velocity.x = cos(t.phase) * 0.15; t.velocity.z = sin(t.phase) * 0.15
            if t.position.y < boxCentre.y + boxSize.y && simd_length(fromHome) < boxSize.x / 2 + 0.05 && t.velocity.y == 0 { t.velocity.y = 2.4 }
        }
    }

    func draw(into scene: inout Scene3D, context c: GameContext) {
        let m = c.meshes
        let eye = c.headPosition
        // The box: four painted walls and a floor, rounded, with a lighter rim.
        let rot = G.yaw(boxYaw)
        let wood = SIMD4<Float>(0.85, 0.6, 0.35, 1)
        let b = boxCentre, s = boxSize
        scene.add(m.box, at: b + SIMD3(0, 0.015, 0), rotation: rot, scale: SIMD3(s.x, 0.03, s.z), color: wood, roughness: 0.6, pattern: 2, shadow: false)
        for (dx, dz, sx, sz) in [(Float(0), s.z / 2, s.x, Float(0.03)), (0, -s.z / 2, s.x, 0.03), (s.x / 2, 0, 0.03, s.z), (-s.x / 2, 0, 0.03, s.z)] {
            let offset = rot.act(SIMD3(dx, s.y / 2, dz))
            scene.add(m.box, at: b + offset, rotation: rot, scale: SIMD3(sx, s.y, sz), color: SIMD4(0.3, 0.6, 0.95, 1), roughness: 0.45, pattern: 3, shadow: false)
            scene.add(m.box, at: b + offset + SIMD3(0, s.y / 2, 0), rotation: rot, scale: SIMD3(sx + 0.02, 0.03, sz + 0.02), color: SIMD4(1, 0.85, 0.3, 1), roughness: 0.4, shadow: false)
        }
        scene.shadows.append((SIMD3(b.x, c.floorHeight + 0.004, b.z), 0.45, 0.5))
        // The wake-up button: a big red dome on a chrome base on the box's front rim, with a glow
        // so it reads from standing height (owner, 2026-11-08: it could not be found or pressed).
        let press = buttonPress * 0.02
        scene.add(m.cylinder, at: buttonPosition + SIMD3(0, -0.02, 0), scale: SIMD3(0.11, 0.025, 0.11), color: SIMD4(0.8, 0.82, 0.88, 1), roughness: 0.2, metallic: 0.9, shadow: false)
        scene.add(m.sphere, at: buttonPosition - SIMD3(0, 0.01 + press, 0), scale: SIMD3(0.085, 0.06, 0.085), color: awake ? SIMD4(1, 0.25, 0.2, 1) : SIMD4(0.85, 0.1, 0.1, 1), roughness: 0.15, emissive: awake ? 0.5 + 0.2 * sin(Float(c.time) * 6) : 0.05, shadow: false)
        scene.glow(buttonPosition + SIMD3(0, 0.04, 0), size: 0.3, eye: c.headPosition, color: awake ? SIMD4(1, 0.8, 0.3, 0.35) : SIMD4(1, 0.25, 0.2, 0.3))
        if awake { scene.glow(buttonPosition, size: 0.2, eye: eye, color: SIMD4(1, 0.3, 0.2, 0.3)) }
        for toy in toys { draw(toy, into: &scene, m, time: Float(c.time)) }
        particles.draw(into: &scene, eye: eye)
    }

    private func draw(_ t: Toy, into scene: inout Scene3D, _ m: MeshLibrary, time: Float) {
        let p = t.position, s = t.size
        let rot = G.yaw(t.yaw)
        let dark = SIMD4<Float>(0.12, 0.12, 0.15, 1)
        let cream = SIMD4<Float>(0.98, 0.95, 0.85, 1)
        switch t.kind {
        case .car:
            let body = rot.act(SIMD3(0, 0, 0))
            scene.add(m.box, at: p + body, rotation: rot, scale: SIMD3(s * 0.9, s * 0.4, s * 1.6), color: t.color, roughness: 0.25, metallic: 0.2)
            scene.add(m.box, at: p + rot.act(SIMD3(0, s * 0.35, -s * 0.05)), rotation: rot, scale: SIMD3(s * 0.75, s * 0.35, s * 0.8), color: SIMD4(0.7, 0.85, 1, 1), roughness: 0.1, metallic: 0.3, shadow: false)
            for (x, z) in [(-1, 1), (1, 1), (-1, -1), (1, -1)] as [(Float, Float)] {
                let wheel = p + rot.act(SIMD3(x * s * 0.48, -s * 0.2, z * s * 0.5))
                scene.add(m.cylinder, at: wheel, rotation: rot * G.roll(.pi / 2), scale: SIMD3(s * 0.2, s * 0.12, s * 0.2), color: dark, roughness: 0.9, shadow: false)
                scene.add(m.cylinder, at: wheel, rotation: rot * G.roll(.pi / 2), scale: SIMD3(s * 0.1, s * 0.13, s * 0.1), color: SIMD4(0.85, 0.85, 0.9, 1), roughness: 0.2, metallic: 0.8, shadow: false)
            }
            for x: Float in [-1, 1] {
                scene.add(m.smallSphere, at: p + rot.act(SIMD3(x * s * 0.3, s * 0.02, -s * 0.8)), scale: SIMD3(repeating: s * 0.08), color: SIMD4(1, 1, 0.8, 1), emissive: awake ? 1 : 0.1, shadow: false)
            }
        case .duck:
            let waddle = awake ? sin(t.phase) * 0.15 : 0
            let r = rot * G.roll(waddle)
            scene.add(m.sphere, at: p, rotation: r, scale: SIMD3(s * 0.5, s * 0.42, s * 0.6), color: SIMD4(1, 0.85, 0.2, 1), roughness: 0.4)
            let head = p + r.act(SIMD3(0, s * 0.45, -s * 0.35))
            scene.add(m.sphere, at: head, rotation: r, scale: SIMD3(repeating: s * 0.3), color: SIMD4(1, 0.85, 0.2, 1), roughness: 0.4, shadow: false)
            scene.add(m.cone, at: head + r.act(SIMD3(0, -s * 0.05, -s * 0.28)), rotation: r * G.pitch(-.pi / 2), scale: SIMD3(s * 0.12, s * 0.22, s * 0.12), color: SIMD4(1, 0.5, 0.15, 1), roughness: 0.3, shadow: false)
            for x: Float in [-1, 1] {
                scene.add(m.smallSphere, at: head + r.act(SIMD3(x * s * 0.14, s * 0.08, -s * 0.2)), scale: SIMD3(repeating: s * 0.05), color: dark, roughness: 0.1, shadow: false)
            }
            scene.add(m.sphere, at: p + r.act(SIMD3(0, s * 0.1, s * 0.55)), rotation: r * G.pitch(0.6), scale: SIMD3(s * 0.15, s * 0.1, s * 0.3), color: SIMD4(1, 0.8, 0.15, 1), roughness: 0.4, shadow: false)
        case .rocket:
            let flying = awake && t.mode == 1
            let r = flying ? G.along(simd_length(t.velocity) > 0.1 ? t.velocity : SIMD3(0, 1, 0)) : (awake && t.mode == 2 ? G.pitch(sin(time * 2) * 0.2) : rot)
            scene.add(m.cylinder, at: p, rotation: r, scale: SIMD3(s * 0.28, s * 1.0, s * 0.28), color: cream, roughness: 0.3, pattern: 2)
            scene.add(m.cone, at: p + r.act(SIMD3(0, s * 0.5, 0)), rotation: r, scale: SIMD3(s * 0.28, s * 0.45, s * 0.28), color: t.color, roughness: 0.3, shadow: false)
            for i in 0..<3 {
                let a = Float(i) / 3 * 2 * .pi
                let fin = r.act(SIMD3(cos(a) * s * 0.3, -s * 0.4, sin(a) * s * 0.3))
                scene.add(m.box, at: p + fin, rotation: r * G.yaw(-a), scale: SIMD3(s * 0.25, s * 0.3, s * 0.05), color: t.color, roughness: 0.3, shadow: false)
            }
            scene.add(m.smallSphere, at: p + r.act(SIMD3(0, s * 0.1, -s * 0.26)), scale: SIMD3(repeating: s * 0.1), color: SIMD4(0.6, 0.85, 1, 1), roughness: 0.1, shadow: false)
            if awake && t.mode == 2 {
                // The parachute: a half-dome above on strings.
                let canopy = p + SIMD3(0, s * 1.6, 0)
                scene.add(m.sphere, at: canopy, scale: SIMD3(s * 0.9, s * 0.5, s * 0.9), color: SIMD4(1, 0.95, 0.9, 1), roughness: 0.8, pattern: 2, shadow: false)
                for i in 0..<4 {
                    let a = Float(i) / 4 * 2 * .pi + .pi / 4
                    scene.rod(m, p + r.act(SIMD3(0, s * 0.5, 0)), canopy + SIMD3(cos(a) * s * 0.8, 0, sin(a) * s * 0.8), radius: 0.002, color: SIMD4(0.9, 0.9, 0.9, 1))
                }
            }
        case .robot:
            let step = awake ? sin(t.phase) : 0
            scene.add(m.box, at: p, rotation: rot, scale: SIMD3(s * 0.6, s * 0.7, s * 0.4), color: t.color, roughness: 0.35, metallic: 0.5)
            scene.add(m.box, at: p + SIMD3(0, s * 0.6, 0), rotation: rot, scale: SIMD3(s * 0.45, s * 0.4, s * 0.4), color: SIMD4(0.8, 0.82, 0.88, 1), roughness: 0.3, metallic: 0.7, shadow: false)
            for x: Float in [-1, 1] {
                scene.add(m.smallSphere, at: p + rot.act(SIMD3(x * s * 0.12, s * 0.62, -s * 0.2)), scale: SIMD3(repeating: s * 0.07), color: SIMD4(0.3, 1, 1, 1), emissive: awake ? 1.2 : 0.2, shadow: false)
                let shoulder = p + rot.act(SIMD3(x * s * 0.38, s * 0.3, 0))
                let hand = shoulder + rot.act(SIMD3(0, -s * 0.55, x * step * s * 0.35))
                scene.capsule(m, shoulder, hand, radius: s * 0.08, color: SIMD4(0.8, 0.82, 0.88, 1), roughness: 0.3, metallic: 0.7)
                let hip = p + rot.act(SIMD3(x * s * 0.16, -s * 0.35, 0))
                let foot = hip + rot.act(SIMD3(0, -s * 0.25, -x * step * s * 0.25))
                scene.capsule(m, hip, foot, radius: s * 0.09, color: dark, roughness: 0.6)
            }
            scene.rod(m, p + SIMD3(0, s * 0.8, 0), p + SIMD3(0, s * 1.05, 0), radius: s * 0.02, color: SIMD4(0.8, 0.82, 0.88, 1), metallic: 0.7)
            scene.add(m.smallSphere, at: p + SIMD3(0, s * 1.08, 0), scale: SIMD3(repeating: s * 0.06), color: SIMD4(1, 0.3, 0.3, 1), emissive: awake ? 0.6 + 0.6 * sin(time * 8) : 0.1, shadow: false)
        case .plane:
            let flying = awake && t.mode == 1
            let bank: Float = flying ? -0.45 : 0
            let forward = flying && simd_length(t.velocity) > 0.1 ? t.velocity : SIMD3(sin(t.yaw), 0, -cos(t.yaw))
            let r = G.look(forward) * G.roll(bank)
            scene.add(m.capsule, at: p, rotation: r * G.pitch(.pi / 2), scale: SIMD3(s * 0.16, s * 0.9, s * 0.16), color: t.color, roughness: 0.3)
            scene.add(m.box, at: p + r.act(SIMD3(0, 0, -s * 0.05)), rotation: r, scale: SIMD3(s * 1.5, s * 0.04, s * 0.35), color: cream, roughness: 0.4, pattern: 2, shadow: false)
            scene.add(m.box, at: p + r.act(SIMD3(0, s * 0.15, s * 0.6)), rotation: r, scale: SIMD3(s * 0.05, s * 0.3, s * 0.25), color: t.color, roughness: 0.4, shadow: false)
            scene.add(m.box, at: p + r.act(SIMD3(0, s * 0.02, s * 0.6)), rotation: r, scale: SIMD3(s * 0.6, s * 0.04, s * 0.2), color: cream, roughness: 0.4, shadow: false)
            let prop = p + r.act(SIMD3(0, 0, -s * 0.7))
            scene.add(m.box, at: prop, rotation: r * G.roll(flying ? time * 40 : 0.3), scale: SIMD3(s * 0.45, s * 0.05, s * 0.02), color: dark, roughness: 0.5, shadow: false)
            scene.add(m.smallSphere, at: p + r.act(SIMD3(0, s * 0.12, -s * 0.1)), scale: SIMD3(s * 0.12, s * 0.1, s * 0.2), color: SIMD4(0.7, 0.85, 1, 1), roughness: 0.1, metallic: 0.3, shadow: false)
        case .ball:
            let r = simd_quatf(angle: t.spin, axis: simd_normalize(simd_cross(SIMD3(0, 1, 0), simd_length(SIMD3(t.velocity.x, 0, t.velocity.z)) > 0.01 ? t.velocity : SIMD3(1, 0, 0))))
            scene.add(m.sphere, at: p, rotation: r, scale: SIMD3(repeating: s / 2), color: t.color, roughness: 0.35, pattern: 3)
        case .top:
            let lean = awake ? 0.12 : 0.0
            let r = G.yaw(t.phase) * G.pitch(Float(lean)) * G.yaw(t.spin * time)
            scene.add(m.cone, at: p - SIMD3(0, s * 0.5, 0), rotation: r, scale: SIMD3(s * 0.5, s * 0.5, s * 0.5), color: t.color, roughness: 0.25, metallic: 0.3, pattern: 2)
            scene.add(m.sphere, at: p + SIMD3(0, s * 0.05, 0), rotation: r, scale: SIMD3(s * 0.5, s * 0.25, s * 0.5), color: t.color * SIMD4(0.8, 0.8, 0.8, 1) + SIMD4(0.1, 0.1, 0.1, 0), roughness: 0.25, metallic: 0.3, shadow: false)
            scene.rod(m, p + SIMD3(0, s * 0.2, 0), p + SIMD3(0, s * 0.55, 0), radius: s * 0.06, color: SIMD4(0.9, 0.9, 0.95, 1), metallic: 0.8)
        }
    }
}

// MARK: - Mini golf

/// An eighteen-hole mini golf course, one hole at a time on the floor ahead: a felt fairway in
/// its own shape (one surface, triangulated), wooden bumper walls round it, a cup with a flag,
/// ramps, windmills, tunnels and islands; par per hole and a card. A putter hangs from each
/// hand (the shaft from the hand to a head on the felt); only the head moving through the ball
/// putts it, with the head's speed. The ball rolls, slows, bounces off the walls and drops in
/// the cup; when it comes to rest out of reach the course shifts so it lies a step ahead (a
/// teleport along the course), and the next hole lays out when it drops.
@MainActor
final class GolfGame: Game {
    let title = "⛳ Mini golf"
    struct Wall { var a: SIMD2<Float>; var b: SIMD2<Float> }
    struct Block { var centre: SIMD2<Float>; var size: SIMD2<Float>; var height: Float; var spins: Bool }
    struct Hole {
        var name: String
        var par: Int
        var fairway: [SIMD2<Float>]
        var tee: SIMD2<Float>
        var cup: SIMD2<Float>
        var blocks: [Block] = []
        var ramp: (from: Float, to: Float, rise: Float)? = nil
    }
    private var holeIndex = 0
    private var strokes = 0
    private var card: [Int] = []
    private var ball = SIMD2<Float>.zero
    private var velocity = SIMD2<Float>.zero
    private var holed = false
    private var sink: Float = 0
    private var placed = false
    private var origin = SIMD3<Float>.zero
    private var right = SIMD3<Float>(1, 0, 0), ahead = SIMD3<Float>(0, 0, -1)
    private var lastHit: Double = 0
    private var roll = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    private var windmill: Float = 0
    private var restSince: Double = 0
    private var clubHeads: [Bool: (SIMD3<Float>, Double)] = [:]
    private var particles = ParticleSystem()
    var status: String {
        if holeIndex >= Self.holes.count { return "Round over: \(card.reduce(0, +)) (par \(Self.holes.reduce(0) { $0 + $1.par }))" }
        let h = Self.holes[holeIndex]
        return "Hole \(holeIndex + 1) of 18 · \(h.name) · par \(h.par) · \(strokes) strokes" + (card.isEmpty ? "" : " · total \(card.reduce(0, +))")
    }

    func reset() { holeIndex = 0; strokes = 0; card.removeAll(); placed = false; holed = false; sink = 0; velocity = .zero }

    var summary: GameSummary? {
        guard holeIndex >= Self.holes.count else { return nil }
        let total = card.reduce(0, +), par = Self.holes.reduce(0) { $0 + $1.par }
        let best = card.enumerated().min { $0.element - Self.holes[$0.offset].par < $1.element - Self.holes[$1.offset].par }
        let aces = card.filter { $0 == 1 }.count
        return GameSummary(title: "Round complete", lines: [
            ("Strokes", "\(total)"),
            ("Against par", total == par ? "Even" : (total < par ? "\(par - total) under" : "\(total - par) over")),
            ("Holes in one", "\(aces)"),
            ("Best hole", best.map { "\($0.offset + 1), \(Self.holes[$0.offset].name)" } ?? "None"),
        ], again: "New round")
    }
    private var stepRequested = false
    /// The controls window's step to the ball.
    func stepToBallNow() { stepRequested = true }
    /// The games panel's Next hole.
    func nextHole() { if holeIndex < Self.holes.count { card.append(strokes); holeIndex += 1; placed = false } }

    private static func rect(_ w: Float, _ l: Float) -> [SIMD2<Float>] { [SIMD2(-w / 2, 0), SIMD2(w / 2, 0), SIMD2(w / 2, l), SIMD2(-w / 2, l)] }
    static let holes: [Hole] = {
        var h: [Hole] = []
        h.append(Hole(name: "The Straight", par: 2, fairway: rect(1.0, 3.2), tee: SIMD2(0, 0.4), cup: SIMD2(0, 2.8)))
        h.append(Hole(name: "Dogleg Right", par: 3, fairway: [SIMD2(-0.5, 0), SIMD2(0.5, 0), SIMD2(0.5, 1.6), SIMD2(2.0, 1.6), SIMD2(2.0, 2.6), SIMD2(-0.5, 2.6)], tee: SIMD2(0, 0.4), cup: SIMD2(1.6, 2.1)))
        h.append(Hole(name: "The Island", par: 3, fairway: rect(1.4, 3.4), tee: SIMD2(0, 0.4), cup: SIMD2(0, 3.0), blocks: [Block(centre: SIMD2(0, 1.7), size: SIMD2(0.5, 0.5), height: 0.12, spins: false)]))
        h.append(Hole(name: "The Ramp", par: 3, fairway: rect(1.0, 3.6), tee: SIMD2(0, 0.4), cup: SIMD2(0, 3.2), ramp: (from: 1.4, to: 2.2, rise: 0.18)))
        h.append(Hole(name: "Windmill", par: 3, fairway: rect(1.1, 3.6), tee: SIMD2(0, 0.4), cup: SIMD2(0, 3.2), blocks: [Block(centre: SIMD2(0, 1.9), size: SIMD2(0.9, 0.25), height: 0.3, spins: true)]))
        h.append(Hole(name: "Dogleg Left", par: 3, fairway: [SIMD2(-0.5, 0), SIMD2(0.5, 0), SIMD2(0.5, 2.6), SIMD2(-2.0, 2.6), SIMD2(-2.0, 1.6), SIMD2(-0.5, 1.6)], tee: SIMD2(0, 0.4), cup: SIMD2(-1.6, 2.1)))
        h.append(Hole(name: "The Gates", par: 3, fairway: rect(1.4, 3.4), tee: SIMD2(0, 0.4), cup: SIMD2(0, 3.0), blocks: [Block(centre: SIMD2(-0.45, 1.5), size: SIMD2(0.4, 0.15), height: 0.1, spins: false), Block(centre: SIMD2(0.45, 1.5), size: SIMD2(0.4, 0.15), height: 0.1, spins: false)]))
        h.append(Hole(name: "The Zigzag", par: 4, fairway: [SIMD2(-0.5, 0), SIMD2(0.5, 0), SIMD2(0.5, 1.2), SIMD2(1.6, 1.2), SIMD2(1.6, 2.2), SIMD2(0.2, 2.2), SIMD2(0.2, 3.2), SIMD2(-0.5, 3.2)], tee: SIMD2(0, 0.4), cup: SIMD2(-0.15, 2.9)))
        h.append(Hole(name: "The Tunnel", par: 3, fairway: rect(1.0, 3.6), tee: SIMD2(0, 0.4), cup: SIMD2(0, 3.2), blocks: [Block(centre: SIMD2(0, 1.8), size: SIMD2(1.0, 0.6), height: 0.5, spins: false)]))
        h.append(Hole(name: "Wide Open", par: 2, fairway: rect(2.2, 2.6), tee: SIMD2(-0.7, 0.4), cup: SIMD2(0.7, 2.2)))
        h.append(Hole(name: "Two Islands", par: 4, fairway: rect(1.6, 3.8), tee: SIMD2(0, 0.4), cup: SIMD2(0, 3.4), blocks: [Block(centre: SIMD2(-0.35, 1.4), size: SIMD2(0.4, 0.4), height: 0.12, spins: false), Block(centre: SIMD2(0.35, 2.3), size: SIMD2(0.4, 0.4), height: 0.12, spins: false)]))
        h.append(Hole(name: "The Hook", par: 3, fairway: [SIMD2(-0.5, 0), SIMD2(0.5, 0), SIMD2(0.5, 2.0), SIMD2(1.8, 2.0), SIMD2(1.8, 3.0), SIMD2(-0.5, 3.0)], tee: SIMD2(0, 0.4), cup: SIMD2(1.4, 2.5)))
        h.append(Hole(name: "The Hill", par: 3, fairway: rect(1.2, 3.8), tee: SIMD2(0, 0.4), cup: SIMD2(0, 3.4), ramp: (from: 1.2, to: 2.6, rise: 0.25)))
        h.append(Hole(name: "Double Windmill", par: 4, fairway: rect(1.2, 4.2), tee: SIMD2(0, 0.4), cup: SIMD2(0, 3.8), blocks: [Block(centre: SIMD2(0, 1.5), size: SIMD2(1.0, 0.25), height: 0.3, spins: true), Block(centre: SIMD2(0, 2.8), size: SIMD2(1.0, 0.25), height: 0.3, spins: true)]))
        h.append(Hole(name: "The Corner", par: 3, fairway: [SIMD2(-0.5, 0), SIMD2(0.5, 0), SIMD2(0.5, 2.6), SIMD2(-1.6, 2.6), SIMD2(-1.6, 1.8), SIMD2(-0.5, 1.8)], tee: SIMD2(0, 0.4), cup: SIMD2(-1.2, 2.2), blocks: [Block(centre: SIMD2(0, 1.3), size: SIMD2(0.3, 0.3), height: 0.12, spins: false)]))
        h.append(Hole(name: "The Long One", par: 4, fairway: rect(1.0, 5.0), tee: SIMD2(0, 0.4), cup: SIMD2(0, 4.6)))
        h.append(Hole(name: "The Maze", par: 5, fairway: rect(2.0, 3.6), tee: SIMD2(-0.7, 0.4), cup: SIMD2(0.7, 3.2), blocks: [Block(centre: SIMD2(0.3, 1.0), size: SIMD2(1.2, 0.12), height: 0.12, spins: false), Block(centre: SIMD2(-0.3, 1.9), size: SIMD2(1.2, 0.12), height: 0.12, spins: false), Block(centre: SIMD2(0.3, 2.7), size: SIMD2(1.2, 0.12), height: 0.12, spins: false)]))
        h.append(Hole(name: "The Finale", par: 4, fairway: rect(1.6, 4.4), tee: SIMD2(0, 0.4), cup: SIMD2(0, 4.0), blocks: [Block(centre: SIMD2(0, 2.0), size: SIMD2(1.1, 0.25), height: 0.3, spins: true)], ramp: (from: 2.6, to: 3.4, rise: 0.2)))
        // Real mini golf is wider and longer than the first draft: everything 1.6 times.
        let k: Float = 1.6
        return h.map { hole in
            var scaled = hole
            scaled.fairway = hole.fairway.map { $0 * k }
            scaled.tee = hole.tee * k
            scaled.cup = hole.cup * k
            scaled.blocks = hole.blocks.map { Block(centre: $0.centre * k, size: $0.size * k, height: $0.height, spins: $0.spins) }
            if let r = hole.ramp { scaled.ramp = (from: r.from * k, to: r.to * k, rise: r.rise) }
            return scaled
        }
    }()

    /// Where each hole sits on the course: three abreast, six deep, a serpentine so the next hole
    /// is always near, with lamps and a scoreboard between them.
    static let offsets: [SIMD2<Float>] = (0..<18).map { i in
        let row = i / 3
        let col = row % 2 == 0 ? i % 3 : 2 - i % 3
        return SIMD2(Float(col - 1) * 4.8, Float(row) * 9.6)
    }

    private var hole: Hole { Self.holes[min(holeIndex, Self.holes.count - 1)] }

    private func walls(for hole: Hole) -> [Wall] {
        var w: [Wall] = []
        for i in hole.fairway.indices { w.append(Wall(a: hole.fairway[i], b: hole.fairway[(i + 1) % hole.fairway.count])) }
        for b in hole.blocks where b.height < 0.4 {
            let h = b.size / 2
            let c = [b.centre + SIMD2(-h.x, -h.y), b.centre + SIMD2(h.x, -h.y), b.centre + SIMD2(h.x, h.y), b.centre + SIMD2(-h.x, h.y)]
            for i in 0..<4 { w.append(Wall(a: c[i], b: c[(i + 1) % 4])) }
        }
        return w
    }

    private func height(at p: SIMD2<Float>, hole: Hole) -> Float {
        guard let ramp = hole.ramp else { return 0 }
        if p.y <= ramp.from { return 0 }
        if p.y >= ramp.to { return ramp.rise }
        return ramp.rise * (p.y - ramp.from) / (ramp.to - ramp.from)
    }

    /// The course stands on a deck 5 cm above the floor: at floor level the room's own depth
    /// (passthrough occlusion) swallowed the felt and left only the walls (owner, 2026-11-07).
    static let deck: Float = 0.05
    private func world(_ p: SIMD2<Float>, hole i: Int? = nil, up: Float = 0) -> SIMD3<Float> {
        let off = Self.offsets[min(i ?? holeIndex, Self.offsets.count - 1)]
        return origin + right * (p.x + off.x) + ahead * (p.y + off.y) + SIMD3(0, up + Self.deck, 0)
    }
    private func course(_ w: SIMD3<Float>) -> SIMD2<Float> {
        let d = w - origin
        let off = Self.offsets[min(holeIndex, Self.offsets.count - 1)]
        return SIMD2(simd_dot(d, right) - off.x, simd_dot(d, ahead) - off.y)
    }

    /// The fairway as one surface: the polygon ear-clipped into triangles, in the course's frame
    /// (x right, -z up the fairway), with the felt's checks running along it.
    static func feltMesh(_ polygon: [SIMD2<Float>]) -> ([MeshVertex], [UInt32]) {
        var pts = polygon
        // Counter-clockwise, so an ear is a left turn.
        var area: Float = 0
        for i in pts.indices { let a = pts[i], b = pts[(i + 1) % pts.count]; area += a.x * b.y - b.x * a.y }
        if area < 0 { pts.reverse() }
        var indices = Array(pts.indices)
        var tris: [UInt32] = []
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        func inside(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
            cross(a, b, p) >= -1e-6 && cross(b, c, p) >= -1e-6 && cross(c, a, p) >= -1e-6
        }
        var guardCount = 0
        while indices.count > 3 && guardCount < 1000 {
            guardCount += 1
            var clipped = false
            for i in indices.indices {
                let i0 = indices[(i + indices.count - 1) % indices.count], i1 = indices[i], i2 = indices[(i + 1) % indices.count]
                let a = pts[i0], b = pts[i1], c = pts[i2]
                if cross(a, b, c) <= 1e-6 { continue }   // a reflex corner is no ear
                var clear = true
                for j in indices where j != i0 && j != i1 && j != i2 && inside(pts[j], a, b, c) { clear = false; break }
                if !clear { continue }
                tris += [UInt32(i0), UInt32(i1), UInt32(i2)]
                indices.remove(at: i)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if indices.count == 3 { tris += indices.map { UInt32($0) } }
        let vertices = pts.map { MeshVertex(position: SIMD3($0.x, 0, -$0.y), normal: SIMD3(0, 1, 0), uv: SIMD2($0.x * 2, $0.y * 2)) }
        return (vertices, tris)
    }

    private func layHole(_ c: GameContext) {
        let f = G.flat(c.forward)
        ahead = f
        right = simd_normalize(simd_cross(f, SIMD3(0, 1, 0)))
        // The tee a step ahead of the player; the rest of the course lies out round it.
        let off = Self.offsets[min(holeIndex, Self.offsets.count - 1)]
        origin = SIMD3(c.headPosition.x, c.floorHeight, c.headPosition.z) + f * 0.8 - right * (hole.tee.x + off.x) - ahead * (hole.tee.y + off.y)
        ball = hole.tee
        velocity = .zero
        holed = false
        sink = 0
        strokes = 0
        placed = true
        restSince = c.time
        log("[Games] Mini golf: hole \(holeIndex + 1) \(hole.name), par \(hole.par)")
    }

    /// Shifts the course so the ball lies a step ahead of the player: the teleport between putts.
    private func stepToBall(_ c: GameContext) {
        let f = G.flat(c.forward)
        let ballWorld = world(ball)
        let wanted = SIMD3(c.headPosition.x, c.floorHeight, c.headPosition.z) + f * 0.7
        let shift = SIMD3(wanted.x - ballWorld.x, 0, wanted.z - ballWorld.z)
        origin += shift
        particles.burst(at: wanted + SIMD3(0, 0.05, 0), count: 24, speed: 0.8, color: SIMD4(0.5, 0.9, 1, 0.8), life: 0.6, size: 0.02, gravity: -0.5)
        log("[Games] Mini golf: stepped to the ball")
    }

    /// The putter from a hand: the grip at the hand, the shaft down to a head on the felt a
    /// little ahead of the hand, facing the way the hand points.
    private func club(for hand: TrackedHandState, floor: Float, eye: SIMD3<Float>) -> (grip: SIMD3<Float>, head: SIMD3<Float>, facing: SIMD3<Float>) {
        let grip = hand.joints[HandGeometry.wrist]
        let lean = G.flat(grip - eye)
        let head = SIMD3(grip.x, floor + Self.deck + 0.035, grip.z) + lean * 0.22
        return (grip, head, lean)
    }

    func update(_ c: GameContext) {
        particles.update(dt: c.dt)
        windmill += c.dt * 1.2
        guard holeIndex < Self.holes.count else { return }
        if !placed { layHole(c) }
        if holed {
            sink = min(1, sink + c.dt * 2)
            if sink >= 1 {
                card.append(strokes)
                holeIndex += 1
                placed = false
                if holeIndex >= Self.holes.count { log("[Games] Mini golf: round over, \(card.reduce(0, +))") }
            }
            return
        }
        let ballUp = height(at: ball, hole: hole) + 0.021
        let ballWorld = world(ball, up: ballUp)
        // A putt: the club's head moving through the ball; its speed is the ball's.
        for hand in c.hands {
            let (_, head, _) = club(for: hand, floor: c.floorHeight, eye: c.headPosition)
            var v = SIMD3<Float>.zero
            if let (last, t) = clubHeads[hand.isRight], c.time > t { v = (head - last) / Float(min(c.time - t, 0.1)) }
            clubHeads[hand.isRight] = (head, c.time)
            let flatV = SIMD2(simd_dot(v, right), simd_dot(v, ahead))
            if simd_distance(SIMD3(head.x, 0, head.z), SIMD3(ballWorld.x, 0, ballWorld.z)) < 0.09 && simd_length(flatV) > 0.25 && c.time - lastHit > 0.4 && simd_length(velocity) < 0.3 {
                lastHit = c.time
                strokes += 1
                let speed = min(simd_length(flatV) * 0.9, 3.5)
                velocity = simd_normalize(flatV) * speed
                particles.burst(at: ballWorld, count: 10, speed: 0.5, color: SIMD4(0.6, 1, 0.5, 1), life: 0.4, size: 0.015)
                log(String(format: "[Games] Mini golf: putt at %.1f m/s", speed))
            }
        }
        if c.select, c.hands.isEmpty, c.time - lastHit > 0.5, simd_length(velocity) < 0.3 {
            lastHit = c.time
            strokes += 1
            let f = G.flat(c.forward)
            velocity = SIMD2(simd_dot(f, right), simd_dot(f, ahead)) * 2.2
        }
        if let ramp = hole.ramp, ball.y > ramp.from, ball.y < ramp.to { velocity.y -= 9.8 * (ramp.rise / (ramp.to - ramp.from)) * 0.6 * c.dt }
        var next = ball + velocity * c.dt
        for wall in walls(for: hole) {
            let ab = wall.b - wall.a
            let t = max(0, min(1, simd_dot(next - wall.a, ab) / max(simd_dot(ab, ab), 1e-6)))
            let closest = wall.a + ab * t
            let d = next - closest
            let dist = simd_length(d)
            if dist < 0.021 && dist > 1e-5 {
                let n = d / dist
                next = closest + n * 0.021
                let into = simd_dot(velocity, n)
                if into < 0 { velocity -= n * into * 1.75 }   // a bumper's bounce: three quarters of the speed back
                particles.burst(at: world(next, up: ballUp), count: 3, speed: 0.3, color: SIMD4(1, 0.9, 0.6, 0.8), life: 0.25, size: 0.01)
            }
        }
        for b in hole.blocks where b.spins {
            let blade = SIMD2(cos(windmill), sin(windmill)) * 0.45
            if abs(next.y - b.centre.y) < 0.12 && abs(next.x - b.centre.x) < 0.2 && abs(blade.x) > 0.25 { velocity = -velocity * 0.6; next = ball }
        }
        ball = next
        let speed = simd_length(velocity)
        if speed > 0 {
            let axis = simd_normalize(simd_cross(SIMD3(0, 1, 0), right * velocity.x + ahead * velocity.y))
            roll = simd_quatf(angle: speed * c.dt / 0.021, axis: axis) * roll
        }
        velocity *= max(0, 1 - 0.8 * c.dt)
        if speed < 0.03 { velocity = .zero } else { restSince = c.time }
        let toCup = simd_distance(ball, hole.cup)
        if toCup < 0.15 && speed < 2 { velocity += simd_normalize(hole.cup - ball) * 1.0 * c.dt }
        if toCup < 0.055 && speed < 1.6 {
            holed = true
            particles.burst(at: world(hole.cup, up: 0.1), count: 60, speed: 2.5, color: SIMD4(1, 0.9, 0.3, 1), life: 1.2, size: 0.03)
            log("[Games] Mini golf: hole \(holeIndex + 1) in \(strokes) (par \(hole.par))")
        }
        // At rest out of reach, or asked for: step to it.
        let flatBall = world(ball)
        if stepRequested { stepRequested = false; stepToBall(c); restSince = c.time + 10 }
        else if speed == 0, c.time - restSince > 0.8, simd_distance(SIMD3(flatBall.x, 0, flatBall.z), SIMD3(c.headPosition.x, 0, c.headPosition.z)) > 1.25 {
            stepToBall(c)
            restSince = c.time + 10
        }
    }

    func draw(into scene: inout Scene3D, context c: GameContext) {
        guard placed else { return }
        let m = c.meshes
        let eye = c.headPosition
        let felt = SIMD4<Float>(0.18, 0.6, 0.25, 1)
        let wood = SIMD4<Float>(0.6, 0.4, 0.22, 1)
        let stone = SIMD4<Float>(0.5, 0.48, 0.45, 1)
        let rot = G.look(ahead)
        let currentIndex = min(holeIndex, Self.holes.count - 1)
        for (i, hole) in Self.holes.enumerated() {
            // Far holes are skipped for the draw count; near ones in full.
            let xs = hole.fairway.map(\.x), ys = hole.fairway.map(\.y)
            let centre = SIMD2((xs.min()! + xs.max()!) / 2, (ys.min()! + ys.max()!) / 2)
            let centreWorld = world(centre, hole: i)
            let far = simd_distance(SIMD3(centreWorld.x, 0, centreWorld.z), SIMD3(eye.x, 0, eye.z))
            if far > 26 { continue }
            let isCurrent = i == currentIndex
            let feltMesh = m.mesh("golf-felt-\(i)") { Self.feltMesh(hole.fairway) }
            scene.add(feltMesh, at: world(SIMD2(0, 0), hole: i, up: 0.006), rotation: rot, scale: SIMD3(1, 1, 1), color: isCurrent ? felt : felt * SIMD4(0.85, 0.85, 0.85, 1), roughness: 0.95, pattern: 3, shadow: false)
            scene.add(m.box, at: world(centre, hole: i, up: -Self.deck / 2 - 0.004), rotation: rot, scale: SIMD3(xs.max()! - xs.min()! + 0.4, Self.deck, ys.max()! - ys.min()! + 0.4), color: SIMD4(0.25, 0.22, 0.2, 1), roughness: 0.9, pattern: 5, shadow: false)
            for wall in walls(for: hole) {
                let mid = (wall.a + wall.b) / 2
                let len = simd_distance(wall.a, wall.b)
                let dir = simd_normalize(wall.b - wall.a)
                let yaw = atan2(dir.x, dir.y)
                scene.add(m.box, at: world(mid, hole: i, up: 0.07 + height(at: mid, hole: hole)), rotation: rot * G.yaw(-yaw), scale: SIMD3(len + 0.1, 0.14, 0.1), color: wood, roughness: 0.6, pattern: 2, shadow: false)
                // A rounded rail along the top of each bumper.
                scene.rod(m, world(wall.a, hole: i, up: 0.15 + height(at: wall.a, hole: hole)), world(wall.b, hole: i, up: 0.15 + height(at: wall.b, hole: hole)), radius: 0.03, color: wood * SIMD4(1.15, 1.15, 1.1, 1), roughness: 0.5)
            }
            if far > 14 { continue }
            for b in hole.blocks {
                let top = world(b.centre, hole: i, up: b.height / 2 + height(at: b.centre, hole: hole))
                if b.spins {
                    scene.add(m.box, at: top + SIMD3(0, 0.3, 0), rotation: rot, scale: SIMD3(b.size.x, b.height + 0.6, b.size.y), color: SIMD4(0.95, 0.9, 0.8, 1), roughness: 0.7, pattern: 3, shadow: false)
                    scene.add(m.cone, at: top + SIMD3(0, 0.6 + b.height / 2, 0), rotation: rot, scale: SIMD3(b.size.x * 0.7, 0.4, b.size.y * 0.7), color: SIMD4(0.8, 0.25, 0.2, 1), roughness: 0.6, shadow: false)
                    let hub = world(b.centre - SIMD2(0, b.size.y / 2 + 0.05), hole: i, up: b.height + 0.45)
                    for k in 0..<4 {
                        let a = windmill + Float(k) * .pi / 2
                        let tip = hub + (SIMD3(0, 1, 0) * cos(a) + right * sin(a)) * 0.6
                        scene.rod(m, hub, tip, radius: 0.025, color: wood, roughness: 0.6)
                        scene.add(m.box, at: (hub + tip) / 2 + (tip - hub) * 0.15, rotation: rot * G.roll(-a), scale: SIMD3(0.14, 0.45, 0.02), color: SIMD4(0.95, 0.95, 0.9, 1), roughness: 0.7, shadow: false)
                    }
                    scene.add(m.box, at: world(b.centre, hole: i, up: 0.06), rotation: rot, scale: SIMD3(0.5, 0.11, b.size.y + 0.02), color: SIMD4(0.05, 0.05, 0.06, 1), roughness: 1, shadow: false)
                } else if b.height >= 0.4 {
                    scene.add(m.box, at: top + SIMD3(0, 0.1, 0), rotation: rot, scale: SIMD3(b.size.x + 0.1, 0.12, b.size.y), color: stone, roughness: 0.8, pattern: 5, shadow: false)
                    for sgn: Float in [-1, 1] {
                        scene.add(m.box, at: world(b.centre + SIMD2(sgn * (b.size.x / 2 + 0.03), 0), hole: i, up: b.height / 2 - 0.05), rotation: rot, scale: SIMD3(0.08, b.height - 0.1, b.size.y), color: stone, roughness: 0.8, pattern: 5, shadow: false)
                    }
                } else {
                    scene.add(m.box, at: top, rotation: rot, scale: SIMD3(b.size.x, b.height, b.size.y), color: wood, roughness: 0.6, pattern: 2, shadow: false)
                    scene.add(m.box, at: top + SIMD3(0, b.height / 2 + 0.01, 0), rotation: rot, scale: SIMD3(b.size.x, 0.02, b.size.y), color: felt, roughness: 0.95, shadow: false)
                }
            }
            if let ramp = hole.ramp {
                let mid = SIMD2<Float>(0, (ramp.from + ramp.to) / 2)
                let len = ramp.to - ramp.from
                let pitch = -atan2(ramp.rise, len)
                let w = xs.max()! - xs.min()!
                scene.add(m.box, at: world(mid, hole: i, up: ramp.rise / 2 + 0.006), rotation: rot * G.pitch(pitch), scale: SIMD3(w, 0.012, sqrt(len * len + ramp.rise * ramp.rise)), color: felt, roughness: 0.95, pattern: 3, shadow: false)
                scene.add(m.box, at: world(SIMD2(0, (ramp.to + ys.max()!) / 2), hole: i, up: ramp.rise / 2), rotation: rot, scale: SIMD3(w, ramp.rise, ys.max()! - ramp.to), color: felt * SIMD4(0.9, 0.9, 0.9, 1), roughness: 0.95, pattern: 3, shadow: false)
            }
            // The tee mat, the cup, the flag with the hole's number in beads; lamps at the far corners.
            scene.add(m.disc, at: world(hole.tee, hole: i, up: 0.014), scale: SIMD3(0.16, 1, 0.16), color: SIMD4(0.1, 0.35, 0.15, 1), roughness: 1, shadow: false)
            let cupUp = height(at: hole.cup, hole: hole)
            scene.add(m.cylinder, at: world(hole.cup, hole: i, up: cupUp - 0.03), scale: SIMD3(0.06, 0.08, 0.06), color: SIMD4(0.04, 0.05, 0.06, 1), roughness: 1, shadow: false)
            scene.add(m.torus, at: world(hole.cup, hole: i, up: cupUp + 0.014), scale: SIMD3(0.06, 0.06, 0.06), color: G.white, roughness: 0.5, shadow: false)
            let pole = world(hole.cup, hole: i, up: cupUp)
            scene.rod(m, pole, pole + SIMD3(0, 1.1, 0), radius: 0.01, color: SIMD4(0.9, 0.9, 0.95, 1), roughness: 0.3, metallic: 0.6)
            // The flag hangs from the pole and waves about it, so its edge stays on the pole.
            let wave = sin(Float(c.time) * 3 + Float(i)) * 0.12
            let flagRot = rot * G.yaw(wave)
            let flagCentre = pole + SIMD3(0, 0.96, 0) + flagRot.act(SIMD3(0.17, 0, 0))
            scene.add(m.box, at: flagCentre, rotation: flagRot, scale: SIMD3(0.32, 0.2, 0.012), color: isCurrent ? SIMD4(1, 0.3, 0.35, 1) : SIMD4(0.95, 0.85, 0.3, 1), roughness: 0.8, shadow: false)
            scene.add(m.smallSphere, at: pole + SIMD3(0, 1.12, 0), scale: SIMD3(repeating: 0.025), color: SIMD4(1, 0.85, 0.3, 1), roughness: 0.3, metallic: 0.8, shadow: false)
            for k in 0..<min(i + 1, 9) {
                scene.add(m.smallSphere, at: pole + SIMD3(0, 1.03 - Float(k / 3) * 0.055, 0) + right * (0.07 + Float(k % 3) * 0.055), scale: SIMD3(repeating: 0.014), color: SIMD4(0.1, 0.1, 0.12, 1), shadow: false)
            }
            for corner in [SIMD2(xs.min()! - 0.35, ys.max()! + 0.35), SIMD2(xs.max()! + 0.35, ys.min()! - 0.35)] {
                let base = world(corner, hole: i)
                scene.rod(m, base, base + SIMD3(0, 1.6, 0), radius: 0.035, color: SIMD4(0.2, 0.2, 0.25, 1), roughness: 0.5, metallic: 0.5)
                scene.add(m.smallSphere, at: base + SIMD3(0, 1.7, 0), scale: SIMD3(repeating: 0.11), color: SIMD4(1, 0.85, 0.5, 1), emissive: 1.2, shadow: false)
                scene.glow(base + SIMD3(0, 1.7, 0), size: 0.6, eye: eye, color: SIMD4(1, 0.75, 0.35, 0.3))
            }
        }
        // The scoreboard by the first tee.
        let board = world(Self.holes[0].tee + SIMD2(-1.6, -0.4), hole: 0)
        scene.rod(m, board, board + SIMD3(0, 1.3, 0), radius: 0.03, color: wood, roughness: 0.7)
        scene.add(m.box, at: board + SIMD3(0, 1.5, 0), rotation: rot, scale: SIMD3(0.9, 0.5, 0.04), color: SIMD4(0.12, 0.3, 0.16, 1), roughness: 0.8, shadow: false)
        for (k, strokesForHole) in card.prefix(18).enumerated() {
            let par = Self.holes[k].par
            let color: SIMD4<Float> = strokesForHole < par ? SIMD4(0.4, 1, 0.5, 1) : strokesForHole == par ? G.white : SIMD4(1, 0.5, 0.4, 1)
            scene.add(m.smallSphere, at: board + SIMD3(0, 1.66 - Float(k / 6) * 0.14, 0) + right * (-0.35 + Float(k % 6) * 0.14), scale: SIMD3(repeating: 0.035), color: color, emissive: 0.4, shadow: false)
        }
        // The ball and the putters on the current hole.
        guard holeIndex < Self.holes.count else { return }
        let hole = self.hole
        if !holed || sink < 1 {
            let p = world(ball, up: height(at: ball, hole: hole) + 0.021 - (holed ? sink * 0.08 : 0))
            scene.add(m.sphere, at: p, rotation: roll, scale: SIMD3(repeating: 0.021), color: G.white, roughness: 0.3, pattern: 1)
        }
        for hand in c.hands {
            let (grip, head, facing) = club(for: hand, floor: c.floorHeight, eye: eye)
            scene.capsule(m, grip + SIMD3(0, 0.06, 0), grip - SIMD3(0, 0.08, 0), radius: 0.016, color: SIMD4(0.1, 0.1, 0.12, 1), roughness: 0.8)
            scene.rod(m, grip - SIMD3(0, 0.08, 0), head + SIMD3(0, 0.03, 0), radius: 0.007, color: SIMD4(0.8, 0.82, 0.88, 1), roughness: 0.25, metallic: 0.9)
            scene.add(m.box, at: head, rotation: G.look(facing), scale: SIMD3(0.11, 0.035, 0.03), color: SIMD4(0.85, 0.7, 0.35, 1), roughness: 0.25, metallic: 0.9)
        }
        particles.draw(into: &scene, eye: eye)
    }
}

// MARK: - Coaster

/// A roller coaster over the grid. The course is laid out from segments (a chain lift, drops,
/// hills, a loop, banked turns) as poses half a metre apart in the world; the rider's car
/// follows them, gaining speed down the drops and losing it up the climbs. The rider is carried:
/// the renderer moves the camera by the car's pose relative to where the ride began, so the
/// whole world (the floor, the sky, the track) tilts, climbs and spins round the rider, while
/// the car is drawn at the seat. The interface stays out of the way while riding; the viewer's
/// double tap, or the controls window's Stop before the ride, ends it.
@MainActor
final class GridRide: Game {
    let title = "🎢 Coaster"
    struct Pose { var position: SIMD3<Float>; var orientation: simd_quatf }

    /// The course: random each ride and one smooth closed curve (owner, 2026-11-08: the old lap
    /// was laid segment by segment and its end dragged up onto the start, so the track "jetted"
    /// up and the car jumped back to the station). The plan is a closed, gently wobbling loop
    /// round a centre; the height is a profile along it, flat at the station, a chain lift, a
    /// big first drop into a flat valley that may carry a vertical loop, then smaller hills and
    /// a run back down to station level; every join has zero slope, so the track is smooth.
    /// The speed comes from the drop (energy, less friction and drag), the lift's chain and the
    /// station's brakes, which bring the car to rest exactly where it started.
    private static let step: Float = 0.5
    private static let seatHeight: Float = 1.1
    private static let g: Float = 9.8
    private static let liftSpeed: Float = 3.5
    private static let brakeLength: Float = 40
    private static let stationLength: Float = 18

    private var poses: [Pose] = []        // in the world; the last leads back into the first
    private var speeds: [Float] = []      // the planned speed at each pose, m/s
    private var loopRange: Range<Int>?    // the poses of the vertical loop, if the course has one
    private var along: Float = 0
    private(set) var speed: Float = 0
    private(set) var distance: Float = 0
    private var particles = ParticleSystem()
    private var built = false
    /// The car's pose relative to the rider's start: the renderer moves the camera by it.
    private(set) var riderTransform = matrix_identity_float4x4
    private var anchorHead = SIMD3<Float>.zero
    private var anchorYaw: simd_quatf = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    private(set) var lapSeconds: Float = 0
    private var lapLength: Float { Float(poses.count) * Self.step }
    /// The ride waits at the station until Ride is pressed, so a world can be picked first.
    private(set) var riding = false
    private var rideTime: Float = 0
    private var topSpeed: Float = 0
    private var topHeight: Float = 0
    private var finished = false
    /// The worlds the ride can run through: the Places app's choices, cycled from the controls.
    var onNextWorld: (() -> Void)?

    var status: String {
        if riding { return String(format: "%.0f m at %.0f km/h · %.0f s of %.0f", along, speed * 3.6, rideTime, lapSeconds) }
        return String(format: "At the station · a %.0f s ride%@ · Ride when ready", lapSeconds, loopRange == nil ? "" : " with a loop")
    }

    var summary: GameSummary? {
        guard finished else { return nil }
        return GameSummary(title: "Ride complete", lines: [
            ("Time", String(format: "%.0f s", rideTime)),
            ("Distance", String(format: "%.0f m", lapLength)),
            ("Top speed", String(format: "%.0f km/h", topSpeed * 3.6)),
            ("Highest point", String(format: "%.0f m", topHeight)),
            ("Loops", loopRange == nil ? "None this time" : "One"),
        ], again: "Ride again")
    }

    func reset() {
        poses.removeAll(); speeds.removeAll(); loopRange = nil; along = 0; speed = 0; distance = 0; built = false
        riderTransform = matrix_identity_float4x4; lapSeconds = 0; riding = false; finished = false
    }

    func go() {
        along = 0; rideTime = 0; topSpeed = 0; topHeight = 0; finished = false; riding = true
        log("[Games] Coaster: riding")
    }

    func again() { go() }

    // MARK: Building

    nonisolated private static func smooth(_ t: Float) -> Float { let x = min(max(t, 0), 1); return x * x * (3 - 2 * x) }

    /// A height profile: knots (metres along the plan, height), joined by smoothsteps, so the
    /// slope is zero at every knot and the track has no kinks.
    private struct Profile {
        var knots: [(s: Float, h: Float)]
        func height(_ s: Float) -> Float {
            guard let first = knots.first else { return 0 }
            if s <= first.s { return first.h }
            for k in 1..<knots.count where s <= knots[k].s {
                let a = knots[k - 1], b = knots[k]
                return a.h + (b.h - a.h) * GridRide.smooth((s - a.s) / max(b.s - a.s, 1e-3))
            }
            return knots.last!.h
        }
    }

    private struct Plan {
        var points: [SIMD3<Float>]     // the plan, flat, densely sampled; closed
        var lengths: [Float]           // cumulative plan length at each point
        var total: Float { lengths.last ?? 0 }
        func at(_ s: Float) -> (SIMD3<Float>, SIMD3<Float>) {
            let wrapped = s - floor(s / total) * total
            var lo = 0, hi = lengths.count - 1
            while hi - lo > 1 { let mid = (lo + hi) / 2; if lengths[mid] <= wrapped { lo = mid } else { hi = mid } }
            let t = (wrapped - lengths[lo]) / max(lengths[hi] - lengths[lo], 1e-4)
            let p = simd_mix(points[lo], points[hi], SIMD3(repeating: t))
            let tangent = simd_normalize(points[hi] - points[lo])
            return (p, tangent)
        }
    }

    /// A closed plan from the start (the origin, heading -z), wobbling round a centre to one side.
    private static func plan(radius r0: Float, turn: Float, wobble: [(k: Float, a: Float)]) -> Plan {
        let n = 6000
        var points: [SIMD3<Float>] = []
        var lengths: [Float] = []
        var total: Float = 0
        for i in 0...n {
            let phi = Float(i) / Float(n) * 2 * .pi
            // r(0) = r0 and r'(0) = 0, so the start is exactly at the origin heading -z.
            var r = r0
            for w in wobble { r += r0 * w.a * (1 - cos(w.k * phi)) }
            let p = SIMD3(turn * (r0 - r * cos(phi)), 0, -r * sin(phi))
            if let last = points.last { total += simd_distance(p, last) }
            points.append(p)
            lengths.append(total)
        }
        return Plan(points: points, lengths: lengths)
    }

    struct Course {
        var poses: [Pose]
        var speeds: [Float]
        var loop: Range<Int>?
        var seconds: Float
    }

    static func makeCourse(radius r0: Float, liftHeight lift: Float, turn: Float, wobble: [(k: Float, a: Float)], hills: [Float], wantLoop: Bool) -> Course {
        let plan = plan(radius: r0, turn: turn, wobble: wobble)
        let total = plan.total
        // The height profile, in plan metres.
        var knots: [(s: Float, h: Float)] = [(0, 0), (stationLength, 0)]
        var s = stationLength
        s += lift * 1.8; knots.append((s, lift))                 // the chain lift, about 30 degrees
        s += 6; knots.append((s, lift))                          // the crest
        let valley: Float = 1.0
        s += lift * 1.15; knots.append((s, valley))              // the first drop, about 50 degrees at its steepest
        let loopAt = s + 18
        s += 36; knots.append((s, valley))                       // a flat valley, where a loop may go
        let finalRun: Float = 34
        for hill in hills {
            let run = hill * 1.6 + 8
            guard s + 2 * run + 10 < total - brakeLength - finalRun else { break }
            s += run; knots.append((s, valley + hill))
            s += 4; knots.append((s, valley + hill))
            s += run; knots.append((s, valley))
            s += 10; knots.append((s, valley))
        }
        knots.append((total - brakeLength - 4, valley))
        knots.append((total - brakeLength, 0))
        knots.append((total, 0))
        let profile = Profile(knots: knots)

        // Speed down the first drop decides whether a loop fits: the top needs some g to spare.
        let dropSpeed2 = 2 * g * (lift - valley) * 0.8
        let loopRadius = min(7, dropSpeed2 / (6.5 * g))
        let hasLoop = wantLoop && loopRadius >= 3.2
        let sway: Float = 2.2                                    // the loop's sideways offset, so it does not meet itself

        // A dense polyline of the whole ride, with an "up" hint for the loop and a side offset round it.
        var dense: [(p: SIMD3<Float>, up: SIMD3<Float>?, plan: Float)] = []
        func side(_ tangent: SIMD3<Float>) -> SIMD3<Float> { simd_normalize(simd_cross(tangent, SIMD3(0, 1, 0))) }
        func offset(_ s: Float) -> Float {
            guard hasLoop else { return 0 }
            if s > loopAt - 20 && s <= loopAt { return -sway / 2 * smooth((s - (loopAt - 20)) / 20) }
            if s > loopAt && s < loopAt + 20 { return sway / 2 * (1 - smooth((s - loopAt) / 20)) }
            return 0
        }
        var ds: Float = 0
        let fine: Float = 0.1
        var loopInserted = false
        while ds < total {
            let (p, t) = plan.at(ds)
            // The loop goes in before the first point past its place: the points before it are
            // offset to one side and those after to the other, as the loop's own ends are.
            if hasLoop && !loopInserted && ds >= loopAt {
                loopInserted = true
                let base = p + SIMD3(0, profile.height(ds), 0)
                let up = SIMD3<Float>(0, 1, 0), sideways = side(t)
                let steps = Int(2 * .pi * loopRadius / fine)
                for k in 1..<steps {
                    let theta = Float(k) / Float(steps) * 2 * .pi
                    let q = base + t * (loopRadius * sin(theta)) + up * (loopRadius * (1 - cos(theta))) + sideways * (sway * (theta / (2 * .pi) - 0.5))
                    dense.append((q, up * cos(theta) - t * sin(theta), ds))
                }
            }
            dense.append((p + SIMD3(0, profile.height(ds), 0) + side(t) * offset(ds), nil, ds))
            ds += fine
        }

        // Even poses every half metre along the track itself.
        var positions: [SIMD3<Float>] = [], hints: [SIMD3<Float>?] = [], planAt: [Float] = []
        var carried: Float = 0
        positions.append(dense[0].p); hints.append(dense[0].up); planAt.append(dense[0].plan)
        for i in 1..<dense.count {
            var a = dense[i - 1].p
            let b = dense[i].p
            var left = simd_distance(a, b)
            while carried + left >= step {
                let need = step - carried
                let t = need / max(left, 1e-5)
                let q = simd_mix(a, b, SIMD3(repeating: t))
                positions.append(q); hints.append(dense[i].up); planAt.append(dense[i].plan)
                left -= need; a = q; carried = 0
            }
            carried += left
        }
        let count = positions.count
        let loopStart = hints.firstIndex { $0 != nil }
        let loopEnd = hints.lastIndex { $0 != nil }

        // Speeds: the station's drive, the chain, then energy with friction and drag, and the brakes.
        let crest = stationLength + lift * 1.8 + 6
        var v = [Float](repeating: 0, count: count)
        var current: Float = 0.8
        for i in 0..<count {
            let sPlan = planAt[i], sTrack = Float(i) * step
            if sPlan < stationLength { current = min(liftSpeed, max(current, sqrt(1.6 * max(sTrack, 0.4)))) }
            else if sPlan < crest { current = liftSpeed }
            else if i > 0 {
                let dh = positions[i].y - positions[i - 1].y
                var v2 = current * current - 2 * g * dh - 2 * (0.012 * g + 0.0009 * current * current) * step
                v2 = max(v2, 2.5 * 2.5)                          // the tyres keep a stalled car rolling
                current = sqrt(v2)
            }
            v[i] = current
        }
        // The brakes: from the brake zone, never faster than a steady stop at the station.
        let trackLength = Float(count) * step
        for i in 0..<count {
            let remaining = trackLength - Float(i + 1) * step
            if remaining < brakeLength + 25 { v[i] = min(v[i], max(0.35, sqrt(2 * 1.8 * remaining))) }
        }

        // Orientation: along the track, with the loop's own up, elsewhere banked into the turns.
        var poses: [Pose] = []
        poses.reserveCapacity(count)
        var banks = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let prev = positions[(i - 2 + count) % count], next = positions[(i + 2) % count]
            let here = positions[i]
            let a = G.flat(here - prev), b = G.flat(next - here)
            let turnAngle = atan2(simd_cross(a, b).y, simd_dot(a, b))
            let curvature = turnAngle / (4 * step)
            // No banking from the loop's own shape (its level parts point every way).
            let nearLoop = (-3...3).contains { hints[(i + $0 + count) % count] != nil }
            banks[i] = nearLoop ? 0 : max(-0.9, min(0.9, atan(v[i] * v[i] * curvature / g)))
        }
        // Smoothed, so the car rolls into and out of a bank.
        var smoothBanks = banks
        for i in 0..<count {
            var sum: Float = 0
            for k in -12...12 { sum += banks[(i + k + count) % count] }
            smoothBanks[i] = sum / 25
        }
        for i in 0..<count {
            let forward = simd_normalize(positions[(i + 1) % count] - positions[(i - 1 + count) % count])
            var up: SIMD3<Float>
            if let hint = hints[i] {
                up = hint
            } else {
                up = SIMD3(0, 1, 0)
                up = simd_normalize(up - forward * simd_dot(up, forward))
                up = simd_quatf(angle: -smoothBanks[i], axis: forward).act(up)
            }
            up = simd_normalize(up - forward * simd_dot(up, forward))
            poses.append(Pose(position: positions[i], orientation: G.look(forward, up: up)))
        }
        var seconds: Float = 0
        for i in 0..<count { seconds += step / max(v[i], 0.35) }
        let loop: Range<Int>? = (loopStart != nil && loopEnd != nil) ? loopStart!..<(loopEnd! + 1) : nil
        return Course(poses: poses, speeds: v, loop: loop, seconds: seconds)
    }

    /// A new random course, its size tuned until a ride takes about two minutes.
    private func build() {
        let turn: Float = Bool.random() ? 1 : -1
        let lift = Float.random(in: 16...24)
        let wobble: [(k: Float, a: Float)] = [(2, Float.random(in: -0.12...0.12)), (3, Float.random(in: -0.08...0.08)), (4, Float.random(in: -0.05...0.05))]
        var hills: [Float] = []
        var h = lift * Float.random(in: 0.6...0.75)
        while h > 3 { hills.append(h); h *= Float.random(in: 0.6...0.8) }
        let wantLoop = Float.random(in: 0...1) < 0.7
        var radius: Float = 140
        var course = Self.makeCourse(radius: radius, liftHeight: lift, turn: turn, wobble: wobble, hills: hills, wantLoop: wantLoop)
        for _ in 0..<6 where abs(course.seconds - 120) > 6 {
            radius *= pow(120 / max(course.seconds, 20), 0.85)
            radius = min(max(radius, 45), 320)
            course = Self.makeCourse(radius: radius, liftHeight: lift, turn: turn, wobble: wobble, hills: hills, wantLoop: wantLoop)
        }
        // Into the world: the start under the rider, heading the way they face.
        let origin = anchorHead - SIMD3(0, Self.seatHeight, 0) - G.flat(anchorYaw.act(SIMD3(0, 0, -1))) * 1.0
        poses = course.poses.map { Pose(position: origin + anchorYaw.act($0.position), orientation: simd_normalize(anchorYaw * $0.orientation)) }
        speeds = course.speeds
        loopRange = course.loop
        lapSeconds = course.seconds
    }

    private func index(at metres: Float) -> (Int, Int, Float) {
        let f = min(max(metres, 0), lapLength) / Self.step
        let i = min(Int(f), poses.count - 1)
        return (i, (i + 1) % poses.count, f - Float(i))
    }

    private func pose(at metres: Float) -> Pose {
        guard !poses.isEmpty else { return Pose(position: .zero, orientation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))) }
        let (i, j, t) = index(at: metres)
        return Pose(position: simd_mix(poses[i].position, poses[j].position, SIMD3(repeating: t)),
                    orientation: simd_slerp(poses[i].orientation, poses[j].orientation, t))
    }

    private func plannedSpeed(at metres: Float) -> Float {
        guard !speeds.isEmpty else { return 0 }
        let (i, j, t) = index(at: metres)
        return speeds[i] + (speeds[j] - speeds[i]) * t
    }

    private func place(car: Pose) {
        let seat = car.position + car.orientation.act(SIMD3(0, Self.seatHeight, 0))
        riderTransform = simd_float4x4.translation(seat) * simd_float4x4(car.orientation) * simd_float4x4(anchorYaw.inverse) * simd_float4x4.translation(-anchorHead)
    }

    func update(_ c: GameContext) {
        if !built {
            anchorHead = c.headPosition
            anchorYaw = G.look(G.flat(c.forward))
            build()
            along = 0
            built = true
            log(String(format: "[Games] Coaster: a new course of %d poses, %.0f m, about %.0f s a ride%@", poses.count, lapLength, lapSeconds, loopRange == nil ? "" : ", with a loop"))
        }
        particles.update(dt: c.dt)
        guard riding else {
            // At the station (before or after a ride): the car at the start, the world still.
            place(car: pose(at: 0))
            speed = 0
            return
        }
        speed = plannedSpeed(at: along)
        along += max(speed, 0.35) * c.dt
        rideTime += c.dt
        distance += speed * c.dt
        topSpeed = max(topSpeed, speed)
        let car = pose(at: along)
        topHeight = max(topHeight, car.position.y - poses[0].position.y)
        if along >= lapLength - 0.05 {
            // Back at the station, at rest where the ride began: the same point, no jump.
            along = 0
            riding = false
            finished = true
            place(car: pose(at: 0))
            log(String(format: "[Games] Coaster: ride complete in %.0f s, top speed %.0f km/h", rideTime, topSpeed * 3.6))
            return
        }
        place(car: car)
        if speed > 12 {
            particles.burst(at: car.position + car.orientation.act(SIMD3(Float.random(in: -0.8...0.8), 0.2, -3)), count: 1, speed: 0.1, color: SIMD4(0.6, 0.9, 1, 0.7), life: 0.4, size: 0.02, gravity: 0)
        }
    }

    func draw(into scene: inout Scene3D, context c: GameContext) {
        guard built else { return }
        let m = c.meshes
        let eye = c.headPosition
        let rail = SIMD4<Float>(0.95, 0.35, 1, 1)
        let steel = SIMD4<Float>(0.3, 0.3, 0.4, 1)
        let floor = c.floorHeight
        // The whole loop is drawn: a lap is a few hundred metres and the far side is in view.
        let from = 0, to = poses.count
        guard poses.count > 2 else { return }
        var i = from
        while i < to {
            let p0 = poses[i], p1 = poses[(i + 1) % poses.count]
            let r0 = p0.orientation.act(SIMD3(0.55, 0, 0)), r1 = p1.orientation.act(SIMD3(0.55, 0, 0))
            scene.rod(m, p0.position - r0, p1.position - r1, radius: 0.06, color: rail, roughness: 0.2, metallic: 0.6, emissive: 0.4)
            scene.rod(m, p0.position + r0, p1.position + r1, radius: 0.06, color: rail, roughness: 0.2, metallic: 0.6, emissive: 0.4)
            if i % 4 == 0 { scene.rod(m, p0.position - r0, p0.position + r0, radius: 0.04, color: steel, roughness: 0.6, metallic: 0.3) }
            if i % 8 == 0 {
                // A pylon to the ground; none where the track is upside down or passes under
                // itself (the loop), where it would run through the rails.
                var clear = p0.orientation.act(SIMD3(0, 1, 0)).y > 0.75
                if clear {
                    var j = max(0, i - 40)
                    while j < min(poses.count, i + 40) {
                        let other = poses[j]
                        if j != i, other.position.y < p0.position.y - 0.3, abs(other.position.x - p0.position.x) < 1.0, abs(other.position.z - p0.position.z) < 1.0 { clear = false; break }
                        j += 1
                    }
                }
                if clear, p0.position.y - floor > 0.3 {
                    scene.rod(m, SIMD3(p0.position.x, floor, p0.position.z), p0.position - SIMD3(0, 0.1, 0), radius: 0.09, color: steel, roughness: 0.6, metallic: 0.3)
                }
            }
            if i % 48 == 0 {
                let up = p0.orientation.act(SIMD3(0, 1, 0))
                let centre = p0.position + up * 2.0
                scene.add(m.ring, at: centre, rotation: p0.orientation * G.pitch(.pi / 2), scale: SIMD3(1.8, 1, 1.8), color: SIMD4(0.3, 0.9, 1, 1), roughness: 0.3, emissive: 0.8, shadow: false)
                scene.add(m.smallSphere, at: centre + up * 1.9, scale: SIMD3(repeating: 0.15), color: G.white, emissive: 1.5, shadow: false)
                scene.glow(centre + up * 1.9, size: 0.9, eye: eye, color: SIMD4(0.3, 0.9, 1, 0.5))
            }
            i += 1
        }
        // The car at the seat: a tub, a nose, a lap bar, wheels, in the car's own frame.
        let car = pose(at: riding ? along : 0)
        let o = car.orientation
        let base = car.position
        let pink = SIMD4<Float>(1, 0.3, 0.55, 1)
        scene.add(m.box, at: base + o.act(SIMD3(0, 0.45, 0)), rotation: o, scale: SIMD3(1.3, 0.5, 1.6), color: pink, roughness: 0.3, metallic: 0.3, shadow: false)
        scene.add(m.box, at: base + o.act(SIMD3(0, 0.75, 0.75)), rotation: o, scale: SIMD3(1.3, 0.9, 0.12), color: pink, roughness: 0.3, metallic: 0.3, shadow: false)
        scene.add(m.sphere, at: base + o.act(SIMD3(0, 0.55, -1.1)), rotation: o, scale: SIMD3(0.6, 0.3, 0.6), color: pink, roughness: 0.3, metallic: 0.3, shadow: false)
        scene.rod(m, base + o.act(SIMD3(-0.5, 0.72, -0.55)), base + o.act(SIMD3(0.5, 0.72, -0.55)), radius: 0.04, color: SIMD4(0.85, 0.85, 0.9, 1), roughness: 0.2, metallic: 0.9)
        for s: Float in [-0.5, 0.5] {
            scene.rod(m, base + o.act(SIMD3(s, 0.5, -0.55)), base + o.act(SIMD3(s, 0.72, -0.55)), radius: 0.03, color: SIMD4(0.85, 0.85, 0.9, 1), roughness: 0.2, metallic: 0.9)
        }
        for (x, z) in [(Float(-0.55), Float(0.6)), (0.55, 0.6), (-0.55, -0.6), (0.55, -0.6)] {
            scene.add(m.cylinder, at: base + o.act(SIMD3(x, 0.08, z)), rotation: o * G.roll(.pi / 2), scale: SIMD3(0.16, 0.1, 0.16), color: SIMD4(0.1, 0.1, 0.12, 1), roughness: 0.9, shadow: false)
        }
        particles.draw(into: &scene, eye: eye)
    }
}

// MARK: - Portal

/// A stone archway ahead with a swirling gate in it; walk through (the head crossing its plane)
/// and the surroundings change to the next of the palettes; walk back for the previous.
@MainActor
final class PortalGame: Game {
    let title = "🌀 Portal"
    private var placed = false
    private var centre = SIMD3<Float>.zero
    private var normal = SIMD3<Float>(0, 0, 1)
    private var side: Float = 1
    private(set) var world = 0
    private var particles = ParticleSystem()
    private var moveRequested = false
    private var throughRequested = false
    private var walkRoom: Float = 0
    /// How many other worlds there are to go through to (the Places app's photospheres).
    static let worlds = 4
    static let palettes: [SIMD3<Float>] = [SIMD3(1, 0.2, 0.85), SIMD3(0.2, 0.7, 1), SIMD3(1, 0.5, 0.15), SIMD3(0.7, 0.9, 1)]
    var status: String {
        world == 0 ? "In your room · walk through the gate, or Step through" : "Through the portal · walk back through to come home"
    }
    /// The world now: 0 is the room, the rest are other places (the renderer shows them).
    var onWorldChange: ((Int) -> Void)?

    func reset() { placed = false; world = 0; onWorldChange?(0) }
    /// The controls window's Step through: the same as walking through, for a room too small.
    func stepThrough() { throughRequested = true }
    /// The controls window's Move it in front of me.
    func moveHere() { moveRequested = true }

    /// How far a level ray from `origin` goes before it meets a wall, a door, a window or a piece
    /// of furniture the room scan found (a long way when nothing is in the way).
    private static func freeDistance(from origin: SIMD3<Float>, along direction: SIMD3<Float>, floor: Float, surfaces: [RoomModel.Surface]) -> Float {
        var nearest: Float = 20
        for height in [origin.y, floor + 0.45] {
            let o = SIMD3(origin.x, height, origin.z)
            for s in surfaces {
                // Floors and anything near floor level are walked on, not into.
                if s.isHorizontal && (s.center.y < floor + 0.25 || s.center.y > origin.y + 0.3) { continue }
                let n = simd_normalize(s.transform.columns.1.xyz)
                let denominator = simd_dot(direction, n)
                if s.isHorizontal {
                    // A table or seat top: blocked if the ray passes over its footprint below head height.
                    let toCentre = s.center - o
                    let along = simd_dot(toCentre, direction)
                    guard along > 0 else { continue }
                    let local = (s.transform.inverse * SIMD4(o + direction * along, 1)).xyz
                    if abs(local.x) <= s.extent.x + 0.2 && abs(local.z) <= s.extent.y + 0.2 { nearest = min(nearest, max(0, along - max(s.extent.x, s.extent.y))) }
                    continue
                }
                guard abs(denominator) > 1e-3 else { continue }
                let t = simd_dot(s.center - o, n) / denominator
                guard t > 0.05, t < nearest else { continue }
                let local = (s.transform.inverse * SIMD4(o + direction * t, 1)).xyz
                if abs(local.x) <= s.extent.x + 0.1 && abs(local.z) <= s.extent.y + 0.1 { nearest = t }
            }
        }
        return nearest
    }

    /// The gate goes where there is room to walk through it and on: ahead if the scan allows,
    /// else the nearest clear direction round the player (owner, 2026-11-08: it stood where it
    /// could not be walked through).
    private func place(_ c: GameContext) {
        let ahead = G.flat(c.forward)
        let needed: Float = 2.6
        var best: (offset: Float, room: Float)?
        var roomiest: (offset: Float, room: Float) = (0, 0)
        for offset: Float in [0, 0.35, -0.35, 0.7, -0.7, 1.05, -1.05, 1.4, -1.4, 1.9, -1.9, 2.5, -2.5, .pi] {
            let direction = G.yaw(-offset).act(ahead)
            let room = Self.freeDistance(from: c.headPosition, along: direction, floor: c.floorHeight, surfaces: c.surfaces)
            if room > roomiest.room { roomiest = (offset, room) }
            if room >= needed { best = (offset, room); break }
        }
        let chosen = best ?? roomiest
        let direction = G.yaw(-chosen.offset).act(ahead)
        let distance = min(1.1, chosen.room * 0.4)
        walkRoom = chosen.room
        centre = SIMD3(c.headPosition.x, c.floorHeight + 1.1, c.headPosition.z) + direction * max(distance, 0.7)
        normal = -direction
        side = 1
        log(String(format: "[Games] Portal: placed %.1f m away, %.0f degrees from ahead, %.1f m clear to walk (%d surfaces)", max(distance, 0.7), chosen.offset * 180 / .pi, chosen.room, c.surfaces.count))
    }

    private func cross(to next: Int, c: GameContext) {
        world = next
        onWorldChange?(world)
        particles.burst(at: c.headPosition + c.forward * 0.5, count: 50, speed: 1.5, color: SIMD4(Self.palettes[world % Self.palettes.count], 1), life: 1, size: 0.03, gravity: 0)
        log("[Games] Portal: now in world \(world)")
    }

    func update(_ c: GameContext) {
        if !placed || moveRequested {
            place(c)
            placed = true
            moveRequested = false
        }
        particles.update(dt: c.dt)
        if throughRequested {
            throughRequested = false
            cross(to: world == 0 ? 1 + Int.random(in: 0..<Self.worlds) : 0, c: c)
        }
        let now: Float = simd_dot(c.headPosition - centre, normal) >= 0 ? 1 : -1
        if now != side {
            let withinDoor = abs(simd_dot(c.headPosition - centre, simd_cross(normal, SIMD3(0, 1, 0)))) < 0.6
            if withinDoor {
                // Walking in (away from the start side) goes to another world; walking back comes home.
                cross(to: now < 0 ? (world == 0 ? 1 + Int.random(in: 0..<Self.worlds) : world) : 0, c: c)
            }
            side = now
        }
        // The vortex's motes.
        let right = simd_cross(normal, SIMD3(0, 1, 0))
        let a = Float(c.time) * 2
        particles.burst(at: centre + right * cos(a) * 0.5 + SIMD3(0, sin(a) * 0.9, 0), count: 1, speed: 0.1, color: SIMD4(Self.palettes[(world + 1) % Self.palettes.count], 0.8), life: 0.8, size: 0.03, gravity: 0)
    }

    func draw(into scene: inout Scene3D, context c: GameContext) {
        let m = c.meshes
        let eye = c.headPosition
        let right = simd_cross(normal, SIMD3(0, 1, 0))
        let next = SIMD4(Self.palettes[(world + 1) % Self.palettes.count], 1)
        let w: Float = 0.65, h: Float = 1.1
        let rot = G.look(normal)
        let stone = SIMD4<Float>(0.55, 0.52, 0.58, 1)
        // Two fluted columns on plinths, a lintel, and a glowing keystone ring.
        for s: Float in [-1, 1] {
            let foot = centre + right * s * w - SIMD3(0, h, 0)
            scene.add(m.box, at: foot + SIMD3(0, 0.08, 0), rotation: rot, scale: SIMD3(0.4, 0.16, 0.4), color: stone, roughness: 0.9, pattern: 5)
            scene.rod(m, foot + SIMD3(0, 0.16, 0), foot + SIMD3(0, 2 * h - 0.2, 0), radius: 0.13, color: stone, roughness: 0.85, pattern: 2)
            scene.add(m.box, at: foot + SIMD3(0, 2 * h - 0.12, 0), rotation: rot, scale: SIMD3(0.36, 0.16, 0.36), color: stone, roughness: 0.9, pattern: 5, shadow: false)
        }
        scene.add(m.box, at: centre + SIMD3(0, h + 0.1, 0), rotation: rot, scale: SIMD3(2 * w + 0.5, 0.2, 0.4), color: stone, roughness: 0.9, pattern: 5, shadow: false)
        scene.add(m.torus, at: centre + SIMD3(0, h + 0.1, 0), rotation: rot * G.pitch(0), scale: SIMD3(0.2, 0.2, 0.2), color: next, roughness: 0.2, emissive: 1.2, shadow: false)
        // The gate: a shimmering disc of the next world's colour, framed by a ring.
        scene.add(m.torus, at: centre, rotation: rot * G.pitch(.pi / 2), scale: SIMD3(w * 0.95, 0.25, h * 0.9), color: next, roughness: 0.3, metallic: 0.3, emissive: 0.6 + 0.2 * sin(Float(c.time) * 3), shadow: false)
        scene.add(m.disc, at: centre, rotation: rot * G.pitch(.pi / 2), scale: SIMD3(w * 0.9, 1, h * 0.85), color: next * SIMD4(0.5, 0.5, 0.5, 0.55), roughness: 0.1, emissive: 0.5, shadow: false)
        scene.glow(centre, size: 2.2, eye: eye, color: next * SIMD4(1, 1, 1, 0.12))
        // Swirl: glows on a spiral in the doorway.
        let t = Float(c.time)
        for i in 0..<14 {
            let a = t * 1.5 + Float(i) * 0.45
            let r = 0.15 + Float(i) * 0.05
            let p = centre + right * cos(a) * r * w / 0.65 + SIMD3(0, sin(a) * r * h / 0.65, 0)
            scene.glow(p, size: 0.08 + Float(i) * 0.004, eye: eye, color: next * SIMD4(1, 1, 1, 0.5))
        }
        particles.draw(into: &scene, eye: eye)
    }
}
