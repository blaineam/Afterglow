// Writes a spatial photo for testing: one HEIC holding a picture per eye, tied together by the
// stereo pair group that an iPhone 15 Pro and later write, so the Photos library lists it as
// spatial media and the player's spatial path can be checked without a phone. The two pictures
// are the same scene with the near shapes shifted between the eyes, so depth shows in a viewer.
//
//   swift Tools/make_spatial_photo.swift <output.heic>
//
// Needs macOS 14 or later, where ImageIO learned the group keys.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width = 2048
let height = 1536

func eye(_ shift: CGFloat, _ text: String) -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    // Sky and ground, which are far away, so they sit in the same place for both eyes.
    context.setFillColor(CGColor(red: 0.25, green: 0.45, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    context.setFillColor(CGColor(red: 0.25, green: 0.2, blue: 0.15, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    // Three posts at three depths: the nearer, the more it shifts between the eyes.
    let posts: [(x: CGFloat, depth: CGFloat, color: CGColor)] = [
        (0.3, 3.0, CGColor(red: 0.95, green: 0.8, blue: 0.3, alpha: 1)),
        (0.55, 1.5, CGColor(red: 0.9, green: 0.4, blue: 0.35, alpha: 1)),
        (0.75, 1.0, CGColor(red: 0.4, green: 0.85, blue: 0.5, alpha: 1)),
    ]
    for post in posts {
        let x = CGFloat(width) * post.x + shift / post.depth
        let tall = CGFloat(height) * (0.25 + 0.35 / post.depth)
        context.setFillColor(post.color)
        context.fill(CGRect(x: x - 40 / post.depth, y: CGFloat(height) * 0.35, width: 80 / post.depth, height: tall))
    }
    // The eye's name, far away, so it reads the same in both.
    let attributes: [CFString: Any] = [
        kCTFontAttributeName: CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil),
        kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary))
    context.textPosition = CGPoint(x: 80, y: CGFloat(height) - 160)
    CTLineDraw(line, context)
    return context.makeImage()!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make_spatial_photo.swift <output.heic>\n".data(using: .utf8)!)
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
// A spatial photo's two eyes are 64 mm apart; a shift of 48 px at the nearest post is a comfortable
// amount of depth on a phone-sized screen.
let left = eye(24, "Spatial photo, left eye")
let right = eye(-24, "Spatial photo, right eye")

guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 2, nil) else {
    FileHandle.standardError.write("Couldn't create \(url.path)\n".data(using: .utf8)!)
    exit(1)
}
// The group says which picture is which eye and ties the two together (one dictionary per
// picture, not an array: ImageIO refuses the array form on writing and reads the pair back as a
// group with both indexes). The baseline is what a spatial photo also carries.
func properties(leftEye: Bool) -> [CFString: Any] {
    var group: [CFString: Any] = [
        kCGImagePropertyGroupIndex: 0,
        kCGImagePropertyGroupType: kCGImagePropertyGroupTypeStereoPair,
        kCGImagePropertyGroupImageBaseline: 0.064,
        kCGImagePropertyGroupImageDisparityAdjustment: 0.0,
    ]
    group[leftEye ? kCGImagePropertyGroupImageIsLeftImage : kCGImagePropertyGroupImageIsRightImage] = true
    return [
        kCGImagePropertyGroups: group,
        kCGImageDestinationLossyCompressionQuality: 0.9,
    ]
}
let leftProperties = properties(leftEye: true)
let rightProperties = properties(leftEye: false)
CGImageDestinationAddImage(destination, left, leftProperties as CFDictionary)
CGImageDestinationAddImage(destination, right, rightProperties as CFDictionary)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write("Couldn't write \(url.path)\n".data(using: .utf8)!)
    exit(1)
}

// Read it back: the group has to be there, or the player will see one picture.
if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
   let properties = CGImageSourceCopyProperties(source, nil) as? [String: Any],
   let groups = properties[kCGImagePropertyGroups as String] as? [[String: Any]],
   groups.contains(where: { ($0[kCGImagePropertyGroupType as String] as? String) == (kCGImagePropertyGroupTypeStereoPair as String) }) {
    print("\(url.path): \(CGImageSourceGetCount(source)) pictures, stereo pair group present")
} else {
    FileHandle.standardError.write("\(url.path) was written without a stereo pair group\n".data(using: .utf8)!)
    exit(1)
}
