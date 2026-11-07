import Photos
import UIKit
import Metal
import ImageIO
import UniformTypeIdentifiers

/// One thing to look at: a photo or video from the Photos library or a file, with the kind the
/// viewer should show it as.
struct MediaItem: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case photo, spatialPhoto, panorama, photo360, photo180, video, spatialVideo, video360, video180
    }
    let id: String
    let kind: Kind
    let title: String
    let date: Date?
    let pixelSize: CGSize
    let duration: Double
    let asset: PHAsset?
    let fileURL: URL?
    /// What a file's metadata or name said about its stereo layout and a panorama's span.
    var fileLayout: MediaMetadata.VideoFormat.Layout? = nil
    var fileSpan: Float? = nil

    var isVideo: Bool { [.video, .spatialVideo, .video360, .video180].contains(kind) }
    var isSpatial: Bool { kind == .spatialPhoto || kind == .spatialVideo }
}

/// An album: a Photos collection, or a folder of files.
struct MediaAlbum: Identifiable, Sendable {
    let id: String
    let title: String
    let count: Int
    let collection: PHAssetCollection?
}

/// The Photos library: albums and their items, classified the way the Unity app's plugin did it
/// (spatial media by the subtype, panoramas by the subtype or a wide aspect, 360 by a 2:1 shape),
/// thumbnails and full pictures as Metal textures, and spatial photos' two eyes from the HEIC's
/// stereo pair group. Logs [Photos].
@MainActor
final class MediaLibrary {
    private let imageManager = PHCachingImageManager()
    private let device: MTLDevice
    private(set) var authorized = false

    init(device: MTLDevice) {
        self.device = device
    }

    func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorized = status == .authorized || status == .limited
        log("[Photos] Library access \(authorized ? "granted" : "denied") (\(status.rawValue))")
        return authorized
    }

    /// The albums worth showing: the smart albums with content (Recents, Favorites, Panoramas,
    /// Videos, Spatial), then the user's own, each with its item count.
    func albums() -> [MediaAlbum] {
        var result: [MediaAlbum] = []
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let smart = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
        let wanted: Set<PHAssetCollectionSubtype> = [.smartAlbumUserLibrary, .smartAlbumFavorites, .smartAlbumPanoramas, .smartAlbumVideos, .smartAlbumSpatial, .smartAlbumScreenshots, .smartAlbumLivePhotos]
        smart.enumerateObjects { collection, _, _ in
            guard wanted.contains(collection.assetCollectionSubtype) else { return }
            let count = PHAsset.fetchAssets(in: collection, options: options).count
            if count > 0 {
                result.append(MediaAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "Album", count: count, collection: collection))
            }
        }
        let user = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        user.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: options).count
            if count > 0 {
                result.append(MediaAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "Album", count: count, collection: collection))
            }
        }
        log("[Photos] \(result.count) albums: " + result.map { "\($0.title) (\($0.count))" }.joined(separator: ", "))
        return result
    }

    /// The items of an album, newest first.
    func items(in album: MediaAlbum, limit: Int = 200) -> [MediaItem] {
        guard let collection = album.collection else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        options.fetchLimit = limit
        let assets = PHAsset.fetchAssets(in: collection, options: options)
        var items: [MediaItem] = []
        assets.enumerateObjects { asset, _, _ in
            items.append(Self.classify(asset))
        }
        let kinds = Dictionary(grouping: items, by: \.kind).mapValues(\.count)
        log("[Photos] \(album.title): \(items.count) items, " + kinds.map { "\($0.value) \($0.key.rawValue)" }.sorted().joined(separator: ", "))
        return items
    }

    /// What an asset is, from its subtypes and shape.
    static func classify(_ asset: PHAsset) -> MediaItem {
        let size = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
        let aspect = size.height > 0 ? size.width / size.height : 1
        let kind: MediaItem.Kind
        // The Unity app's rules (VideoLibrary.Classify): spatial by subtype, panoramas by subtype
        // or an aspect of 2.4 and over, 360 by a 2:1 shape within 0.06.
        if asset.mediaType == .video {
            if asset.mediaSubtypes.contains(.spatialMedia) { kind = .spatialVideo }
            else if abs(aspect - 2) <= 0.06 { kind = .video360 }
            else { kind = .video }
        } else {
            if asset.mediaSubtypes.contains(.spatialMedia) { kind = .spatialPhoto }
            else if asset.mediaSubtypes.contains(.photoPanorama) || aspect >= 2.4 { kind = .panorama }
            else if abs(aspect - 2) <= 0.06 { kind = .photo360 }
            else { kind = .photo }
        }
        return MediaItem(id: asset.localIdentifier, kind: kind, title: asset.creationDate.map { Self.dateText($0) } ?? "",
                         date: asset.creationDate, pixelSize: size, duration: asset.duration, asset: asset, fileURL: nil)
    }

    private static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// A small picture for the grid.
    func thumbnail(for item: MediaItem, size: CGSize = CGSize(width: 240, height: 240)) async -> UIImage? {
        guard let asset = item.asset else { return nil }
        return await withCheckedContinuation { continuation in
            // The Unity plugin's request, which the Simulator serves; the fast format failed there.
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            let once = LockedValue<Bool>(false)
            imageManager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { @Sendable image, info in
                if once.value { return }
                // A degraded picture is fine for a thumbnail; a nil with an error is the answer too.
                let error = info?[PHImageErrorKey]
                if image == nil && error == nil && (info?[PHImageCancelledKey] as? Bool) != true {
                    return   // not the final call
                }
                if image == nil, let error { log("[Photos] Thumbnail failed: \(error)") }
                once.value = true
                continuation.resume(returning: image)
            }
        }
    }

    /// The whole picture as a texture; a spatial photo as a two-slice array (left, right).
    func picture(for item: MediaItem) async -> (texture: MTLTexture?, eyes: MTLTexture?) {
        if let fileURL = item.fileURL {
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return (nil, nil) }
            return decode(source, item: item)
        }
        guard let asset = item.asset else { return (nil, nil) }
        let data: Data? = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current
            imageManager.requestImageDataAndOrientation(for: asset, options: options) { @Sendable data, _, _, _ in continuation.resume(returning: data) }
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return (nil, nil) }
        return decode(source, item: item)
    }

    private func decode(_ source: CGImageSource, item: MediaItem) -> (texture: MTLTexture?, eyes: MTLTexture?) {
        // Any picture with a stereo pair in it is spatial, marked so or not (an imported HEIC is not).
        if CGImageSourceGetCount(source) >= 2, let pair = Self.stereoPair(in: source) {
            let left = Self.texture(from: pair.left, device: device, maxSide: 4096)
            let right = Self.texture(from: pair.right, device: device, maxSide: 4096)
            if let left, let right, let eyes = Self.array(left, right, device: device) {
                log("[Photos] Spatial photo \(left.width)x\(left.height) per eye")
                return (nil, eyes)
            }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return (nil, nil) }
        let oriented = Self.upright(image, source: source)
        let texture = Self.texture(from: oriented, device: device, maxSide: item.kind == .photo ? 4096 : 8192)
        if let texture { log("[Photos] Picture \(texture.width)x\(texture.height) (\(item.kind.rawValue))") }
        return (texture, nil)
    }

    /// A HEIC's stereo pair (left and right images), from its image groups.
    static func stereoPair(in source: CGImageSource) -> (left: CGImage, right: CGImage)? {
        guard let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
              let groups = properties[kCGImagePropertyGroups] as? [[CFString: Any]] else { return nil }
        for group in groups {
            guard let type = group[kCGImagePropertyGroupType] as? String, type == (kCGImagePropertyGroupTypeStereoPair as String),
                  let leftIndex = group[kCGImagePropertyGroupImageIndexLeft] as? Int,
                  let rightIndex = group[kCGImagePropertyGroupImageIndexRight] as? Int else { continue }
            if let left = CGImageSourceCreateImageAtIndex(source, leftIndex, nil), let right = CGImageSourceCreateImageAtIndex(source, rightIndex, nil) {
                return (left, right)
            }
        }
        // No group but two images: an unmarked or imported pair, left first.
        if CGImageSourceGetCount(source) >= 2, let left = CGImageSourceCreateImageAtIndex(source, 0, nil),
           let right = CGImageSourceCreateImageAtIndex(source, 1, nil) {
            return (left, right)
        }
        return nil
    }

    private static func upright(_ image: CGImage, source: CGImageSource) -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation != 1,
              let cgOrientation = CGImagePropertyOrientation(rawValue: orientation) else { return image }
        let uiOrientation: UIImage.Orientation
        switch cgOrientation {
        case .up: uiOrientation = .up
        case .upMirrored: uiOrientation = .upMirrored
        case .down: uiOrientation = .down
        case .downMirrored: uiOrientation = .downMirrored
        case .left: uiOrientation = .right
        case .leftMirrored: uiOrientation = .rightMirrored
        case .right: uiOrientation = .left
        case .rightMirrored: uiOrientation = .leftMirrored
        }
        let ui = UIImage(cgImage: image, scale: 1, orientation: uiOrientation)
        let renderer = UIGraphicsImageRenderer(size: ui.size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let drawn = renderer.image { _ in ui.draw(in: CGRect(origin: .zero, size: ui.size)) }
        return drawn.cgImage ?? image
    }

    /// A CGImage as a BGRA texture, downscaled to `maxSide` if larger.
    static func texture(from image: CGImage, device: MTLDevice, maxSide: Int) -> MTLTexture? {
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: buffer.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }

    /// Two same-sized textures as a two-slice array.
    static func array(_ left: MTLTexture, _ right: MTLTexture, device: MTLDevice) -> MTLTexture? {
        guard left.width == right.width, left.height == right.height, let queue = device.makeCommandQueue() else { return nil }
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.arrayLength = 2
        d.pixelFormat = .bgra8Unorm
        d.width = left.width
        d.height = left.height
        d.usage = .shaderRead
        d.storageMode = .private
        guard let array = device.makeTexture(descriptor: d), let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { return nil }
        let size = MTLSize(width: left.width, height: left.height, depth: 1)
        blit.copy(from: left, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: size, to: array, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.copy(from: right, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: size, to: array, destinationSlice: 1, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        return array
    }
}
