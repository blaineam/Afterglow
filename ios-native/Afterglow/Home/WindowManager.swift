import Metal
import simd
import SwiftUI

/// The kinds of window the app opens; each app is one, and several can be open at once.
enum WindowKind: String, CaseIterable, Sendable {
    case home, browser, media, files, games, places, settings, music, gameControls
    var title: String {
        switch self {
        case .home: return "Afterglow"
        case .browser: return "Browser"
        case .media: return "Media"
        case .files: return "Files"
        case .games: return "Games"
        case .places: return "Places"
        case .settings: return "Settings"
        case .music: return "Music"
        case .gameControls: return "Controls"
        }
    }
    var icon: String {
        switch self {
        case .home: return "✦"
        case .browser: return "🌐"
        case .media: return "🖼"
        case .files: return "📁"
        case .games: return "🎮"
        case .places: return "🌄"
        case .settings: return "⚙"
        case .music: return "🎵"
        case .gameControls: return "🎛"
        }
    }
}

/// A window in the scene: a pane for its content, a title bar above with minimize, size and
/// close, and a state. Moved by holding a pinch on its title bar (the window follows the gaze at
/// the distance it was grabbed) or by the bar's move mode, resized with the bar's size buttons.
@MainActor
final class AppWindow {
    let kind: WindowKind
    var pane = BrowserWindow()
    let titleBar: ScenePanel
    var minimized = false
    var moving = false
    /// The bar hidden with the app's own controls (the media viewer's hide), out of the gaze too.
    var barHidden = false
    var grabDistance: Float = 1.3
    var sizeIndex = 1
    /// Extra room above the pane for the app's own bar (the browser's tabs and address).
    var barGap: Float = 0.015
    static let widths: [Float] = [1.3, 1.8, 2.4, 3.2]

    init(kind: WindowKind, device: MTLDevice, aspect: Float) {
        self.kind = kind
        titleBar = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 150)
        pane.aspect = aspect
        pane.widthMeters = Self.widths[sizeIndex]
        layoutBar()
    }

    func layoutBar() {
        var b: [ScenePanel.Button] = []
        // Traffic lights at the top left (close, minimize, size), the name as a grab handle, move.
        b.append(.init(id: "close", rect: CGRect(x: 0.02, y: 0.08, width: 0.08, height: 0.84), label: "Close", icon: "xmark", style: .round, light: 1))
        b.append(.init(id: "minimize", rect: CGRect(x: 0.105, y: 0.08, width: 0.08, height: 0.84), label: "Minimize", icon: "minus", style: .round, light: 2))
        b.append(.init(id: "larger", rect: CGRect(x: 0.19, y: 0.08, width: 0.08, height: 0.84), label: "Size", icon: "arrow.up.left.and.arrow.down.right", style: .round, light: 3))
        b.append(.init(id: "title", rect: CGRect(x: 0.29, y: 0.05, width: 0.58, height: 0.9), label: kind.title, wide: true, icon: "line.3.horizontal", style: .pill, accent: moving))
        b.append(.init(id: "move", rect: CGRect(x: 0.89, y: 0.05, width: 0.095, height: 0.9), label: "Move", icon: moving ? "mappin.and.ellipse" : "arrow.up.and.down.and.arrow.left.and.right", style: .round, accent: moving))
        titleBar.set(buttons: b, version: "bar|\(kind.rawValue)|\(moving)|\(sizeIndex)")
    }

    /// The bar sits above the pane, the same width.
    func placeBar() {
        titleBar.pane.widthMeters = pane.widthMeters
        titleBar.pane.right = pane.right
        titleBar.pane.up = pane.up
        titleBar.pane.centre = pane.centre + pane.up * (pane.heightMeters / 2 + titleBar.pane.heightMeters / 2 + barGap)
    }

    func render() {
        titleBar.render(ButtonsView(size: CGSize(width: 1600, height: 150), buttons: titleBar.buttons, hovered: titleBar.hovered, title: nil, titleHighlight: false))
    }
}

/// The windows and the dock: which are open, where they hang, which has the gaze, the moves
/// and resizes, and the minimized ones as chips on the dock. New windows open to the right of
/// the last, in an arc round the user.
@MainActor
final class WindowManager {
    private(set) var windows: [AppWindow] = []
    private let device: MTLDevice
    private var dragging: AppWindow?
    private var dragStart: Double = 0
    var onClose: ((WindowKind) -> Void)?
    var onFocus: ((WindowKind) -> Void)?

    init(device: MTLDevice) { self.device = device }

    func window(_ kind: WindowKind) -> AppWindow? { windows.first { $0.kind == kind } }

    /// Opens a window (or brings it back from the dock), hung ahead of the head or beside the
    /// last window.
    @discardableResult
    func open(_ kind: WindowKind, head: simd_float4x4, aspect: Float, width: Float? = nil) -> AppWindow {
        if let existing = window(kind) {
            existing.minimized = false
            return existing
        }
        let w = AppWindow(kind: kind, device: device, aspect: aspect)
        if let width { w.pane.widthMeters = width }
        let open = windows.filter { !$0.minimized }
        w.pane.place(ahead: head, distance: 1.4)
        w.pane.centre.y += 0.12
        if !open.isEmpty {
            // Round the user: the nearest free arc, ahead first, then alternately right and left,
            // where "free" means no open window's arc (its width at its distance, plus a gap)
            // overlaps the new one's. Windows never open through one another.
            let position = head.columns.3.xyz
            let f = -head.columns.2.xyz
            let aheadYaw = atan2(f.x, -f.z)
            let distance: Float = 1.4
            let halfArc = { (width: Float, d: Float) -> Float in atan(width / 2 / max(d, 0.3)) }
            let mine = halfArc(w.pane.widthMeters, distance) + 0.06
            func free(_ yaw: Float) -> Bool {
                for o in open {
                    let to = o.pane.centre - position
                    let oYaw = atan2(to.x, -to.z)
                    let oArc = halfArc(o.pane.widthMeters, simd_length(SIMD3(to.x, 0, to.z)))
                    var d = yaw - oYaw
                    d = atan2(sin(d), cos(d))
                    if abs(d) < mine + oArc { return false }
                }
                return true
            }
            var yaw = aheadYaw
            var found = free(yaw)
            var stepIndex = 1
            while !found && stepIndex < 24 {
                let offset = Float((stepIndex + 1) / 2) * 0.35 * (stepIndex % 2 == 1 ? 1 : -1)
                yaw = aheadYaw + offset
                found = free(yaw)
                stepIndex += 1
            }
            let forward = SIMD3(sin(yaw), 0, -cos(yaw))
            w.pane.centre = position + forward * distance + SIMD3(0, 0.12, 0)
            w.pane.right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
            w.pane.up = SIMD3(0, 1, 0)
        }
        w.placeBar()
        windows.append(w)
        log("[Windows] Opened \(kind.rawValue) (\(windows.count) windows)")
        return w
    }

    /// Hangs every open window again in an arc round where the head looks now, in the order they
    /// were in, left to right. A switch between 6DoF and 3DoF (or a fresh world-tracking start)
    /// changes the tracker's frame, which left windows sideways or behind (owner, 2026-11-08).
    func rearrange(head: simd_float4x4) {
        let open = visible
        guard !open.isEmpty else { return }
        // Their order: by the way each faces, round the circular mean.
        let yaws = open.map { w -> Float in let d = -w.pane.normal; return atan2(d.x, -d.z) }
        let meanX = yaws.reduce(0) { $0 + sin($1) }, meanZ = yaws.reduce(0) { $0 + cos($1) }
        let mean = atan2(meanX, meanZ)
        let order = open.indices.sorted { a, b in
            atan2(sin(yaws[a] - mean), cos(yaws[a] - mean)) < atan2(sin(yaws[b] - mean), cos(yaws[b] - mean))
        }
        let position = head.columns.3.xyz
        let f = -head.columns.2.xyz
        let aheadYaw = atan2(f.x, -f.z)
        let distance: Float = 1.4
        let gap: Float = 0.06
        let arcs = order.map { atan(open[$0].pane.widthMeters / 2 / distance) }
        let total = arcs.reduce(0) { $0 + 2 * $1 } + gap * Float(max(order.count - 1, 0))
        var yaw = aheadYaw - total / 2
        for (k, i) in order.enumerated() {
            let w = open[i]
            yaw += arcs[k]
            let forward = SIMD3(sin(yaw), 0, -cos(yaw))
            let lift: Float = w.kind == .gameControls ? -0.3 : 0.1
            w.pane.centre = position + forward * distance + SIMD3(0, lift, 0)
            w.pane.right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
            w.pane.up = SIMD3(0, 1, 0)
            w.moving = false
            w.placeBar()
            yaw += arcs[k] + gap
        }
        dragging = nil
        log("[Windows] Rearranged \(open.count) windows round the view")
    }

    func close(_ kind: WindowKind) {
        windows.removeAll { $0.kind == kind }
        onClose?(kind)
        log("[Windows] Closed \(kind.rawValue)")
    }

    func minimize(_ kind: WindowKind) {
        window(kind)?.minimized = true
    }

    var visible: [AppWindow] { windows.filter { !$0.minimized } }
    var minimized: [AppWindow] { windows.filter { $0.minimized } }

    /// A press on a title bar's button.
    func press(_ w: AppWindow, id: String) {
        switch id {
        case "close": close(w.kind)
        case "minimize": w.minimized = true
        case "larger": w.sizeIndex = (w.sizeIndex + 1) % AppWindow.widths.count; w.pane.widthMeters = AppWindow.widths[w.sizeIndex]
        case "move": w.moving.toggle()
        default: break
        }
        w.layoutBar()
        w.placeBar()
    }

    /// Per frame: the gaze over the title bars, holds that drag a window, move mode. Returns the
    /// window whose bar the gaze is on, and whether the select was consumed.
    func frame(head: simd_float4x4, select: Bool, pinchHeld: Bool, time: Double) -> (hovered: AppWindow?, consumed: Bool) {
        let origin = head.columns.3.xyz
        let forward = -head.columns.2.xyz
        var consumed = false
        var hovered: AppWindow?
        for w in visible {
            w.placeBar()
            if !w.barHidden, let hit = w.titleBar.pane.hit(origin: origin, direction: forward) {
                _ = w.titleBar.hover(hit.uv)
                hovered = w
                onFocus?(w.kind)
                if select, let id = w.titleBar.hovered {
                    if id == "title" {
                        // A select on the title starts a drag that lasts while the pinch is held.
                        dragging = w
                        dragStart = time
                        w.grabDistance = simd_length(w.pane.centre - origin)
                    } else {
                        press(w, id: id)
                    }
                    consumed = true
                }
            } else {
                _ = w.titleBar.hover(nil)
            }
            if w.moving {
                w.pane.place(ahead: head, distance: w.grabDistance)
                w.placeBar()
                if select && hovered !== w { w.moving = false; w.layoutBar(); consumed = true }
            }
            w.render()
        }
        if let d = dragging {
            if pinchHeld || time - dragStart < 0.25 {
                d.pane.place(ahead: head, distance: d.grabDistance)
                d.placeBar()
            } else {
                dragging = nil
            }
        }
        return (hovered, consumed)
    }
}

/// The Home menu: the apps as tiles, the open windows, and a lock button.
@MainActor
final class HomeMenu {
    let panel: ScenePanel
    var onLaunch: ((WindowKind) -> Void)?
    var onLock: (() -> Void)?
    private var openKinds: [WindowKind] = []

    init(device: MTLDevice) {
        panel = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 900)
        layout(open: [])
    }

    func layout(open: [WindowKind]) {
        openKinds = open
        var b: [ScenePanel.Button] = []
        let apps: [(WindowKind, String)] = [(.browser, "safari.fill"), (.media, "photo.on.rectangle.angled"), (.files, "folder.fill"), (.games, "gamecontroller.fill"),
                                            (.places, "mountain.2.fill"), (.music, "music.note"), (.settings, "gearshape.fill")]
        for (i, (app, icon)) in apps.enumerated() {
            let col = i % 4, row = i / 4
            b.append(.init(id: "app:\(app.rawValue)", rect: CGRect(x: 0.03 + CGFloat(col) * 0.2375, y: 0.06 + CGFloat(row) * 0.47, width: 0.2275, height: 0.44),
                           label: app.title, wide: true, icon: icon, style: .tile, accent: open.contains(app)))
        }
        b.append(.init(id: "lock", rect: CGRect(x: 0.03 + 3 * 0.2375, y: 0.53, width: 0.2275, height: 0.44), label: "Lock", wide: true, icon: "lock.fill", style: .tile))
        panel.set(buttons: b, version: "home|\(open.map(\.rawValue).joined())")
    }

    func press(_ id: String) -> Bool {
        if id.hasPrefix("app:"), let kind = WindowKind(rawValue: String(id.dropFirst(4))) { onLaunch?(kind); return true }
        if id == "lock" { onLock?(); return true }
        return id == "close"
    }

    func render() {
        panel.render(ButtonsView(size: CGSize(width: 1600, height: 900), buttons: panel.buttons, hovered: panel.hovered, title: nil, titleHighlight: true))
    }
}
