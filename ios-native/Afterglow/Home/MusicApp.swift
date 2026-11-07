import MediaPlayer
import Metal
import UIKit
import SwiftUI

/// Apple Music through the system player: what is playing (title, artist, artwork), play and
/// pause, next and previous, so the user can run their music without leaving the viewer. No
/// MusicKit authorization is needed to drive the system player; browsing the library would be.
/// Logs [Music].
@MainActor
final class MusicApp {
    let panel: ScenePanel
    private let player = MPMusicPlayerController.systemMusicPlayer
    private var artwork: UIImage?
    private var version = 0
    private var observers: [NSObjectProtocol] = []

    init(device: MTLDevice) {
        panel = ScenePanel(device: device, pixelWidth: 1200, pixelHeight: 700)
        player.beginGeneratingPlaybackNotifications()
        observers.append(NotificationCenter.default.addObserver(forName: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .MPMusicPlayerControllerPlaybackStateDidChange, object: player, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        refresh()
    }

    private var isPlaying: Bool { player.playbackState == .playing }

    private func refresh() {
        let item = player.nowPlayingItem
        artwork = item?.artwork?.image(at: CGSize(width: 400, height: 400))
        version += 1
        layout()
        log("[Music] \(isPlaying ? "Playing" : "Paused"): \(item?.title ?? "nothing") — \(item?.artist ?? "")")
    }

    private func layout() {
        var b: [ScenePanel.Button] = []
        let y: CGFloat = 0.72, h: CGFloat = 0.22
        b.append(.init(id: "prev", rect: CGRect(x: 0.08, y: y, width: 0.2, height: h), label: "⏮"))
        b.append(.init(id: "play", rect: CGRect(x: 0.31, y: y, width: 0.38, height: h), label: isPlaying ? "⏸" : "▶"))
        b.append(.init(id: "next", rect: CGRect(x: 0.72, y: y, width: 0.2, height: h), label: "⏭"))
        panel.set(buttons: b, version: "music|\(version)|\(isPlaying)")
    }

    func press(_ id: String) {
        switch id {
        case "play": if isPlaying { player.pause() } else { player.play() }
        case "next": player.skipToNextItem()
        case "prev": player.skipToPreviousItem()
        default: break
        }
        layout()
    }

    func render() {
        let item = player.nowPlayingItem
        panel.render(MusicView(size: CGSize(width: 1200, height: 700), buttons: panel.buttons, hovered: panel.hovered,
                               title: item?.title ?? "Nothing playing", subtitle: [item?.artist, item?.albumTitle].compactMap { $0 }.joined(separator: " · "),
                               artwork: artwork))
    }
}

struct MusicView: View {
    let size: CGSize
    let buttons: [ScenePanel.Button]
    let hovered: String?
    let title: String
    let subtitle: String
    let artwork: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ButtonsView(size: size, buttons: buttons, hovered: hovered, title: nil, titleHighlight: false)
            HStack(alignment: .top, spacing: 30) {
                if let artwork {
                    Image(uiImage: artwork).resizable().aspectRatio(contentMode: .fill).frame(width: 300, height: 300).clipShape(RoundedRectangle(cornerRadius: 24))
                } else {
                    RoundedRectangle(cornerRadius: 24).fill(PanelStyle.key).frame(width: 300, height: 300).overlay(Text("🎵").font(.system(size: 120)))
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Apple Music").font(.system(size: 26, weight: .medium, design: .rounded)).foregroundStyle(PanelStyle.accent)
                    Text(title).font(.system(size: 44, weight: .semibold, design: .rounded)).foregroundStyle(PanelStyle.text).lineLimit(2)
                    Text(subtitle).font(.system(size: 30, design: .rounded)).foregroundStyle(PanelStyle.text.opacity(0.8)).lineLimit(2)
                }
            }
            .padding(40)
        }
    }
}
