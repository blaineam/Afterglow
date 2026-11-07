import Foundation

/// What a file says about its own projection: MP4 boxes (`st3d` for the stereo layout, `sv3d`'s
/// `equi` crop or the spherical v1 `uuid` XML for the projection), GPano XMP in a JPEG for a photo
/// sphere's span, and the words in a file name. The Unity app's `MediaMetadata.cs` and
/// `VideoFormat.FromFileName`, with the same decisions: box metadata wins over the name.
enum MediaMetadata {
    struct VideoFormat: Equatable {
        enum Projection { case full360, half180, flat }
        enum Layout { case mono, sideBySide, topBottom }
        var projection: Projection
        var layout: Layout
    }

    struct PhotoSphere: Equatable {
        var widthDegrees: Float
        var heightDegrees: Float
        var isFull: Bool { widthDegrees >= 359 && heightDegrees >= 170 }
    }

    // MARK: File names

    /// `180`/`vr180` → 180; `flat`/`screen`/`cinema` → flat; `sbs`/`lr`/`3dh` → side by side;
    /// `tb`/`ou`/`3dv` → top-bottom; `mono`/`2d` → mono. Defaults: 360 and flat mono, 180 side by
    /// side (the Unity app made a flat name side by side too, which showed a plain video as half).
    static func format(fromFileName name: String) -> VideoFormat? {
        let words = Set(name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        var projection: VideoFormat.Projection?
        var layout: VideoFormat.Layout?
        if words.contains("180") || words.contains("vr180") { projection = .half180 }
        if words.contains("360") { projection = .full360 }
        if !words.isDisjoint(with: ["flat", "screen", "cinema"]) { projection = .flat }
        if !words.isDisjoint(with: ["sbs", "lr", "3dh"]) { layout = .sideBySide }
        if !words.isDisjoint(with: ["tb", "ou", "3dv"]) { layout = .topBottom }
        if !words.isDisjoint(with: ["mono", "2d"]) { layout = .mono }
        guard projection != nil || layout != nil else { return nil }
        let p = projection ?? .full360
        let l = layout ?? (p == .half180 ? .sideBySide : .mono)
        return VideoFormat(projection: p, layout: l)
    }

    // MARK: MP4 boxes

    /// The format from an MP4's boxes, or nil when it says nothing.
    static func videoFormat(at url: URL) -> VideoFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var stereo: VideoFormat.Layout?
        var projection: VideoFormat.Projection?
        walk(handle: handle, from: 0, to: size, depth: 0) { type, start, length in
            switch type {
            case "st3d":
                if let data = read(handle, start + 8, 5), data.count == 5 {
                    stereo = data[4] == 1 ? .topBottom : data[4] == 2 ? .sideBySide : VideoFormat.Layout.mono
                }
            case "equi":
                projection = .full360
                if let data = read(handle, start + 8, 20), data.count == 20 {
                    let left = Float(be32(data, 12)) / 4294967296, right = Float(be32(data, 16)) / 4294967296
                    if left + right >= 0.45 { projection = .half180 }
                }
            case "uuid":
                if let data = read(handle, start + 8, min(length - 8, 65536)), data.count > 16,
                   data.prefix(16) == Data([0xff, 0xcc, 0x82, 0x63, 0xf8, 0x55, 0x4a, 0x93, 0x88, 0x14, 0x58, 0x7a, 0x02, 0x52, 0x1f, 0xdd]),
                   let xml = String(data: data.dropFirst(16), encoding: .utf8) {
                    if xml.contains("<GSpherical:ProjectionType>equirectangular") {
                        projection = .full360
                        if let cropped = number(in: xml, tag: "GSpherical:CroppedAreaImageWidthPixels"),
                           let full = number(in: xml, tag: "GSpherical:FullPanoWidthPixels"), full > 0, cropped / full <= 0.55 {
                            projection = .half180
                        }
                    }
                    if xml.contains("<GSpherical:StereoMode>top-bottom") { stereo = .topBottom }
                    if xml.contains("<GSpherical:StereoMode>left-right") { stereo = .sideBySide }
                }
            default: break
            }
        }
        if let projection { return VideoFormat(projection: projection, layout: stereo ?? .mono) }
        if let stereo { return VideoFormat(projection: .flat, layout: stereo) }
        return nil
    }

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "sv3d", "proj"]

    private static func walk(handle: FileHandle, from: UInt64, to end: UInt64, depth: Int, visit: (String, UInt64, UInt64) -> Void) {
        var offset = from
        var count = 0
        while offset + 8 <= end && count < 4000 && depth < 12 {
            count += 1
            guard let header = read(handle, offset, 16), header.count >= 8 else { return }
            var length = UInt64(be32(header, 0))
            let type = String(decoding: header[4..<8], as: UTF8.self)
            var headerSize: UInt64 = 8
            if length == 1, header.count >= 16 {
                length = UInt64(be32(header, 8)) << 32 | UInt64(be32(header, 12))
                headerSize = 16
            } else if length == 0 {
                length = end - offset
            }
            guard length >= headerSize else { return }
            visit(type, offset, length)
            if containers.contains(type) {
                walk(handle: handle, from: offset + headerSize, to: min(end, offset + length), depth: depth + 1, visit: visit)
            } else if type == "stsd" {
                // The sample description: a version/flags/count header, then each entry's 78 bytes
                // of visual fields before its own child boxes.
                var entry = offset + headerSize + 8
                let entryEnd = min(end, offset + length)
                var entries = 0
                while entry + 8 <= entryEnd && entries < 8 {
                    entries += 1
                    guard let h = read(handle, entry, 8), h.count == 8 else { break }
                    let entryLength = UInt64(be32(h, 0))
                    guard entryLength >= 16 else { break }
                    walk(handle: handle, from: entry + 8 + 78, to: min(entryEnd, entry + entryLength), depth: depth + 1, visit: visit)
                    entry += entryLength
                }
            }
            offset += length
        }
    }

    private static func read(_ handle: FileHandle, _ offset: UInt64, _ length: UInt64) -> Data? {
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.read(upToCount: Int(length))
    }

    private static func be32(_ data: Data, _ at: Int) -> UInt32 {
        guard at + 4 <= data.count else { return 0 }
        let b = data.startIndex + at
        return UInt32(data[b]) << 24 | UInt32(data[b + 1]) << 16 | UInt32(data[b + 2]) << 8 | UInt32(data[b + 3])
    }

    private static func number(in xml: String, tag: String) -> Float? {
        guard let open = xml.range(of: "<\(tag)>"), let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return Float(xml[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: GPano (JPEG)

    /// A photo sphere's span from the APP1 XMP of a JPEG: width and height in degrees from the
    /// cropped area over the full panorama (360 × 180 by default), or nil without GPano.
    static func photoSphere(at url: URL) -> PhotoSphere? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 4, data[0] == 0xff, data[1] == 0xd8 else { return nil }
        var offset = 2
        while offset + 4 <= data.count && data[offset] == 0xff {
            let marker = data[offset + 1]
            if marker == 0xda || marker == 0xd9 { break }
            let length = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            if marker == 0xe1, offset + 2 + length <= data.count {
                let segment = data[(offset + 4)..<(offset + 2 + length)]
                let header = "http://ns.adobe.com/xap/1.0/\0".data(using: .utf8)!
                if segment.starts(with: header), let xml = String(data: segment.dropFirst(header.count), encoding: .utf8) {
                    return parseGPano(xml)
                }
            }
            offset += 2 + max(length, 2)
        }
        return nil
    }

    static func parseGPano(_ xml: String) -> PhotoSphere? {
        guard xml.contains("GPano:ProjectionType=\"equirectangular\"") || xml.contains("<GPano:ProjectionType>equirectangular") else { return nil }
        func value(_ name: String) -> Float? {
            if let n = number(in: xml, tag: "GPano:\(name)") { return n }
            guard let r = xml.range(of: "GPano:\(name)=\"") else { return nil }
            let rest = xml[r.upperBound...]
            guard let q = rest.firstIndex(of: "\"") else { return nil }
            return Float(rest[..<q])
        }
        var width: Float = 360, height: Float = 180
        if let cropped = value("CroppedAreaImageWidthPixels"), let full = value("FullPanoWidthPixels"), full > 0 {
            width = min(360, max(1, cropped / full * 360))
        }
        if let cropped = value("CroppedAreaImageHeightPixels"), let full = value("FullPanoHeightPixels"), full > 0 {
            height = min(180, max(1, cropped / full * 180))
        }
        return PhotoSphere(widthDegrees: width, heightDegrees: height)
    }
}
