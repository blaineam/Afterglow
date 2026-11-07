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
    private(set) var recents: [AppKind] = [.browser, .media, .files, .environments, .games]
    private let recentsKey = "toolbar.recents"
    var settings: Settings
    /// Set by the owner of the toolbar: what each button does.
    var onLaunch: ((AppKind) -> Void)?
    var onRecentre: (() -> Void)?
    var onCloseApp: (() -> Void)?
    var onRecord: ((Int) -> Void)?
    var isRecording: () -> Bool = { false }

    init(device: MTLDevice, settings: Settings) {
        self.settings = settings
        panel = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 180)
        panel.pane.widthMeters = 1.1
        menu = ScenePanel(device: device, pixelWidth: 1400, pixelHeight: 820)
        menu.pane.widthMeters = 1.0
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

    /// Hangs the toolbar low ahead of the head and the menu above it.
    func place(ahead head: simd_float4x4) {
        var w = BrowserWindow()
        w.place(ahead: head, distance: 1.1)
        let position = head.columns.3.xyz
        panel.pane.right = w.right
        panel.pane.up = w.up
        panel.pane.centre = w.centre - SIMD3(0, 0.42, 0)
        // Tilted up to face a head looking down at it.
        let tilt = simd_quatf(angle: -0.5, axis: w.right)
        panel.pane.up = tilt.act(w.up)
        _ = position
        menu.pane.right = w.right
        menu.pane.up = w.up
        menu.pane.centre = w.centre + SIMD3(0, 0.05, 0)
    }

    func layout() {
        var buttons: [ScenePanel.Button] = []
        let h: CGFloat = 0.82, y: CGFloat = 0.09
        var x: CGFloat = 0.01
        func add(_ id: String, _ label: String, _ width: CGFloat) {
            buttons.append(.init(id: id, rect: CGRect(x: x, y: y, width: width, height: h), label: label, wide: true))
            x += width + 0.006
        }
        add("toggle:passthrough", settings.passthrough ? "👁 Room" : "👁 Scene", 0.11)
        add("toggle:hands", settings.showHands ? "✋ On" : "✋ Off", 0.09)
        add("toggle:dof", settings.degreesOfFreedom == 3 ? "3DoF" : "6DoF", 0.09)
        add("toggle:surfaces", settings.surfaces ? "▦ On" : "▦ Off", 0.09)
        add("recentre", "⌖", 0.06)
        for app in recents.prefix(4) { add("app:\(app.rawValue)", app.label, 0.13) }
        add("more", "⋯ More", 0.11)
        panel.set(buttons: buttons, version: "toolbar|\(settings.passthrough)|\(settings.showHandsLive)|\(settings.degreesOfFreedom)|\(settings.surfaces)|\(recents.map(\.rawValue).joined())")

        // The menu: every app, then the settings as rows of value and +/-.
        var m: [ScenePanel.Button] = []
        let appY: CGFloat = 0.05, appH: CGFloat = 0.14
        var ax: CGFloat = 0.02
        for app in AppKind.allCases {
            m.append(.init(id: "app:\(app.rawValue)", rect: CGRect(x: ax, y: appY, width: 0.155, height: appH), label: app.label, wide: true))
            ax += 0.16
        }
        let rows: [(String, String, String)] = [
            ("renderScale", "Render scale", "\(settings.renderScalePercent)%"),
            ("fps", "Frame rate", "\(settings.targetFrameRate) fps"),
            ("textScale", "Browser text", "\(settings.textScaleLive)%"),
            ("handHz", "Hand images/s", "\(settings.handHzLive)"),
            ("prediction", "Head prediction", "+\(settings.extraPredictionMs) ms"),
        ]
        var ry: CGFloat = 0.25
        for (id, name, value) in rows {
            m.append(.init(id: "label:\(id)", rect: CGRect(x: 0.02, y: ry, width: 0.42, height: 0.12), label: name, wide: true))
            m.append(.init(id: "minus:\(id)", rect: CGRect(x: 0.46, y: ry, width: 0.12, height: 0.12), label: "−"))
            m.append(.init(id: "value:\(id)", rect: CGRect(x: 0.59, y: ry, width: 0.25, height: 0.12), label: value, wide: true))
            m.append(.init(id: "plus:\(id)", rect: CGRect(x: 0.85, y: ry, width: 0.12, height: 0.12), label: "+"))
            ry += 0.135
        }
        m.append(.init(id: "toggle:occlusion", rect: CGRect(x: 0.36, y: 0.9, width: 0.3, height: 0.09), label: settings.occlusion ? "Occlusion on" : "Occlusion off", wide: true))
        let recording = isRecording()
        m.append(.init(id: "record:0", rect: CGRect(x: 0.02, y: 0.80, width: 0.3, height: 0.09), label: recording ? "■ Stop recording" : "● Record left eye", wide: true))
        m.append(.init(id: "record:1", rect: CGRect(x: 0.36, y: 0.80, width: 0.3, height: 0.09), label: recording ? "■ Stop recording" : "● Record right eye", wide: true))
        m.append(.init(id: "closeapp", rect: CGRect(x: 0.02, y: 0.9, width: 0.3, height: 0.09), label: "Close app", wide: true))
        m.append(.init(id: "closemenu", rect: CGRect(x: 0.68, y: 0.9, width: 0.3, height: 0.09), label: "Done", wide: true))
        menu.set(buttons: m, version: "menu|\(rows.map { $0.2 }.joined())|\(settings.occlusion)|\(recording)|\(recents.map(\.rawValue).joined())")
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
        case "more": menuOpen = true
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
            if id.hasPrefix("app:"), let app = AppKind(rawValue: String(id.dropFirst(4))) {
                if app == .settings { menuOpen = true } else { onLaunch?(app); menuOpen = false }
            }
        }
        layout()
    }

    func render() {
        panel.render(ButtonsView(size: CGSize(width: 1600, height: 180), buttons: panel.buttons, hovered: panel.hovered, title: nil, titleHighlight: false))
        if menuOpen {
            menu.render(ButtonsView(size: CGSize(width: 1400, height: 820), buttons: menu.buttons, hovered: menu.hovered, title: "Afterglow", titleHighlight: false))
        }
    }
}
