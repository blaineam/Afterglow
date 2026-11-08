import simd

// The roadmap's "more games": a tower on a real table, a glow garden, orbital pong between the
// hands, and a skyline drive steered with the head. Each is a catalog entry like the others.

// MARK: - Tower

/// Stacks sliding slabs on a real table (or a plinth, where no table has been found): a pinch or
/// tap drops the slab, the part past the stack below breaks off and falls, and the next is only
/// as big as what stayed. Missing the stack ends the game. Logs [Games].
final class TowerGame: Game {
    let title = "🏗️ Tower"
    struct Slab: Equatable { var centre: SIMD2<Float>; var size: SIMD2<Float> }

    /// What of a slab rests on the one below, or nil if none of it does.
    nonisolated static func overlap(_ moving: Slab, on base: Slab) -> Slab? {
        let low = simd_max(moving.centre - moving.size / 2, base.centre - base.size / 2)
        let high = simd_min(moving.centre + moving.size / 2, base.centre + base.size / 2)
        let size = high - low
        guard size.x > 0, size.y > 0 else { return nil }
        return Slab(centre: (low + high) / 2, size: size)
    }

    private struct Offcut { var position: SIMD3<Float>; var velocity: SIMD3<Float>; var size: SIMD3<Float>; var spin: Float; var age: Float; var color: SIMD4<Float> }
    private static let slabHeight: Float = 0.035
    private static let swing: Float = 0.2
    private static let snap: Float = 0.006

    private var placed = false
    private var onTable = false
    private var base = SIMD3<Float>.zero
    private var stack: [Slab] = []
    private var phase: Float = 0
    private var over = false
    private var perfects = 0
    private var offcuts: [Offcut] = []
    private var lowered: Float = 0
    private var particles = ParticleSystem()
    private var loweredTarget: Float { max(0, Float(stack.count) * Self.slabHeight - 0.3) }

    private var height: Int { max(0, stack.count - 1) }
    var status: String { over ? "Fell at \(height)" : (placed ? "\(height) high" + (perfects > 0 ? " · \(perfects) perfect" : "") : "Finding a table") }
    var summary: GameSummary? {
        guard over else { return nil }
        return GameSummary(title: "The tower stands at \(height)", lines: [
            ("Height", String(format: "%d slabs, %.0f cm", height, Float(height) * Self.slabHeight * 100)),
            ("Perfect drops", "\(perfects)"),
            ("Built on", onTable ? "Your table" : "A plinth"),
        ])
    }

    func reset() { placed = false; stack.removeAll(); over = false; perfects = 0; offcuts.removeAll(); lowered = 0; phase = 0 }

    private func place(_ c: GameContext) {
        let head = c.headPosition
        let tables = c.surfaces.filter { s in
            s.isHorizontal && s.center.y > c.floorHeight + 0.3 && s.center.y < head.y - 0.1 && s.classification != "ceiling"
                && simd_distance(SIMD2(s.center.x, s.center.z), SIMD2(head.x, head.z)) < 2
        }
        if let table = tables.min(by: { simd_distance($0.center, head) < simd_distance($1.center, head) }) {
            base = table.center
            onTable = true
        } else {
            base = head + G.flat(c.forward) * 0.65 - SIMD3(0, 0.5, 0)
            onTable = false
        }
        stack = [Slab(centre: .zero, size: SIMD2(0.16, 0.16))]
        placed = true
        log("[Games] Tower on " + (onTable ? "a table" : "a plinth"))
    }

    /// A tower already built, for the gallery's picture (Tools/capture_gallery.sh): the script
    /// cannot time a drop.
    func stackUp(_ levels: Int) {
        guard placed else { return }
        for i in 0..<levels {
            let top = stack[stack.count - 1]
            let nudge: Float = i % 3 == 2 ? 0.006 : 0
            let moved = Slab(centre: top.centre + (i % 2 == 0 ? SIMD2(nudge, 0) : SIMD2(0, nudge)), size: top.size)
            stack.append(Self.overlap(moved, on: top) ?? top)
        }
    }

    private var movingAlongX: Bool { stack.count % 2 == 1 }
    private var moving: Slab {
        let top = stack[stack.count - 1]
        let along = sin(phase) * Self.swing
        return Slab(centre: top.centre + (movingAlongX ? SIMD2(along, 0) : SIMD2(0, along)), size: top.size)
    }
    private func position(_ centre: SIMD2<Float>, level: Int) -> SIMD3<Float> {
        base + SIMD3(centre.x, (Float(level) + 0.5) * Self.slabHeight - lowered, centre.y)
    }
    private func color(_ level: Int) -> SIMD4<Float> { G.palette[level % G.palette.count] }

    func update(_ c: GameContext) {
        particles.update(dt: c.dt)
        if !placed { place(c) }
        for i in offcuts.indices {
            offcuts[i].velocity.y -= 9.8 * c.dt
            offcuts[i].position += offcuts[i].velocity * c.dt
            offcuts[i].age += c.dt
            offcuts[i].spin += c.dt * 4
        }
        offcuts.removeAll { $0.age > 2 }
        lowered += (loweredTarget - lowered) * min(1, c.dt * 4)
        guard !over else { return }
        phase += c.dt * (1.4 + Float(stack.count) * 0.07)
        guard c.select, !c.pointerOnInterface else { return }
        let drop = moving
        let top = stack[stack.count - 1]
        let level = stack.count
        guard let kept = Self.overlap(drop, on: top) else {
            let p = position(drop.centre, level: level)
            offcuts.append(Offcut(position: p, velocity: SIMD3(0, 0.2, 0), size: SIMD3(drop.size.x, Self.slabHeight, drop.size.y), spin: 0, age: 0, color: color(level)))
            over = true
            log("[Games] Tower fell at \(height)")
            return
        }
        if simd_length(drop.centre - top.centre) < Self.snap {
            stack.append(Slab(centre: top.centre, size: top.size))
            perfects += 1
            particles.burst(at: position(top.centre, level: level), count: 30, speed: 0.6, color: SIMD4(1, 0.95, 0.6, 1), life: 0.6, size: 0.02)
        } else {
            stack.append(kept)
            // The part that missed breaks off and falls.
            let delta = drop.centre - kept.centre
            let cutSize = SIMD2(movingAlongX ? drop.size.x - kept.size.x : kept.size.x, movingAlongX ? kept.size.y : drop.size.y - kept.size.y)
            let cutCentre = kept.centre + (movingAlongX
                ? SIMD2((delta.x > 0 ? 1 : -1) * (kept.size.x + cutSize.x) / 2, 0)
                : SIMD2(0, (delta.y > 0 ? 1 : -1) * (kept.size.y + cutSize.y) / 2))
            offcuts.append(Offcut(position: position(cutCentre, level: level), velocity: SIMD3(0, 0.1, 0), size: SIMD3(cutSize.x, Self.slabHeight, cutSize.y), spin: 0, age: 0, color: color(level)))
        }
        phase = -.pi / 2    // the next starts from the side
    }

    func draw(into scene: inout Scene3D, context c: GameContext) {
        guard placed else { return }
        let m = c.meshes
        if !onTable {
            scene.add(m.cylinder, at: base - SIMD3(0, 0.03, 0), scale: SIMD3(0.14, 0.06, 0.14), color: SIMD4(0.2, 0.2, 0.25, 1), roughness: 0.4, metallic: 0.5, shadow: false)
        }
        let first = max(0, stack.count - 16)
        for i in first..<stack.count {
            let s = stack[i]
            let p = position(s.centre, level: i)
            if p.y < base.y { continue }
            scene.add(m.box, at: p, scale: SIMD3(s.size.x, Self.slabHeight, s.size.y), color: i == 0 ? SIMD4(0.3, 0.3, 0.35, 1) : color(i), roughness: 0.35, shadow: false)
        }
        if !over {
            let s = moving
            let p = position(s.centre, level: stack.count)
            scene.add(m.box, at: p, scale: SIMD3(s.size.x, Self.slabHeight, s.size.y), color: color(stack.count), roughness: 0.3, emissive: 0.25, shadow: false)
        }
        for cut in offcuts {
            scene.add(m.box, at: cut.position, rotation: G.roll(cut.spin), scale: cut.size, color: cut.color, roughness: 0.4, shadow: false)
        }
        particles.draw(into: &scene, eye: c.headPosition)
    }
}

// MARK: - Glow garden

/// A garden that grows where you point: a pinch or tap plants a glowing stem on the surface the
/// pointing hand (or the gaze) aims at; it grows for a few seconds and sways. Nothing to win.
final class GardenGame: Game {
    let title = "🌱 Glow garden"
    private struct Plant { var root: SIMD3<Float>; var born: Double; var seed: Float; var height: Float; var color: SIMD4<Float>; var leaves: Int }
    private static let growSeconds: Float = 5
    private static let most = 40
    private var plants: [Plant] = []
    private var planted = 0
    private var particles = ParticleSystem()
    var status: String { plants.isEmpty ? "Pinch to plant" : "\(plants.count) growing" }

    func reset() { plants.removeAll(); planted = 0 }

    /// Where a ray lands: the nearest level surface it crosses, or the floor.
    nonisolated static func landing(origin: SIMD3<Float>, direction: SIMD3<Float>, floor: Float, tables: [(centre: SIMD3<Float>, extent: SIMD2<Float>)]) -> SIMD3<Float>? {
        guard direction.y < -0.02 else { return nil }
        var best: SIMD3<Float>?
        var nearest = Float.infinity
        for table in tables where table.centre.y < origin.y {
            let t = (table.centre.y - origin.y) / direction.y
            let hit = origin + direction * t
            if abs(hit.x - table.centre.x) <= table.extent.x, abs(hit.z - table.centre.z) <= table.extent.y, t < nearest { nearest = t; best = hit }
        }
        if let best { return best }
        let t = (floor - origin.y) / direction.y
        return t > 0 && t < 6 ? origin + direction * t : nil
    }

    func update(_ c: GameContext) {
        particles.update(dt: c.dt)
        guard c.select, !c.pointerOnInterface else { return }
        let eye = c.headPosition
        // Through the pinching hand where there is one, as you would point; else along the gaze.
        let aim = c.hands.first(where: \.pinched).map { simd_normalize($0.pinchPoint - eye) } ?? c.forward
        let tables = c.surfaces.filter(\.isHorizontal).map { (centre: $0.center, extent: $0.extent) }
        let root = Self.landing(origin: eye, direction: aim, floor: c.floorHeight, tables: tables) ?? (eye + G.flat(c.forward) * 1.2 + SIMD3(0, c.floorHeight - eye.y, 0))
        plants.append(Plant(root: root, born: c.time, seed: .random(in: 0...100), height: .random(in: 0.45...1.15), color: G.palette[planted % G.palette.count], leaves: .random(in: 2...5)))
        planted += 1
        if plants.count > Self.most { plants.removeFirst() }
        particles.burst(at: root + SIMD3(0, 0.02, 0), count: 18, speed: 0.35, color: G.palette[(planted - 1) % G.palette.count], life: 0.7, size: 0.018, gravity: -0.2)
    }

    func draw(into scene: inout Scene3D, context c: GameContext) {
        let m = c.meshes
        let eye = c.headPosition
        let stem = SIMD4<Float>(0.25, 0.75, 0.45, 1)
        for plant in plants {
            let age = Float(c.time - plant.born)
            let grown = min(1, age / Self.growSeconds)
            let ease = grown * grown * (3 - 2 * grown)
            let height = plant.height * max(ease, 0.02)
            let sway = sin(Float(c.time) * 0.9 + plant.seed) * 0.05 * height
            func point(_ t: Float) -> SIMD3<Float> {
                let bend = t * t
                return plant.root + SIMD3(cos(plant.seed) * bend * 0.1 * height + sway * bend, t * height, sin(plant.seed) * bend * 0.1 * height)
            }
            let segments = 5
            for i in 0..<segments {
                let radius = 0.013 * (1 - Float(i) / Float(segments)) + 0.004
                scene.rod(m, point(Float(i) / Float(segments)), point(Float(i + 1) / Float(segments)), radius: radius, color: stem, roughness: 0.6)
            }
            for leaf in 0..<plant.leaves {
                let t = (Float(leaf) + 1) / Float(plant.leaves + 1)
                guard ease > t * 0.8 else { continue }
                let a = plant.seed + Float(leaf) * 2.4
                let at = point(t) + SIMD3(cos(a), 0.15, sin(a)) * 0.06 * ease
                scene.add(m.smallSphere, at: at, rotation: G.yaw(-a), scale: SIMD3(0.07, 0.01, 0.03) * ease, color: stem * SIMD4(1.1, 1.2, 1.1, 1), roughness: 0.5, emissive: 0.2, shadow: false)
            }
            let tip = point(1)
            let pulse = 0.8 + 0.2 * sin(Float(c.time) * 2 + plant.seed)
            scene.add(m.smallSphere, at: tip, scale: SIMD3(repeating: 0.045 * ease + 0.006), color: plant.color, roughness: 0.3, emissive: 1.2, shadow: false)
            scene.glow(tip, size: (0.16 + 0.22 * ease) * pulse, eye: eye, color: SIMD4(plant.color.x, plant.color.y, plant.color.z, 0.5))
        }
        particles.draw(into: &scene, eye: eye)
    }
}

// MARK: - Orbital pong

/// A ball orbits a small sun on a plane in front of you and spirals slowly out; a hand (or the
/// gaze, or a controller's stick) is the paddle that knocks it back in. Past the ring it is lost,
/// and three lost ends the game; every return makes it faster.
final class OrbitalPong: Game {
    let title = "☄️ Orbital pong"
    struct Ball { var position: SIMD2<Float>; var velocity: SIMD2<Float> }
    nonisolated static let ringRadius: Float = 0.42
    nonisolated private static let gravity: Float = 0.22

    /// A step of the orbit: drawn to the sun, thrust along its way so the orbit grows.
    nonisolated static func step(_ ball: Ball, thrust: Float, dt: Float) -> Ball {
        var b = ball
        let r = max(simd_length(b.position), 0.06)
        b.velocity += -b.position / r * (gravity / (r * r)) * dt
        b.velocity *= 1 + thrust * dt
        b.position += b.velocity * dt
        return b
    }
    /// The ball knocked back: on a tighter orbit the same way round, at the speed of a circle there.
    nonisolated static func knocked(_ ball: Ball, speedUp: Float) -> Ball {
        let r = max(simd_length(ball.position), 0.06)
        let inward = ball.position / r * min(r, ringRadius * 0.55)
        let round = ball.position.x * ball.velocity.y - ball.position.y * ball.velocity.x >= 0 ? Float(1) : -1
        let tangent = SIMD2(-inward.y, inward.x) / max(simd_length(inward), 1e-3) * round
        let speed = (gravity / simd_length(inward)).squareRoot()
        return Ball(position: inward, velocity: tangent * speed * speedUp * 0.5 + tangent * speed * 0.5)
    }

    private var placed = false
    private var centre = SIMD3<Float>.zero, right = SIMD3<Float>(1, 0, 0), up = SIMD3<Float>(0, 1, 0)
    private var ball = Ball(position: SIMD2(0.2, 0), velocity: .zero)
    private var score = 0, best = 0, lives = 3
    private var paddles: [SIMD2<Float>] = []
    private var padPaddle = SIMD2<Float>(0, -OrbitalPong.ringRadius * 0.8)
    private var lastHit: Double = 0
    private var trail: [SIMD2<Float>] = []
    private var particles = ParticleSystem()
    private var over: Bool { lives <= 0 }
    private var thrust: Float { Self.baseThrust + Float(score) * 0.006 }
    nonisolated static let baseThrust: Float = 0.09
    var status: String { over ? "Out at \(score)" : "\(score) returned · \(lives) left" }
    var summary: GameSummary? {
        guard over else { return nil }
        return GameSummary(title: "Out of orbit", lines: [("Returned", "\(score)"), ("Best run", "\(best)")])
    }

    func reset() { placed = false; score = 0; lives = 3; trail.removeAll(); paddles.removeAll() }

    private func serve() {
        ball = Ball(position: SIMD2(Self.ringRadius * 0.45, 0), velocity: SIMD2(0, (Self.gravity / (Self.ringRadius * 0.45)).squareRoot()))
        trail.removeAll()
    }
    private func world(_ p: SIMD2<Float>) -> SIMD3<Float> { centre + right * p.x + up * p.y }
    private func onPlane(_ w: SIMD3<Float>) -> SIMD2<Float> { SIMD2(simd_dot(w - centre, right), simd_dot(w - centre, up)) }

    func update(_ c: GameContext) {
        particles.update(dt: c.dt)
        if !placed {
            let f = G.flat(c.forward)
            centre = c.headPosition + f * 0.6 - SIMD3(0, 0.12, 0)
            right = simd_normalize(simd_cross(f, SIMD3(0, 1, 0)))
            up = SIMD3(0, 1, 0)
            serve()
            placed = true
        }
        guard !over else { return }
        // The paddles: the palms; without hands the gaze on the plane, or the stick's own.
        paddles = c.hands.map { onPlane($0.joints[9]) }
        if paddles.isEmpty {
            if simd_length(c.stick) > 0.15 {
                padPaddle += c.stick * c.dt * 1.2
                if simd_length(padPaddle) > Self.ringRadius { padPaddle = simd_normalize(padPaddle) * Self.ringRadius }
                paddles = [padPaddle]
            } else {
                let normal = simd_cross(right, up)
                let facing = simd_dot(c.forward, normal)
                if abs(facing) > 1e-3 {
                    let t = simd_dot(centre - c.headPosition, normal) / facing
                    if t > 0 { paddles = [onPlane(c.headPosition + c.forward * t)] }
                }
            }
        }
        // Small steps: the sun's pull is sharp up close.
        let steps = 4
        for _ in 0..<steps { ball = Self.step(ball, thrust: thrust, dt: c.dt / Float(steps)) }
        trail.append(ball.position)
        if trail.count > 24 { trail.removeFirst() }
        if c.time - lastHit > 0.3, let paddle = paddles.first(where: { simd_distance($0, ball.position) < 0.075 }) {
            lastHit = c.time
            score += 1
            best = max(best, score)
            particles.burst(at: world(paddle), count: 22, speed: 0.5, color: SIMD4(0.5, 0.9, 1, 1), life: 0.4, size: 0.014, gravity: 0)
            ball = Self.knocked(ball, speedUp: 1 + Float(score) * 0.02)
        }
        if simd_length(ball.position) > Self.ringRadius {
            lives -= 1
            particles.burst(at: world(ball.position), count: 40, speed: 0.8, color: SIMD4(1, 0.4, 0.3, 1), life: 0.6, size: 0.02, gravity: 0)
            log("[Games] Orbital pong: lost one at \(score), \(lives) left")
            if !over { serve() }
        }
    }

    func draw(into scene: inout Scene3D, context c: GameContext) {
        guard placed else { return }
        let m = c.meshes
        let eye = c.headPosition
        let facing = G.look(SIMD3(0, 1, 0), up: simd_cross(right, up))
        scene.add(m.ring, at: centre, rotation: facing, scale: SIMD3(repeating: Self.ringRadius), color: over ? SIMD4(1, 0.3, 0.3, 1) : SIMD4(0.4, 0.8, 1, 1), roughness: 0.3, emissive: 0.9, shadow: false)
        scene.add(m.sphere, at: centre, scale: SIMD3(repeating: 0.035), color: SIMD4(1, 0.8, 0.3, 1), roughness: 0.3, emissive: 1.4, shadow: false)
        scene.glow(centre, size: 0.22, eye: eye, color: SIMD4(1, 0.7, 0.2, 0.5))
        for (i, t) in trail.enumerated() {
            let a = Float(i) / Float(max(trail.count, 1))
            scene.glow(world(t), size: 0.012 + 0.02 * a, eye: eye, color: SIMD4(0.5, 0.9, 1, 0.4 * a))
        }
        if !over {
            scene.add(m.smallSphere, at: world(ball.position), scale: SIMD3(repeating: 0.016), color: G.white, roughness: 0.2, emissive: 1, shadow: false)
            scene.glow(world(ball.position), size: 0.06, eye: eye, color: SIMD4(0.6, 0.95, 1, 0.8))
        }
        for paddle in paddles {
            scene.add(m.ring, at: world(paddle), rotation: facing, scale: SIMD3(repeating: 0.06), color: SIMD4(1, 0.4, 0.8, 1), roughness: 0.3, emissive: 1, shadow: false)
        }
        particles.draw(into: &scene, eye: eye)
    }
}

// MARK: - Skyline drive

/// A drive down a neon road at speed, steered by looking where you want to go (or a controller's
/// stick): rings to collect, pylons to miss, three shields. The room gives way to the synthwave
/// surroundings while it runs.
final class SkylineDrive: Game {
    let title = "🏎️ Skyline drive"
    private struct Thing { var ahead: Float; var x: Float; var ring: Bool }
    private struct Tower { var ahead: Float; var x: Float; var height: Float; var width: Float; var color: SIMD4<Float> }
    private static let roadHalf: Float = 5
    private static let hit: Float = 0.9
    private static let spawnAhead: Float = 130

    private var started = false
    private var anchor = SIMD3<Float>.zero, ahead = SIMD3<Float>(0, 0, -1), right = SIMD3<Float>(1, 0, 0)
    private var carX: Float = 0
    private var speed: Float = 12
    private var travelled: Float = 0
    private var shields = 3, rings = 0
    private var things: [Thing] = []
    private var towers: [Tower] = []
    private var nextSpawn: Float = 30
    private var flash: Float = 0
    private var particles = ParticleSystem()
    private var over: Bool { shields <= 0 }
    var hidesRoom: Bool { started && !over }
    var status: String { over ? "Crashed at \(Int(travelled)) m" : String(format: "%.0f km/h · %d rings · %d shields", speed * 3.6, rings, shields) }
    var summary: GameSummary? {
        guard over else { return nil }
        return GameSummary(title: "End of the road", lines: [
            ("Distance", String(format: "%.2f km", travelled / 1000)),
            ("Rings", "\(rings)"),
            ("Top speed", String(format: "%.0f km/h", speed * 3.6)),
        ], again: "Drive again")
    }

    func reset() { started = false; carX = 0; speed = 12; travelled = 0; shields = 3; rings = 0; things.removeAll(); towers.removeAll(); nextSpawn = 30; flash = 0 }

    /// Which way the head steers: its turn from straight ahead, full lock at 25 degrees.
    nonisolated static func steering(forward: SIMD3<Float>, ahead: SIMD3<Float>, right: SIMD3<Float>) -> Float {
        let level = SIMD3(forward.x, 0, forward.z)
        guard simd_length(level) > 0.1 else { return 0 }
        let angle = atan2(simd_dot(level, right), simd_dot(level, ahead))
        return max(-1, min(1, angle / (25 * .pi / 180)))
    }

    private func start(_ c: GameContext) {
        ahead = G.flat(c.forward)
        right = simd_normalize(simd_cross(ahead, SIMD3(0, 1, 0)))
        anchor = SIMD3(c.headPosition.x, c.floorHeight, c.headPosition.z)
        towers = (0..<40).map { i in
            let side: Float = i % 2 == 0 ? -1 : 1
            return Tower(ahead: Float(i / 2) * 12 + 10, x: side * .random(in: 9...16), height: .random(in: 6...28), width: .random(in: 3...6), color: G.palette[i % G.palette.count])
        }
        started = true
        log("[Games] Skyline drive started")
    }
    private func world(_ x: Float, _ along: Float, up: Float = 0) -> SIMD3<Float> {
        anchor + right * (x - carX) + ahead * along + SIMD3(0, up, 0)
    }

    func update(_ c: GameContext) {
        particles.update(dt: c.dt)
        flash = max(0, flash - c.dt * 2)
        if !started { start(c) }
        guard !over else { return }
        // The stick when it is used; otherwise the head.
        let steer = simd_length(c.stick) > 0.15 ? c.stick.x : Self.steering(forward: c.forward, ahead: ahead, right: right)
        carX = max(-Self.roadHalf, min(Self.roadHalf, carX + steer * 7 * c.dt))
        speed = min(45, speed + c.dt * 0.35)
        let move = speed * c.dt
        travelled += move
        nextSpawn -= move
        while nextSpawn <= 0 {
            nextSpawn += .random(in: 14...26)
            things.append(Thing(ahead: Self.spawnAhead, x: .random(in: -Self.roadHalf...Self.roadHalf), ring: Float.random(in: 0...1) < 0.35))
        }
        for i in things.indices {
            let before = things[i].ahead
            things[i].ahead -= move
            guard before > 0, things[i].ahead <= 0, abs(things[i].x - carX) < Self.hit else { continue }
            if things[i].ring {
                rings += 1
                particles.burst(at: world(carX, 3, up: 1.2), count: 30, speed: 2.5, color: SIMD4(1, 0.85, 0.3, 1), life: 0.5, size: 0.06, gravity: 0)
            } else {
                shields -= 1
                flash = 1
                particles.burst(at: world(carX, 3, up: 0.9), count: 50, speed: 4, color: SIMD4(1, 0.3, 0.3, 1), life: 0.6, size: 0.08, gravity: 3)
                log("[Games] Skyline drive: hit a pylon at \(Int(travelled)) m, \(shields) shields left")
            }
        }
        things.removeAll { $0.ahead < -3 }
        for i in towers.indices {
            towers[i].ahead -= move
            if towers[i].ahead < -6 { towers[i].ahead += 240 }
        }
    }

    func draw(into scene: inout Scene3D, context c: GameContext) {
        guard started else { return }
        let m = c.meshes
        let eye = c.headPosition
        let rot = G.look(ahead)
        // The road's edges and its centre dashes running by.
        let dash = travelled.truncatingRemainder(dividingBy: 6)
        for i in 0..<22 {
            let a = Float(i) * 6 - dash
            let b = a + 3
            let fade = max(0, 1 - a / 130)
            for x in [-Self.roadHalf - 1, Self.roadHalf + 1] {
                scene.streak(world(x, a, up: 0.03), world(x, a + 6, up: 0.03), width: 0.18, eye: eye, color: SIMD4(1, 0.2, 0.75, 0.9 * fade))
            }
            scene.streak(world(0, a, up: 0.02), world(0, b, up: 0.02), width: 0.1, eye: eye, color: SIMD4(0.3, 0.9, 1, 0.7 * fade))
        }
        for tower in towers where tower.ahead < 130 {
            scene.add(m.box, at: world(tower.x, tower.ahead, up: tower.height / 2), rotation: rot, scale: SIMD3(tower.width, tower.height, tower.width), color: tower.color * SIMD4(0.3, 0.3, 0.35, 1), roughness: 0.6, emissive: 0.15, shadow: false)
            scene.add(m.box, at: world(tower.x, tower.ahead, up: tower.height + 0.15), rotation: rot, scale: SIMD3(tower.width, 0.3, tower.width), color: tower.color, roughness: 0.4, emissive: 1.1, shadow: false)
        }
        for thing in things where thing.ahead > -3 {
            if thing.ring {
                scene.add(m.ring, at: world(thing.x, thing.ahead, up: 1.2), rotation: G.look(SIMD3(0, 1, 0), up: ahead), scale: SIMD3(repeating: 0.9), color: SIMD4(1, 0.85, 0.3, 1), roughness: 0.3, emissive: 1.3, shadow: false)
            } else {
                scene.add(m.cone, at: world(thing.x, thing.ahead, up: 0.8), scale: SIMD3(0.5, 1.6, 0.5), color: SIMD4(1, 0.35, 0.15, 1), roughness: 0.4, emissive: 0.9, shadow: false)
            }
        }
        // The car's bonnet under the eyes; it flashes red on a hit.
        let hood = SIMD4<Float>(0.08 + flash * 0.8, 0.09, 0.14, 1)
        scene.add(m.box, at: anchor + ahead * 1.25 + SIMD3(0, eye.y - anchor.y - 0.62, 0), rotation: rot, scale: SIMD3(1.1, 0.14, 1.1), color: hood, roughness: 0.25, metallic: 0.7, shadow: false)
        particles.draw(into: &scene, eye: eye)
    }
}
