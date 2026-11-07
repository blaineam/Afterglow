import Metal
import simd
import SwiftUI

/// What a game sees each frame: the head, the hands, the room, the time, and the one-shot
/// select (a pinch beginning, a tap, a double tap).
struct GameContext {
    var head: simd_float4x4
    var hands: [TrackedHandState]
    var floorHeight: Float
    var surfaces: [RoomModel.Surface]
    var time: Double
    var dt: Float
    var select: Bool
    var meshes: MeshLibrary
    var headPosition: SIMD3<Float> { head.columns.3.xyz }
    var forward: SIMD3<Float> { -head.columns.2.xyz }
}

/// A game: updated every frame and drawn as lit meshes, glows and shadows into the scene (and,
/// for thin things like hand ribbons, the overlay), with a line of status for its panel.
@MainActor
protocol Game: AnyObject {
    var title: String { get }
    var status: String { get }
    func update(_ context: GameContext)
    func draw(into scene: inout Scene3D, context: GameContext)
    func draw(into overlay: inout HandOverlay, context: GameContext)
    func reset()
}

extension Game {
    func draw(into overlay: inout HandOverlay, context: GameContext) {}
}

/// The games panel (a launcher of the games, with the running game's status and a reset) and
/// the running game. Games draw with the overlay primitives, so they are occluded by the room
/// and lit the same as everything else.
@MainActor
final class GameHost {
    let panel: ScenePanel
    private(set) var games: [Game]
    private(set) var current: Game?
    private let device: MTLDevice
    let meshes: MeshLibrary

    /// The Music app, for the rhythm game to keep time to.
    var music: MusicApp? { didSet { games.compactMap { $0 as? RhythmGame }.forEach { $0.music = music } } }

    init(device: MTLDevice) {
        self.device = device
        meshes = MeshLibrary(device: device)
        panel = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 560)
        panel.pane.widthMeters = 1.2
        games = [PaintGame(), BlobShooter(), VacuumGame(), ToyBox(), GolfGame(), GridRide(), PortalGame(), RhythmGame()]
        layout()
    }

    func open(head: simd_float4x4) {
        var w = BrowserWindow()
        w.place(ahead: head, distance: 1.4)
        panel.pane.centre = w.centre - SIMD3(0, 0.45, 0)
        panel.pane.right = w.right
        panel.pane.up = simd_quatf(angle: -0.4, axis: w.right).act(w.up)
    }

    private func layout() {
        var b: [ScenePanel.Button] = []
        for (i, game) in games.enumerated() {
            let col = i % 4, row = i / 4
            let parts = game.title.split(separator: " ", maxSplits: 1).map(String.init)
            b.append(.init(id: "game:\(i)", rect: CGRect(x: 0.02 + CGFloat(col) * 0.2, y: 0.36 + CGFloat(row) * 0.32, width: 0.19, height: 0.3),
                           label: parts.last ?? game.title, wide: true, icon: parts.first, style: .tile, accent: current === game))
        }
        b.append(.init(id: "reset", rect: CGRect(x: 0.83, y: 0.36, width: 0.15, height: 0.3), label: "Restart", icon: "arrow.counterclockwise", style: .round))
        b.append(.init(id: "stop", rect: CGRect(x: 0.83, y: 0.68, width: 0.15, height: 0.3), label: "Stop", icon: "stop.fill", style: .round))
        if let rhythm = current as? RhythmGame {
            b.append(.init(id: "style", rect: CGRect(x: 0.42, y: 0.04, width: 0.22, height: 0.28), label: rhythm.style.name, wide: true, icon: "music.quarternote.3", style: .pill))
            b.append(.init(id: "tempo:-", rect: CGRect(x: 0.66, y: 0.04, width: 0.15, height: 0.28), label: "Slower", icon: "minus", style: .round))
            b.append(.init(id: "tempo:+", rect: CGRect(x: 0.83, y: 0.04, width: 0.15, height: 0.28), label: "Faster", icon: "plus", style: .round))
        }
        if let paint = current as? PaintGame {
            // The palette: the swatches, the rainbow, then size, brush, dynamics and undo.
            var x: CGFloat = 0.30
            for (i, (emoji, _)) in PaintGame.swatches.enumerated() {
                b.append(.init(id: "paint:color:\(i)", rect: CGRect(x: x, y: 0.04, width: 0.05, height: 0.28), label: emoji, style: .key, accent: paint.swatch == i))
                x += 0.052
            }
            b.append(.init(id: "paint:color:rainbow", rect: CGRect(x: x, y: 0.04, width: 0.05, height: 0.28), label: "🌈", style: .key, accent: paint.swatch == nil))
            x += 0.062
            b.append(.init(id: "paint:size", rect: CGRect(x: x, y: 0.04, width: 0.055, height: 0.28), label: ["S", "M", "L"][paint.sizeIndex], style: .round))
            x += 0.06
            b.append(.init(id: "paint:brush", rect: CGRect(x: x, y: 0.04, width: 0.055, height: 0.28), label: paint.brush.name, icon: paint.brush.icon, style: .round))
            x += 0.06
            b.append(.init(id: "paint:dyn", rect: CGRect(x: x, y: 0.04, width: 0.055, height: 0.28), label: "Dynamics", icon: paint.dynamics ? "waveform.path" : "minus", style: .round, accent: paint.dynamics))
            x += 0.06
            b.append(.init(id: "paint:undo", rect: CGRect(x: x, y: 0.04, width: 0.055, height: 0.28), label: "Undo", icon: "arrow.uturn.backward", style: .round))
        }
        if current is GolfGame {
            b.append(.init(id: "golf:next", rect: CGRect(x: 0.72, y: 0.04, width: 0.26, height: 0.28), label: "Next hole", wide: true, icon: "flag.fill", style: .pill))
        }
        let extra = (current as? PaintGame).map { "\($0.swatch ?? -1)|\($0.sizeIndex)|\($0.brush)|\($0.dynamics)" } ?? ""
        panel.set(buttons: b, version: "games|\(current?.title ?? "")|\(current?.status ?? "")|\(extra)")
    }

    func press(_ id: String) {
        switch id {
        case "reset": current?.reset()
        case "stop": current = nil
        case "tempo:-": (current as? RhythmGame).map { $0.setTempo($0.bpm - 4) }
        case "tempo:+": (current as? RhythmGame).map { $0.setTempo($0.bpm + 4) }
        case "style": (current as? RhythmGame)?.cycleStyle()
        case "paint:size": (current as? PaintGame)?.cycleSize()
        case "paint:brush": (current as? PaintGame)?.cycleBrush()
        case "paint:dyn": (current as? PaintGame)?.toggleDynamics()
        case "paint:undo": (current as? PaintGame)?.undo()
        case "paint:color:rainbow": (current as? PaintGame)?.pick(swatch: nil)
        case "golf:next": (current as? GolfGame)?.nextHole()
        default:
            if id.hasPrefix("paint:color:"), let i = Int(id.dropFirst(12)) { (current as? PaintGame)?.pick(swatch: i) }
            else if id.hasPrefix("game:"), let i = Int(id.dropFirst(5)), games.indices.contains(i) {
                current = games[i]
                current?.reset()
                log("[Games] Playing \(games[i].title)")
            }
        }
        layout()
    }

    func start(_ index: Int) { press("game:\(index)") }

    func frame(_ context: GameContext, overlay: inout HandOverlay, scene: inout Scene3D) {
        guard let current else { return }
        current.update(context)
        current.draw(into: &scene, context: context)
        current.draw(into: &overlay, context: context)
        layout()
    }

    func render() {
        panel.render(ButtonsView(size: CGSize(width: 1600, height: 560), buttons: panel.buttons, hovered: panel.hovered,
                                 title: current.map { $0.title } ?? "Games", titleHighlight: current != nil, subtitle: current?.status))
    }
}

// MARK: - Shared bits

extension HandOverlay {
    /// A ball as a small cube cross (three squares facing the eye) reads round enough at a glance.
    mutating func addBall(_ p: SIMD3<Float>, radius: Float, eye: SIMD3<Float>, color: SIMD4<Float>) {
        addSquare(p, size: radius * 2, eye: eye, color: color)
        addSquare(p, size: radius * 1.4, eye: eye, color: SIMD4(min(color.x * 1.3, 1), min(color.y * 1.3, 1), min(color.z * 1.3, 1), color.w))
    }
}

/// A pinching hand's point and its speed, for games that fire or throw.
struct HandMotion {
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var pinched: Bool
    var isRight: Bool
}

final class HandMotionTracker {
    private var last: [Bool: (SIMD3<Float>, Double)] = [:]

    func motions(_ hands: [TrackedHandState], time: Double) -> [HandMotion] {
        hands.map { hand in
            let p = hand.joints[HandGeometry.wrist]
            var v = SIMD3<Float>.zero
            if let (lp, lt) = last[hand.isRight], time > lt { v = (p - lp) / Float(min(time - lt, 0.1)) }
            last[hand.isRight] = (p, time)
            return HandMotion(position: p, velocity: v, pinched: hand.pinched, isRight: hand.isRight)
        }
    }
}
