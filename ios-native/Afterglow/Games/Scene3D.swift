import Metal
import simd

/// Generated meshes: smooth spheres, capsules, cylinders, cones, tori, rounded boxes, planes,
/// each with normals and texture coordinates, built once and kept on the GPU.
final class MeshLibrary {
    struct Mesh {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let indexCount: Int
    }
    private let device: MTLDevice
    private var meshes: [String: Mesh] = [:]

    init(device: MTLDevice) { self.device = device }

    func mesh(_ name: String, build: () -> ([MeshVertex], [UInt32])) -> Mesh {
        if let m = meshes[name] { return m }
        let (v, i) = build()
        let m = Mesh(vertices: device.makeBuffer(bytes: v, length: v.count * MemoryLayout<MeshVertex>.stride, options: .storageModeShared)!,
                     indices: device.makeBuffer(bytes: i, length: i.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)!,
                     indexCount: i.count)
        meshes[name] = m
        return m
    }

    /// A mesh rebuilt as its data changes (a paint stroke while it is drawn): the buffers grow as
    /// needed and the mesh under `name` is replaced.
    func dynamic(_ name: String, vertices: [MeshVertex], indices: [UInt32]) -> Mesh? {
        guard !vertices.isEmpty, !indices.isEmpty else { return nil }
        let vBytes = vertices.count * MemoryLayout<MeshVertex>.stride, iBytes = indices.count * MemoryLayout<UInt32>.stride
        var vBuffer = meshes[name]?.vertices, iBuffer = meshes[name]?.indices
        if vBuffer == nil || vBuffer!.length < vBytes { vBuffer = device.makeBuffer(length: max(vBytes * 2, 4096), options: .storageModeShared) }
        if iBuffer == nil || iBuffer!.length < iBytes { iBuffer = device.makeBuffer(length: max(iBytes * 2, 4096), options: .storageModeShared) }
        guard let vBuffer, let iBuffer else { return nil }
        vertices.withUnsafeBytes { vBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: vBytes) }
        indices.withUnsafeBytes { iBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: iBytes) }
        let m = Mesh(vertices: vBuffer, indices: iBuffer, indexCount: indices.count)
        meshes[name] = m
        return m
    }
    func forget(_ name: String) { meshes[name] = nil }
    func existing(_ name: String) -> Mesh? { meshes[name] }

    /// A smooth tube along a polyline: the points run through a Catmull-Rom spline (four
    /// samples a segment), the radii blend along it, and a ring of `sides` vertices is laid at
    /// each sample with a parallel-transported frame, so the tube has no kinks or twists. Caps
    /// close the ends. `flat` lays a ribbon instead: two vertices a sample, `width` across,
    /// facing `facing`.
    static func tube(points: [SIMD3<Float>], radii: [Float], sides: Int = 10, flat: Bool = false, facing: SIMD3<Float> = SIMD3(0, 0, 1)) -> ([MeshVertex], [UInt32]) {
        guard points.count >= 2 else {
            let p = points.first ?? .zero, r = radii.first ?? 0.01
            let (v, i) = sphere(rings: 6, segments: 10)
            return (v.map { MeshVertex(position: p + $0.position * r, normal: $0.normal, uv: $0.uv) }, i)
        }
        // Spline samples.
        var samples: [(SIMD3<Float>, Float)] = []
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let r1 = radii[min(i, radii.count - 1)], r2 = radii[min(i + 1, radii.count - 1)]
            let steps = 4
            for s in 0..<steps {
                let t = Float(s) / Float(steps)
                let t2 = t * t, t3 = t2 * t
                let p = 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
                samples.append((p, r1 + (r2 - r1) * t))
            }
        }
        samples.append((points.last!, radii.last ?? radii.first ?? 0.01))
        // Frames: a tangent per sample and a normal carried along (parallel transport).
        var vertices: [MeshVertex] = []
        var indices: [UInt32] = []
        var normal = SIMD3<Float>(0, 1, 0)
        var lastTangent = SIMD3<Float>(0, 0, -1)
        let ringSize = flat ? 2 : sides
        for (k, (p, r)) in samples.enumerated() {
            var tangent: SIMD3<Float>
            if k + 1 < samples.count { tangent = samples[k + 1].0 - p } else { tangent = p - samples[k - 1].0 }
            if simd_length(tangent) < 1e-6 { tangent = lastTangent } else { tangent = simd_normalize(tangent) }
            if k == 0 {
                var seed = abs(tangent.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
                if flat { seed = facing }
                normal = simd_normalize(seed - tangent * simd_dot(seed, tangent))
            } else {
                // Carry the normal: remove the part along the new tangent.
                normal = normal - tangent * simd_dot(normal, tangent)
                if simd_length(normal) < 1e-5 { normal = simd_normalize(simd_cross(tangent, lastTangent)) }
                normal = simd_normalize(normal)
            }
            lastTangent = tangent
            let binormal = simd_cross(tangent, normal)
            if flat {
                let side = simd_normalize(simd_cross(tangent, facing))
                let s = side * r
                vertices.append(MeshVertex(position: p - s, normal: facing, uv: SIMD2(0, Float(k) * 0.1)))
                vertices.append(MeshVertex(position: p + s, normal: facing, uv: SIMD2(1, Float(k) * 0.1)))
            } else {
                for j in 0..<sides {
                    let a = Float(j) / Float(sides) * 2 * .pi
                    let n = normal * cos(a) + binormal * sin(a)
                    vertices.append(MeshVertex(position: p + n * r, normal: n, uv: SIMD2(Float(j) / Float(sides), Float(k) * 0.1)))
                }
            }
            if k > 0 {
                let base = UInt32((k - 1) * ringSize), next = UInt32(k * ringSize)
                if flat {
                    indices += [base, base + 1, next, base + 1, next + 1, next, base, next, base + 1, base + 1, next, next + 1]   // both faces
                } else {
                    for j in 0..<sides {
                        let j2 = UInt32((j + 1) % sides)
                        let a = base + UInt32(j), b = base + j2, c = next + UInt32(j), d = next + j2
                        indices += [a, c, b, b, c, d]
                    }
                }
            }
        }
        if !flat {
            // Caps: a centre vertex and a fan at each end.
            for end in [0, samples.count - 1] {
                let (p, _) = samples[end]
                let tangent = end == 0 ? samples[0].0 - samples[1].0 : samples[end].0 - samples[end - 1].0
                let centre = UInt32(vertices.count)
                vertices.append(MeshVertex(position: p, normal: simd_normalize(tangent), uv: SIMD2(0.5, 0.5)))
                let ring = UInt32(end * sides)
                for j in 0..<sides {
                    let j2 = UInt32((j + 1) % sides)
                    if end == 0 { indices += [centre, ring + UInt32(j), ring + j2] } else { indices += [centre, ring + j2, ring + UInt32(j)] }
                }
            }
        }
        return (vertices, indices)
    }

    var sphere: Mesh { mesh("sphere") { Self.sphere(rings: 24, segments: 36) } }
    var smallSphere: Mesh { mesh("sphere12") { Self.sphere(rings: 12, segments: 18) } }
    var capsule: Mesh { mesh("capsule") { Self.capsule(rings: 10, segments: 24, length: 1) } }
    var cylinder: Mesh { mesh("cylinder") { Self.cylinder(segments: 32) } }
    var cone: Mesh { mesh("cone") { Self.cone(segments: 32) } }
    var torus: Mesh { mesh("torus") { Self.torus(major: 1, minor: 0.18, segments: 48, rings: 16) } }
    var ring: Mesh { mesh("ring") { Self.torus(major: 1, minor: 0.035, segments: 64, rings: 10) } }
    var box: Mesh { mesh("box") { Self.roundedBox(radius: 0.12, steps: 4) } }
    var plane: Mesh { mesh("plane") { Self.plane() } }
    var disc: Mesh { mesh("disc") { Self.cone(segments: 40, height: 0) } }

    // MARK: Builders (unit sizes: radius 1, the box 1 wide, the cylinder 1 tall along y)

    static func sphere(rings: Int, segments: Int) -> ([MeshVertex], [UInt32]) {
        var v: [MeshVertex] = []
        var i: [UInt32] = []
        for r in 0...rings {
            let lat = Float.pi * (Float(r) / Float(rings) - 0.5)
            for s in 0...segments {
                let lon = 2 * Float.pi * Float(s) / Float(segments)
                let n = SIMD3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
                v.append(MeshVertex(position: n, normal: n, uv: SIMD2(Float(s) / Float(segments), Float(r) / Float(rings))))
            }
        }
        for r in 0..<rings {
            for s in 0..<segments {
                let a = UInt32(r * (segments + 1) + s), b = a + UInt32(segments + 1)
                i += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        return (v, i)
    }

    static func capsule(rings: Int, segments: Int, length: Float) -> ([MeshVertex], [UInt32]) {
        // Two hemispheres joined by a cylinder along y, radius 1, the straight part `length`.
        var v: [MeshVertex] = []
        var i: [UInt32] = []
        let half = length / 2
        for r in 0...(rings * 2 + 1) {
            let lower = r <= rings
            let t = lower ? Float(r) / Float(rings) : Float(r - rings - 1) / Float(rings)
            let lat = lower ? -Float.pi / 2 + t * Float.pi / 2 : t * Float.pi / 2
            let yOffset: Float = lower ? -half : half
            for s in 0...segments {
                let lon = 2 * Float.pi * Float(s) / Float(segments)
                let n = SIMD3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
                v.append(MeshVertex(position: n + SIMD3(0, yOffset, 0), normal: n, uv: SIMD2(Float(s) / Float(segments), (n.y + yOffset + half + 1) / (length + 2))))
            }
        }
        let rows = rings * 2 + 1
        for r in 0..<rows {
            for s in 0..<segments {
                let a = UInt32(r * (segments + 1) + s), b = a + UInt32(segments + 1)
                i += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        return (v, i)
    }

    static func cylinder(segments: Int) -> ([MeshVertex], [UInt32]) {
        var v: [MeshVertex] = []
        var i: [UInt32] = []
        for s in 0...segments {
            let a = 2 * Float.pi * Float(s) / Float(segments)
            let n = SIMD3(cos(a), 0, sin(a))
            v.append(MeshVertex(position: SIMD3(n.x, -0.5, n.z), normal: n, uv: SIMD2(Float(s) / Float(segments), 0)))
            v.append(MeshVertex(position: SIMD3(n.x, 0.5, n.z), normal: n, uv: SIMD2(Float(s) / Float(segments), 1)))
        }
        for s in 0..<segments {
            let a = UInt32(s * 2)
            i += [a, a + 2, a + 1, a + 1, a + 2, a + 3]
        }
        // Caps.
        for (y, ny) in [(Float(-0.5), Float(-1)), (0.5, 1)] {
            let centre = UInt32(v.count)
            v.append(MeshVertex(position: SIMD3(0, y, 0), normal: SIMD3(0, ny, 0), uv: SIMD2(0.5, 0.5)))
            for s in 0...segments {
                let a = 2 * Float.pi * Float(s) / Float(segments)
                v.append(MeshVertex(position: SIMD3(cos(a), y, sin(a)), normal: SIMD3(0, ny, 0), uv: SIMD2(0.5 + cos(a) * 0.5, 0.5 + sin(a) * 0.5)))
            }
            for s in 0..<segments {
                let a = centre + 1 + UInt32(s)
                i += ny > 0 ? [centre, a + 1, a] : [centre, a, a + 1]
            }
        }
        return (v, i)
    }

    static func cone(segments: Int, height: Float = 1) -> ([MeshVertex], [UInt32]) {
        var v: [MeshVertex] = []
        var i: [UInt32] = []
        let tip = UInt32(0)
        v.append(MeshVertex(position: SIMD3(0, height, 0), normal: SIMD3(0, 1, 0), uv: SIMD2(0.5, 1)))
        for s in 0...segments {
            let a = 2 * Float.pi * Float(s) / Float(segments)
            let n = simd_normalize(SIMD3(cos(a), height > 0 ? 1 / max(height, 0.01) : 1, sin(a)))
            v.append(MeshVertex(position: SIMD3(cos(a), 0, sin(a)), normal: height > 0 ? n : SIMD3(0, 1, 0), uv: SIMD2(Float(s) / Float(segments), 0)))
        }
        for s in 0..<segments { i += [tip, UInt32(s + 2), UInt32(s + 1)] }
        let centre = UInt32(v.count)
        v.append(MeshVertex(position: .zero, normal: SIMD3(0, -1, 0), uv: SIMD2(0.5, 0.5)))
        for s in 0...segments {
            let a = 2 * Float.pi * Float(s) / Float(segments)
            v.append(MeshVertex(position: SIMD3(cos(a), 0, sin(a)), normal: SIMD3(0, -1, 0), uv: SIMD2(0.5 + cos(a) * 0.5, 0.5 + sin(a) * 0.5)))
        }
        for s in 0..<segments { i += [centre, centre + 1 + UInt32(s), centre + 2 + UInt32(s)] }
        return (v, i)
    }

    static func torus(major: Float, minor: Float, segments: Int, rings: Int) -> ([MeshVertex], [UInt32]) {
        var v: [MeshVertex] = []
        var i: [UInt32] = []
        for s in 0...segments {
            let a = 2 * Float.pi * Float(s) / Float(segments)
            let centre = SIMD3(cos(a) * major, 0, sin(a) * major)
            for r in 0...rings {
                let b = 2 * Float.pi * Float(r) / Float(rings)
                let n = SIMD3(cos(a) * cos(b), sin(b), sin(a) * cos(b))
                v.append(MeshVertex(position: centre + n * minor, normal: n, uv: SIMD2(Float(s) / Float(segments), Float(r) / Float(rings))))
            }
        }
        for s in 0..<segments {
            for r in 0..<rings {
                let a = UInt32(s * (rings + 1) + r), b = a + UInt32(rings + 1)
                i += [a, a + 1, b, b, a + 1, b + 1]
            }
        }
        return (v, i)
    }

    /// A box 1 unit across with rounded edges: the sphere's directions pushed onto a cube.
    static func roundedBox(radius: Float, steps: Int) -> ([MeshVertex], [UInt32]) {
        let (sv, si) = sphere(rings: steps * 4, segments: steps * 8)
        let v = sv.map { vertex -> MeshVertex in
            let n = vertex.normal
            let inner = SIMD3<Float>(repeating: 0.5 - radius)
            let clamped = simd_clamp(n * 10, -inner, inner)
            let p = clamped + simd_normalize(n) * radius
            let normal = simd_normalize(p - clamped)
            return MeshVertex(position: p, normal: normal, uv: vertex.uv)
        }
        return (v, si)
    }

    static func plane() -> ([MeshVertex], [UInt32]) {
        let n = SIMD3<Float>(0, 1, 0)
        let v = [MeshVertex(position: SIMD3(-0.5, 0, -0.5), normal: n, uv: SIMD2(0, 0)), MeshVertex(position: SIMD3(0.5, 0, -0.5), normal: n, uv: SIMD2(1, 0)),
                 MeshVertex(position: SIMD3(0.5, 0, 0.5), normal: n, uv: SIMD2(1, 1)), MeshVertex(position: SIMD3(-0.5, 0, 0.5), normal: n, uv: SIMD2(0, 1))]
        return (v, [0, 2, 1, 0, 3, 2])
    }
}

/// What a game asks to be drawn this frame: lit mesh instances, additive glows, and blob
/// shadows on the floor. Cleared every frame.
struct Scene3D {
    struct Draw {
        var mesh: MeshLibrary.Mesh
        var instance: MeshInstance
    }
    var draws: [Draw] = []
    var glows: [OverlayVertex] = []
    var shadows: [(SIMD3<Float>, Float, Float)] = []   // position on the floor, radius, strength
    var floorHeight: Float = -1.6

    mutating func clear() { draws.removeAll(keepingCapacity: true); glows.removeAll(keepingCapacity: true); shadows.removeAll(keepingCapacity: true) }

    static func transform(position: SIMD3<Float>, rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: SIMD3<Float>) -> simd_float4x4 {
        var m = simd_float4x4(rotation)
        m.columns.0 *= scale.x
        m.columns.1 *= scale.y
        m.columns.2 *= scale.z
        m.columns.3 = SIMD4(position, 1)
        return m
    }

    mutating func add(_ mesh: MeshLibrary.Mesh, at position: SIMD3<Float>, rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
                      scale: SIMD3<Float>, color: SIMD4<Float>, roughness: Float = 0.5, metallic: Float = 0, emissive: Float = 0, pattern: Float = 0, shadow: Bool = true) {
        let model = Self.transform(position: position, rotation: rotation, scale: scale)
        draws.append(Draw(mesh: mesh, instance: MeshInstance(model: model, color: color, roughness: roughness, metallic: metallic, emissive: emissive, pattern: pattern)))
        if shadow {
            let radius = max(scale.x, scale.z) * 1.1
            let height = max(0, position.y - floorHeight)
            shadows.append((SIMD3(position.x, floorHeight + 0.004, position.z), radius * (1 + height * 0.3), max(0.1, 0.6 - height * 0.15)))
        }
    }

    /// A camera-facing glow sprite, added to the frame, soft at its edges.
    mutating func glow(_ p: SIMD3<Float>, size: Float, eye: SIMD3<Float>, color: SIMD4<Float>) {
        let n = simd_normalize(eye - p)
        var up = SIMD3<Float>(0, 1, 0)
        if abs(simd_dot(n, up)) > 0.99 { up = SIMD3(1, 0, 0) }
        let right = simd_normalize(simd_cross(up, n)) * (size / 2)
        let upv = simd_normalize(simd_cross(n, right)) * (size / 2)
        let p0 = OverlayVertex(position: p - right - upv, color: color, uv: SIMD2(0, 0))
        let p1 = OverlayVertex(position: p + right - upv, color: color, uv: SIMD2(1, 0))
        let p2 = OverlayVertex(position: p + right + upv, color: color, uv: SIMD2(1, 1))
        let p3 = OverlayVertex(position: p - right + upv, color: color, uv: SIMD2(0, 1))
        glows += [p0, p1, p2, p0, p2, p3]
    }

    /// A glowing streak from a to b, soft across its width.
    mutating func streak(_ a: SIMD3<Float>, _ b: SIMD3<Float>, width: Float, eye: SIMD3<Float>, color: SIMD4<Float>) {
        let along = b - a
        var side = simd_cross(along, eye - (a + b) / 2)
        let length = simd_length(side)
        if length < 1e-6 { return }
        side = side / length * (width / 2)
        let p0 = OverlayVertex(position: a - side, color: color, uv: SIMD2(0.5, 0))
        let p1 = OverlayVertex(position: a + side, color: color, uv: SIMD2(0.5, 1))
        let p2 = OverlayVertex(position: b + side, color: color, uv: SIMD2(0.5, 1))
        let p3 = OverlayVertex(position: b - side, color: color, uv: SIMD2(0.5, 0))
        glows += [p0, p1, p2, p0, p2, p3]
    }
}

/// Particles for the games: sparks, dust, trails; updated on the CPU, drawn as glows.
struct ParticleSystem {
    struct Particle { var position: SIMD3<Float>; var velocity: SIMD3<Float>; var life: Float; var age: Float; var size: Float; var color: SIMD4<Float>; var gravity: Float }
    private(set) var particles: [Particle] = []

    mutating func burst(at p: SIMD3<Float>, count: Int, speed: Float, color: SIMD4<Float>, life: Float = 0.6, size: Float = 0.03, gravity: Float = 2) {
        for _ in 0..<count {
            let dir = simd_normalize(SIMD3(Float.random(in: -1...1), Float.random(in: -1...1), Float.random(in: -1...1)))
            particles.append(Particle(position: p, velocity: dir * speed * Float.random(in: 0.4...1), life: life * Float.random(in: 0.6...1), age: 0, size: size, color: color, gravity: gravity))
        }
        if particles.count > 2000 { particles.removeFirst(particles.count - 2000) }
    }

    mutating func update(dt: Float) {
        for i in particles.indices {
            particles[i].velocity.y -= particles[i].gravity * dt
            particles[i].velocity *= max(0, 1 - dt * 1.5)
            particles[i].position += particles[i].velocity * dt
            particles[i].age += dt
        }
        particles.removeAll { $0.age >= $0.life }
    }

    func draw(into scene: inout Scene3D, eye: SIMD3<Float>) {
        for p in particles {
            let t = 1 - p.age / p.life
            scene.glow(p.position, size: p.size * (0.5 + t), eye: eye, color: SIMD4(p.color.x, p.color.y, p.color.z, p.color.w * t))
        }
    }
}
