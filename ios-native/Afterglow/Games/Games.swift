import simd
import Foundation

// MARK: - 3D painting

/// Pinch and move to draw a ribbon in the air; each new stroke takes the next colour. A double
/// tap (a select with no pinch) clears the last stroke.
@MainActor
final class PaintGame: Game {
    let title = "🎨 Paint"
    private var strokes: [(color: SIMD4<Float>, points: [SIMD3<Float>])] = []
    private var drawing: [Bool: Int] = [:]
    private static let colors: [SIMD4<Float>] = [SIMD4(1, 0.3, 0.8, 1), SIMD4(0.3, 0.9, 1, 1), SIMD4(1, 0.85, 0.3, 1), SIMD4(0.6, 1, 0.4, 1), SIMD4(0.7, 0.4, 1, 1)]
    var status: String { "\(strokes.count) strokes, \(strokes.reduce(0) { $0 + $1.points.count }) points" }

    func reset() { strokes.removeAll(); drawing.removeAll() }

    func update(_ c: GameContext) {
        for hand in c.hands {
            let tip = hand.joints[HandGeometry.indexTip]
            if hand.pinched {
                if let i = drawing[hand.isRight] {
                    if let last = strokes[i].points.last, simd_distance(last, tip) > 0.004 { strokes[i].points.append(tip) }
                } else {
                    strokes.append((Self.colors[strokes.count % Self.colors.count], [tip]))
                    drawing[hand.isRight] = strokes.count - 1
                }
            } else {
                drawing[hand.isRight] = nil
            }
        }
        if c.select && c.hands.allSatisfy({ !$0.pinched }) && !strokes.isEmpty { strokes.removeLast() }
    }

    func draw(into overlay: inout HandOverlay, context c: GameContext) {
        let eye = c.headPosition
        for stroke in strokes {
            for i in 1..<max(stroke.points.count, 1) {
                overlay.addBone(stroke.points[i - 1], stroke.points[i], width: 0.012, eye: eye, color: stroke.color)
            }
            if stroke.points.count == 1 { overlay.addSquare(stroke.points[0], size: 0.012, eye: eye, color: stroke.color) }
        }
    }
}

// MARK: - Alien blob shooter

/// Blobs drift in from around the room; a punch forward (the hand moving ahead faster than
/// 1.5 m/s) fires a bolt the way the head faces, from the hand. A blob that reaches you costs a
/// life. The owner's "defend your space from alien monsters".
@MainActor
final class BlobShooter: Game {
    let title = "👾 Blobs"
    private struct Blob { var position: SIMD3<Float>; var speed: Float; var phase: Float; var size: Float }
    private struct Bolt { var position: SIMD3<Float>; var velocity: SIMD3<Float>; var age: Float }
    private var blobs: [Blob] = []
    private var bolts: [Bolt] = []
    private var score = 0
    private var lives = 3
    private var spawnTimer: Float = 0
    private var fireCooldown: [Bool: Double] = [:]
    private let motion = HandMotionTracker()
    private var over = false
    var status: String { over ? "Game over: \(score)" : "Score \(score), lives \(lives)" }

    func reset() { blobs.removeAll(); bolts.removeAll(); score = 0; lives = 3; over = false; spawnTimer = 0 }

    func update(_ c: GameContext) {
        guard !over else { return }
        spawnTimer -= c.dt
        if spawnTimer <= 0 && blobs.count < 8 {
            spawnTimer = Float.random(in: 1.2...2.5)
            let angle = Float.random(in: -1.2...1.2)
            let forward = simd_normalize(SIMD3(c.forward.x, 0, c.forward.z))
            let dir = simd_quatf(angle: angle, axis: SIMD3(0, 1, 0)).act(forward)
            blobs.append(Blob(position: c.headPosition + dir * Float.random(in: 5...7) + SIMD3(0, Float.random(in: -0.6...0.6), 0),
                              speed: Float.random(in: 0.5...0.9), phase: Float.random(in: 0...6), size: Float.random(in: 0.18...0.3)))
        }
        // The punch: a hand moving forward fast fires a bolt from it along the head's gaze.
        for hand in motion.motions(c.hands, time: c.time) {
            let forwardSpeed = simd_dot(hand.velocity, c.forward)
            let last = fireCooldown[hand.isRight] ?? 0
            if forwardSpeed > 1.5 && c.time - last > 0.35 {
                fireCooldown[hand.isRight] = c.time
                bolts.append(Bolt(position: hand.position, velocity: c.forward * 9, age: 0))
            }
        }
        if c.select, c.hands.isEmpty {
            bolts.append(Bolt(position: c.headPosition + c.forward * 0.3 - SIMD3(0, 0.1, 0), velocity: c.forward * 9, age: 0))
        }
        for i in bolts.indices { bolts[i].position += bolts[i].velocity * c.dt; bolts[i].age += c.dt }
        bolts.removeAll { $0.age > 2 }
        for i in blobs.indices {
            let toHead = c.headPosition - blobs[i].position
            let distance = simd_length(toHead)
            blobs[i].position += toHead / max(distance, 0.01) * blobs[i].speed * c.dt
            blobs[i].position.y += sin(Float(c.time) * 2 + blobs[i].phase) * 0.004
        }
        var hit = Set<Int>()
        for (bi, bolt) in bolts.enumerated() {
            for (i, blob) in blobs.enumerated() where simd_distance(bolt.position, blob.position) < blob.size + 0.08 {
                hit.insert(i)
                bolts[bi].age = 10
                score += 10
            }
        }
        blobs = blobs.enumerated().filter { !hit.contains($0.offset) }.map(\.element)
        let reached = blobs.filter { simd_distance($0.position, c.headPosition) < 0.5 }
        if !reached.isEmpty {
            lives -= reached.count
            blobs.removeAll { simd_distance($0.position, c.headPosition) < 0.5 }
            if lives <= 0 { over = true; log("[Games] Blobs: game over at \(score)") }
        }
    }

    func draw(into overlay: inout HandOverlay, context c: GameContext) {
        let eye = c.headPosition
        for blob in blobs {
            let pulse = 1 + 0.1 * sin(Float(c.time) * 5 + blob.phase)
            overlay.addBall(blob.position, radius: blob.size * pulse, eye: eye, color: SIMD4(0.5, 1, 0.3, 1))
            overlay.addSquare(blob.position + SIMD3(0, blob.size * 0.5, 0), size: blob.size * 0.5, eye: eye, color: SIMD4(0.1, 0.1, 0.1, 1))
        }
        for bolt in bolts { overlay.addBone(bolt.position, bolt.position - simd_normalize(bolt.velocity) * 0.25, width: 0.03, eye: eye, color: SIMD4(1, 0.4, 0.9, 1)) }
    }
}

// MARK: - Vacuum the room

/// The floor (the detected floor, or the virtual one) is covered in dust marks; run a hand low
/// over them (or walk over them with the head directly above) to clean them. Done when the last
/// mark goes.
@MainActor
final class VacuumGame: Game {
    let title = "🧹 Vacuum"
    private var cells: [SIMD2<Int>: Bool] = [:]   // true = still dusty
    private var floor: Float = -1.6
    private let spacing: Float = 0.25
    private var seeded = false
    var status: String {
        let dusty = cells.values.filter { $0 }.count
        return cells.isEmpty ? "No floor yet" : (dusty == 0 ? "All clean!" : "\(dusty) of \(cells.count) to clean")
    }

    func reset() { cells.removeAll(); seeded = false }

    func update(_ c: GameContext) {
        floor = c.floorHeight
        if !seeded {
            // Dust over the detected floor surfaces, else a 4 m square round the player.
            let floors = c.surfaces.filter { $0.isHorizontal && abs($0.center.y - c.floorHeight) < 0.15 }
            if floors.isEmpty {
                let o = c.headPosition
                for x in -8...8 { for z in -8...8 { cells[SIMD2(Int(o.x / spacing) + x, Int(o.z / spacing) + z)] = true } }
            } else {
                for s in floors {
                    for v in s.vertices {
                        let p = v.position
                        cells[SIMD2(Int((p.x / spacing).rounded()), Int((p.z / spacing).rounded()))] = true
                    }
                    let cx = Int((s.center.x / spacing).rounded()), cz = Int((s.center.z / spacing).rounded())
                    let ex = Int(s.extent.x / spacing), ez = Int(s.extent.y / spacing)
                    for x in -ex...ex { for z in -ez...ez { cells[SIMD2(cx + x, cz + z)] = true } }
                }
            }
            seeded = true
        }
        var vacuums: [SIMD3<Float>] = c.hands.map { $0.joints[HandGeometry.wrist] }.filter { $0.y - floor < 0.45 }
        vacuums.append(SIMD3(c.headPosition.x, floor, c.headPosition.z))   // under the feet
        for v in vacuums {
            let cx = Int((v.x / spacing).rounded()), cz = Int((v.z / spacing).rounded())
            for x in -1...1 { for z in -1...1 { let k = SIMD2(cx + x, cz + z); if cells[k] == true { cells[k] = false } } }
        }
    }

    func draw(into overlay: inout HandOverlay, context c: GameContext) {
        let eye = c.headPosition
        for (k, dusty) in cells where dusty {
            let p = SIMD3(Float(k.x) * spacing, floor + 0.01, Float(k.y) * spacing)
            if simd_distance(p, eye) < 8 {
                overlay.addBone(p - SIMD3(0.05, 0, 0.05), p + SIMD3(0.05, 0, 0.05), width: 0.015, eye: p + SIMD3(0, 1, 0), color: SIMD4(0.8, 0.7, 0.5, 1))
                overlay.addBone(p - SIMD3(0.05, 0, -0.05), p + SIMD3(0.05, 0, -0.05), width: 0.015, eye: p + SIMD3(0, 1, 0), color: SIMD4(0.8, 0.7, 0.5, 1))
            }
        }
    }
}

// MARK: - Toy box

/// Toys with gravity: pinch in empty space to make one, pinch near one to grab and carry it,
/// let go to throw it; they fall to the floor and bounce off it and each other. The foundation
/// for models later.
@MainActor
final class ToyBox: Game {
    let title = "🧸 Toys"
    struct Toy { var position: SIMD3<Float>; var velocity: SIMD3<Float>; var size: Float; var color: SIMD4<Float>; var held: Bool? }
    private(set) var toys: [Toy] = []
    private var held: [Bool: Int] = [:]
    private var wasPinched: [Bool: Bool] = [:]
    private let motion = HandMotionTracker()
    private static let colors: [SIMD4<Float>] = [SIMD4(1, 0.3, 0.8, 1), SIMD4(0.3, 0.9, 1, 1), SIMD4(1, 0.85, 0.3, 1), SIMD4(0.6, 0.4, 1, 1)]
    var status: String { "\(toys.count) toys" }

    func reset() { toys.removeAll(); held.removeAll() }

    func update(_ c: GameContext) {
        let floor = c.floorHeight
        for hand in motion.motions(c.hands, time: c.time) {
            let was = wasPinched[hand.isRight] ?? false
            if hand.pinched {
                if let i = held[hand.isRight], toys.indices.contains(i) {
                    toys[i].position = hand.position
                    toys[i].velocity = hand.velocity
                } else if !was {
                    if let i = toys.indices.min(by: { simd_distance(toys[$0].position, hand.position) < simd_distance(toys[$1].position, hand.position) }),
                       simd_distance(toys[i].position, hand.position) < toys[i].size + 0.08 {
                        held[hand.isRight] = i
                    } else {
                        toys.append(Toy(position: hand.position, velocity: .zero, size: Float.random(in: 0.06...0.12), color: Self.colors[toys.count % Self.colors.count], held: nil))
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
            toys[i].velocity.y -= 9.8 * c.dt
            toys[i].position += toys[i].velocity * c.dt
            // The floor, and any horizontal surface under the toy (a table).
            var ground = floor
            for s in c.surfaces where s.isHorizontal {
                let local = (s.transform.inverse * SIMD4(toys[i].position, 1)).xyz
                if abs(local.x) <= s.extent.x && abs(local.z) <= s.extent.y && s.center.y <= toys[i].position.y + toys[i].size && s.center.y > ground {
                    ground = s.center.y
                }
            }
            if toys[i].position.y - toys[i].size / 2 < ground {
                toys[i].position.y = ground + toys[i].size / 2
                toys[i].velocity.y = -toys[i].velocity.y * 0.45
                toys[i].velocity.x *= 0.9
                toys[i].velocity.z *= 0.9
                if abs(toys[i].velocity.y) < 0.3 { toys[i].velocity.y = 0 }
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

    func draw(into overlay: inout HandOverlay, context c: GameContext) {
        for toy in toys { overlay.addCube(toy.position, size: toy.size, color: toy.color) }
    }
}

// MARK: - Golf

/// A ball on the floor ahead and a hole a few metres on; swing a hand through the ball (the
/// hand low and moving) to putt it. Strokes are counted; the ball drops when it reaches the hole.
@MainActor
final class GolfGame: Game {
    let title = "⛳ Golf"
    private var ball = SIMD3<Float>.zero
    private var velocity = SIMD3<Float>.zero
    private var hole = SIMD3<Float>.zero
    private var strokes = 0
    private var holed = false
    private var placed = false
    private var lastHit: Double = 0
    private let motion = HandMotionTracker()
    var status: String { holed ? "In the hole in \(strokes)!" : "\(strokes) strokes" }

    func reset() { placed = false; strokes = 0; holed = false; velocity = .zero }

    func update(_ c: GameContext) {
        let floor = c.floorHeight
        if !placed {
            let f = simd_normalize(SIMD3(c.forward.x, 0, c.forward.z))
            ball = SIMD3(c.headPosition.x, floor + 0.03, c.headPosition.z) + f * 0.7
            hole = SIMD3(c.headPosition.x, floor, c.headPosition.z) + f * 4 + simd_cross(f, SIMD3(0, 1, 0)) * 0.8
            placed = true
        }
        guard !holed else { return }
        for hand in motion.motions(c.hands, time: c.time) {
            let speed = simd_length(SIMD3(hand.velocity.x, 0, hand.velocity.z))
            if simd_distance(hand.position, ball) < 0.18 && speed > 0.6 && c.time - lastHit > 0.5 {
                lastHit = c.time
                strokes += 1
                velocity = SIMD3(hand.velocity.x, 0, hand.velocity.z) * 1.2
            }
        }
        if c.select, c.hands.isEmpty, c.time - lastHit > 0.5 {
            lastHit = c.time
            strokes += 1
            velocity = simd_normalize(SIMD3(c.forward.x, 0, c.forward.z)) * 2.5
        }
        ball += velocity * c.dt
        velocity *= max(0, 1 - 0.9 * c.dt)
        if simd_length(velocity) < 0.03 { velocity = .zero }
        if simd_distance(SIMD3(ball.x, 0, ball.z), SIMD3(hole.x, 0, hole.z)) < 0.09 && simd_length(velocity) < 1.5 {
            holed = true
            log("[Games] Golf: holed in \(strokes)")
        }
    }

    func draw(into overlay: inout HandOverlay, context c: GameContext) {
        let eye = c.headPosition
        // The hole: a dark disc and a flag.
        overlay.addSquare(hole + SIMD3(0, 0.005, 0), size: 0.2, eye: hole + SIMD3(0, 1, 0), color: SIMD4(0.05, 0.05, 0.08, 1))
        overlay.addBone(hole, hole + SIMD3(0, 1.0, 0), width: 0.015, eye: eye, color: SIMD4(0.9, 0.9, 0.9, 1))
        overlay.addBone(hole + SIMD3(0, 1.0, 0), hole + SIMD3(0.25, 0.85, 0), width: 0.12, eye: eye, color: SIMD4(1, 0.3, 0.4, 1))
        if !holed { overlay.addBall(ball, radius: 0.03, eye: eye, color: SIMD4(1, 1, 1, 1)) }
    }
}

// MARK: - Grid ride

/// A flight over the neon grid: the floor streams past below and the world banks with the head,
/// the sky and sun stay. Nothing in the room moves, so the ride is comfortable as a glide.
@MainActor
final class GridRide: Game {
    let title = "🎢 Ride"
    private(set) var distance: Float = 0
    private(set) var speed: Float = 3
    private(set) var bank: Float = 0
    var status: String { String(format: "%.0f m at %.1f m/s", distance, speed) }

    func reset() { distance = 0; speed = 3; bank = 0 }

    func update(_ c: GameContext) {
        speed = min(12, speed + c.dt * 0.3)
        distance += speed * c.dt
        // Looking left or right banks the glide that way.
        let yaw = atan2(c.forward.x, -c.forward.z)
        bank += (yaw * 0.5 - bank) * min(1, c.dt * 2)
        if c.select { speed = max(1, speed - 3) }
    }

    func draw(into overlay: inout HandOverlay, context c: GameContext) {
        // Gates streaming past, lit, to give the speed a shape; the floor's own scroll is in the renderer.
        let eye = c.headPosition
        for i in 0..<8 {
            let z = -Float(i) * 6 + fmodf(distance, 6)
            let x = sin((distance - z) * 0.08) * 1.5
            let base = SIMD3(x, c.floorHeight, z - 1) + SIMD3(eye.x, 0, eye.z)
            let color = SIMD4<Float>(0.3, 0.9, 1, 1)
            overlay.addBone(base + SIMD3(-1.2, 0, 0), base + SIMD3(-1.2, 2.4, 0), width: 0.06, eye: eye, color: color)
            overlay.addBone(base + SIMD3(1.2, 0, 0), base + SIMD3(1.2, 2.4, 0), width: 0.06, eye: eye, color: color)
            overlay.addBone(base + SIMD3(-1.2, 2.4, 0), base + SIMD3(1.2, 2.4, 0), width: 0.06, eye: eye, color: color)
        }
    }
}

// MARK: - Portal

/// A doorway ahead; walk through it (the head crossing its plane) and the surroundings change
/// to the next of the palettes; walk back for the previous. Each side of the doorway shows the
/// place beyond in its colour.
@MainActor
final class PortalGame: Game {
    let title = "🌀 Portal"
    private var placed = false
    private var centre = SIMD3<Float>.zero
    private var normal = SIMD3<Float>(0, 0, 1)
    private var side: Float = 1
    private(set) var world = 0
    private static let names = ["Synthwave", "Deep sea", "Ember", "Frost"]
    static let palettes: [SIMD3<Float>] = [SIMD3(1, 0.2, 0.85), SIMD3(0.2, 0.7, 1), SIMD3(1, 0.5, 0.15), SIMD3(0.7, 0.9, 1)]
    var status: String { "In \(Self.names[world % Self.names.count])" }
    var onWorldChange: ((Int) -> Void)?

    func reset() { placed = false; world = 0; onWorldChange?(0) }

    func update(_ c: GameContext) {
        if !placed {
            let f = simd_normalize(SIMD3(c.forward.x, 0, c.forward.z))
            centre = SIMD3(c.headPosition.x, c.floorHeight + 1.1, c.headPosition.z) + f * 1.6
            normal = -f
            side = 1
            placed = true
        }
        let now: Float = simd_dot(c.headPosition - centre, normal) >= 0 ? 1 : -1
        if now != side {
            let withinDoor = abs(simd_dot(c.headPosition - centre, simd_cross(normal, SIMD3(0, 1, 0)))) < 0.6
            if withinDoor {
                world = (world + (now < 0 ? 1 : Self.names.count - 1)) % Self.names.count
                onWorldChange?(world)
                log("[Games] Portal: now in \(Self.names[world])")
            }
            side = now
        }
    }

    func draw(into overlay: inout HandOverlay, context c: GameContext) {
        let eye = c.headPosition
        let right = simd_cross(normal, SIMD3(0, 1, 0))
        let color = SIMD4(Self.palettes[(world + 1) % Self.palettes.count], 1)
        let w: Float = 0.6, h: Float = 1.1
        let tl = centre - right * w + SIMD3(0, h, 0), tr = centre + right * w + SIMD3(0, h, 0)
        let bl = centre - right * w - SIMD3(0, h, 0), br = centre + right * w - SIMD3(0, h, 0)
        for (a, b) in [(tl, tr), (tr, br), (br, bl), (bl, tl)] { overlay.addBone(a, b, width: 0.05, eye: eye, color: color) }
        // A shimmer in the doorway.
        let t = Float(c.time)
        for i in 0..<6 {
            let y = centre.y - h + fmodf(t * 0.4 + Float(i) * 0.37, 2 * h)
            overlay.addBone(centre - right * (w - 0.05) + SIMD3(0, y - centre.y, 0), centre + right * (w - 0.05) + SIMD3(0, y - centre.y, 0), width: 0.01, eye: eye, color: color * 0.6)
        }
    }
}
