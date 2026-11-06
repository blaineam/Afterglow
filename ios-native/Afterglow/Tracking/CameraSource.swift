import ARKit
import Metal

/// Where the picture and the head pose come from: ARKit world tracking on the wide camera
/// (6DoF), or an AVFoundation session on the ultra-wide with the head's rotation from the motion
/// sensors (3DoF). The renderer and the hand tracker see the same things either way.
protocol CameraSource: AnyObject {
    /// The latest camera image, ready to draw, with the pose it was taken from.
    var latestFrame: CapturedFrame? { get }
    /// The hand tracker fed with every image, nil with hands off.
    var hands: HandTracker? { get }
    /// "wide" or "ultra-wide", for the status line.
    var cameraName: String { get }
    /// Positional tracking (6) or rotation only (3).
    var degreesOfFreedom: Int { get }
    /// The camera's transform in the world predicted for `time`, from the latest pose.
    func predictedCameraTransform(at time: Double) -> simd_float4x4?
    func start()
    func stop()
}

/// One camera image as the hand tracker takes it, from either source.
struct HandImage {
    let pixelBuffer: CVPixelBuffer
    let timestamp: Double
    let intrinsics: simd_float3x3
    let width: Int
    let height: Int
    let cameraTransform: simd_float4x4
    let sceneDepth: ARDepthData?
}
