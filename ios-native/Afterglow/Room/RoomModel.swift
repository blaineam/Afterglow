import ARKit
import simd

/// The surfaces ARKit found: each plane anchor's mesh in world space, kept up to date from the
/// session's anchor callbacks, and the floor's height (the lowest large horizontal plane). The
/// Unity app's `RoomBoundary`, as a model the renderer draws and the environments and games read.
final class RoomModel: @unchecked Sendable {
    struct Surface {
        let id: UUID
        var transform: simd_float4x4
        var vertices: [SurfaceVertex]
        var indices: [UInt32]
        var extent: SIMD2<Float>
        var isHorizontal: Bool
        var classification: String
        var center: SIMD3<Float> { (transform * SIMD4(0, 0, 0, 1)).xyz }
    }

    private let lock = NSLock()
    private var surfaces: [UUID: Surface] = [:]
    private(set) var floorHeight: Float?
    private var lastLog: Double = 0
    private var added = 0

    var all: [Surface] {
        lock.lock(); defer { lock.unlock() }
        return Array(surfaces.values)
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return surfaces.count }

    func update(_ anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let plane = anchor as? ARPlaneAnchor else { continue }
            let geometry = plane.planeExtent
            let extent = SIMD2(geometry.width / 2, geometry.height / 2)
            // The plane's mesh, with each vertex's place on the plane for the marks.
            var vertices: [SurfaceVertex] = []
            vertices.reserveCapacity(plane.geometry.vertices.count)
            for v in plane.geometry.vertices {
                let world = (plane.transform * SIMD4(v, 1)).xyz
                vertices.append(SurfaceVertex(position: world, local: SIMD2(v.x, v.z), extent: extent))
            }
            let indices = plane.geometry.triangleIndices.map { UInt32($0) }
            let surface = Surface(id: plane.identifier, transform: plane.transform, vertices: vertices, indices: indices, extent: extent,
                                  isHorizontal: plane.alignment == .horizontal, classification: Self.name(plane.classification))
            lock.lock()
            if surfaces[plane.identifier] == nil { added += 1 }
            surfaces[plane.identifier] = surface
            lock.unlock()
        }
        recomputeFloor()
    }

    func remove(_ anchors: [ARAnchor]) {
        lock.lock()
        for anchor in anchors { surfaces[anchor.identifier] = nil }
        lock.unlock()
        recomputeFloor()
    }

    /// A synthetic room for the Simulator: a floor and a wall ahead.
    func addFake(floorY: Float) {
        func plane(id: UUID, transform: simd_float4x4, w: Float, h: Float, horizontal: Bool, name: String) -> Surface {
            let corners: [SIMD3<Float>] = [SIMD3(-w / 2, 0, -h / 2), SIMD3(w / 2, 0, -h / 2), SIMD3(w / 2, 0, h / 2), SIMD3(-w / 2, 0, h / 2)]
            let vertices = corners.map { c in SurfaceVertex(position: (transform * SIMD4(c, 1)).xyz, local: SIMD2(c.x, c.z), extent: SIMD2(w / 2, h / 2)) }
            return Surface(id: id, transform: transform, vertices: vertices, indices: [0, 1, 2, 0, 2, 3], extent: SIMD2(w / 2, h / 2), isHorizontal: horizontal, classification: name)
        }
        let floor = plane(id: UUID(), transform: simd_float4x4.translation(SIMD3(0, floorY, -1)), w: 4, h: 4, horizontal: true, name: "floor")
        var wallTransform = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0)))
        wallTransform.columns.3 = SIMD4(0, floorY + 1.3, -2.5, 1)
        let wall = plane(id: UUID(), transform: wallTransform, w: 4, h: 2.6, horizontal: false, name: "wall")
        lock.lock()
        surfaces[floor.id] = floor
        surfaces[wall.id] = wall
        lock.unlock()
        recomputeFloor()
        log("[Room] Fake floor and wall added for the desk")
    }

    private func recomputeFloor() {
        lock.lock()
        let candidates = surfaces.values.filter { $0.isHorizontal && $0.extent.x * $0.extent.y * 4 >= 0.5 }
        let lowest = candidates.map { $0.center.y }.min()
        lock.unlock()
        if let lowest, floorHeight == nil || abs(lowest - floorHeight!) > 0.02 {
            floorHeight = lowest
            log(String(format: "[Room] Floor at %.2f m", lowest))
        }
    }

    func logStatus(now: Double) {
        guard now - lastLog >= 5 else { return }
        lastLog = now
        lock.lock()
        let n = surfaces.count
        let horizontal = surfaces.values.filter(\.isHorizontal).count
        let names = Dictionary(grouping: surfaces.values, by: \.classification).mapValues(\.count)
        lock.unlock()
        if n > 0 {
            log("[Room] \(n) surfaces (\(horizontal) horizontal): " + names.map { "\($0.value) \($0.key)" }.sorted().joined(separator: ", ") +
                (floorHeight.map { String(format: ", floor %.2f m", $0) } ?? ""))
        }
    }

    private static func name(_ c: ARPlaneAnchor.Classification) -> String {
        switch c {
        case .wall: return "wall"
        case .floor: return "floor"
        case .ceiling: return "ceiling"
        case .table: return "table"
        case .seat: return "seat"
        case .door: return "door"
        case .window: return "window"
        case .none: return "surface"
        @unknown default: return "surface"
        }
    }
}
