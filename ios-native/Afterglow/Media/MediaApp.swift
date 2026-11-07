import SwiftUI
import Metal
import simd
import UIKit

/// A grid of thumbnails with labels, for albums and items, rendered to a panel texture.
struct GridView: View {
    let size: CGSize
    let cells: [GridCell]
    let hovered: String?
    let title: String
    let columns: Int

    var body: some View {
        let gap: CGFloat = 14
        let cellW = (size.width - gap * CGFloat(columns + 1)) / CGFloat(columns)
        let rows = max(1, Int(ceil(Double(cells.count) / Double(columns))))
        let cellH = min(cellW * 0.8, (size.height - 120 - gap * CGFloat(rows + 1)) / CGFloat(rows))
        ZStack(alignment: .topLeading) {
            PanelStyle.glass()
            Text(title).font(.system(size: 54, weight: .semibold, design: .rounded)).foregroundStyle(PanelStyle.text).lineLimit(1)
                .padding(.horizontal, 44).padding(.top, 26)
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                let col = index % columns, row = index / columns
                let x = gap + CGFloat(col) * (cellW + gap), y = 110 + gap + CGFloat(row) * (cellH + gap)
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 18).fill(hovered == cell.id ? PanelStyle.keyHover : PanelStyle.key)
                    if let image = cell.image {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: cellW, height: cellH).clipShape(RoundedRectangle(cornerRadius: 18))
                            .opacity(hovered == cell.id ? 0.75 : 1)
                    }
                    if cell.image == nil {
                        HStack(spacing: 20) {
                            Image(systemName: "rectangle.stack.fill").font(.system(size: 44)).foregroundStyle(PanelStyle.accent)
                            Text(cell.label).font(.system(size: 46, weight: .medium, design: .rounded)).foregroundStyle(PanelStyle.text).lineLimit(1).minimumScaleFactor(0.6)
                        }
                        .frame(width: cellW, height: cellH, alignment: .leading).padding(.leading, 28)
                    } else {
                        Text(cell.label).font(.system(size: 36, weight: .medium, design: .rounded)).foregroundStyle(PanelStyle.text)
                            .lineLimit(2).padding(10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.45)))
                            .padding(8)
                    }
                }
                .frame(width: cellW, height: cellH)
                .position(x: x + cellW / 2, y: y + cellH / 2)
            }
        }
    }
}

struct GridCell: Identifiable {
    let id: String
    let image: UIImage?
    let label: String
}

/// The media app: albums, their items as a thumbnail grid, and the viewer with its controls.
/// Photos hang as a flat frame ahead, spatial photos and videos with an eye each, panoramas on a
/// cylinder, 360 and 180 pictures and videos around the viewer in any of the stereo layouts, and
/// a format button cycles the projection for files whose metadata does not say.
@MainActor
final class MediaApp {
    enum Screen { case albums, items, viewing }
    struct Format: Equatable {
        var projection: MediaProjection
        var layout: MediaLayout
        var label: String
    }

    static let formats: [Format] = [
        Format(projection: MediaProjectionFlat, layout: MediaLayoutMono, label: "Flat"),
        Format(projection: MediaProjectionFlat, layout: MediaLayoutSideBySide, label: "Flat SBS"),
        Format(projection: MediaProjectionFlat, layout: MediaLayoutTopBottom, label: "Flat TB"),
        Format(projection: MediaProjectionEquirect360, layout: MediaLayoutMono, label: "360"),
        Format(projection: MediaProjectionEquirect360, layout: MediaLayoutSideBySide, label: "360 SBS"),
        Format(projection: MediaProjectionEquirect360, layout: MediaLayoutTopBottom, label: "360 TB"),
        Format(projection: MediaProjectionEquirect180, layout: MediaLayoutMono, label: "180"),
        Format(projection: MediaProjectionEquirect180, layout: MediaLayoutSideBySide, label: "180 SBS"),
        Format(projection: MediaProjectionEquirect180, layout: MediaLayoutTopBottom, label: "180 TB"),
        Format(projection: MediaProjectionFisheye180, layout: MediaLayoutMono, label: "Fisheye"),
        Format(projection: MediaProjectionFisheye180, layout: MediaLayoutSideBySide, label: "Fisheye SBS"),
        Format(projection: MediaProjectionCylinder, layout: MediaLayoutMono, label: "Panorama"),
    ]

    let library: MediaLibrary
    let player: VideoPlayer
    let grid: ScenePanel
    let controls: ScenePanel
    private(set) var screen = Screen.albums
    private(set) var albums: [MediaAlbum] = []
    private(set) var album: MediaAlbum?
    private(set) var items: [MediaItem] = []
    private var thumbnails: [String: UIImage] = [:]
    private(set) var page = 0
    private let perPage = 8
    private let albumsPerPage = 8
    private(set) var albumPage = 0
    private(set) var current: MediaItem?
    private(set) var formatIndex = 0
    private(set) var picture: MTLTexture?
    private(set) var eyes: MTLTexture?
    private(set) var yaw: Float = 0
    private var gridVersion = 0
    private var loading = false
    private let device: MTLDevice
    var window = BrowserWindow()
    /// Asks the host to present the Files picker.
    var onPickFolder: (() -> Void)?
    /// Files mode: folders instead of albums, with a search typed on the keyboard.
    private(set) var files: FileSource?
    private var folder: FileSource.Folder?
    private(set) var query = ""
    var isFiles: Bool { files != nil }

    init(device: MTLDevice) {
        self.device = device
        library = MediaLibrary(device: device)
        player = VideoPlayer(device: device)
        grid = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 1000)
        grid.pane.widthMeters = 1.4
        controls = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 260)
        controls.pane.widthMeters = 1.1
    }

    var format: Format { Self.formats[formatIndex] }
    var isProjected: Bool { screen == .viewing && format.projection != MediaProjectionFlat }

    /// Opens on the Files folders rather than the Photos albums.
    func openFiles(head: simd_float4x4) {
        files = FileSource()
        files?.onPicked = { [weak self] folder in self?.openFolder(folder) }
        open(head: head)
    }

    func open(head: simd_float4x4) {
        window.place(ahead: head, distance: 1.5)
        grid.pane.centre = window.centre
        grid.pane.right = window.right
        grid.pane.up = window.up
        controls.pane.right = window.right
        controls.pane.up = window.up
        controls.pane.centre = window.centre - window.up * 0.55
        if files == nil {
            Task { @MainActor in
                guard await library.requestAccess() else { return }
                albums = library.albums()
                screen = .albums
                gridVersion += 1
                layoutGrid()
            }
        }
        layoutGrid()
        layoutControls()
    }

    /// Text from the keyboard while the Files grid is up: the search.
    func type(_ text: String) {
        query += text
        refreshFolder()
    }

    func key(_ name: String) {
        switch name {
        case "Backspace": if !query.isEmpty { query.removeLast() }
        case "Clear": query = ""
        default: return
        }
        refreshFolder()
    }

    private func openFolder(_ folder: FileSource.Folder) {
        self.folder = folder
        query = ""
        refreshFolder()
    }

    private func refreshFolder() {
        guard let files, let folder else { return }
        screen = .items
        let wanted = query
        Task { @MainActor in
            let found = await files.items(in: folder, query: wanted)
            guard wanted == query else { return }
            items = found
            page = 0
            thumbnails.removeAll()
            gridVersion += 1
            layoutGrid()
            loadThumbnails()
        }
        gridVersion += 1
        layoutGrid()
    }

    func close() {
        player.close()
        picture = nil
        eyes = nil
    }

    private func layoutGrid() {
        var buttons: [ScenePanel.Button] = []
        let columns = screen == .albums ? 2 : 4
        let count: Int
        switch screen {
        case .albums: count = min(albumsPerPage, max(0, (files?.folders.count ?? albums.count) - albumPage * albumsPerPage))
        case .items: count = min(perPage, items.count - page * perPage)
        case .viewing: count = 0
        }
        let gap: CGFloat = 14 / 1600, top: CGFloat = (110 + 14) / 1000
        let cellW = (1 - gap * CGFloat(columns + 1)) / CGFloat(columns)
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        let cellH = min(cellW * 1.6 * (screen == .albums ? 0.25 : 0.8), (1 - top - gap * CGFloat(rows + 1)) / CGFloat(rows))
        for i in 0..<max(count, 0) {
            let col = i % columns, row = i / columns
            let id: String
            switch screen {
            case .albums: id = "album:\(albumPage * albumsPerPage + i)"
            case .items: id = "item:\(page * perPage + i)"
            case .viewing: id = ""
            }
            buttons.append(.init(id: id, rect: CGRect(x: gap + CGFloat(col) * (cellW + gap), y: top + CGFloat(row) * (cellH + gap), width: cellW, height: cellH), label: ""))
        }
        // The header's own buttons: back, previous and next page.
        if files != nil {
            buttons.append(.init(id: "addfolder", rect: CGRect(x: 0.50, y: 0.012, width: 0.2, height: 0.1), label: "Folder", wide: true, icon: "folder.badge.plus", style: .pill))
        }
        buttons.append(.init(id: "back", rect: CGRect(x: 0.72, y: 0.012, width: 0.08, height: 0.1), label: "Back", icon: "chevron.left", style: .round))
        buttons.append(.init(id: "prev", rect: CGRect(x: 0.81, y: 0.012, width: 0.08, height: 0.1), label: "Previous page", icon: "arrow.left", style: .round))
        buttons.append(.init(id: "next", rect: CGRect(x: 0.90, y: 0.012, width: 0.08, height: 0.1), label: "Next page", icon: "arrow.right", style: .round))
        grid.set(buttons: buttons, version: "grid\(gridVersion)|\(screen)|\(page)|\(thumbnails.count)")
    }

    private func layoutControls() {
        var b: [ScenePanel.Button] = []
        let y: CGFloat = 0.05, h: CGFloat = 0.42
        let isVideo = current.map { $0.kind == .video || $0.kind == .video180 || $0.kind == .video360 || $0.kind == .spatialVideo } ?? false
        var items: [(String, String, String, CGFloat)] = [("exit", "Back to the album", "chevron.left", 0.07), ("prevItem", "Previous", "backward.end.fill", 0.07)]
        if isVideo {
            items += [("back10", "Back 10 s", "gobackward.10", 0.07), ("play", player.isPlaying ? "Pause" : "Play", player.isPlaying ? "pause.fill" : "play.fill", 0.07), ("fwd10", "Ahead 10 s", "goforward.10", 0.07)]
        }
        items += [("nextItem", "Next", "forward.end.fill", 0.07), ("format", format.label, "", 0.2), ("recentre", "Recentre", "scope", 0.07), ("yawL", "Turn left", "rotate.left", 0.07), ("yawR", "Turn right", "rotate.right", 0.07)]
        var x: CGFloat = 0.01
        for (id, label, icon, w) in items {
            b.append(.init(id: id, rect: CGRect(x: x, y: y, width: w, height: h), label: label, wide: true, icon: icon.isEmpty ? nil : icon, style: icon.isEmpty ? .pill : .round, accent: id == "play" || id == "exit"))
            x += w + 0.01
        }
        if isVideo {
            // The seek bar: ten steps.
            for i in 0..<10 {
                b.append(.init(id: "seek:\(i)", rect: CGRect(x: 0.02 + CGFloat(i) * 0.096, y: 0.55, width: 0.09, height: 0.4), label: "", wide: true))
            }
        } else if let current, let i = items0(current) {
            // The filmstrip: the pictures round this one in the album, pressable.
            let around = max(0, i - 3)...min(self.items.count - 1, i + 3)
            let w: CGFloat = 0.96 / 7
            for (slot, j) in around.enumerated() {
                b.append(.init(id: "strip:\(j)", rect: CGRect(x: 0.02 + CGFloat(slot) * w, y: 0.52, width: w - 0.008, height: 0.45), label: "", wide: true, accent: j == i))
            }
        }
        controls.set(buttons: b, version: "controls|\(format.label)|\(player.isPlaying)|\(Int(player.time))|\(Int(player.duration))")
    }

    func press(_ id: String) {
        switch id {
        case "back":
            if screen == .items { screen = .albums; page = 0 }
            else if screen == .viewing { exitViewer() }
            layoutGrid()
        case "prev":
            if screen == .albums { if albumPage > 0 { albumPage -= 1 } } else if page > 0 { page -= 1 }
            layoutGrid()
        case "next":
            if screen == .albums { if (albumPage + 1) * albumsPerPage < (files?.folders.count ?? albums.count) { albumPage += 1 } }
            else if (page + 1) * perPage < items.count { page += 1 }
            layoutGrid()
        case "exit": exitViewer()
        case "play": player.togglePlay(); layoutControls()
        case "back10": player.skip(-10)
        case "fwd10": player.skip(10)
        case "prevItem": step(-1)
        case "nextItem": step(1)
        case "format":
            formatIndex = (formatIndex + 1) % Self.formats.count
            log("[Media] Format \(format.label)")
            layoutControls()
        case "recentre": yaw = 0
        case "yawL": yaw -= .pi / 12
        case "yawR": yaw += .pi / 12
        case "addfolder": onPickFolder?()
        default:
            if id.hasPrefix("album:"), let i = Int(id.dropFirst(6)) {
                if let files, files.folders.indices.contains(i) { openFolder(files.folders[i]) }
                else if albums.indices.contains(i) { openAlbum(albums[i]) }
            }
            else if id.hasPrefix("item:"), let i = Int(id.dropFirst(5)), items.indices.contains(i) { view(items[i]) }
            else if id.hasPrefix("seek:"), let i = Int(id.dropFirst(5)) { player.seek(fraction: Double(i) / 10) }
            else if id.hasPrefix("strip:"), let i = Int(id.dropFirst(6)), items.indices.contains(i) { view(items[i]) }
        }
    }

    private func openAlbum(_ album: MediaAlbum) {
        self.album = album
        items = library.items(in: album)
        page = 0
        screen = .items
        thumbnails.removeAll()
        layoutGrid()
        loadThumbnails()
    }

    private var stripWanted: Set<String> = []
    private var stripLoading = false
    private func loadStripThumbnails() {
        guard !stripLoading, !stripWanted.isEmpty else { return }
        stripLoading = true
        let wanted = items.filter { stripWanted.contains($0.id) && thumbnails[$0.id] == nil }
        stripWanted.removeAll()
        Task { @MainActor in
            for item in wanted {
                let image: UIImage?
                if let url = item.fileURL { image = await FileSource.thumbnail(for: url) } else { image = await library.thumbnail(for: item) }
                if let image { thumbnails[item.id] = image }
            }
            stripLoading = false
            layoutControls()
        }
    }

    private func loadThumbnails() {
        let wanted = items.dropFirst(page * perPage).prefix(perPage).filter { thumbnails[$0.id] == nil }
        guard !wanted.isEmpty, !loading else { return }
        loading = true
        Task { @MainActor in
            var got = 0
            for item in wanted {
                let image: UIImage?
                if let url = item.fileURL { image = await FileSource.thumbnail(for: url) } else { image = await library.thumbnail(for: item) }
                if let image { thumbnails[item.id] = image; got += 1 }
            }
            log("[Photos] \(got) of \(wanted.count) thumbnails loaded")
            loading = false
            gridVersion += 1
            layoutGrid()
            if got > 0 { loadThumbnails() }   // the rest, or stop: nothing loads this way for these
        }
    }

    private func items0(_ item: MediaItem) -> Int? { items.firstIndex { $0.id == item.id } }

    private func step(_ delta: Int) {
        guard let current, let i = items.firstIndex(where: { $0.id == current.id }) else { return }
        let j = i + delta
        if items.indices.contains(j) { view(items[j]) }
    }

    /// Opens an item in the viewer with the format its kind implies.
    func view(_ item: MediaItem) {
        player.close()
        picture = nil
        eyes = nil
        current = item
        screen = .viewing
        yaw = 0
        var label: String
        switch item.kind {
        case .photo360, .video360: label = "360"
        case .video180, .photo180: label = "180"
        case .panorama: label = "Panorama"
        default: label = "Flat"
        }
        if let layout = item.fileLayout, label != "Panorama" {
            if layout == .sideBySide { label += " SBS" } else if layout == .topBottom { label += " TB" }
        }
        formatIndex = Self.formats.firstIndex { $0.label == label } ?? 0
        log("[Media] Viewing \(item.kind.rawValue) \(item.title) as \(format.label)")
        Task { @MainActor in
            if item.isVideo {
                await player.open(item: item, stereo: item.kind == .spatialVideo)
            } else {
                let loaded = await library.picture(for: item)
                picture = loaded.texture
                eyes = loaded.eyes
            }
            layoutControls()
        }
        layoutGrid()
        layoutControls()
    }

    private func exitViewer() {
        player.close()
        picture = nil
        eyes = nil
        current = nil
        screen = items.isEmpty ? .albums : .items
        layoutGrid()
    }

    /// The uniforms for this frame's media pass, and the textures.
    func uniforms() -> MediaUniforms {
        var u = MediaUniforms()
        u.projection = Int32(format.projection.rawValue)
        u.layout = Int32((eyes != nil || player.isStereo) ? MediaLayoutArray.rawValue : format.layout.rawValue)
        u.span = format.projection == MediaProjectionCylinder ? cylinderSpan() : (format.projection == MediaProjectionEquirect180 || format.projection == MediaProjectionFisheye180 ? .pi : 2 * .pi)
        u.height = cylinderHeight()
        u.yaw = yaw
        u.brightness = 1
        u.swapEyes = 0
        return u
    }

    // A panorama's span from its shape, 60 degrees tall as the Unity app assumes: the width over
    // the height times 60 degrees, between 60 and 360.
    private func cylinderHeight() -> Float { tan(Float.pi / 6) }
    private func cylinderSpan() -> Float {
        if let span = current?.fileSpan { return span * .pi / 180 }
        guard let current, current.pixelSize.height > 0 else { return .pi }
        let aspect = Float(current.pixelSize.width / current.pixelSize.height)
        return min(2 * .pi, max(.pi / 3, aspect * .pi / 3))
    }

    /// The flat frame's size: 1.6 m wide, the picture's shape.
    func flatQuad() -> [QuadVertex] {
        var w = window
        let aspect: Float
        if let current, current.pixelSize.height > 0 { aspect = Float(current.pixelSize.width / current.pixelSize.height) } else { aspect = 16.0 / 9.0 }
        let layoutAspect: Float = format.layout == MediaLayoutSideBySide && eyes == nil ? aspect / 2 : (format.layout == MediaLayoutTopBottom && eyes == nil ? aspect * 2 : aspect)
        w.widthMeters = 1.6
        w.aspect = layoutAspect
        return w.quad
    }

    /// Per frame: the current video frame, and the panels.
    func frame(hostTime: Double) -> (picture: MTLTexture?, eyes: MTLTexture?) {
        if screen == .viewing, let current, current.isVideo {
            let f = player.frame(at: hostTime)
            if Int(player.time) % 1 == 0 { layoutControls() }
            return (f.texture, f.eyes)
        }
        return (picture, eyes)
    }

    func render() {
        if screen == .viewing {
            // The filmstrip's pictures draw under its buttons.
            var strip: [(String, UIImage?)] = []
            for b in controls.buttons where b.id.hasPrefix("strip:") {
                if let j = Int(b.id.dropFirst(6)), items.indices.contains(j) {
                    strip.append((b.id, thumbnails[items[j].id]))
                    if thumbnails[items[j].id] == nil { stripWanted.insert(items[j].id) }
                }
            }
            loadStripThumbnails()
            controls.render(FilmstripView(size: CGSize(width: 1600, height: 260), buttons: controls.buttons, hovered: controls.hovered, strip: strip))
        } else {
            var cells: [GridCell] = []
            switch screen {
            case .albums:
                if let files { cells = files.folders.dropFirst(albumPage * albumsPerPage).prefix(albumsPerPage).map { GridCell(id: $0.id, image: nil, label: $0.name) } }
                else { cells = albums.dropFirst(albumPage * albumsPerPage).prefix(albumsPerPage).map { GridCell(id: $0.id, image: nil, label: "\($0.title)  ·  \($0.count)") } }
            case .items: cells = items.dropFirst(page * perPage).prefix(perPage).map { GridCell(id: $0.id, image: thumbnails[$0.id], label: "\($0.kind.rawValue) \($0.title)") }
            case .viewing: break
            }
            let title: String
            if screen == .albums {
                let total = files?.folders.count ?? albums.count
                title = (files != nil ? "Files" : "Photos") + (total > albumsPerPage ? " · page \(albumPage + 1) of \((total + albumsPerPage - 1) / albumsPerPage)" : "")
            }
            else if files != nil { title = "\(folder?.name ?? "") · \(query.isEmpty ? "type to search" : "search: " + query + "▏") · page \(page + 1) of \(max(1, (items.count + perPage - 1) / perPage))" }
            else { title = "\(album?.title ?? "") · page \(page + 1) of \(max(1, (items.count + perPage - 1) / perPage))" }
            grid.render(GridView(size: CGSize(width: 1600, height: 1000), cells: cells, hovered: grid.hovered.flatMap { h in
                // The hovered button id maps to the cell id.
                if h.hasPrefix("album:"), let i = Int(h.dropFirst(6)) {
                    if let files, files.folders.indices.contains(i) { return files.folders[i].id }
                    if albums.indices.contains(i) { return albums[i].id }
                }
                if h.hasPrefix("item:"), let i = Int(h.dropFirst(5)), items.indices.contains(i) { return items[i].id }
                return nil
            }, title: title, columns: screen == .albums ? 2 : 4))
        }
    }
}


/// The viewer's controls with the filmstrip's pictures under their buttons.
struct FilmstripView: View {
    let size: CGSize
    let buttons: [ScenePanel.Button]
    let hovered: String?
    let strip: [(String, UIImage?)]

    var body: some View {
        ZStack(alignment: .topLeading) {
            PanelStyle.glass()
            ForEach(strip, id: \.0) { id, image in
                if let image, let button = buttons.first(where: { $0.id == id }) {
                    let r = CGRect(x: button.rect.minX * size.width, y: button.rect.minY * size.height,
                                   width: button.rect.width * size.width, height: button.rect.height * size.height).insetBy(dx: 6, dy: 6)
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: r.width, height: r.height).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(hovered == id ? PanelStyle.pink : (button.accent ? PanelStyle.accent : Color.white.opacity(0.2)), lineWidth: hovered == id || button.accent ? 6 : 2))
                        .position(x: r.midX, y: r.midY)
                }
            }
            ButtonsView(size: size, buttons: buttons.filter { b in !strip.contains { $0.0 == b.id && $0.1 != nil } }, hovered: hovered, title: nil, titleHighlight: false, transparent: true)
        }
    }
}
