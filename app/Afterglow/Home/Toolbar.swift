import Metal
import simd
import Foundation

/// The apps the toolbar launches. Recently opened ones come first on it.
enum AppKind: String, CaseIterable, Codable, Sendable {
    case browser, media, files, environments, games, settings

    var label: String {
        switch self {
        case .browser: return "🌐 Browser"
        case .media: return "🖼 Media"
        case .files: return "📁 Files"
        case .environments: return "🌄 Places"
        case .games: return "🎮 Games"
        case .settings: return "⚙ Settings"
        }
    }
}

/// What the toolbar shows and does: quick toggles (passthrough, hands, 3DoF, recentre), the
/// recently opened apps as a launcher, and More, which opens the menu with the settings behind
/// it. A small pane hung low in front; the owner's ask (2026-11-06): quick toggles plus a launcher
/// of recent apps with a More button, settings behind the menu.
@MainActor
final class Toolbar {
    let panel: ScenePanel
    /// A second row above the dock for the minimized windows and the music, so the dock's six
    /// tiles keep their size (owner, 2026-11-08: a full dock felt squashed).
    let tray: ScenePanel
    let menu: ScenePanel
    private(set) var menuOpen = false
    /// The dock shows only when asked: a round Apps button at the feet (straight down) brings it
    /// for ten seconds (owner, 2026-11-07); the button hides during WebXR and 360 playback.
    private(set) var dockShown = false
    private var dockShownAt: Double = 0
    static let dockSeconds: Double = 10
    private(set) var recents: [AppKind] = [.browser, .media, .files, .environments, .games]
    private let recentsKey = "toolbar.recents"
    var settings: Settings
    /// Set by the owner of the toolbar: what each button does.
    var onLaunch: ((AppKind) -> Void)?
    var onRecentre: (() -> Void)?
    var onCloseApp: (() -> Void)?
    var onRecord: ((Int) -> Void)?
    var onMore: (() -> Void)?
    /// The minimized windows, shown on the dock as chips that bring them back.
    var minimized: [WindowKind] = [] { didSet { if minimized != oldValue { layout() } } }
    var onRestore: ((WindowKind) -> Void)?
    /// Music on the dock: nil when nothing is queued, else whether it plays; three small controls.
    var musicPlaying: Bool? = nil { didSet { if musicPlaying != oldValue { layout() } } }
    var onMusic: ((String) -> Void)?
    /// On the coaster the Apps button becomes the way off the ride.
    var riding = false { didSet { if riding != oldValue { layout() } } }
    var isRecording: () -> Bool = { false }

    init(device: MTLDevice, settings: Settings) {
        self.settings = settings
        panel = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 320)
        panel.pane.widthMeters = 1.5
        tray = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 200)
        tray.pane.widthMeters = 1.3
        menu = ScenePanel(device: device, pixelWidth: 400, pixelHeight: 400)
        menu.pane.widthMeters = 0.28
        if let saved = UserDefaults.standard.array(forKey: recentsKey) as? [String] {
            let kinds = saved.compactMap(AppKind.init(rawValue:))
            if !kinds.isEmpty { recents = kinds + AppKind.allCases.filter { !kinds.contains($0) && $0 != .settings } }
        }
        layout()
    }

    func noteOpened(_ app: AppKind) {
        guard app != .settings else { return }
        recents.removeAll { $0 == app }
        recents.insert(app, at: 0)
        UserDefaults.standard.set(recents.map(\.rawValue), forKey: recentsKey)
        layout()
    }

    /// The dock, for a while; a press on it keeps it a while longer.
    func showDock(time: Double) { dockShown = true; dockShownAt = time }
    func hideDock() { dockShown = false }
    func tick(time: Double) { if dockShown && time - dockShownAt > Self.dockSeconds { dockShown = false } }

    /// The Apps button lies flat on the floor half a metre ahead of the feet; on a ride, where
    /// the world may be upside down, it hangs a metre below the head in the rider's frame (its
    /// `up`), ahead of the feet, so it is always in the same place to look down at.
    func placeFeet(head: simd_float4x4, floor: Float, rideUp: SIMD3<Float>? = nil) {
        let position = head.columns.3.xyz
        let up = rideUp.map { simd_normalize($0) } ?? SIMD3(0, 1, 0)
        var f = -head.columns.2.xyz
        f -= up * simd_dot(f, up)
        if simd_length(f) < 1e-3 { f = simd_normalize(simd_cross(up, head.columns.0.xyz)) }
        f = simd_normalize(f)
        if rideUp == nil {
            menu.pane.centre = SIMD3(position.x, floor + 0.03, position.z) + f * 0.45
        } else {
            menu.pane.centre = position - up * 1.0 + f * 0.45
        }
        menu.pane.right = simd_normalize(simd_cross(f, up))
        menu.pane.up = f
    }

    /// Hangs the toolbar low ahead of the head and the menu above it.
    func place(ahead head: simd_float4x4, below ceiling: Float? = nil) {
        var w = BrowserWindow()
        w.place(ahead: head, distance: 1.1)
        let position = head.columns.3.xyz
        panel.pane.right = w.right
        panel.pane.up = w.up
        panel.pane.centre = w.centre - SIMD3(0, 0.55, 0)
        // Under the windows: the top of the dock with its tray stays below `ceiling`, as far down
        // as can still be looked at.
        if let ceiling {
            let top = panel.pane.centre.y + panel.pane.heightMeters / 2 + tray.pane.heightMeters + 0.05
            if top > ceiling { panel.pane.centre.y = max(panel.pane.centre.y - (top - ceiling), w.centre.y - 1.05) }
        }
        // Tilted up to face a head looking down at it.
        let tilt = simd_quatf(angle: -0.5, axis: w.right)
        panel.pane.up = tilt.act(w.up)
        _ = position
        menu.pane.right = w.right
        menu.pane.up = w.up
        menu.pane.centre = w.centre + SIMD3(0, 0.05, 0)
        placeTray()
    }

    /// The tray sits just above the dock, tilted the same.
    private func placeTray() {
        tray.pane.right = panel.pane.right
        tray.pane.up = panel.pane.up
        tray.pane.centre = panel.pane.centre + panel.pane.up * (panel.pane.heightMeters / 2 + tray.pane.heightMeters / 2 + 0.025)
    }

    /// Whether the tray has anything on it.
    var trayShown: Bool { dockShown && (!minimized.isEmpty || musicPlaying != nil) }

    func layout() {
        // The dock: six large tiles, an icon over a word each.
        var buttons: [ScenePanel.Button] = []
        let tiles: [(String, String, String)] = [
            ("more", "square.grid.2x2.fill", "Apps"),
            ("toggle:passthrough", settings.passthrough ? "eye.fill" : "sparkles", settings.passthrough ? "Room" : "Scene"),
            ("toggle:hands", settings.showHandsLive ? "hand.raised.fill" : "hand.raised.slash", "Hands"),
            ("recentre", "scope", "Recentre"),
            ("record:0", isRecording() ? "stop.circle.fill" : "record.circle", isRecording() ? "Stop" : "Record"),
            ("app:settings", "gearshape.fill", "Settings"),
        ]
        let gap: CGFloat = 0.008
        let w = (1 - gap * CGFloat(tiles.count - 1)) / CGFloat(tiles.count)
        var x: CGFloat = 0
        for (id, icon, label) in tiles {
            buttons.append(.init(id: id, rect: CGRect(x: x, y: 0.06, width: w, height: 0.88), label: label, wide: true, icon: icon, style: .tile,
                                 accent: id == "toggle:passthrough" && settings.passthrough || id == "record:0" && isRecording()))
            x += w + gap
        }
        // The tray: a pill per minimized window, then the music's three controls, each a fixed
        // size from the left, so a crowded tray stays readable (up to six windows).
        var trayButtons: [ScenePanel.Button] = []
        var tx: CGFloat = 0.01
        let chipWidth: CGFloat = 0.24
        for kind in minimized.prefix(musicPlaying == nil ? 4 : 3) {
            let icon: String
            switch kind {
            case .browser: icon = "safari.fill"; case .media: icon = "photo.on.rectangle.angled"; case .files: icon = "folder.fill"; case .games: icon = "gamecontroller.fill"
            case .places: icon = "mountain.2.fill"; case .music: icon = "music.note"; case .settings: icon = "gearshape.fill"; case .home: icon = "square.grid.2x2.fill"; case .gameControls: icon = "slider.horizontal.3"
            }
            trayButtons.append(.init(id: "win:\(kind.rawValue)", rect: CGRect(x: tx, y: 0.1, width: chipWidth, height: 0.8), label: kind.title, wide: true, icon: icon, style: .pill, accent: true))
            tx += chipWidth + 0.01
        }
        if let playing = musicPlaying {
            let controls: [(String, String, String)] = [("music:prev", "backward.fill", "Back"), ("music:play", playing ? "pause.fill" : "play.fill", playing ? "Pause" : "Play"), ("music:next", "forward.fill", "Next")]
            var mx: CGFloat = 1 - 0.01 - 3 * 0.08 - 2 * 0.005
            for (id, icon, label) in controls {
                trayButtons.append(.init(id: id, rect: CGRect(x: mx, y: 0.1, width: 0.08, height: 0.8), label: label, icon: icon, style: .round, accent: id == "music:play"))
                mx += 0.085
            }
        }
        tray.set(buttons: trayButtons, version: "tray|\(minimized.map(\.rawValue).joined())|\(String(describing: musicPlaying))")
        panel.set(buttons: buttons, version: "dock|\(settings.passthrough)|\(settings.showHandsLive)|\(isRecording())|\(minimized.map(\.rawValue).joined())|\(String(describing: musicPlaying))")
        menu.set(buttons: [.init(id: "feet", rect: CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84), label: riding ? "Exit ride" : "Apps", icon: riding ? "xmark" : "square.grid.2x2.fill", style: .round, accent: true, light: riding ? 1 : 0)], version: "feet|\(riding)")
    }

    func press(_ id: String) {
        switch id {
        case "toggle:passthrough": settings.passthrough.toggle()
        case "toggle:hands": settings.showHandsLive.toggle()
        case "toggle:dof": settings.degreesOfFreedom = settings.degreesOfFreedom == 3 ? 6 : 3
        case "toggle:surfaces": settings.surfaces.toggle()
        case "toggle:occlusion": settings.occlusion.toggle()
        case "record:0": onRecord?(0)
        case "record:1": onRecord?(1)
        case "recentre": onRecentre?()
        case "more": if let onMore { onMore() } else { menuOpen = true }
        case "closemenu": menuOpen = false
        case "closeapp": onCloseApp?(); menuOpen = false
        case "minus:renderScale": settings.renderScalePercent = max(25, settings.renderScalePercent - 10)
        case "plus:renderScale": settings.renderScalePercent = min(200, settings.renderScalePercent + 10)
        case "minus:fps": settings.targetFrameRate = max(30, settings.targetFrameRate - 30)
        case "plus:fps": settings.targetFrameRate = min(120, settings.targetFrameRate + 30)
        case "minus:textScale": settings.textScaleLive = max(50, settings.textScaleLive - 10)
        case "plus:textScale": settings.textScaleLive = min(300, settings.textScaleLive + 10)
        case "minus:handHz": settings.handHzLive = max(5, settings.handHzLive - 5)
        case "plus:handHz": settings.handHzLive = min(60, settings.handHzLive + 5)
        case "minus:prediction": settings.extraPredictionMs = max(0, settings.extraPredictionMs - 4)
        case "plus:prediction": settings.extraPredictionMs = min(60, settings.extraPredictionMs + 4)
        default:
            if id.hasPrefix("win:"), let kind = WindowKind(rawValue: String(id.dropFirst(4))) { onRestore?(kind) }
            else if id.hasPrefix("music:") { onMusic?(String(id.dropFirst(6))) }
            else if id.hasPrefix("app:"), let app = AppKind(rawValue: String(id.dropFirst(4))) { onLaunch?(app); menuOpen = false }
        }
        layout()
    }

    func render() {
        panel.render(ButtonsView(size: CGSize(width: 1600, height: 320), buttons: panel.buttons, hovered: panel.hovered, title: nil, titleHighlight: false))
        if trayShown { tray.render(ButtonsView(size: CGSize(width: 1600, height: 230), buttons: tray.buttons, hovered: tray.hovered, title: nil, titleHighlight: false)) }
        menu.render(ButtonsView(size: CGSize(width: 400, height: 400), buttons: menu.buttons, hovered: menu.hovered, title: nil, titleHighlight: false, transparent: true))
    }
}
