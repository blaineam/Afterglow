import Metal
import SwiftUI

/// The settings as a window of rows: each a name, a value and − and +, plus toggles. Display,
/// tracking, hands, browser text, the lock. The toolbar keeps the quick toggles.
@MainActor
final class SettingsWindow {
    let panel: ScenePanel
    let settings: Settings
    var onSetPasscode: (() -> Void)?
    var onRemovePasscode: (() -> Void)?
    var hasPasscode: () -> Bool = { false }

    init(device: MTLDevice, settings: Settings) {
        self.settings = settings
        panel = ScenePanel(device: device, pixelWidth: 1400, pixelHeight: 1100)
        layout()
    }

    func layout() {
        var m: [ScenePanel.Button] = []
        let rows: [(String, String, String, String)] = [
            ("renderScale", "Render scale", "\(settings.renderScalePercent)%", "sparkles.tv"),
            ("fps", "Frame rate", "\(settings.targetFrameRate) fps", "speedometer"),
            ("textScale", "Browser text", "\(settings.textScaleLive)%", "textformat.size"),
            ("handHz", "Hand images a second", "\(settings.handHzLive)", "hand.raised"),
            ("prediction", "Head prediction", "+\(settings.extraPredictionMs) ms", "clock"),
        ]
        var ry: CGFloat = 0.04
        for (id, name, value, icon) in rows {
            m.append(.init(id: "label:\(id)", rect: CGRect(x: 0.03, y: ry, width: 0.6, height: 0.095), label: name, wide: true, icon: icon, style: .row, value: value, accent: true))
            m.append(.init(id: "minus:\(id)", rect: CGRect(x: 0.66, y: ry, width: 0.14, height: 0.095), label: "−", icon: "minus", style: .round))
            m.append(.init(id: "plus:\(id)", rect: CGRect(x: 0.83, y: ry, width: 0.14, height: 0.095), label: "+", icon: "plus", style: .round))
            ry += 0.11
        }
        let toggles: [(String, String, Bool)] = [
            ("passthrough", "Passthrough", settings.passthrough),
            ("hands", "Show hands", settings.showHandsLive),
            ("dof", "3DoF ultra-wide", settings.degreesOfFreedom == 3),
            ("surfaces", "Surfaces", settings.surfaces),
            ("occlusion", "Occlusion", settings.occlusion),
            ("depth", "3D passthrough", settings.depthPassthrough),
            ("phone", "Phone view", settings.phoneView),
            ("passcode", "Passcode", hasPasscode()),
        ]
        for (i, (id, label, on)) in toggles.enumerated() {
            m.append(.init(id: "toggle:\(id)", rect: CGRect(x: 0.03 + CGFloat(i % 2) * 0.485, y: 0.60 + CGFloat(i / 2) * 0.095, width: 0.465, height: 0.088),
                           label: label, wide: true, style: .row, value: on ? "On" : "Off", accent: on))
        }
        panel.set(buttons: m, version: "settings|\(rows.map { $0.2 }.joined())|\(toggles.map { "\($0.2)" }.joined())")
    }

    func press(_ id: String) {
        switch id {
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
        case "toggle:passthrough": settings.passthrough.toggle()
        case "toggle:hands": settings.showHandsLive.toggle()
        case "toggle:dof": settings.degreesOfFreedom = settings.degreesOfFreedom == 3 ? 6 : 3
        case "toggle:surfaces": settings.surfaces.toggle()
        case "toggle:occlusion": settings.occlusion.toggle()
        case "toggle:depth": settings.depthPassthrough.toggle()
        case "toggle:phone": settings.phoneView.toggle()
        case "toggle:passcode": if hasPasscode() { onRemovePasscode?() } else { onSetPasscode?() }
        default: break
        }
        layout()
    }

    func render() {
        panel.render(ButtonsView(size: CGSize(width: 1400, height: 1100), buttons: panel.buttons, hovered: panel.hovered, title: nil, titleHighlight: false))
    }
}
