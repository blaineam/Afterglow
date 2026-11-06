import Foundation

/// Physical description of a Cardboard-style viewer, mirroring the Cardboard SDK's DeviceParams
/// protobuf and the Unity app's `ViewerParams.cs`. Lengths are in metres, angles in degrees.
struct ViewerParams: Sendable {
    enum VerticalAlignment: Int, Sendable {
        case bottom = 0 // phone rests against a fixed bottom tray
        case center = 1 // screen is centred on the lenses
        case top = 2    // phone rests against a fixed top tray
    }

    var vendor: String
    var model: String
    var screenToLensDistance: Float
    var interLensDistance: Float
    /// Left eye's view extent (left, right, bottom, top) from the optical axis. The right eye
    /// mirrors left and right.
    var leftEyeFieldOfViewAngles: [Float]
    var verticalAlignment: VerticalAlignment
    var trayToLensDistance: Float
    /// K1, K2, ... of p' = p (1 + K1 r^2 + K2 r^4 + ...), r in tan-angle units.
    var distortionCoefficients: [Float]

    /// The 2015 Google Cardboard, whose lenses the printed viewers use; values decoded from a
    /// real viewer's QR code in the Unity app's tests.
    static let cardboardV2 = ViewerParams(
        vendor: "Google", model: "Cardboard",
        screenToLensDistance: 0.0393, interLensDistance: 0.0639,
        leftEyeFieldOfViewAngles: [60, 60, 60, 60],
        verticalAlignment: .bottom, trayToLensDistance: 0.035,
        distortionCoefficients: [0.3358, 0.5535])

    /// The printed viewers: Cardboard v2's lenses and spacing, centred on the screen rather
    /// than above a bottom tray. The same numbers as the Unity app's `AfterglowViewer`.
    static let afterglowViewer = ViewerParams(
        vendor: "Afterglow", model: "Afterglow Viewer",
        screenToLensDistance: 0.0393, interLensDistance: 0.0639,
        leftEyeFieldOfViewAngles: [60, 60, 60, 60],
        verticalAlignment: .center, trayToLensDistance: 0.035,
        distortionCoefficients: [0.3358, 0.5535])
}
