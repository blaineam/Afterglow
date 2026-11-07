import Metal
import simd
import SwiftUI

/// The environments: the synthwave surroundings, the real room (passthrough with the surfaces
/// marked), or a 360 photo from the Media folder as the surroundings; and the stationary 3DoF
/// switch. A panel of choices.
@MainActor
final class PlacesApp {
    enum Choice: Equatable {
        case synthwave, room, panorama(URL)
        case place(Int)     // an EnvironmentKind other than synthwave
    }
    static let places: [(Int, String)] = [(1, "🌲 Forest"), (2, "🏜 Desert"), (3, "🏖 Beach"), (4, "🏛 Ruins"), (5, "🌆 City"), (6, "🌕 Moon"), (7, "🔴 Mars")]
    private(set) var night = false
    let panel: ScenePanel
    private(set) var choice = Choice.synthwave
    private(set) var panoramaTexture: MTLTexture?
    private(set) var panoramaItem: MediaItem?
    private var panoramas: [URL] = []
    private let files = FileSource()
    private let device: MTLDevice
    var onChoice: ((Choice) -> Void)?

    init(device: MTLDevice) {
        self.device = device
        panel = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 700)
        panel.pane.widthMeters = 1.3
        Task { @MainActor in
            if let folder = files.folders.first {
                let items = await files.items(in: folder)
                panoramas = items.filter { $0.kind == .photo360 || $0.kind == .panorama }.compactMap(\.fileURL)
                layout()
            }
        }
        layout()
    }

    func open(head: simd_float4x4) {
        var w = BrowserWindow()
        w.place(ahead: head, distance: 1.4)
        panel.pane.centre = w.centre
        panel.pane.right = w.right
        panel.pane.up = w.up
    }

    private func layout() {
        var b: [ScenePanel.Button] = []
        b.append(.init(id: "synth", rect: CGRect(x: 0.03, y: 0.14, width: 0.3, height: 0.22), label: (choice == .synthwave ? "● " : "") + "Synthwave", wide: true))
        b.append(.init(id: "room", rect: CGRect(x: 0.35, y: 0.14, width: 0.3, height: 0.22), label: (choice == .room ? "● " : "") + "Your room", wide: true))
        b.append(.init(id: "scan", rect: CGRect(x: 0.67, y: 0.14, width: 0.3, height: 0.22), label: "Scan room", wide: true))
        for (i, (kind, name)) in Self.places.enumerated() {
            let on = choice == .place(kind)
            b.append(.init(id: "place:\(kind)", rect: CGRect(x: 0.03 + CGFloat(i % 4) * 0.24, y: 0.40 + CGFloat(i / 4) * 0.2, width: 0.22, height: 0.17),
                           label: (on ? "● " : "") + name, wide: true))
        }
        b.append(.init(id: "night", rect: CGRect(x: 0.75, y: 0.60, width: 0.22, height: 0.17), label: night ? "🌙 Night" : "☀️ Day", wide: true))
        for (i, url) in panoramas.prefix(4).enumerated() {
            let on = choice == .panorama(url)
            b.append(.init(id: "pano:\(i)", rect: CGRect(x: 0.03 + CGFloat(i) * 0.24, y: 0.80, width: 0.22, height: 0.17),
                           label: (on ? "● " : "") + String(url.deletingPathExtension().lastPathComponent.prefix(14)), wide: true))
        }
        panel.set(buttons: b, version: "places|\(choice)|\(night)|\(panoramas.count)")
    }

    func press(_ id: String) -> Bool {
        switch id {
        case "synth": choice = .synthwave; panoramaTexture = nil
        case "room": choice = .room; panoramaTexture = nil
        case "scan": return true
        case "night": night.toggle()
        default:
            if id.hasPrefix("place:"), let kind = Int(id.dropFirst(6)) { choice = .place(kind); panoramaTexture = nil }
            if id.hasPrefix("pano:"), let i = Int(id.dropFirst(5)), panoramas.indices.contains(i) {
                let url = panoramas[i]
                choice = .panorama(url)
                Task { @MainActor in
                    let item = await files.classify(url, date: nil)
                    panoramaItem = item
                    let library = MediaLibrary(device: device)
                    panoramaTexture = await library.picture(for: item).texture
                    log("[Places] Surroundings: \(url.lastPathComponent) (\(item.kind.rawValue))")
                }
            }
        }
        onChoice?(choice)
        log("[Places] Chose \(choice)")
        layout()
        return false
    }

    func render() {
        panel.render(ButtonsView(size: CGSize(width: 1600, height: 700), buttons: panel.buttons, hovered: panel.hovered, title: "Places", titleHighlight: false))
    }
}
