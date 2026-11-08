import XCTest
@testable import Afterglow

/// The file metadata rules: name tags, GPano XMP, the spatial-video tag collections' shape.
final class MediaMetadataTests: XCTestCase {
    func testFileNameTags() {
        XCTAssertEqual(MediaMetadata.format(fromFileName: "beach_360_tb"), .init(projection: .full360, layout: .topBottom))
        XCTAssertEqual(MediaMetadata.format(fromFileName: "VR180 clip"), .init(projection: .half180, layout: .sideBySide))
        XCTAssertEqual(MediaMetadata.format(fromFileName: "movie-flat"), .init(projection: .flat, layout: .mono))
        XCTAssertEqual(MediaMetadata.format(fromFileName: "cinema_3dh"), .init(projection: .flat, layout: .sideBySide))
        XCTAssertEqual(MediaMetadata.format(fromFileName: "holiday 2d"), .init(projection: .full360, layout: .mono))
        XCTAssertNil(MediaMetadata.format(fromFileName: "IMG_0042"))
    }

    func testGPano() {
        let xml = """
        <x:xmpmeta><rdf:Description GPano:ProjectionType="equirectangular" GPano:CroppedAreaImageWidthPixels="4000"
        GPano:FullPanoWidthPixels="6000" GPano:CroppedAreaImageHeightPixels="1000" GPano:FullPanoHeightPixels="3000"/></x:xmpmeta>
        """
        let sphere = MediaMetadata.parseGPano(xml)
        XCTAssertEqual(sphere?.widthDegrees ?? 0, 240, accuracy: 0.01)
        XCTAssertEqual(sphere?.heightDegrees ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(sphere?.isFull, false)
        let full = MediaMetadata.parseGPano("<GPano:ProjectionType>equirectangular</GPano:ProjectionType>")
        XCTAssertEqual(full?.isFull, true)
        XCTAssertNil(MediaMetadata.parseGPano("<GPano:ProjectionType>cylindrical</GPano:ProjectionType>"))
    }

    func testBoxWalkFindsSt3dInAMinimalFile() throws {
        // moov > trak > mdia > minf > stbl > stsd > entry(avc1) > st3d(stereo_mode 2 = side by side)
        func box(_ type: String, _ payload: Data) -> Data {
            var d = Data()
            let length = UInt32(8 + payload.count)
            d.append(contentsOf: [UInt8(length >> 24), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)])
            d.append(type.data(using: .ascii)!)
            d.append(payload)
            return d
        }
        let st3d = box("st3d", Data([0, 0, 0, 0, 2]))
        var entry = Data(repeating: 0, count: 78)
        entry.append(st3d)
        let avc1 = box("avc1", entry)
        var stsdPayload = Data([0, 0, 0, 0, 0, 0, 0, 1])
        stsdPayload.append(avc1)
        let file = box("moov", box("trak", box("mdia", box("minf", box("stbl", box("stsd", stsdPayload))))))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("afterglow-test-\(UUID().uuidString).mp4")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(MediaMetadata.videoFormat(at: url), .init(projection: .flat, layout: .sideBySide))
    }
}
