import simd
import Foundation

// MARK: - Shared geometry helpers

enum G {
    static func yaw(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3(0, 1, 0)) }
    static func pitch(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3(1, 0, 0)) }
    static func roll(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3(0, 0, 1)) }
    /// A rotation whose -z faces `forward` with y as near up as it can.
    static func look(_ forward: SIMD3<Float>, up: SIMD3<Float> = SIMD3(0, 1, 0)) -> simd_quatf {
        let f = simd_normalize(forward)
        var r = simd_cross(up, f)
        if simd_length(r) < 1e-4 { r = SIMD3(1, 0, 0) }
        r = simd_normalize(r)
        let u = simd_cross(f, r)
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

/// Pinch and move to paint a glossy tube in the air. The colour follows the hand's height when
/// a stroke starts (a rainbow from the floor up), so the painter chooses by reaching; a select
/// with no pinch undoes the last stroke. Sparks follow the brush.
@MainActor
final class PaintGame: Game {
    let title = "🎨 Paint"
    private struct Stroke { var color: SIMD4<Float>; var points: [SIMD3<Float>]; var radius: Float }
    private var strokes: [Stroke] = []
    private var drawing: [Bool: Int] = [:]
    private var particles = ParticleSystem()
    var status: String { "\(strokes.count) strokes, \(strokes.reduce(0) { $0 + $1.points.count }) points" }

    func reset() { strokes.removeAll(); drawing.removeAll() }

    private static func color(forHeight h: Float) -> SIMD4<Float> {
        // Hue from the height above the floor: 0 m red, 1.8 m violet.
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
            let tip = hand.pinchPoint
            if hand.pinched {
                if let i = drawing[hand.isRight] {
                    if let last = strokes[i].points.last, simd_distance(last, tip) > 0.006 {
                        strokes[i].points.append(tip)
                        particles.burst(at: tip, count: 2, speed: 0.3, color: strokes[i].color, life: 0.4, size: 0.012, gravity: 0.5)
                    }
                } else {
                    strokes.append(Stroke(color: Self.color(forHeight: tip.y - c.floorHeight), points: [tip], radius: 0.012))
                    drawing[hand.isRight] = strokes.count - 1
                }
            } else {
                drawing[hand.isRight] = nil
            }
        }
        if c.select && c.hands.allSatisfy({ !$0.pinched }) && !strokes.isEmpty { strokes.removeLast() }
        particles.update(dt: c.dt)
    }

    func draw(into scene: inout Scene3D, context c: GameContext) {
        let m = c.meshes
        for stroke in strokes {
            // Spheres at the points and capsules between them: a continuous glossy tube.
            scene.add(m.smallSphere, at: stroke.points[0], scale: SIMD3(repeating: stroke.radius), color: stroke.color, roughness: 0.2, shadow: false)
            for i in 1..<max(stroke.points.count, 1) {
                scene.capsule(m, stroke.points[i - 1], stroke.points[i], radius: stroke.radius, color: stroke.color, roughness: 0.2)
            }
        }
        // The brush tip: a glowing bead at each pinch point, colour previewing the height.
        for hand in c.hands {
            let p = hand.pinchPoint
            let color = Self.color(forHeight: p.y - c.floorHeight)
            scene.add(m.smallSphere, at: p, scale: SIMD3(repeating: 0.015), color: color, roughness: 0.1, emissive: 0.6, shadow: false)
            scene.glow(p, size: 0.05, eye: c.headPosition, color: color * SIMD4(1, 1, 1, 0.35))
        }
        particles.draw(into: &scene, eye: c.headPosition)
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
    var status: String { over ? "Game over: \(score)" : "Wave \(wave) · Score \(score) · ♥ \(lives)" }

    func reset() { blobs.removeAll(); bolts.removeAll(); score = 0; lives = 3; over = false; spawnTimer = 0; wave = 1; waveLeft = 6 }

    func update(_ c: GameContext) {
        particles.update(dt: c.dt)
        flash = max(0, flash - c.dt * 3)
        guard !over else { return }
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
            }
        }
        if c.select, c.hands.isEmpty {
            bolts.append(Bolt(position: c.headPosition + c.forward * 0.3 - SIMD3(0, 0.1, 0), velocity: c.forward * 10, age: 0))
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
                bolts[bi].age = 10
                blobs[i].hp -= 1
                blobs[i].hurt = 1
                particles.burst(at: bolt.position, count: 18, speed: 1.6, color: blob.color, life: 0.7, size: 0.03)
                if blobs[i].hp <= 0 {
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
    var status: String { piles.isEmpty && seeded ? "All clean! \(cleaned) piles" : (seeded ? "\(piles.count) piles left" : "No floor yet") }

    func reset() { piles.removeAll(); seeded = false; cleaned = 0 }

    private func seed(_ k: SIMD2<Int>) {
        let jitter = SIMD3(Float.random(in: -0.08...0.08), 0, Float.random(in: -0.08...0.08))
        piles[k] = Pile(position: SIMD3(Float(k.x) * spacing, floor, Float(k.y) * spacing) + jitter, size: Float.random(in: 0.04...0.09), seed: Float.random(in: 0...6))
    }

    func update(_ c: GameContext) {
        floor = c.floorHeight
        particles.update(dt: c.dt)
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

    private var buttonPosition: SIMD3<Float> { boxCentre + SIMD3(0, 0.05, 0) }

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
        // Hands: grab, carry, throw, make; or press the button.
        for hand in motion.motions(c.hands, time: c.time) {
            let was = wasPinched[hand.isRight] ?? false
            if hand.pinched {
                if let i = held[hand.isRight], toys.indices.contains(i) {
                    toys[i].position = hand.position
                    toys[i].velocity = hand.velocity
                } else if !was {
                    if simd_distance(hand.position, buttonPosition) < 0.14 {
                        pressButton(time: c.time)
                    } else if let i = toys.indices.min(by: { simd_distance(toys[$0].position, hand.position) < simd_distance(toys[$1].position, hand.position) }),
                              simd_distance(toys[i].position, hand.position) < toys[i].size + 0.08 {
                        held[hand.isRight] = i
                    } else {
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
        // A select with the gaze on the button (no hands) presses it too.
        if c.select, c.hands.isEmpty {
            let to = buttonPosition - c.headPosition
            let along = simd_dot(to, c.forward)
            let miss = simd_length(to - c.forward * along)
            log("[Games] Toys: select with the gaze \(String(format: "%.2f", miss)) m from the button")
            if along > 0, miss < 0.25 { pressButton(time: c.time) }
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
        // The wake-up button: a red dome on a chrome base at the bottom of the box.
        let press = buttonPress * 0.02
        scene.add(m.cylinder, at: buttonPosition + SIMD3(0, -0.02, 0), scale: SIMD3(0.07, 0.02, 0.07), color: SIMD4(0.8, 0.82, 0.88, 1), roughness: 0.2, metallic: 0.9, shadow: false)
        scene.add(m.sphere, at: buttonPosition - SIMD3(0, 0.025 + press, 0), scale: SIMD3(0.055, 0.045, 0.055), color: awake ? SIMD4(1, 0.25, 0.2, 1) : SIMD4(0.85, 0.1, 0.1, 1), roughness: 0.15, emissive: awake ? 0.5 + 0.2 * sin(Float(c.time) * 6) : 0.05, shadow: false)
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

// MARK: - Golf

/// A putting green ahead with a cup and a waving flag; the ball sits at your feet. Swing a
/// hand low through the ball to putt (a putter head follows a low hand), or select to tap it
/// along the gaze. Strokes are counted; the ball drops when it reaches the cup.
@MainActor
final class GolfGame: Game {
    let title = "⛳ Golf"
    private var ball = SIMD3<Float>.zero
    private var velocity = SIMD3<Float>.zero
    private var hole = SIMD3<Float>.zero
    private var greenCentre = SIMD3<Float>.zero
    private var strokes = 0
    private var holed = false
    private var placed = false
    private var lastHit: Double = 0
    private var roll = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    private var sink: Float = 0
    private let motion = HandMotionTracker()
    private var particles = ParticleSystem()
    var status: String { holed ? "In the cup in \(strokes)!" : "\(strokes) strokes" }

    func reset() { placed = false; strokes = 0; holed = false; velocity = .zero; sink = 0 }

    func update(_ c: GameContext) {
        let floor = c.floorHeight
        particles.update(dt: c.dt)
        if !placed {
            let f = G.flat(c.forward)
            ball = SIMD3(c.headPosition.x, floor + 0.021, c.headPosition.z) + f * 0.7
            hole = SIMD3(c.headPosition.x, floor, c.headPosition.z) + f * 4 + simd_cross(f, SIMD3(0, 1, 0)) * 0.8
            greenCentre = (ball + hole) / 2
            greenCentre.y = floor
            placed = true
        }
        if holed { sink = min(1, sink + c.dt * 3); return }
        for hand in motion.motions(c.hands, time: c.time) {
            let speed = simd_length(SIMD3(hand.velocity.x, 0, hand.velocity.z))
            if simd_distance(hand.position, ball) < 0.2 && speed > 0.6 && c.time - lastHit > 0.5 {
                lastHit = c.time
                strokes += 1
                velocity = SIMD3(hand.velocity.x, 0, hand.velocity.z) * 1.2
                particles.burst(at: ball, count: 10, speed: 0.6, color: SIMD4(0.6, 1, 0.5, 1), life: 0.4, size: 0.015)
            }
        }
        if c.select, c.hands.isEmpty, c.time - lastHit > 0.5 {
            lastHit = c.time
            strokes += 1
            velocity = G.flat(c.forward) * 2.5
        }
        ball += velocity * c.dt
        let speed = simd_length(velocity)
        if speed > 0 {
            let axis = simd_normalize(simd_cross(SIMD3(0, 1, 0), velocity))
            roll = simd_quatf(angle: speed * c.dt / 0.021, axis: axis) * roll
        }
        // The green slows the ball a little less than the floor beyond it.
        let onGreen = simd_distance(SIMD3(ball.x, 0, ball.z), SIMD3(greenCentre.x, 0, greenCentre.z)) < 2.6
        velocity *= max(0, 1 - (onGreen ? 0.75 : 1.4) * c.dt)
        if speed < 0.03 { velocity = .zero }
        let toHole = simd_distance(SIMD3(ball.x, 0, ball.z), SIMD3(hole.x, 0, hole.z))
        if toHole < 0.2 && speed < 2 {
            // The cup's lip pulls the ball in.
            velocity += simd_normalize(SIMD3(hole.x - ball.x, 0, hole.z - ball.z)) * 1.2 * c.dt
        }
        if toHole < 0.07 && speed < 1.5 {
            holed = true
            particles.burst(at: hole + SIMD3(0, 0.1, 0), count: 60, speed: 2.5, color: SIMD4(1, 0.9, 0.3, 1), life: 1.2, size: 0.03)
            log("[Games] Golf: holed in \(strokes)")
        }
    }

    func draw(into scene: inout Scene3D, context c: GameContext) {
        let m = c.meshes
        let eye = c.headPosition
        let floor = c.floorHeight
        // The green: a mown disc with a fringe ring.
        scene.add(m.disc, at: greenCentre + SIMD3(0, 0.003, 0), scale: SIMD3(2.6, 1, 2.6), color: SIMD4(0.2, 0.55, 0.22, 1), roughness: 0.95, pattern: 2, shadow: false)
        scene.add(m.ring, at: greenCentre + SIMD3(0, 0.002, 0), scale: SIMD3(2.6, 1, 2.6), color: SIMD4(0.35, 0.65, 0.28, 1), roughness: 1, shadow: false)
        // The cup, the pole and a flag that waves.
        scene.add(m.cylinder, at: hole + SIMD3(0, -0.04, 0), scale: SIMD3(0.055, 0.08, 0.055), color: SIMD4(0.04, 0.05, 0.06, 1), roughness: 1, shadow: false)
        scene.add(m.torus, at: hole + SIMD3(0, 0.004, 0), scale: SIMD3(0.055, 0.055, 0.055), color: G.white, roughness: 0.5, shadow: false)
        scene.rod(m, hole, hole + SIMD3(0, 1.2, 0), radius: 0.008, color: SIMD4(0.9, 0.9, 0.95, 1), roughness: 0.3, metallic: 0.6)
        let wave = sin(Float(c.time) * 3) * 0.1
        let flagDir = G.flat(simd_cross(SIMD3(0, 1, 0), eye - hole))
        scene.add(m.box, at: hole + SIMD3(0, 1.05, 0) + flagDir * 0.16, rotation: G.look(simd_cross(flagDir, SIMD3(0, 1, 0))) * G.yaw(wave), scale: SIMD3(0.32, 0.2, 0.01), color: SIMD4(1, 0.3, 0.35, 1), roughness: 0.8, shadow: false)
        scene.add(m.smallSphere, at: hole + SIMD3(0, 1.22, 0), scale: SIMD3(repeating: 0.02), color: SIMD4(1, 0.85, 0.3, 1), roughness: 0.2, metallic: 0.8, shadow: false)
        if !holed || sink < 1 {
            let p = holed ? ball - SIMD3(0, sink * 0.08, 0) : ball
            scene.add(m.sphere, at: p, rotation: roll, scale: SIMD3(repeating: 0.021), color: G.white, roughness: 0.3, pattern: 1)
        }
        // The putter under a low hand.
        for hand in c.hands where hand.joints[HandGeometry.wrist].y - floor < 0.6 {
            let w = hand.joints[HandGeometry.wrist]
            let headPos = SIMD3(w.x, floor + 0.03, w.z) + G.flat(w - eye) * 0.05
            scene.rod(m, w, headPos, radius: 0.008, color: SIMD4(0.75, 0.78, 0.85, 1), roughness: 0.25, metallic: 0.8)
            scene.add(m.box, at: headPos, rotation: G.look(G.flat(eye - w)), scale: SIMD3(0.1, 0.03, 0.025), color: SIMD4(0.8, 0.82, 0.9, 1), roughness: 0.2, metallic: 0.9)
        }
        particles.draw(into: &scene, eye: eye)
    }
}

// MARK: - Grid ride

/// A coaster over the neon grid: two rails curve ahead, lit arches stream past, lamp posts and
/// pylons mark the speed, and the world banks with the head. Nothing in the room moves
/// sideways, so the ride stays comfortable.
@MainActor
final class GridRide: Game {
    let title = "🎢 Ride"
    private(set) var distance: Float = 0
    private(set) var speed: Float = 3
    private(set) var bank: Float = 0
    private var particles = ParticleSystem()
    var status: String { String(format: "%.0f m at %.1f m/s", distance, speed) }

    func reset() { distance = 0; speed = 3; bank = 0 }

    func update(_ c: GameContext) {
        speed = min(12, speed + c.dt * 0.3)
        distance += speed * c.dt
        let yaw = atan2(c.forward.x, -c.forward.z)
        bank += (yaw * 0.5 - bank) * min(1, c.dt * 2)
        if c.select { speed = max(1, speed - 3) }
        particles.update(dt: c.dt)
        if Int(distance * 10) % 3 == 0 {
            particles.burst(at: c.headPosition + SIMD3(Float.random(in: -1.5...1.5), Float.random(in: -1...1), -4), count: 1, speed: 0, color: SIMD4(0.5, 0.9, 1, 0.8), life: 0.6, size: 0.02, gravity: 0)
        }
    }

    private func trackX(_ z: Float) -> Float { sin((distance - z) * 0.08) * 1.5 }

    func draw(into scene: inout Scene3D, context c: GameContext) {
        let m = c.meshes
        let eye = c.headPosition
        let origin = SIMD3(eye.x, c.floorHeight, eye.z)
        let rail = SIMD4<Float>(0.9, 0.3, 1, 1)
        // Rails: segments between sampled points of the curve, 1.2 m apart, 0.3 m up.
        var last: (SIMD3<Float>, SIMD3<Float>)? = nil
        var z: Float = 2
        while z > -40 {
            let x = trackX(z)
            let l = origin + SIMD3(x - 0.6, 0.3, z), r = origin + SIMD3(x + 0.6, 0.3, z)
            if let (pl, pr) = last {
                scene.rod(m, pl, l, radius: 0.035, color: rail, roughness: 0.2, metallic: 0.6, emissive: 0.5)
                scene.rod(m, pr, r, radius: 0.035, color: rail, roughness: 0.2, metallic: 0.6, emissive: 0.5)
            }
            // Sleepers and pylons every other sample.
            if Int((distance - z) / 1.5) % 2 == 0 {
                scene.rod(m, l - SIMD3(0, 0.05, 0), r - SIMD3(0, 0.05, 0), radius: 0.025, color: SIMD4(0.2, 0.2, 0.3, 1), roughness: 0.7)
                scene.rod(m, origin + SIMD3(x, 0, z), origin + SIMD3(x, 0.25, z), radius: 0.05, color: SIMD4(0.25, 0.25, 0.35, 1), roughness: 0.6, metallic: 0.3)
            }
            last = (l, r)
            z -= 1.5
        }
        // Arches every 6 m: a glowing ring the track passes through, with lamps on top.
        for i in 0..<7 {
            let az = -Float(i) * 6 + fmodf(distance, 6) - 2
            let ax = trackX(az)
            let centre = origin + SIMD3(ax, 1.6, az)
            let color = i % 2 == 0 ? SIMD4<Float>(0.3, 0.9, 1, 1) : SIMD4<Float>(1, 0.4, 0.9, 1)
            scene.add(m.ring, at: centre, rotation: G.pitch(.pi / 2), scale: SIMD3(1.6, 1, 1.6), color: color, roughness: 0.3, metallic: 0.4, emissive: 0.8, shadow: false)
            scene.rod(m, centre - SIMD3(1.6, 1.6, 0), centre + SIMD3(-1.6, 0, 0), radius: 0.05, color: SIMD4(0.25, 0.25, 0.35, 1), roughness: 0.6, metallic: 0.3)
            scene.rod(m, centre + SIMD3(1.6, -1.6, 0), centre + SIMD3(1.6, 0, 0), radius: 0.05, color: SIMD4(0.25, 0.25, 0.35, 1), roughness: 0.6, metallic: 0.3)
            scene.add(m.smallSphere, at: centre + SIMD3(0, 1.7, 0), scale: SIMD3(repeating: 0.12), color: G.white, emissive: 1.5, shadow: false)
            scene.glow(centre + SIMD3(0, 1.7, 0), size: 0.6, eye: eye, color: color * SIMD4(1, 1, 1, 0.5))
        }
        // Lamp posts along the sides every 3 m.
        for i in 0..<12 {
            let lz = -Float(i) * 3 + fmodf(distance, 3) - 1
            for side: Float in [-1, 1] {
                let base = origin + SIMD3(trackX(lz) + side * 3.5, 0, lz)
                scene.rod(m, base, base + SIMD3(0, 2.2, 0), radius: 0.04, color: SIMD4(0.3, 0.3, 0.4, 1), roughness: 0.5, metallic: 0.5)
                scene.add(m.smallSphere, at: base + SIMD3(0, 2.3, 0), scale: SIMD3(repeating: 0.15), color: SIMD4(1, 0.8, 0.4, 1), emissive: 1.4, shadow: false)
                scene.glow(base + SIMD3(0, 2.3, 0), size: 0.8, eye: eye, color: SIMD4(1, 0.7, 0.3, 0.35))
            }
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
    private static let names = ["Synthwave", "Deep sea", "Ember", "Frost"]
    static let palettes: [SIMD3<Float>] = [SIMD3(1, 0.2, 0.85), SIMD3(0.2, 0.7, 1), SIMD3(1, 0.5, 0.15), SIMD3(0.7, 0.9, 1)]
    var status: String { "In \(Self.names[world % Self.names.count])" }
    var onWorldChange: ((Int) -> Void)?

    func reset() { placed = false; world = 0; onWorldChange?(0) }

    func update(_ c: GameContext) {
        if !placed {
            let f = G.flat(c.forward)
            centre = SIMD3(c.headPosition.x, c.floorHeight + 1.1, c.headPosition.z) + f * 1.6
            normal = -f
            side = 1
            placed = true
        }
        particles.update(dt: c.dt)
        let now: Float = simd_dot(c.headPosition - centre, normal) >= 0 ? 1 : -1
        if now != side {
            let withinDoor = abs(simd_dot(c.headPosition - centre, simd_cross(normal, SIMD3(0, 1, 0)))) < 0.6
            if withinDoor {
                world = (world + (now < 0 ? 1 : Self.names.count - 1)) % Self.names.count
                onWorldChange?(world)
                particles.burst(at: c.headPosition + c.forward * 0.5, count: 50, speed: 1.5, color: SIMD4(Self.palettes[world], 1), life: 1, size: 0.03, gravity: 0)
                log("[Games] Portal: now in \(Self.names[world])")
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
