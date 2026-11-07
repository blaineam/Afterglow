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
    var isRecording: () -> Bool = { false }

    init(device: MTLDevice, settings: Settings) {
        self.settings = settings
        panel = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 320)
        panel.pane.widthMeters = 1.5
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

    /// The Apps button lies flat on the floor half a metre ahead of the feet.
    func placeFeet(head: simd_float4x4, floor: Float) {
        let position = head.columns.3.xyz
        var f = -head.columns.2.xyz
        f.y = 0
        if simd_length(f) < 1e-3 { f = SIMD3(0, 0, -1) }
        f = simd_normalize(f)
        menu.pane.centre = SIMD3(position.x, floor + 0.03, position.z) + f * 0.45
        menu.pane.right = simd_normalize(simd_cross(f, SIMD3(0, 1, 0)))
        menu.pane.up = f
    }

    /// Hangs the toolbar low ahead of the head and the menu above it.
    func place(ahead head: simd_float4x4) {
        var w = BrowserWindow()
        w.place(ahead: head, distance: 1.1)
        let position = head.columns.3.xyz
        panel.pane.right = w.right
        panel.pane.up = w.up
        panel.pane.centre = w.centre - SIMD3(0, 0.55, 0)
        // Tilted up to face a head looking down at it.
        let tilt = simd_quatf(angle: -0.5, axis: w.right)
        panel.pane.up = tilt.act(w.up)
        _ = position
        menu.pane.right = w.right
        menu.pane.up = w.up
        menu.pane.centre = w.centre + SIMD3(0, 0.05, 0)
    }

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
        let chips = minimized.prefix(4)
        let count = CGFloat(tiles.count + chips.count)
        let gap: CGFloat = 0.008
        let w = min(0.158, (1 - gap * (count - 1)) / count)
        var x: CGFloat = (1 - (w * count + gap * (count - 1))) / 2
        for (id, icon, label) in tiles {
            buttons.append(.init(id: id, rect: CGRect(x: x, y: 0.06, width: w, height: 0.88), label: label, wide: true, icon: icon, style: .tile,
                                 accent: id == "toggle:passthrough" && settings.passthrough || id == "record:0" && isRecording()))
            x += w + gap
        }
        for kind in chips {
            let icon: String
            switch kind {
            case .browser: icon = "safari.fill"; case .media: icon = "photo.on.rectangle.angled"; case .files: icon = "folder.fill"; case .games: icon = "gamecontroller.fill"
            case .places: icon = "mountain.2.fill"; case .music: icon = "music.note"; case .settings: icon = "gearshape.fill"; case .home: icon = "square.grid.2x2.fill"; case .gameControls: icon = "slider.horizontal.3"
            }
            buttons.append(.init(id: "win:\(kind.rawValue)", rect: CGRect(x: x, y: 0.06, width: w, height: 0.88), label: kind.title, wide: true, icon: icon, style: .tile, accent: true))
            x += w + gap
        }
        panel.set(buttons: buttons, version: "dock|\(settings.passthrough)|\(settings.showHandsLive)|\(isRecording())|\(minimized.map(\.rawValue).joined())")
        menu.set(buttons: [.init(id: "feet", rect: CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84), label: "Apps", icon: "square.grid.2x2.fill", style: .round, accent: true)], version: "feet")
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
            else if id.hasPrefix("app:"), let app = AppKind(rawValue: String(id.dropFirst(4))) { onLaunch?(app); menuOpen = false }
        }
        layout()
    }

    func render() {
        panel.render(ButtonsView(size: CGSize(width: 1600, height: 320), buttons: panel.buttons, hovered: panel.hovered, title: nil, titleHighlight: false))
        menu.render(ButtonsView(size: CGSize(width: 400, height: 400), buttons: menu.buttons, hovered: menu.hovered, title: nil, titleHighlight: false, transparent: true))
    }
}
