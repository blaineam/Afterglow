import Metal
import QuartzCore
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
    /// The pointer is on a window, the dock or the controls: a pinch now is for the interface,
    /// and a game must not paint, spawn or swing with it (owner, 2026-11-08: changing colours
    /// painted strokes).
    var pointerOnInterface: Bool = false
    /// A paired controller's left stick, for the games that steer.
    var stick: SIMD2<Float> = .zero
    var meshes: MeshLibrary
    var headPosition: SIMD3<Float> { head.columns.3.xyz }
    var forward: SIMD3<Float> { -head.columns.2.xyz }
}

/// The end of a game: a title, its numbers, and the label of the button that plays again.
struct GameSummary {
    var title: String
    var lines: [(String, String)]
    var again: String = String(localized: "Play again")
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
    /// Set when the game has ended (the blobs got through, the round is played, the ride is
    /// over): the host shows it with Play again and Exit (owner, 2026-11-08).
    var summary: GameSummary? { get }
    /// Play again after a summary.
    func again()
    /// The game is its own world just now: the room's passthrough makes no sense behind it.
    var hidesRoom: Bool { get }
}

extension Game {
    func draw(into overlay: inout HandOverlay, context: GameContext) {}
    var summary: GameSummary? { nil }
    func again() { reset() }
    var hidesRoom: Bool { false }
}

/// The games panel (a launcher of the games, with the running game's status and a reset) and
/// the running game. Games draw with the overlay primitives, so they are occluded by the room
/// and lit the same as everything else.
@MainActor
final class GameHost {
    let panel: ScenePanel
    /// The running game's own controls (the paint palette, the rhythm style and tempo, the golf
    /// holes), a window of their own rather than a crowd on the launcher (owner, 2026-11-07).
    let controlsPanel: ScenePanel
    /// A finished game's numbers, with Play again and Exit, hung in front of the player.
    let summaryPanel: ScenePanel
    /// Which game is running, by identity: picking another game while one runs is a change too
    /// (owner, 2026-11-08: the menu stayed open showing the new game's state).
    var currentID: ObjectIdentifier? { current.map { ObjectIdentifier($0) } }
    private(set) var games: [Game]
    private(set) var current: Game?
    private let device: MTLDevice
    let meshes: MeshLibrary

    /// The Music app, for the rhythm game to keep time to.
    var music: MusicApp? { didSet { games.compactMap { $0 as? RhythmGame }.forEach { $0.music = music } } }

    init(device: MTLDevice) {
        self.device = device
        meshes = MeshLibrary(device: device)
        panel = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 760)
        panel.pane.widthMeters = 1.2
        controlsPanel = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 300)
        summaryPanel = ScenePanel(device: device, pixelWidth: 1200, pixelHeight: 900)
        summaryPanel.pane.widthMeters = 0.9
        games = [PaintGame(), BlobShooter(), VacuumGame(), ToyBox(), GolfGame(), GridRide(), PortalGame(), RhythmGame(),
                 TowerGame(), GardenGame(), OrbitalPong(), SkylineDrive()]
        layout()
    }

    func open(head: simd_float4x4) {
        var w = BrowserWindow()
        w.place(ahead: head, distance: 1.4)
        panel.pane.centre = w.centre - SIMD3(0, 0.45, 0)
        panel.pane.right = w.right
        panel.pane.up = simd_quatf(angle: -0.4, axis: w.right).act(w.up)
    }

    /// The menu is only the games: the running one's state, restart and stop live in its controls
    /// window (owner, 2026-11-08: the menu kept showing the game's state and controls).
    private func layout() {
        var b: [ScenePanel.Button] = []
        for (i, game) in games.enumerated() {
            let col = i % 4, row = i / 4
            let parts = game.title.split(separator: " ", maxSplits: 1).map(String.init)
            b.append(.init(id: "game:\(i)", rect: CGRect(x: 0.02 + CGFloat(col) * 0.245, y: 0.24 + CGFloat(row) * 0.25, width: 0.235, height: 0.235),
                           label: parts.last ?? game.title, wide: true, icon: parts.first, style: .tile, accent: current === game))
        }
        panel.set(buttons: b, version: "games|\(current?.title ?? "")")
        layoutControls()
    }

    /// Whether the running game has controls of its own to show.
    var hasControls: Bool { current != nil }

    /// The controls window's content for the running game.
    private func layoutControls() {
        var b: [ScenePanel.Button] = []
        if let paint = current as? PaintGame {
            var x: CGFloat = 0.02
            for (i, (emoji, _)) in PaintGame.swatches.enumerated() {
                b.append(.init(id: "paint:color:\(i)", rect: CGRect(x: x, y: 0.06, width: 0.085, height: 0.42), label: emoji, style: .key, accent: paint.swatch == i))
                x += 0.09
            }
            b.append(.init(id: "paint:color:rainbow", rect: CGRect(x: x, y: 0.06, width: 0.085, height: 0.42), label: "🌈", style: .key, accent: paint.swatch == nil))
            b.append(.init(id: "paint:size", rect: CGRect(x: 0.02, y: 0.54, width: 0.22, height: 0.42), label: String(localized: "Size \(["S", "M", "L"][paint.sizeIndex])"), wide: true, icon: "circle.fill", style: .pill))
            b.append(.init(id: "paint:brush", rect: CGRect(x: 0.26, y: 0.54, width: 0.24, height: 0.42), label: paint.brush.name, wide: true, icon: paint.brush.icon, style: .pill))
            b.append(.init(id: "paint:dyn", rect: CGRect(x: 0.52, y: 0.54, width: 0.24, height: 0.42), label: String(localized: "Dynamics"), wide: true, icon: paint.dynamics ? "waveform.path" : "minus", style: .pill, accent: paint.dynamics))
            b.append(.init(id: "paint:undo", rect: CGRect(x: 0.78, y: 0.54, width: 0.2, height: 0.42), label: String(localized: "Undo"), wide: true, icon: "arrow.uturn.backward", style: .pill))
        } else if let rhythm = current as? RhythmGame {
            if !(music?.isPlaying ?? false) {
                // The built-in music's style; with Apple Music playing the song decides.
                b.append(.init(id: "style", rect: CGRect(x: 0.02, y: 0.06, width: 0.46, height: 0.42), label: rhythm.style.name, wide: true, icon: "music.quarternote.3", style: .pill))
            } else {
                b.append(.init(id: "music", rect: CGRect(x: 0.02, y: 0.06, width: 0.46, height: 0.42), label: "Apple Music", wide: true, icon: "music.note", style: .label))
            }
            b.append(.init(id: "tempo:-", rect: CGRect(x: 0.52, y: 0.06, width: 0.12, height: 0.42), label: String(localized: "Slower"), icon: "minus", style: .round))
            b.append(.init(id: "tempo", rect: CGRect(x: 0.65, y: 0.06, width: 0.2, height: 0.42), label: "\(Int(rhythm.bpm)) bpm", wide: true, style: .label))
            b.append(.init(id: "tempo:+", rect: CGRect(x: 0.86, y: 0.06, width: 0.12, height: 0.42), label: String(localized: "Faster"), icon: "plus", style: .round))
            b.append(.init(id: "reset", rect: CGRect(x: 0.02, y: 0.54, width: 0.46, height: 0.42), label: String(localized: "Restart"), wide: true, icon: "arrow.counterclockwise", style: .pill))
            b.append(.init(id: "stop", rect: CGRect(x: 0.52, y: 0.54, width: 0.46, height: 0.42), label: String(localized: "Stop"), wide: true, icon: "stop.fill", style: .pill))
        } else if current is GridRide {
            b.append(.init(id: "ride:world", rect: CGRect(x: 0.02, y: 0.06, width: 0.46, height: 0.42), label: String(localized: "Next world"), wide: true, icon: "globe.americas.fill", style: .pill))
            b.append(.init(id: "reset", rect: CGRect(x: 0.52, y: 0.06, width: 0.46, height: 0.42), label: String(localized: "New course"), wide: true, icon: "shuffle", style: .pill))
            b.append(.init(id: "ride:go", rect: CGRect(x: 0.02, y: 0.54, width: 0.46, height: 0.42), label: String(localized: "Ride"), wide: true, icon: "play.fill", style: .pill, accent: true))
            b.append(.init(id: "stop", rect: CGRect(x: 0.52, y: 0.54, width: 0.46, height: 0.42), label: String(localized: "Stop"), wide: true, icon: "stop.fill", style: .pill))
        } else if let toys = current as? ToyBox {
            b.append(.init(id: "toy:wake", rect: CGRect(x: 0.02, y: 0.06, width: 0.46, height: 0.42), label: toys.awake ? String(localized: "Back to sleep") : String(localized: "Come alive!"), wide: true, icon: toys.awake ? "moon.zzz.fill" : "sparkles", style: .pill, accent: !toys.awake))
            b.append(.init(id: "toy:new", rect: CGRect(x: 0.52, y: 0.06, width: 0.22, height: 0.42), label: String(localized: "New toy"), wide: true, icon: "plus", style: .pill))
            b.append(.init(id: "toy:tidy", rect: CGRect(x: 0.76, y: 0.06, width: 0.22, height: 0.42), label: String(localized: "Tidy up"), wide: true, icon: "shippingbox.fill", style: .pill))
            b.append(.init(id: "reset", rect: CGRect(x: 0.02, y: 0.54, width: 0.46, height: 0.42), label: String(localized: "Restart"), wide: true, icon: "arrow.counterclockwise", style: .pill))
            b.append(.init(id: "stop", rect: CGRect(x: 0.52, y: 0.54, width: 0.46, height: 0.42), label: String(localized: "Stop"), wide: true, icon: "stop.fill", style: .pill))
        } else if current is PortalGame {
            b.append(.init(id: "portal:through", rect: CGRect(x: 0.02, y: 0.06, width: 0.46, height: 0.42), label: String(localized: "Step through"), wide: true, icon: "figure.walk.motion", style: .pill, accent: true))
            b.append(.init(id: "portal:here", rect: CGRect(x: 0.52, y: 0.06, width: 0.46, height: 0.42), label: String(localized: "Move it in front of me"), wide: true, icon: "scope", style: .pill))
            b.append(.init(id: "reset", rect: CGRect(x: 0.02, y: 0.54, width: 0.46, height: 0.42), label: String(localized: "Back to the room"), wide: true, icon: "house.fill", style: .pill))
            b.append(.init(id: "stop", rect: CGRect(x: 0.52, y: 0.54, width: 0.46, height: 0.42), label: String(localized: "Stop"), wide: true, icon: "stop.fill", style: .pill))
        } else if current is BlobShooter || current is VacuumGame || current is TowerGame || current is GardenGame || current is OrbitalPong || current is SkylineDrive {
            b.append(.init(id: "reset", rect: CGRect(x: 0.02, y: 0.3, width: 0.46, height: 0.42), label: String(localized: "Restart"), wide: true, icon: "arrow.counterclockwise", style: .pill))
            b.append(.init(id: "stop", rect: CGRect(x: 0.52, y: 0.3, width: 0.46, height: 0.42), label: String(localized: "Stop"), wide: true, icon: "stop.fill", style: .pill))
        } else if current is GolfGame {
            b.append(.init(id: "golf:next", rect: CGRect(x: 0.02, y: 0.06, width: 0.46, height: 0.42), label: String(localized: "Next hole"), wide: true, icon: "flag.fill", style: .pill))
            b.append(.init(id: "golf:step", rect: CGRect(x: 0.52, y: 0.06, width: 0.46, height: 0.42), label: String(localized: "Step to the ball"), wide: true, icon: "figure.walk", style: .pill))
            b.append(.init(id: "reset", rect: CGRect(x: 0.02, y: 0.54, width: 0.46, height: 0.42), label: String(localized: "Restart the round"), wide: true, icon: "arrow.counterclockwise", style: .pill))
            b.append(.init(id: "stop", rect: CGRect(x: 0.52, y: 0.54, width: 0.46, height: 0.42), label: String(localized: "Stop"), wide: true, icon: "stop.fill", style: .pill))
        }
        let toyState = (current as? ToyBox).map { "\($0.awake)" } ?? ""
        let extra = toyState + ((current as? PaintGame).map { "\($0.swatch ?? -1)|\($0.sizeIndex)|\($0.brush)|\($0.dynamics)" } ?? ((current as? RhythmGame).map { "\($0.style)|\($0.bpm)|\(music?.isPlaying ?? false)" } ?? ""))
        controlsPanel.set(buttons: b, version: "controls|\(current?.title ?? "")|\(extra)")
    }

    /// The summary's rows and its two buttons.
    private func layoutSummary() {
        guard let summary = current?.summary else { summaryPanel.set(buttons: [], version: "summary|none"); return }
        var b: [ScenePanel.Button] = []
        let rowHeight: CGFloat = min(0.1, 0.5 / CGFloat(max(summary.lines.count, 1)))
        for (i, line) in summary.lines.enumerated() {
            b.append(.init(id: "sum:\(i)", rect: CGRect(x: 0.05, y: 0.2 + CGFloat(i) * (rowHeight + 0.01), width: 0.9, height: rowHeight), label: line.0, wide: true, style: .row, value: line.1))
        }
        b.append(.init(id: "again", rect: CGRect(x: 0.05, y: 0.78, width: 0.43, height: 0.17), label: summary.again, wide: true, icon: "arrow.counterclockwise", style: .pill, accent: true))
        b.append(.init(id: "exit", rect: CGRect(x: 0.52, y: 0.78, width: 0.43, height: 0.17), label: String(localized: "Exit game"), wide: true, icon: "xmark", style: .pill))
        summaryPanel.set(buttons: b, version: "summary|\(summary.title)|\(summary.lines.map { $0.0 + $0.1 }.joined())")
    }

    /// Hangs the summary ahead of the head, a little low, facing it.
    func placeSummary(head: simd_float4x4) {
        var w = BrowserWindow()
        w.place(ahead: head, distance: 1.1)
        summaryPanel.pane.centre = w.centre - SIMD3(0, 0.05, 0)
        summaryPanel.pane.right = w.right
        summaryPanel.pane.up = w.up
    }

    func renderSummary() {
        // A dark backing so the windows behind do not show through the numbers, and only the two
        // buttons light up under the gaze (the rows are not buttons).
        let hovered = summaryPanel.hovered.flatMap { $0 == "again" || $0 == "exit" ? $0 : nil }
        summaryPanel.render(ZStack {
            RoundedRectangle(cornerRadius: 64, style: .continuous).fill(Color(red: 0.07, green: 0.04, blue: 0.14).opacity(0.88))
            ButtonsView(size: CGSize(width: 1200, height: 900), buttons: summaryPanel.buttons, hovered: hovered,
                        title: current?.summary?.title, titleHighlight: true, subtitle: current?.title)
        })
    }

    func renderControls() {
        controlsPanel.render(ButtonsView(size: CGSize(width: 1600, height: 300), buttons: controlsPanel.buttons, hovered: controlsPanel.hovered,
                                         title: nil, titleHighlight: false, subtitle: current?.status))
    }

    func press(_ id: String) {
        switch id {
        case "reset": current?.reset()
        case "stop", "exit": if current != nil { log("[Games] \(id == "exit" ? "Exit from the summary" : "Stopped"): \(current!.title)") }; current = nil
        case "again": log("[Games] Play again: \(current?.title ?? "none")"); current?.again()
        case "toy:wake": (current as? ToyBox)?.pressButton(time: CACurrentMediaTime())
        case "toy:new": (current as? ToyBox)?.newToy()
        case "toy:tidy": (current as? ToyBox)?.tidy()
        case "portal:through": (current as? PortalGame)?.stepThrough()
        case "portal:here": (current as? PortalGame)?.moveHere()
        case "tempo:-": (current as? RhythmGame).map { $0.setTempo($0.bpm - 4) }
        case "tempo:+": (current as? RhythmGame).map { $0.setTempo($0.bpm + 4) }
        case "style": if !(music?.isPlaying ?? false) { (current as? RhythmGame)?.cycleStyle() }
        case "paint:size": (current as? PaintGame)?.cycleSize()
        case "paint:brush": (current as? PaintGame)?.cycleBrush()
        case "paint:dyn": (current as? PaintGame)?.toggleDynamics()
        case "paint:undo": (current as? PaintGame)?.undo()
        case "paint:color:rainbow": (current as? PaintGame)?.pick(swatch: nil)
        case "golf:next": (current as? GolfGame)?.nextHole()
        case "golf:step": (current as? GolfGame)?.stepToBallNow()
        case "ride:world": (current as? GridRide)?.onNextWorld?()
        case "ride:go": (current as? GridRide)?.go()
        default:
            if id.hasPrefix("paint:color:"), let i = Int(id.dropFirst(12)) { (current as? PaintGame)?.pick(swatch: i) }
            else if id.hasPrefix("game:"), let i = Int(id.dropFirst(5)), games.indices.contains(i) {
                current = games[i]
                current?.reset()
                log("[Games] Playing \(games[i].title)")
            }
        }
        layout()
        layoutSummary()
    }

    func start(_ index: Int) { press("game:\(index)") }

    func frame(_ context: GameContext, overlay: inout HandOverlay, scene: inout Scene3D) {
        guard let current else { return }
        current.update(context)
        current.draw(into: &scene, context: context)
        current.draw(into: &overlay, context: context)
        layout()
        layoutSummary()
    }

    func render() {
        panel.render(ButtonsView(size: CGSize(width: 1600, height: 760), buttons: panel.buttons, hovered: panel.hovered,
                                 title: String(localized: "Games"), titleHighlight: false, subtitle: current.map { String(localized: "Playing \($0.title): its controls have their own window") } ?? String(localized: "Pick a game")))
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
