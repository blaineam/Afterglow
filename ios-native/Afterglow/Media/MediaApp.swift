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
    var albums = false
    var buttons: [ScenePanel.Button] = []
    var emptyText: String? = nil

    var body: some View {
        // The same geometry as the buttons: the grid under the tabs, arrows at the right.
        let gap = 0.009 * size.width, top = 0.125 * size.height, left = 0.01 * size.width, gridWidth = 0.90 * size.width
        let rowsShown = albums ? MediaApp.albumRows : MediaApp.itemRows
        let cellW = (gridWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellH = (0.99 * size.height - top - gap * CGFloat(rowsShown - 1)) / CGFloat(rowsShown)
        ZStack(alignment: .topLeading) {
            PanelStyle.glass()
            if !title.isEmpty {
                Text(title).font(.system(size: 54, weight: .semibold, design: .rounded)).foregroundStyle(PanelStyle.text).lineLimit(1)
                    .padding(.horizontal, 44).padding(.top, 120)
            }
            // The tabs, the folder and back buttons, and the scroll arrows: everything that is not a cell.
            ButtonsView(size: size, buttons: buttons.filter { !$0.id.hasPrefix("item:") && !$0.id.hasPrefix("album:") }, hovered: hovered, title: nil, titleHighlight: false, transparent: true)
            if let emptyText, cells.isEmpty {
                Text(emptyText).font(.system(size: 54, weight: .medium, design: .rounded)).foregroundStyle(PanelStyle.dim)
                    .frame(width: size.width, height: size.height * 0.6).position(x: size.width / 2, y: size.height * 0.55)
            }
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                let col = index % columns, row = index / columns
                let x = left + CGFloat(col) * (cellW + gap), y = top + CGFloat(row) * (cellH + gap)
                let imageH = albums ? cellH - 110 : cellH
                VStack(spacing: 10) {
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 22, style: .continuous).fill(hovered == cell.id ? PanelStyle.keyHover : PanelStyle.key)
                        if let image = cell.image, image.size.width > 0 {
                            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: cellW, height: imageH).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .opacity(hovered == cell.id ? 0.8 : 1)
                        } else if albums {
                            Image(systemName: "rectangle.stack.fill").font(.system(size: 90)).foregroundStyle(PanelStyle.dim).frame(width: cellW, height: imageH)
                        }
                        if !albums && !cell.label.isEmpty {
                            Text(cell.label).font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Capsule().fill(Color.black.opacity(0.55)))
                                .padding(12)
                        }
                        RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(hovered == cell.id ? PanelStyle.pink : Color.white.opacity(0.14), lineWidth: hovered == cell.id ? 6 : 2)
                    }
                    .frame(width: cellW, height: imageH)
                    if albums {
                        Text(cell.label).font(.system(size: 42, weight: .medium, design: .rounded)).foregroundStyle(hovered == cell.id ? PanelStyle.pink : PanelStyle.text)
                            .lineLimit(2).minimumScaleFactor(0.6).multilineTextAlignment(.center).frame(width: cellW, height: 96)
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
    /// The tabs across the top: the library and the collections made for a headset, and the
    /// user's albums as covers. The grid under them scrolls by rows: the arrows at its side,
    /// the gaze held at its top or bottom edge, a pinch dragged up or down over it, or a drag
    /// on the phone (the owner's 687 albums could not be browsed eight names a page, 2026-11-07).
    enum Tab: String, CaseIterable { case library, albums, spatial, panoramas, threeSixty, videos
        var title: String { switch self { case .library: return "Library"; case .albums: return "Albums"; case .spatial: return "Spatial"; case .panoramas: return "Panoramas"; case .threeSixty: return "360°"; case .videos: return "Videos" } }
        var icon: String { switch self { case .library: return "photo.on.rectangle"; case .albums: return "rectangle.stack"; case .spatial: return "cube.transparent"; case .panoramas: return "pano"; case .threeSixty: return "globe"; case .videos: return "film" } }
    }
    private(set) var tab = Tab.library
    private(set) var row = 0            // the first visible row of items
    private(set) var albumRow = 0       // and of albums
    static let itemColumns = 4, itemRows = 3, albumColumns = 4, albumRows = 2
    private var covers: [String: UIImage] = [:]
    private var coversLoading = false
    private var lastEdgeScroll: Double = 0
    private var dragStartY: Float?
    private var dragRows = 0
    /// Kept for the harness and the viewer: the page of the current row.
    var page: Int { row / Self.itemRows }
    private var perPage: Int { Self.itemColumns * Self.itemRows }
    private(set) var current: MediaItem?
    /// The viewer's controls out of the way (a select brings them back), and the projection picker.
    private(set) var controlsHidden = false
    private(set) var formatMenu = false
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
                gridVersion += 1
                selectTab(.library)
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
            row = 0
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

    /// The album a tab stands for, from the library's collections.
    private func album(for tab: Tab) -> MediaAlbum? {
        switch tab {
        case .library: return albums.first { $0.collection?.assetCollectionSubtype == .smartAlbumUserLibrary }
        case .spatial: return albums.first { $0.collection?.assetCollectionSubtype == .smartAlbumSpatial }
        case .panoramas: return albums.first { $0.collection?.assetCollectionSubtype == .smartAlbumPanoramas }
        case .threeSixty: return albums.first { $0.id == MediaLibrary.threeSixtyId }
        case .videos: return albums.first { $0.collection?.assetCollectionSubtype == .smartAlbumVideos }
        case .albums: return nil
        }
    }

    /// The user's own albums, for the Albums tab: everything that is not a smart collection.
    private var userAlbums: [MediaAlbum] { albums.filter { $0.collection?.assetCollectionType == .album } }

    func selectTab(_ newTab: Tab) {
        tab = newTab
        player.close()
        current = nil
        if newTab == .albums {
            screen = .albums
            albumRow = 0
            layoutGrid()
            loadCovers()
        } else if let a = album(for: newTab) {
            openAlbum(a, limit: newTab == .library ? 600 : 400)
        } else {
            album = nil
            items = []
            screen = .items
            layoutGrid()
        }
        log("[Media] Tab \(newTab.title): \(screen == .albums ? userAlbums.count : items.count) entries")
    }

    private var visibleAlbums: ArraySlice<MediaAlbum> {
        let all = files.map { _ in [MediaAlbum]() } ?? userAlbums
        let start = albumRow * Self.albumColumns
        return all.dropFirst(start).prefix(Self.albumColumns * Self.albumRows)
    }

    /// Scrolls the grid by rows, clamped to the content.
    func scroll(rows: Int) {
        if screen == .albums {
            let total = files?.folders.count ?? userAlbums.count
            let maxRow = max(0, (total + Self.albumColumns - 1) / Self.albumColumns - Self.albumRows)
            albumRow = min(max(albumRow + rows, 0), maxRow)
            loadCovers()
        } else if screen == .items {
            let maxRow = max(0, (items.count + Self.itemColumns - 1) / Self.itemColumns - Self.itemRows)
            row = min(max(row + rows, 0), maxRow)
            loadThumbnails()
        }
        layoutGrid()
    }

    /// A drag on the phone's screen over the grid: 150 points a row.
    private var panAccumulated: Float = 0
    func scrollBy(pixels: Float) {
        panAccumulated += pixels
        while panAccumulated > 150 { scroll(rows: -1); panAccumulated -= 150 }
        while panAccumulated < -150 { scroll(rows: 1); panAccumulated += 150 }
    }

    /// Per frame while the grid is up: the gaze held at the grid's top or bottom edge scrolls a
    /// row every half second; a pinch held on the grid and moved up or down scrolls with it.
    func gaze(uv: SIMD2<Float>?, pinchHeld: Bool, time: Double) {
        guard screen != .viewing else { return }
        if pinchHeld, let uv {
            if dragStartY == nil { dragStartY = uv.y; dragRows = 0 }
            let rowsNow = Int(((dragStartY ?? uv.y) - uv.y) / -0.09)
            if rowsNow != dragRows { scroll(rows: rowsNow - dragRows); dragRows = rowsNow }
            return
        }
        dragStartY = nil
        guard let uv, time - lastEdgeScroll > 0.5 else { return }
        if uv.y > 0.95 { lastEdgeScroll = time; scroll(rows: 1) }
        else if uv.y > 0.12 && uv.y < 0.18 { lastEdgeScroll = time; scroll(rows: -1) }
    }

    private func layoutGrid() {
        var buttons: [ScenePanel.Button] = []
        // The tabs (or, for Files, the folder button), then the grid with its arrows at the side.
        if files != nil {
            buttons.append(.init(id: "addfolder", rect: CGRect(x: 0.01, y: 0.012, width: 0.24, height: 0.095), label: "Add folder", wide: true, icon: "folder.badge.plus", style: .pill))
            if screen == .items {
                buttons.append(.init(id: "back", rect: CGRect(x: 0.27, y: 0.012, width: 0.2, height: 0.095), label: "Folders", wide: true, icon: "chevron.left", style: .pill))
            }
        } else {
            var x: CGFloat = 0.01
            for t in Tab.allCases {
                let w: CGFloat = t == .threeSixty || t == .videos || t == .spatial ? 0.14 : 0.16
                buttons.append(.init(id: "tab:\(t.rawValue)", rect: CGRect(x: x, y: 0.012, width: w - 0.008, height: 0.095), label: t.title, wide: true, icon: nil, style: .pill, accent: tab == t))
                x += w
            }
        }
        let columns = screen == .albums ? Self.albumColumns : Self.itemColumns
        let rowsShown = screen == .albums ? Self.albumRows : Self.itemRows
        let gap: CGFloat = 0.009, top: CGFloat = 0.125, left: CGFloat = 0.01, gridWidth: CGFloat = 0.90
        let cellW = (gridWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellH = (0.99 - top - gap * CGFloat(rowsShown - 1)) / CGFloat(rowsShown)
        let count: Int
        let first: Int
        switch screen {
        case .albums:
            let total = files?.folders.count ?? userAlbums.count
            first = albumRow * columns
            count = min(columns * rowsShown, max(0, total - first))
        case .items:
            first = row * columns
            count = min(columns * rowsShown, max(0, items.count - first))
        case .viewing: first = 0; count = 0
        }
        for i in 0..<count {
            let col = i % columns, r = i / columns
            let id = screen == .albums ? "album:\(first + i)" : "item:\(first + i)"
            buttons.append(.init(id: id, rect: CGRect(x: left + CGFloat(col) * (cellW + gap), y: top + CGFloat(r) * (cellH + gap), width: cellW, height: cellH), label: ""))
        }
        buttons.append(.init(id: "up", rect: CGRect(x: 0.925, y: top, width: 0.065, height: 0.11), label: "Up", icon: "chevron.up", style: .round))
        buttons.append(.init(id: "down", rect: CGRect(x: 0.925, y: 0.87, width: 0.065, height: 0.11), label: "Down", icon: "chevron.down", style: .round))
        grid.set(buttons: buttons, version: "grid\(gridVersion)|\(screen)|\(tab)|\(row)|\(albumRow)|\(thumbnails.count)|\(covers.count)|\(items.count)")
    }

    private func loadCovers() {
        let wanted = visibleAlbums.filter { covers[$0.id] == nil }
        guard !wanted.isEmpty, !coversLoading else { return }
        coversLoading = true
        Task { @MainActor in
            for a in wanted { covers[a.id] = await library.cover(for: a) ?? UIImage() }
            coversLoading = false
            gridVersion += 1
            layoutGrid()
            loadCovers()
        }
    }

    private func layoutControls() {
        var b: [ScenePanel.Button] = []
        let y: CGFloat = 0.05, h: CGFloat = 0.42
        if formatMenu {
            // The projections as a grid to pick from, with the current one lit.
            for (i, f) in Self.formats.enumerated() {
                let col = i % 4, row = i / 4
                b.append(.init(id: "fmt:\(i)", rect: CGRect(x: 0.02 + CGFloat(col) * 0.2, y: 0.04 + CGFloat(row) * 0.32, width: 0.19, height: 0.29), label: f.label, wide: true, style: .pill, accent: i == formatIndex))
            }
            b.append(.init(id: "fmtclose", rect: CGRect(x: 0.84, y: 0.04, width: 0.14, height: 0.29), label: "Done", wide: true, icon: "xmark", style: .pill))
            controls.set(buttons: b, version: "fmtmenu|\(formatIndex)")
            return
        }
        let isVideo = current.map { $0.kind == .video || $0.kind == .video180 || $0.kind == .video360 || $0.kind == .spatialVideo } ?? false
        var items: [(String, String, String, CGFloat)] = [("exit", "Back to the album", "chevron.left", 0.07), ("prevItem", "Previous", "backward.end.fill", 0.07)]
        if isVideo {
            items += [("back10", "Back 10 s", "gobackward.10", 0.07), ("play", player.isPlaying ? "Pause" : "Play", player.isPlaying ? "pause.fill" : "play.fill", 0.07), ("fwd10", "Ahead 10 s", "goforward.10", 0.07)]
        }
        items += [("nextItem", "Next", "forward.end.fill", 0.07), ("format", format.label, "", 0.2), ("recentre", "Recentre", "scope", 0.07), ("yawL", "Turn left", "rotate.left", 0.07), ("yawR", "Turn right", "rotate.right", 0.07), ("hide", "Hide the controls", "eye.slash", 0.07)]
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
        controls.set(buttons: b, version: "controls|\(format.label)|\(player.isPlaying)|\(Int(player.time))|\(Int(player.duration))|\(player.isLoading)|\(picture == nil && eyes == nil)")
    }

    func press(_ id: String) {
        switch id {
        case "back":
            if screen == .viewing { exitViewer() }
            else if files != nil { screen = .albums; layoutGrid() }
            else { selectTab(.albums) }
        case "up", "prev": scroll(rows: -(screen == .albums ? Self.albumRows : Self.itemRows))
        case "down", "next": scroll(rows: screen == .albums ? Self.albumRows : Self.itemRows)
        case "exit": exitViewer()
        case "play": player.togglePlay(); layoutControls()
        case "back10": player.skip(-10)
        case "fwd10": player.skip(10)
        case "prevItem": step(-1)
        case "nextItem": step(1)
        case "format": formatMenu = true; layoutControls()
        case "fmtclose": formatMenu = false; layoutControls()
        case "hide": controlsHidden = true; log("[Media] Controls hidden; a select brings them back")
        case "recentre": yaw = 0
        case "yawL": yaw -= .pi / 12
        case "yawR": yaw += .pi / 12
        case "addfolder": onPickFolder?()
        default:
            if id.hasPrefix("tab:"), let t = Tab(rawValue: String(id.dropFirst(4))) { selectTab(t) }
            else if id.hasPrefix("album:"), let i = Int(id.dropFirst(6)) {
                if let files, files.folders.indices.contains(i) { openFolder(files.folders[i]) }
                else if userAlbums.indices.contains(i) { openAlbum(userAlbums[i]) }
            }
            else if id.hasPrefix("item:"), let i = Int(id.dropFirst(5)), items.indices.contains(i) { view(items[i]) }
            else if id.hasPrefix("seek:"), let i = Int(id.dropFirst(5)) { player.seek(fraction: Double(i) / 10) }
            else if id.hasPrefix("strip:"), let i = Int(id.dropFirst(6)), items.indices.contains(i) { view(items[i]) }
            else if id.hasPrefix("fmt:"), let i = Int(id.dropFirst(4)), Self.formats.indices.contains(i) {
                formatIndex = i
                formatMenu = false
                log("[Media] Format \(format.label)")
                layoutControls()
            }
        }
    }

    private func openAlbum(_ album: MediaAlbum, limit: Int = 400) {
        self.album = album
        items = library.items(in: album, limit: limit)
        row = 0
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
        let first = row * Self.itemColumns
        let wanted = items.dropFirst(first).prefix(Self.itemColumns * (Self.itemRows + 1)).filter { thumbnails[$0.id] == nil }
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
    /// A select while the controls are hidden shows them again.
    func showControls() { controlsHidden = false }

    func view(_ item: MediaItem) {
        player.close()
        controlsHidden = false
        formatMenu = false
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
        loadThumbnails()
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
            let loading = current.map { $0.isVideo ? player.isLoading : (picture == nil && eyes == nil) } ?? false
            controls.render(FilmstripView(size: CGSize(width: 1600, height: 260), buttons: controls.buttons, hovered: controls.hovered, strip: strip, loading: loading))
        } else {
            var cells: [GridCell] = []
            switch screen {
            case .albums:
                if let files { cells = files.folders.dropFirst(albumRow * Self.albumColumns).prefix(Self.albumColumns * Self.albumRows).map { GridCell(id: $0.id, image: nil, label: $0.name) } }
                else { cells = visibleAlbums.map { GridCell(id: $0.id, image: covers[$0.id], label: "\($0.title)  ·  \($0.count)") } }
            case .items:
                cells = items.dropFirst(row * Self.itemColumns).prefix(Self.itemColumns * Self.itemRows).map { item in
                    let badge: String
                    switch item.kind {
                    case .spatialPhoto, .spatialVideo: badge = "Spatial"
                    case .photo360, .video360: badge = "360°"
                    case .photo180, .video180: badge = "180°"
                    case .panorama: badge = "Panorama"
                    case .video: badge = item.duration > 0 ? String(format: "%d:%02d", Int(item.duration) / 60, Int(item.duration) % 60) : "Video"
                    case .photo: badge = ""
                    }
                    return GridCell(id: item.id, image: thumbnails[item.id], label: badge)
                }
            case .viewing: break
            }
            let title: String
            if files != nil {
                title = screen == .albums ? "Files" : "\(folder?.name ?? "") · \(query.isEmpty ? "type to search" : "search: " + query + "▏")"
            } else {
                title = ""
            }
            grid.render(GridView(size: CGSize(width: 1600, height: 1000), cells: cells, hovered: grid.hovered.flatMap { h in
                // The hovered button id maps to the cell id.
                if h.hasPrefix("album:"), let i = Int(h.dropFirst(6)) {
                    if let files, files.folders.indices.contains(i) { return files.folders[i].id }
                    if albums.indices.contains(i) { return albums[i].id }
                }
                if h.hasPrefix("item:"), let i = Int(h.dropFirst(5)), items.indices.contains(i) { return items[i].id }
                return nil
            }, title: title, columns: screen == .albums ? Self.albumColumns : Self.itemColumns, albums: screen == .albums, buttons: grid.buttons,
               emptyText: screen == .albums ? (files != nil ? "Add a folder to browse" : "No albums of your own yet") : (tab == .spatial ? "No spatial photos or videos" : tab == .panoramas ? "No panoramas" : tab == .threeSixty ? "No 360° pictures" : "Nothing here")))
        }
    }
}


/// The viewer's controls with the filmstrip's pictures under their buttons.
struct FilmstripView: View {
    let size: CGSize
    let buttons: [ScenePanel.Button]
    let hovered: String?
    let strip: [(String, UIImage?)]
    var loading = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            PanelStyle.glass()
            if loading {
                HStack(spacing: 20) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 48, weight: .medium)).foregroundStyle(PanelStyle.accent)
                    Text("Loading…").font(.system(size: 54, weight: .medium, design: .rounded)).foregroundStyle(PanelStyle.text)
                }
                .padding(.horizontal, 36).padding(.vertical, 16)
                .background(Capsule().fill(Color.black.opacity(0.7)))
                .position(x: size.width / 2, y: size.height * 0.75)
            }
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
