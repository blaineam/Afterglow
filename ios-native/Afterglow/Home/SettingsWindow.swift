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
        panel = ScenePanel(device: device, pixelWidth: 1400, pixelHeight: 1000)
        layout()
    }

    func layout() {
        var m: [ScenePanel.Button] = []
        let rows: [(String, String, String)] = [
            ("renderScale", "Render scale", "\(settings.renderScalePercent)%"),
            ("fps", "Frame rate", "\(settings.targetFrameRate) fps"),
            ("textScale", "Browser text", "\(settings.textScaleLive)%"),
            ("handHz", "Hand images/s", "\(settings.handHzLive)"),
            ("prediction", "Head prediction", "+\(settings.extraPredictionMs) ms"),
        ]
        var ry: CGFloat = 0.12
        for (id, name, value) in rows {
            m.append(.init(id: "label:\(id)", rect: CGRect(x: 0.02, y: ry, width: 0.42, height: 0.1), label: name, wide: true))
            m.append(.init(id: "minus:\(id)", rect: CGRect(x: 0.46, y: ry, width: 0.12, height: 0.1), label: "−"))
            m.append(.init(id: "value:\(id)", rect: CGRect(x: 0.59, y: ry, width: 0.25, height: 0.1), label: value, wide: true))
            m.append(.init(id: "plus:\(id)", rect: CGRect(x: 0.85, y: ry, width: 0.12, height: 0.1), label: "+"))
            ry += 0.115
        }
        let toggles: [(String, String)] = [
            ("passthrough", settings.passthrough ? "Passthrough on" : "Passthrough off"),
            ("hands", settings.showHandsLive ? "Hands shown" : "Hands hidden"),
            ("dof", settings.degreesOfFreedom == 3 ? "3DoF ultra-wide" : "6DoF wide camera"),
            ("surfaces", settings.surfaces ? "Surfaces on" : "Surfaces off"),
            ("occlusion", settings.occlusion ? "Occlusion on" : "Occlusion off"),
            ("passcode", hasPasscode() ? "Passcode: remove" : "Passcode: set"),
        ]
        for (i, (id, label)) in toggles.enumerated() {
            m.append(.init(id: "toggle:\(id)", rect: CGRect(x: 0.02 + CGFloat(i % 2) * 0.49, y: 0.70 + CGFloat(i / 2) * 0.1, width: 0.47, height: 0.09), label: label, wide: true))
        }
        panel.set(buttons: m, version: "settings|\(rows.map { $0.2 }.joined())|\(toggles.map { $0.1 }.joined())")
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
        case "toggle:passcode": if hasPasscode() { onRemovePasscode?() } else { onSetPasscode?() }
        default: break
        }
        layout()
    }

    func render() {
        panel.render(ButtonsView(size: CGSize(width: 1400, height: 1000), buttons: panel.buttons, hovered: panel.hovered, title: "⚙ Settings", titleHighlight: false))
    }
}
