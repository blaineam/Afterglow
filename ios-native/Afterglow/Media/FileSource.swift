import Foundation
import UIKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Pictures and videos from folders: the app's own Documents/Media, and folders the user picked in
/// the Files app, kept as security-scoped bookmarks and read in place (streamed, not copied), with
/// a search by name. Each file is classified by what it says about itself (`MediaMetadata`), its
/// name, and its shape. Logs [Files].
@MainActor
final class FileSource: NSObject, UIDocumentPickerDelegate {
    struct Folder: Identifiable {
        let id: String
        let name: String
        let url: URL
        let bookmark: Data?
    }

    private static let bookmarksKey = "files.bookmarks"
    nonisolated private static let imageTypes: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
    nonisolated private static let videoTypes: Set<String> = ["mp4", "mov", "m4v", "webm"]
    private(set) var folders: [Folder] = []
    private var accessed: [URL] = []
    var onPicked: ((Folder) -> Void)?

    override init() {
        super.init()
        let media = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Media")
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        folders = [Folder(id: "media", name: "Media folder", url: media, bookmark: nil)]
        for data in UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] ?? [] {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if url.startAccessingSecurityScopedResource() { accessed.append(url) }
                folders.append(Folder(id: url.path, name: url.lastPathComponent, url: url, bookmark: data))
            }
        }
        log("[Files] \(folders.count) folders: " + folders.map(\.name).joined(separator: ", "))
    }

    deinit {
        for url in accessed { url.stopAccessingSecurityScopedResource() }
    }

    /// Lets the user pick a folder in the Files app; it is bookmarked and listed from then on.
    func pickFolder(from presenter: UIViewController) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { log("[Files] No access to \(url.lastPathComponent)"); return }
        accessed.append(url)
        var data: Data?
        do {
            data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            // Some file providers give no bookmark; the folder still opens for this session.
            log("[Files] No bookmark for \(url.lastPathComponent) (\(error.localizedDescription)): kept for this session only")
        }
        guard let data else {
            let folder = Folder(id: url.path, name: url.lastPathComponent, url: url, bookmark: nil)
            folders.append(folder)
            onPicked?(folder)
            return
        }
        var saved = UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] ?? []
        saved.append(data)
        UserDefaults.standard.set(saved, forKey: Self.bookmarksKey)
        let folder = Folder(id: url.path, name: url.lastPathComponent, url: url, bookmark: data)
        folders.append(folder)
        log("[Files] Bookmarked \(url.lastPathComponent)")
        onPicked?(folder)
    }

    func forget(_ folder: Folder) {
        guard let bookmark = folder.bookmark else { return }
        var saved = UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] ?? []
        saved.removeAll { $0 == bookmark }
        UserDefaults.standard.set(saved, forKey: Self.bookmarksKey)
        folders.removeAll { $0.id == folder.id }
    }

    /// The folder's pictures and videos, newest first, matching `query` in their names when given.
    func items(in folder: Folder, query: String = "", limit: Int = 500) async -> [MediaItem] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let found = Self.mediaFiles(in: folder.url, matching: needle, limit: limit)
        var items: [MediaItem] = []
        for (url, date) in found {
            items.append(await classify(url, date: date))
        }
        items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        log("[Files] \(folder.name): \(items.count) items" + (needle.isEmpty ? "" : " matching \"\(needle)\""))
        return items
    }

    /// The picture and video files under a folder (walked synchronously: the enumerator cannot be
    /// stepped from an async function), with their modification dates.
    nonisolated private static func mediaFiles(in root: URL, matching needle: String, limit: Int) -> [(URL, Date?)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var found: [(URL, Date?)] = []
        var count = 0
        for case let url as URL in enumerator {
            guard count < 4000 else { break }
            count += 1
            let ext = url.pathExtension.lowercased()
            guard imageTypes.contains(ext) || videoTypes.contains(ext) else { continue }
            if !needle.isEmpty && !url.lastPathComponent.lowercased().contains(needle) { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            found.append((url, values?.contentModificationDate))
            if found.count >= limit { break }
        }
        return found
    }

    /// A file's kind: a video's boxes or name, a JPEG's GPano, a HEIC's stereo pair, else its shape.
    func classify(_ url: URL, date: Date?) async -> MediaItem {
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent
        if Self.videoTypes.contains(ext) {
            let asset = AVURLAsset(url: url)
            var size = CGSize.zero
            var duration: Double = 0
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let applied = natural.applying(transform)
                size = CGSize(width: abs(applied.width), height: abs(applied.height))
            }
            if let d = try? await asset.load(.duration), d.seconds.isFinite { duration = d.seconds }
            let format = MediaMetadata.videoFormat(at: url) ?? MediaMetadata.format(fromFileName: name)
            let aspect = size.height > 0 ? size.width / size.height : 1
            let kind: MediaItem.Kind
            if let format {
                switch format.projection {
                case .full360: kind = .video360
                case .half180: kind = .video180
                case .flat: kind = .video
                }
            } else {
                kind = abs(aspect - 2) <= 0.06 ? .video360 : .video
            }
            return MediaItem(id: url.path, kind: kind, title: name, date: date, pixelSize: size, duration: duration, asset: nil, fileURL: url,
                             fileLayout: format.map { $0.layout }, fileSpan: nil)
        }
        var size = CGSize.zero
        var spatial = false
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int {
                let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
                size = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
            }
            spatial = CGImageSourceGetCount(source) >= 2 && MediaLibrary.stereoPair(in: source) != nil
        }
        let aspect = size.height > 0 ? size.width / size.height : 1
        var span: Float?
        var kind: MediaItem.Kind
        if spatial { kind = .spatialPhoto }
        else if (ext == "jpg" || ext == "jpeg"), let sphere = MediaMetadata.photoSphere(at: url) {
            kind = sphere.isFull ? .photo360 : .panorama
            span = sphere.widthDegrees
        }
        else if aspect >= 2.4 { kind = .panorama }
        else if abs(aspect - 2) <= 0.06 { kind = .photo360 }
        else { kind = .photo }
        if let named = MediaMetadata.format(fromFileName: name), kind == .photo || kind == .photo360 {
            kind = named.projection == .full360 ? .photo360 : named.projection == .half180 ? .photo180 : kind
        }
        return MediaItem(id: url.path, kind: kind, title: name, date: date, pixelSize: size, duration: 0, asset: nil, fileURL: url,
                         fileLayout: MediaMetadata.format(fromFileName: name).map { $0.layout }, fileSpan: span)
    }

    /// A thumbnail: the image scaled, or a video frame at one second.
    nonisolated static func thumbnail(for url: URL, pixels: Int = 240) async -> UIImage? {
        let ext = url.pathExtension.lowercased()
        if videoTypes.contains(ext) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: pixels, height: pixels)
            if let result = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) {
                return UIImage(cgImage: result.image)
            }
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceShouldCache: false]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
