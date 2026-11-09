import MusicKit
import Metal
import UIKit
import SwiftUI

/// Apple Music through MusicKit: what is playing with its artwork and the transport, and the
/// user's library (playlists first, then albums) as a paged list to play from. Authorization
/// is asked for on first open; the music keeps playing while other apps are used. Logs [Music].
@MainActor
final class MusicApp {
    let panel: ScenePanel
    private let player = ApplicationMusicPlayer.shared
    private var artwork: UIImage?
    private var version = 0
    private(set) var authorized = false
    private var playlists: [Playlist] = []
    private var albums: [Album] = []
    private var page = 0
    private let perPage = 6
    private var showingLibrary = false
    private var observer: Task<Void, Never>?
    private var nowTitle = String(localized: "Nothing playing")
    private var nowSubtitle = ""
    private var artworkURL: URL?
    /// The playing song's tempo, measured from its audio when the device holds it unprotected.
    let tempo = TempoAnalyzer()
    private(set) var currentTempo: Double?
    /// What the tempo lookup said, for the Music window.
    private(set) var tempoNote = ""
    var nowPlayingId: String { (player.queue.currentEntry?.id ?? "") }
    var nowPlayingTitle: String { nowTitle }

    init(device: MTLDevice) {
        panel = ScenePanel(device: device, pixelWidth: 1400, pixelHeight: 760)
        layout()
        Task { @MainActor in await self.start() }
    }

    private func start() async {
        let status = await MusicAuthorization.request()
        authorized = status == .authorized
        log("[Music] Authorization \(status)")
        if authorized { await loadLibrary() }
        observer = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        layout()
    }

    private func loadLibrary() async {
        do {
            var request = MusicLibraryRequest<Playlist>()
            request.limit = 60
            playlists = Array(try await request.response().items)
            var albumsRequest = MusicLibraryRequest<Album>()
            albumsRequest.limit = 60
            albums = Array(try await albumsRequest.response().items)
            log("[Music] Library: \(playlists.count) playlists, \(albums.count) albums")
        } catch {
            log("[Music] Library failed: \(error.localizedDescription)")
        }
        layout()
    }

    var isPlaying: Bool { player.state.playbackStatus == .playing }
    var hasQueue: Bool { player.queue.currentEntry != nil }
    /// Seconds into the playing song, for a game that keeps time to it.
    var playbackTime: Double { player.playbackTime }

    private func refresh() {
        let entry = player.queue.currentEntry
        let title = entry?.title ?? String(localized: "Nothing playing")
        let subtitle = entry?.subtitle ?? ""
        let url = entry?.artwork?.url(width: 400, height: 400)
        if title != nowTitle || subtitle != nowSubtitle || url != artworkURL {
            nowTitle = title
            nowSubtitle = subtitle
            artworkURL = url
            artwork = nil
            if let url {
                Task { @MainActor [weak self] in
                    if let data = try? await URLSession.shared.data(from: url).0 { self?.artwork = UIImage(data: data); self?.version += 1; self?.layout() }
                }
            }
            log("[Music] \(isPlaying ? "Playing" : "Paused"): \(title) — \(subtitle)")
            version += 1
            currentTempo = nil
            if entry != nil {
                let id = entry?.id ?? title
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let bpm = await self.tempo.tempo(forTitle: title, artist: subtitle.components(separatedBy: " — ").first ?? "", id: id)
                    if self.nowTitle == title {
                        self.currentTempo = bpm
                        self.tempoNote = bpm.map { String(format: "%.0f bpm", $0) } ?? String(localized: "tempo unknown: not in the catalogues")
                        self.version += 1
                        self.layout()
                    }
                }
            }
        }
        layout()
    }

    private func layout() {
        var b: [ScenePanel.Button] = []
        if showingLibrary {
            let entries: [(String, String, String)] = playlists.map { ("playlist:\($0.id.rawValue)", $0.name, "music.note.list") } + albums.map { ("album:\($0.id.rawValue)", "\($0.title) · \($0.artistName)", "square.stack") }
            let shown = entries.dropFirst(page * perPage).prefix(perPage)
            for (i, (id, name, icon)) in shown.enumerated() {
                b.append(.init(id: id, rect: CGRect(x: 0.03, y: 0.04 + CGFloat(i) * 0.135, width: 0.94, height: 0.125), label: name, wide: true, icon: icon, style: .row))
            }
            let pages = max(1, (entries.count + perPage - 1) / perPage)
            b.append(.init(id: "prev", rect: CGRect(x: 0.03, y: 0.87, width: 0.12, height: 0.11), label: String(localized: "Previous"), icon: "chevron.left", style: .round))
            b.append(.init(id: "pagelabel", rect: CGRect(x: 0.17, y: 0.87, width: 0.3, height: 0.11), label: String(localized: "\(page + 1) of \(pages)"), wide: true, style: .label))
            b.append(.init(id: "next", rect: CGRect(x: 0.47, y: 0.87, width: 0.12, height: 0.11), label: String(localized: "Next"), icon: "chevron.right", style: .round))
            b.append(.init(id: "nowplaying", rect: CGRect(x: 0.63, y: 0.87, width: 0.34, height: 0.11), label: String(localized: "Now playing"), wide: true, icon: "play.circle", style: .pill))
        } else {
            let y: CGFloat = 0.50, h: CGFloat = 0.24
            b.append(.init(id: "prevTrack", rect: CGRect(x: 0.14, y: y, width: 0.2, height: h), label: String(localized: "Previous"), icon: "backward.fill", style: .round))
            b.append(.init(id: "play", rect: CGRect(x: 0.40, y: y, width: 0.2, height: h), label: isPlaying ? String(localized: "Pause") : String(localized: "Play"), icon: isPlaying ? "pause.fill" : "play.fill", style: .round, accent: true))
            b.append(.init(id: "nextTrack", rect: CGRect(x: 0.66, y: y, width: 0.2, height: h), label: String(localized: "Next"), icon: "forward.fill", style: .round))
            b.append(.init(id: "library", rect: CGRect(x: 0.03, y: 0.78, width: 0.94, height: 0.19), label: authorized ? String(localized: "Your library") : String(localized: "Allow Apple Music in Settings"), wide: true, icon: "music.note.list", style: .pill))
        }
        panel.set(buttons: b, version: "music|\(version)|\(isPlaying)|\(showingLibrary)|\(page)|\(playlists.count)|\(albums.count)|\(authorized)")
    }

    /// The player's async calls, off the main actor: the player type is not Sendable, so it is
    /// reached through its shared instance inside the task rather than captured.
    private static func run(_ body: @escaping @Sendable () async throws -> Void) {
        Task.detached { do { try await body() } catch { log("[Music] \(error.localizedDescription)") } }
    }

    func press(_ id: String) {
        switch id {
        case "play":
            if isPlaying { player.pause() } else { Self.run { try await ApplicationMusicPlayer.shared.play() } }
        case "nextTrack": Self.run { try await ApplicationMusicPlayer.shared.skipToNextEntry() }
        case "prevTrack": Self.run { try await ApplicationMusicPlayer.shared.skipToPreviousEntry() }
        case "library": showingLibrary = true; page = 0
        case "nowplaying": showingLibrary = false
        case "prev": page = max(0, page - 1)
        case "next": if (page + 1) * perPage < playlists.count + albums.count { page += 1 }
        default:
            if id.hasPrefix("playlist:"), let p = playlists.first(where: { $0.id.rawValue == String(id.dropFirst(9)) }) {
                player.queue = ApplicationMusicPlayer.Queue(for: [p])
                Self.run { try await ApplicationMusicPlayer.shared.play() }
                showingLibrary = false
                log("[Music] Playing playlist \(p.name)")
            } else if id.hasPrefix("album:"), let a = albums.first(where: { $0.id.rawValue == String(id.dropFirst(6)) }) {
                player.queue = ApplicationMusicPlayer.Queue(for: [a])
                Self.run { try await ApplicationMusicPlayer.shared.play() }
                showingLibrary = false
                log("[Music] Playing album \(a.title)")
            }
        }
        layout()
    }

    func render() {
        panel.render(MusicView(size: CGSize(width: 1400, height: 760), buttons: panel.buttons, hovered: panel.hovered,
                               title: showingLibrary ? nil : nowTitle, subtitle: nowSubtitle + (tempoNote.isEmpty ? "" : "  ·  " + tempoNote), artwork: showingLibrary ? nil : artwork))
    }
}

struct MusicView: View {
    let size: CGSize
    let buttons: [ScenePanel.Button]
    let hovered: String?
    let title: String?
    let subtitle: String
    let artwork: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ButtonsView(size: size, buttons: buttons, hovered: hovered, title: nil, titleHighlight: false)
            if let title {
                HStack(alignment: .center, spacing: 36) {
                    if let artwork {
                        Image(uiImage: artwork).resizable().aspectRatio(contentMode: .fill).frame(width: 280, height: 280).clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 28, style: .continuous).fill(PanelStyle.key).frame(width: 280, height: 280).overlay(Image(systemName: "music.note").font(.system(size: 120)).foregroundStyle(PanelStyle.dim))
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Apple Music").font(.system(size: 40, weight: .medium, design: .rounded)).foregroundStyle(PanelStyle.accent)
                        Text(title).font(.system(size: 62, weight: .semibold, design: .rounded)).foregroundStyle(PanelStyle.text).lineLimit(2).minimumScaleFactor(0.6)
                        Text(subtitle).font(.system(size: 44, design: .rounded)).foregroundStyle(PanelStyle.dim).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 44).padding(.top, 36)
            }
        }
    }
}
