import Foundation
import UIKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import QuickLookThumbnailing

/// Pictures and videos from folders: the app's own Documents/Media, and folders the user picked in
/// the Files app, kept as security-scoped bookmarks and read in place (streamed, not copied), with
/// a search by name. Each file is classified by what it says about itself (`MediaMetadata`), its
/// name, and its shape. Folders from a file provider (a cloud drive, a remote in another app) are
/// listed through file coordination without downloading their files: a file not on the phone is
/// classified by its name, gets a thumbnail only when it is a small picture, and is downloaded
/// when it is opened. Logs [Files].
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
        var renewedBookmarks: [(Data, Data)] = []
        let media = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Media")
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        folders = [Folder(id: "media", name: String(localized: "Media folder"), url: media, bookmark: nil)]
        for data in UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] ?? [] {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if url.startAccessingSecurityScopedResource() { accessed.append(url) }
                var kept = data
                // A provider that moved or renamed the folder hands back a stale bookmark: renewed
                // while it still resolves, or the folder is lost at the next launch.
                if stale, let renewed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    kept = renewed
                    renewedBookmarks.append((data, renewed))
                }
                folders.append(Folder(id: url.path, name: url.lastPathComponent, url: url, bookmark: kept))
            } else {
                log("[Files] A saved folder no longer resolves; kept in case its provider comes back")
            }
        }
        if !renewedBookmarks.isEmpty {
            var saved = UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] ?? []
            for (old, new) in renewedBookmarks { if let i = saved.firstIndex(of: old) { saved[i] = new } }
            UserDefaults.standard.set(saved, forKey: Self.bookmarksKey)
            log("[Files] Renewed \(renewedBookmarks.count) stale folder bookmarks")
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
        let root = folder.url
        let picked = folder.id != "media"
        let found = await Task.detached(priority: .userInitiated) {
            Self.coordinatedMediaFiles(in: root, matching: needle, limit: limit, maxDepth: picked ? Self.pickedFolderDepth : Int.max)
        }.value
        var items: [MediaItem] = []
        for (url, date) in found {
            items.append(await classify(url, date: date))
        }
        items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        log("[Files] \(folder.name): \(items.count) items" + (needle.isEmpty ? "" : " matching \"\(needle)\""))
        return items
    }

    /// Levels below a picked folder that are walked: a provider lists each folder from its server
    /// as it is opened, and a whole drive walked to the bottom took minutes.
    nonisolated static let pickedFolderDepth = 3

    /// The listing inside a coordinated read of the folder's metadata only, which is how a file
    /// provider is asked for a folder's contents without downloading the files in it.
    nonisolated private static func coordinatedMediaFiles(in root: URL, matching needle: String, limit: Int, maxDepth: Int) -> [(URL, Date?)] {
        var found: [(URL, Date?)] = []
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: root, options: [.immediatelyAvailableMetadataOnly], error: &coordinationError) { url in
            found = mediaFiles(in: url, matching: needle, limit: limit, maxDepth: maxDepth)
        }
        if let coordinationError {
            log("[Files] Coordinated listing of \(root.lastPathComponent) failed (\(coordinationError.localizedDescription)); listing directly")
            found = mediaFiles(in: root, matching: needle, limit: limit, maxDepth: maxDepth)
        }
        return found
    }

    /// The picture and video files under a folder (walked synchronously: the enumerator cannot be
    /// stepped from an async function), with their modification dates.
    nonisolated private static func mediaFiles(in root: URL, matching needle: String, limit: Int, maxDepth: Int) -> [(URL, Date?)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(URL, Date?)] = []
        var count = 0
        for case let url as URL in enumerator {
            guard count < 4000 else { break }
            count += 1
            if enumerator.level >= maxDepth { enumerator.skipDescendants() }
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
        if Self.isRemote(url) {
            // Not on the phone: reading it would download it, so its name says what it is until
            // it is opened (and classified again from its contents).
            let named = MediaMetadata.format(fromFileName: name)
            let kind: MediaItem.Kind
            if Self.videoTypes.contains(ext) {
                kind = named?.projection == .full360 ? .video360 : named?.projection == .half180 ? .video180 : .video
            } else {
                kind = named?.projection == .full360 ? .photo360 : named?.projection == .half180 ? .photo180 : .photo
            }
            return MediaItem(id: url.path, kind: kind, title: name, date: date, pixelSize: .zero, duration: 0, asset: nil, fileURL: url,
                             fileLayout: named.map { $0.layout }, fileSpan: nil)
        }
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
        if isRemote(url) {
            // The provider's own thumbnail when it has one; otherwise a small picture is
            // downloaded for it, and a video (or a big picture) goes without.
            if let provided = await providerThumbnail(for: url, pixels: pixels) { return provided }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
            guard imageTypes.contains(ext), size <= maxThumbnailDownload, await download(url) else { return nil }
        }
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

    /// Pictures up to this size are downloaded for their thumbnails.
    nonisolated static let maxThumbnailDownload = 25 * 1024 * 1024

    /// Whether a file is a placeholder for one that lives with its provider: a cloud file not yet
    /// downloaded reports a size with no space taken on the phone.
    nonisolated static func isRemote(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isUbiquitousItemKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        if values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus { return status == .notDownloaded }
        if let size = values.fileSize, size > 0, let allocated = values.totalFileAllocatedSize { return allocated == 0 }
        return false
    }

    /// Downloads a provider's file to the phone through a coordinated read, which is how its
    /// provider is asked for the contents. True when the file is there to read.
    nonisolated static func download(_ url: URL) async -> Bool {
        guard isRemote(url) else { return true }
        let started = CACurrentMediaTime()
        let ok: Bool = await withCheckedContinuation { continuation in
            NSFileCoordinator(filePresenter: nil).coordinate(with: [.readingIntent(with: url)], queue: downloadQueue) { error in
                if let error { log("[Files] Download of \(url.lastPathComponent) failed: \(error.localizedDescription)") }
                continuation.resume(returning: error == nil)
            }
        }
        if ok {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            log(String(format: "[Files] Downloaded %@ (%.1f MB) in %.1f s", url.lastPathComponent, Double(size) / 1_048_576, CACurrentMediaTime() - started))
        }
        return ok
    }

    nonisolated private static let downloadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "afterglow.files.download"
        queue.maxConcurrentOperationCount = 3
        return queue
    }()

    /// The provider's thumbnail for a file not on the phone, without downloading the file.
    nonisolated private static func providerThumbnail(for url: URL, pixels: Int) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: pixels, height: pixels), scale: 1, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
    }
}
