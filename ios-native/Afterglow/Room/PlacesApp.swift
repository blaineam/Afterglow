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
        case libraryPhoto(String)
    }
    static let places: [(Int, String)] = [(1, "🌲 Forest"), (2, "🏜 Desert"), (3, "🏖 Beach"), (4, "🏛 Ruins"), (5, "🌆 City"), (6, "🌕 Moon"), (7, "🔴 Mars")]
    private(set) var night = false
    let panel: ScenePanel
    private(set) var choice = Choice.synthwave
    private(set) var panoramaTexture: MTLTexture?
    private(set) var panoramaItem: MediaItem?
    private var panoramas: [URL] = []
    private var libraryItems: [MediaItem] = []
    private let files = FileSource()
    private let device: MTLDevice
    private let library: MediaLibrary
    private let generator = SkyboxGenerator()
    private(set) var generating = false
    private(set) var generatorStatus = ""
    var onChoice: ((Choice) -> Void)?
    /// Asks the host for a prompt (dictation or the keyboard); the host calls `generate`.
    var onWantPrompt: (() -> Void)?
    private var page = 0

    init(device: MTLDevice) {
        self.device = device
        library = MediaLibrary(device: device)
        panel = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 900)
        panel.pane.widthMeters = 1.3
        Task { @MainActor in await self.scan() }
        layout()
    }

    /// Every fully 360 picture the user has: the Environments folder, the Media folder and any
    /// bookmarked folder, then the Photos library's 360 pictures (by shape or the Spatial/360
    /// albums), newest first.
    func scan() async {
        // The photospheres shipped in the app come first, then the user's own.
        var found: [URL] = (Bundle.main.urls(forResourcesWithExtension: "jpg", subdirectory: "Places") ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let environments = SkyboxGenerator.environmentsFolder
        let envFolder = FileSource.Folder(id: "environments", name: "Environments", url: environments, bookmark: nil)
        for folder in [envFolder] + files.folders {
            let items = await files.items(in: folder)
            found += items.filter { $0.kind == .photo360 || $0.kind == .panorama }.compactMap(\.fileURL)
        }
        panoramas = found
        if await library.requestAccess() {
            var items: [MediaItem] = []
            for album in library.albums().prefix(4) {
                items += library.items(in: album, limit: 300).filter { $0.kind == .photo360 }
            }
            var seen = Set<String>()
            libraryItems = items.filter { seen.insert($0.id).inserted }
        }
        log("[Places] \(panoramas.count) 360 files, \(libraryItems.count) 360 photos in the library")
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
        b.append(.init(id: "synth", rect: CGRect(x: 0.03, y: 0.14, width: 0.3, height: 0.13), label: "Synthwave", wide: true, icon: "sun.horizon.fill", style: .pill, accent: choice == .synthwave))
        b.append(.init(id: "room", rect: CGRect(x: 0.35, y: 0.14, width: 0.3, height: 0.13), label: "Your room", wide: true, icon: "eye.fill", style: .pill, accent: choice == .room))
        b.append(.init(id: "scan", rect: CGRect(x: 0.67, y: 0.14, width: 0.3, height: 0.13), label: "Scan room", wide: true, icon: "viewfinder", style: .pill))
        for (i, (kind, name)) in Self.places.enumerated() {
            let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
            b.append(.init(id: "place:\(kind)", rect: CGRect(x: 0.03 + CGFloat(i % 4) * 0.2375, y: 0.30 + CGFloat(i / 4) * 0.2, width: 0.2275, height: 0.19),
                           label: parts.last ?? name, wide: true, icon: parts.first, style: .tile, accent: choice == .place(kind)))
        }
        b.append(.init(id: "night", rect: CGRect(x: 0.03 + 3 * 0.2375, y: 0.50, width: 0.2275, height: 0.19), label: night ? "Night" : "Day", wide: true, icon: night ? "moon.stars.fill" : "sun.max.fill", style: .tile, accent: night))
        // The 360 pictures, four a row, paged; a generate button and a rescan.
        let all: [(String, String, String)] = panoramas.map { ("pano:" + $0.path, String($0.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ").prefix(16)), "photo.circle.fill") }
            + libraryItems.map { ("lib:" + $0.id, String($0.title.prefix(14)), "photo.on.rectangle") }
        let perPage = 4
        let shown = all.dropFirst(page * perPage).prefix(perPage)
        for (i, (id, label, icon)) in shown.enumerated() {
            let on: Bool
            if case .panorama(let url) = choice, id == "pano:" + url.path { on = true }
            else if case .libraryPhoto(let itemId) = choice, id == "lib:" + itemId { on = true }
            else { on = false }
            b.append(.init(id: id, rect: CGRect(x: 0.03 + CGFloat(i) * 0.2375, y: 0.71, width: 0.2275, height: 0.15), label: label, wide: true, icon: icon, style: .tile, accent: on))
        }
        b.append(.init(id: "prevpage", rect: CGRect(x: 0.03, y: 0.875, width: 0.1, height: 0.11), label: "Previous", icon: "chevron.left", style: .round))
        b.append(.init(id: "nextpage", rect: CGRect(x: 0.14, y: 0.875, width: 0.1, height: 0.11), label: "Next", icon: "chevron.right", style: .round))
        b.append(.init(id: "generate", rect: CGRect(x: 0.26, y: 0.875, width: 0.5, height: 0.11), label: generating ? generatorStatus : "Generate a place", wide: true, icon: "wand.and.stars", style: .pill))
        b.append(.init(id: "rescan", rect: CGRect(x: 0.87, y: 0.875, width: 0.1, height: 0.11), label: "Rescan", icon: "arrow.clockwise", style: .round))
        panel.set(buttons: b, version: "places|\(choice)|\(night)|\(panoramas.count)|\(libraryItems.count)|\(page)|\(generating)|\(generatorStatus)")
    }

    /// The test script: the first 360 file whose name contains `name` becomes the surroundings.
    func choose(named name: String) {
        if let url = panoramas.first(where: { $0.lastPathComponent.localizedCaseInsensitiveContains(name) }) { _ = press("pano:" + url.path) }
        else { log("[Places] No 360 file named like \(name) among \(panoramas.count)") }
    }

    func press(_ id: String) -> Bool {
        switch id {
        case "synth": choice = .synthwave; panoramaTexture = nil
        case "room": choice = .room; panoramaTexture = nil
        case "scan": return true
        case "night": night.toggle()
        case "prevpage": page = max(0, page - 1)
        case "nextpage": if (page + 1) * 4 < panoramas.count + libraryItems.count { page += 1 }
        case "rescan": Task { @MainActor in await self.scan() }
        case "generate": if !generating { onWantPrompt?() }
        default:
            if id.hasPrefix("place:"), let kind = Int(id.dropFirst(6)) { choice = .place(kind); panoramaTexture = nil }
            if id.hasPrefix("pano:") {
                let url = URL(fileURLWithPath: String(id.dropFirst(5)))
                choice = .panorama(url)
                Task { @MainActor in
                    let item = await files.classify(url, date: nil)
                    panoramaItem = item
                    panoramaTexture = await library.picture(for: item).texture
                    log("[Places] Surroundings: \(url.lastPathComponent) (\(item.kind.rawValue))")
                }
            }
            if id.hasPrefix("lib:"), let item = libraryItems.first(where: { $0.id == String(id.dropFirst(4)) }) {
                choice = .libraryPhoto(item.id)
                Task { @MainActor in
                    panoramaItem = item
                    panoramaTexture = await library.picture(for: item).texture
                    log("[Places] Surroundings: a 360 photo from the library (\(item.title))")
                }
            }
        }
        onChoice?(choice)
        log("[Places] Chose \(choice)")
        layout()
        return false
    }

    /// Generates a place from a prompt and makes it the surroundings when it lands.
    func generate(prompt: String) {
        guard !generating, !prompt.isEmpty else { return }
        generating = true
        generatorStatus = "Asking…"
        layout()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await self.generator.generate(prompt: prompt) { [weak self] status in
                    Task { @MainActor in self?.generatorStatus = status; self?.layout() }
                }
                self.generating = false
                await self.scan()
                _ = self.press("pano:" + url.path)
            } catch {
                self.generating = false
                self.generatorStatus = ""
                log("[Skybox] \(error)")
                self.layout()
            }
        }
    }

    func render() {
        panel.render(ButtonsView(size: CGSize(width: 1600, height: 900), buttons: panel.buttons, hovered: panel.hovered, title: "Places", titleHighlight: false,
                                 subtitle: "Surroundings when passthrough is off"))
    }
}
