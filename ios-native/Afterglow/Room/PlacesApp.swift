import Metal
import simd
import SwiftUI
import UIKit
import ImageIO

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
        b.append(.init(id: "synth", rect: CGRect(x: 0.03, y: 0.04, width: 0.22, height: 0.12), label: "Synthwave", wide: true, icon: "sun.horizon.fill", style: .pill, accent: choice == .synthwave))
        b.append(.init(id: "room", rect: CGRect(x: 0.27, y: 0.04, width: 0.22, height: 0.12), label: "Your room", wide: true, icon: "eye.fill", style: .pill, accent: choice == .room))
        b.append(.init(id: "scan", rect: CGRect(x: 0.51, y: 0.04, width: 0.22, height: 0.12), label: "Scan room", wide: true, icon: "viewfinder", style: .pill))
        b.append(.init(id: "night", rect: CGRect(x: 0.75, y: 0.04, width: 0.22, height: 0.12), label: night ? "Night" : "Day", wide: true, icon: night ? "moon.stars.fill" : "sun.max.fill", style: .pill, accent: night))
        // The 360 pictures as picture tiles, eight a page, with the page arrows.
        let all = tiles
        let shown = all.dropFirst(page * Self.perPage).prefix(Self.perPage)
        for (i, tile) in shown.enumerated() {
            let col = i % 4, row = i / 4
            b.append(.init(id: tile.id, rect: CGRect(x: 0.03 + CGFloat(col) * 0.2375, y: 0.19 + CGFloat(row) * 0.345, width: 0.2275, height: 0.33),
                           label: tile.label, wide: true, style: .tile, accent: tile.on))
        }
        let pages = max(1, (all.count + Self.perPage - 1) / Self.perPage)
        b.append(.init(id: "prevpage", rect: CGRect(x: 0.03, y: 0.885, width: 0.1, height: 0.1), label: "Previous", icon: "chevron.left", style: .round))
        b.append(.init(id: "pagelabel", rect: CGRect(x: 0.15, y: 0.885, width: 0.3, height: 0.1), label: "\(page + 1) of \(pages)", wide: true, style: .label))
        b.append(.init(id: "nextpage", rect: CGRect(x: 0.46, y: 0.885, width: 0.1, height: 0.1), label: "Next", icon: "chevron.right", style: .round))
        b.append(.init(id: "rescan", rect: CGRect(x: 0.75, y: 0.885, width: 0.22, height: 0.1), label: "Rescan", wide: true, icon: "arrow.clockwise", style: .pill))
        panel.set(buttons: b, version: "places|\(choice)|\(night)|\(panoramas.count)|\(libraryItems.count)|\(page)|\(thumbnails.count)")
    }

    static let perPage = 8
    struct Tile { var id: String; var label: String; var on: Bool; var image: UIImage? }
    private var thumbnails: [String: UIImage] = [:]
    /// Every selectable picture, bundled first, then the user's files, then the library's.
    private var tiles: [Tile] {
        var t: [Tile] = []
        for url in panoramas {
            let id = "pano:" + url.path
            var on = false
            if case .panorama(let u) = choice, u.path == url.path { on = true }
            let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ").capitalized
            t.append(Tile(id: id, label: name, on: on, image: thumbnails[id]))
        }
        for item in libraryItems {
            let id = "lib:" + item.id
            var on = false
            if case .libraryPhoto(let itemId) = choice, itemId == item.id { on = true }
            t.append(Tile(id: id, label: item.title, on: on, image: thumbnails[id]))
        }
        return t
    }

    /// Small pictures for the tiles on the current page, loaded once each.
    private func loadThumbnails() {
        let wanted = tiles.dropFirst(page * Self.perPage).prefix(Self.perPage).filter { thumbnails[$0.id] == nil }
        guard !wanted.isEmpty, !loadingThumbnails else { return }
        loadingThumbnails = true
        Task { @MainActor in
            for tile in wanted {
                if tile.id.hasPrefix("pano:") {
                    thumbnails[tile.id] = await Self.thumbnail(URL(fileURLWithPath: String(tile.id.dropFirst(5))))
                } else if let item = libraryItems.first(where: { "lib:" + $0.id == tile.id }) {
                    thumbnails[tile.id] = await library.thumbnail(for: item)
                }
                if thumbnails[tile.id] == nil { thumbnails[tile.id] = UIImage() }
            }
            loadingThumbnails = false
            layout()
        }
    }
    private var loadingThumbnails = false

    nonisolated static func thumbnail(_ url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480, kCGImageSourceCreateThumbnailWithTransform: true]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }

    /// The next world: synthwave, then each bundled and found 360 picture in turn, round again.
    func nextWorld() {
        var index = -1
        if case .panorama(let url) = choice, let i = panoramas.firstIndex(where: { $0.path == url.path }) { index = i }
        let next = index + 1
        if next < panoramas.count { _ = press("pano:" + panoramas[next].path) } else { _ = press("synth") }
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
        case "nextpage": if (page + 1) * Self.perPage < panoramas.count + libraryItems.count { page += 1 }
        case "rescan": Task { @MainActor in await self.scan() }
        default:
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
        loadThumbnails()
        let shown = Array(tiles.dropFirst(page * Self.perPage).prefix(Self.perPage))
        panel.render(PlacesView(size: CGSize(width: 1600, height: 900), buttons: panel.buttons, hovered: panel.hovered, tiles: shown))
    }
}


/// The Places panel: the glass and buttons, with each picture tile's thumbnail under its name.
struct PlacesView: View {
    let size: CGSize
    let buttons: [ScenePanel.Button]
    let hovered: String?
    let tiles: [PlacesApp.Tile]

    var body: some View {
        ZStack(alignment: .topLeading) {
            PanelStyle.glass()
            ForEach(Array(tiles.enumerated()), id: \.element.id) { _, tile in
                if let image = tile.image, image.size.width > 0, let button = buttons.first(where: { $0.id == tile.id }) {
                    let r = CGRect(x: button.rect.minX * size.width, y: button.rect.minY * size.height,
                                   width: button.rect.width * size.width, height: button.rect.height * size.height).insetBy(dx: 6, dy: 6)
                    let radius = min(44, r.height * 0.16)
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: r.width, height: r.height).clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(LinearGradient(colors: [.clear, .clear, Color.black.opacity(0.78)], startPoint: .top, endPoint: .bottom)))
                        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(hovered == tile.id ? PanelStyle.pink : (tile.on ? PanelStyle.accent : Color.white.opacity(0.18)), lineWidth: hovered == tile.id || tile.on ? 6 : 2))
                        .overlay(alignment: .bottom) {
                            Text(tile.label).font(.system(size: 52, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6).padding(.bottom, 18).padding(.horizontal, 12)
                        }
                        .position(x: r.midX, y: r.midY)
                }
            }
            // The other controls, and the tiles still loading their pictures.
            ButtonsView(size: size, buttons: buttons.filter { b in !tiles.contains { $0.id == b.id && ($0.image?.size.width ?? 0) > 0 } },
                        hovered: hovered, title: nil, titleHighlight: false, transparent: true)
        }
    }
}
