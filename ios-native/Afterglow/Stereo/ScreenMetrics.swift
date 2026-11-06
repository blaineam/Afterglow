import UIKit

/// The screen's physical size, which the lens geometry needs: pixels over pixel density. iOS does
/// not report the density, so it comes from a table of the phones this project knows, with 460 ppi
/// (every Pro-sized iPhone since the 15 Pro) as the default. Landscape: width is the long side.
struct ScreenMetrics: Sendable {
    let modelIdentifier: String
    let pixelWidth: Int
    let pixelHeight: Int
    let pixelsPerInch: Float
    let known: Bool

    var widthMeters: Float { Float(pixelWidth) / pixelsPerInch * 0.0254 }
    var heightMeters: Float { Float(pixelHeight) / pixelsPerInch * 0.0254 }

    private static let densities: [String: Float] = [
        "iPhone19,3": 460, // iPhone 18 Pro Max
        "iPhone19,2": 460, // iPhone 18 Pro
        "iPhone18,2": 460, // iPhone 17 Pro Max
        "iPhone18,1": 460, // iPhone 17 Pro
        "iPhone17,2": 460, // iPhone 16 Pro Max
        "iPhone17,1": 460, // iPhone 16 Pro
        "iPhone16,2": 460, // iPhone 15 Pro Max
        "iPhone16,1": 460, // iPhone 15 Pro
    ]

    @MainActor
    static func of(_ screen: UIScreen) -> ScreenMetrics {
        let bounds = screen.nativeBounds
        let long = Int(max(bounds.width, bounds.height).rounded())
        let short = Int(min(bounds.width, bounds.height).rounded())
        let model = Self.modelIdentifier()
        let density = densities[model]
        return ScreenMetrics(modelIdentifier: model, pixelWidth: long, pixelHeight: short,
                             pixelsPerInch: density ?? 460, known: density != nil)
    }

    private static func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
