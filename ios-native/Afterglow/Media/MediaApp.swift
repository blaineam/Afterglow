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
        let cellH = min(cellW * 0.8, (size.height - 90 - gap * CGFloat(rows + 1)) / CGFloat(rows))
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 36).fill(PanelStyle.background)
            Text(title).font(.system(size: 36, weight: .semibold, design: .rounded)).foregroundStyle(PanelStyle.text)
                .padding(.horizontal, 30).padding(.top, 18)
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                let col = index % columns, row = index / columns
                let x = gap + CGFloat(col) * (cellW + gap), y = 80 + gap + CGFloat(row) * (cellH + gap)
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 18).fill(hovered == cell.id ? PanelStyle.keyHover : PanelStyle.key)
                    if let image = cell.image {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: cellW, height: cellH).clipShape(RoundedRectangle(cornerRadius: 18))
                            .opacity(hovered == cell.id ? 0.75 : 1)
                    }
                    Text(cell.label).font(.system(size: 22, weight: .medium, design: .rounded)).foregroundStyle(PanelStyle.text)
                        .lineLimit(2).padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.45)))
                        .padding(8)
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
    private let perPage = 15
    private(set) var current: MediaItem?
    private(set) var formatIndex = 0
    private(set) var picture: MTLTexture?
    private(set) var eyes: MTLTexture?
    private(set) var yaw: Float = 0
    private var gridVersion = 0
    private var loading = false
    private let device: MTLDevice
    var window = BrowserWindow()

    init(device: MTLDevice) {
        self.device = device
        library = MediaLibrary(device: device)
        player = VideoPlayer(device: device)
        grid = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 1000)
        grid.pane.widthMeters = 1.4
        controls = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 200)
        controls.pane.widthMeters = 1.1
    }

    var format: Format { Self.formats[formatIndex] }
    var isProjected: Bool { screen == .viewing && format.projection != MediaProjectionFlat }

    func open(head: simd_float4x4) {
        window.place(ahead: head, distance: 1.5)
        grid.pane.centre = window.centre
        grid.pane.right = window.right
        grid.pane.up = window.up
        controls.pane.right = window.right
        controls.pane.up = window.up
        controls.pane.centre = window.centre - window.up * 0.55
        Task { @MainActor in
            guard await library.requestAccess() else { return }
            albums = library.albums()
            screen = .albums
            gridVersion += 1
            layoutGrid()
        }
        layoutGrid()
        layoutControls()
    }

    func close() {
        player.close()
        picture = nil
        eyes = nil
    }

    private func layoutGrid() {
        var buttons: [ScenePanel.Button] = []
        let columns = 5
        let count: Int
        switch screen {
        case .albums: count = albums.count
        case .items: count = min(perPage, items.count - page * perPage)
        case .viewing: count = 0
        }
        let gap: CGFloat = 14 / 1600, top: CGFloat = (80 + 14) / 1000
        let cellW = (1 - gap * CGFloat(columns + 1)) / CGFloat(columns)
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        let cellH = min(cellW * 1.6 * 0.8, (1 - top - gap * CGFloat(rows + 1)) / CGFloat(rows))
        for i in 0..<max(count, 0) {
            let col = i % columns, row = i / columns
            let id: String
            switch screen {
            case .albums: id = "album:\(i)"
            case .items: id = "item:\(page * perPage + i)"
            case .viewing: id = ""
            }
            buttons.append(.init(id: id, rect: CGRect(x: gap + CGFloat(col) * (cellW + gap), y: top + CGFloat(row) * (cellH + gap), width: cellW, height: cellH), label: ""))
        }
        // The header's own buttons: back, previous and next page.
        buttons.append(.init(id: "back", rect: CGRect(x: 0.72, y: 0.01, width: 0.08, height: 0.07), label: "‹"))
        buttons.append(.init(id: "prev", rect: CGRect(x: 0.81, y: 0.01, width: 0.08, height: 0.07), label: "◀"))
        buttons.append(.init(id: "next", rect: CGRect(x: 0.90, y: 0.01, width: 0.08, height: 0.07), label: "▶"))
        grid.set(buttons: buttons, version: "grid\(gridVersion)|\(screen)|\(page)|\(thumbnails.count)")
    }

    private func layoutControls() {
        var b: [ScenePanel.Button] = []
        let y: CGFloat = 0.08, h: CGFloat = 0.42
        let items: [(String, String, CGFloat)] = [("exit", "✕", 0.07), ("prevItem", "⏮", 0.07), ("back10", "-10", 0.09), ("play", player.isPlaying ? "⏸" : "▶", 0.09),
                                                  ("fwd10", "+10", 0.09), ("nextItem", "⏭", 0.07), ("format", format.label, 0.17), ("recentre", "⌖", 0.07), ("yawL", "↶", 0.07), ("yawR", "↷", 0.07)]
        var x: CGFloat = 0.02
        for (id, label, w) in items {
            b.append(.init(id: id, rect: CGRect(x: x, y: y, width: w, height: h), label: label, wide: true))
            x += w + 0.008
        }
        // The seek bar: ten steps.
        for i in 0..<10 {
            b.append(.init(id: "seek:\(i)", rect: CGRect(x: 0.02 + CGFloat(i) * 0.096, y: 0.56, width: 0.09, height: 0.36), label: "", wide: true))
        }
        controls.set(buttons: b, version: "controls|\(format.label)|\(player.isPlaying)|\(Int(player.time))|\(Int(player.duration))")
    }

    func press(_ id: String) {
        switch id {
        case "back":
            if screen == .items { screen = .albums; page = 0 }
            else if screen == .viewing { exitViewer() }
            layoutGrid()
        case "prev": if page > 0 { page -= 1; layoutGrid() }
        case "next": if (page + 1) * perPage < items.count { page += 1; layoutGrid() }
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
        default:
            if id.hasPrefix("album:"), let i = Int(id.dropFirst(6)), albums.indices.contains(i) { openAlbum(albums[i]) }
            else if id.hasPrefix("item:"), let i = Int(id.dropFirst(5)), items.indices.contains(i) { view(items[i]) }
            else if id.hasPrefix("seek:"), let i = Int(id.dropFirst(5)) { player.seek(fraction: Double(i) / 10) }
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

    private func loadThumbnails() {
        let wanted = items.dropFirst(page * perPage).prefix(perPage).filter { thumbnails[$0.id] == nil }
        guard !wanted.isEmpty, !loading else { return }
        loading = true
        Task { @MainActor in
            var got = 0
            for item in wanted {
                if let image = await library.thumbnail(for: item) { thumbnails[item.id] = image; got += 1 }
            }
            log("[Photos] \(got) of \(wanted.count) thumbnails loaded")
            loading = false
            gridVersion += 1
            layoutGrid()
            if got > 0 { loadThumbnails() }   // the rest, or stop: nothing loads this way for these
        }
    }

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
        let label: String
        switch item.kind {
        case .photo360, .video360: label = "360"
        case .video180: label = "180"
        case .panorama: label = "Panorama"
        default: label = "Flat"
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
            controls.render(ButtonsView(size: CGSize(width: 1600, height: 200), buttons: controls.buttons, hovered: controls.hovered,
                                        title: nil, titleHighlight: false))
        } else {
            var cells: [GridCell] = []
            switch screen {
            case .albums: cells = albums.map { GridCell(id: $0.id, image: nil, label: "\($0.title) (\($0.count))") }
            case .items: cells = items.dropFirst(page * perPage).prefix(perPage).map { GridCell(id: $0.id, image: thumbnails[$0.id], label: "\($0.kind.rawValue) \($0.title)") }
            case .viewing: break
            }
            let title = screen == .albums ? "Media" : "\(album?.title ?? "") · page \(page + 1) of \(max(1, (items.count + perPage - 1) / perPage))"
            grid.render(GridView(size: CGSize(width: 1600, height: 1000), cells: cells, hovered: grid.hovered.flatMap { h in
                // The hovered button id maps to the cell id.
                if h.hasPrefix("album:"), let i = Int(h.dropFirst(6)), albums.indices.contains(i) { return albums[i].id }
                if h.hasPrefix("item:"), let i = Int(h.dropFirst(5)), items.indices.contains(i) { return items[i].id }
                return nil
            }, title: title, columns: 5))
        }
    }
}
