import ARKit
import Metal
import CoreVideo

/// The latest camera frame, ready to draw: its pose and when it was taken, the intrinsics that
/// give its field of view, and its image as two Metal textures (luma and chroma planes) that stay
/// valid while this struct is held.
struct CapturedFrame: @unchecked Sendable {
    let pose: PoseSample
    let intrinsics: simd_float3x3
    let imageWidth: Int
    let imageHeight: Int
    let luma: MTLTexture
    let chroma: MTLTexture
    // The Metal textures are views of the pixel buffer's planes and stay valid only while these
    // cache entries are retained, so they travel with the frame.
    let lumaRef: CVMetalTexture
    let chromaRef: CVMetalTexture
    // And the pixel buffer itself: ARKit recycles it for a new capture once its frame is released,
    // which showed as coloured static in passthrough (2026-11-06).
    let pixelBuffer: CVPixelBuffer
    /// Video range (Y 16-235, C 16-240 of 255) rather than full range; 10-bit buffers are video range.
    let videoRange: Bool
}

/// Runs ARKit world tracking: picks the camera format (the ultra-wide at 60 fps where the phone
/// offers it), hands each frame's pose to the predictor and its image to the renderer, and logs
/// tracking as the Unity app does under [AR], [Camera] and [Passthrough].
final class ARController: NSObject, ARSessionDelegate, @unchecked Sendable {
    let session = ARSession()
    let predictor = PosePredictor()
    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private let queue = DispatchQueue(label: "afterglow.ar", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: CapturedFrame?
    private var frameCount = 0
    private var framesSinceLog = 0
    private var lastLog: Double = 0
    private var lastState = ""
    private var loggedImage = false
    private let preferUltraWide: Bool
    private let wantsDepth: Bool
    /// The hand tracker fed with every frame; nil with hands off.
    let hands: HandTracker?
    private(set) var chosenFormatText = "none"
    private(set) var cameraName = "wide"

    init(device: MTLDevice, preferUltraWide: Bool, hands: HandTracker?, wantsDepth: Bool) {
        self.device = device
        self.preferUltraWide = preferUltraWide
        self.hands = hands
        self.wantsDepth = wantsDepth
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    var latestFrame: CapturedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            log("[AR] World tracking is not supported on this device")
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = []
        configuration.isLightEstimationEnabled = false
        configuration.environmentTexturing = .none
        configuration.worldAlignment = .gravity
        if let format = chooseFormat() {
            configuration.videoFormat = format
        }
        // The scene depth (LiDAR) teaches the hand tracker the user's palm size.
        if wantsDepth && hands != nil && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
            log("[AR] Scene depth on, for the hands' palm size")
        }
        session.delegate = self
        session.delegateQueue = queue
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        predictor.start()
        log("[AR] World tracking started, format \(chosenFormatText), \(cameraName) camera")
    }

    func pause() { session.pause() }

    // The format: the ultra-wide at 60 fps if the phone lists one (about 120 degrees across, so
    // the view is not magnified to fill the viewer), else the wide camera's 1920x1440 at 60.
    private func chooseFormat() -> ARConfiguration.VideoFormat? {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        var lines = ["[Camera] \(formats.count) world-tracking video formats:"]
        for (index, f) in formats.enumerated() {
            lines.append("  \(index): \(Int(f.imageResolution.width))x\(Int(f.imageResolution.height)) @\(f.framesPerSecond)fps \(Self.name(of: f.captureDeviceType))\(f.isVideoHDRSupported ? " hdr" : "")")
        }
        log(lines.joined(separator: "\n"))

        func best(_ type: AVCaptureDevice.DeviceType, maxWidth: CGFloat) -> ARConfiguration.VideoFormat? {
            formats.filter { $0.captureDeviceType == type && $0.framesPerSecond == 60 && $0.imageResolution.width <= maxWidth && !$0.isVideoHDRSupported }
                .max { $0.imageResolution.width < $1.imageResolution.width }
        }
        var chosen: ARConfiguration.VideoFormat?
        if preferUltraWide, let ultra = best(.builtInUltraWideCamera, maxWidth: 1920) {
            chosen = ultra
            cameraName = "ultra-wide"
        } else {
            if preferUltraWide {
                log("[Camera] No ultra-wide world-tracking format on this phone; using the wide camera")
            }
            chosen = best(.builtInWideAngleCamera, maxWidth: 1920) ?? formats.first { $0.framesPerSecond == 60 }
            cameraName = "wide"
        }
        if let chosen {
            chosenFormatText = "\(Int(chosen.imageResolution.width))x\(Int(chosen.imageResolution.height))@\(chosen.framesPerSecond)"
        }
        return chosen
    }

    private static func name(of type: AVCaptureDevice.DeviceType) -> String {
        switch type {
        case .builtInWideAngleCamera: return "wide"
        case .builtInUltraWideCamera: return "ultrawide"
        case .builtInTelephotoCamera: return "telephoto"
        default: return type.rawValue
        }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let pose = PoseSample(timestamp: frame.timestamp, transform: frame.camera.transform)
        predictor.arrived(pose)
        hands?.submit(frame)

        var captured: CapturedFrame?
        // The iPhone 18 Pro Max delivers x420, 10-bit video-range samples left-justified in 16-bit
        // words, even for its non-HDR formats; read as 8-bit it was coloured static (2026-11-06).
        // 16-bit unorm textures read the 10 bits as a fraction directly.
        let pixelFormat = CVPixelBufferGetPixelFormatType(frame.capturedImage)
        let tenBit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let videoRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        if let cache = textureCache,
           let luma = texture(from: frame.capturedImage, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm, cache: cache),
           let chroma = texture(from: frame.capturedImage, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm, cache: cache) {
            captured = CapturedFrame(pose: pose, intrinsics: frame.camera.intrinsics,
                                     imageWidth: CVPixelBufferGetWidth(frame.capturedImage),
                                     imageHeight: CVPixelBufferGetHeight(frame.capturedImage),
                                     luma: luma.texture, chroma: chroma.texture,
                                     lumaRef: luma.ref, chromaRef: chroma.ref, pixelBuffer: frame.capturedImage,
                                     videoRange: videoRange)
        }
        // Entries the renderer no longer holds go back to the pool.
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
        lock.lock()
        if let captured { latest = captured }
        frameCount += 1
        framesSinceLog += 1
        lock.unlock()

        let state = Self.describe(frame.camera.trackingState)
        let now = frame.timestamp
        if state != lastState {
            log("[AR] Tracking \(state)")
            lastState = state
        }
        if !loggedImage, let captured {
            loggedImage = true
            let fx = captured.intrinsics.columns.0.x
            let fy = captured.intrinsics.columns.1.y
            let degrees = 180 / Float.pi
            let h = 2 * atan(Float(captured.imageWidth) / (2 * fx)) * degrees
            let v = 2 * atan(Float(captured.imageHeight) / (2 * fy)) * degrees
            let format = CVPixelBufferGetPixelFormatType(captured.pixelBuffer)
            let fourcc = String(bytes: [UInt8(format >> 24 & 0xff), UInt8(format >> 16 & 0xff), UInt8(format >> 8 & 0xff), UInt8(format & 0xff)], encoding: .ascii) ?? "?"
            log(String(format: "[Passthrough] Camera image %dx%d %@ (%d planes, %@, %@), %.0f x %.0f deg (%@ camera), intrinsics fx %.1f fy %.1f cx %.1f cy %.1f",
                       captured.imageWidth, captured.imageHeight, fourcc, CVPixelBufferGetPlaneCount(captured.pixelBuffer),
                       captured.luma.pixelFormat == .r16Unorm ? "16-bit" : "8-bit", captured.videoRange ? "video range" : "full range",
                       h, v, cameraName, fx, fy,
                       captured.intrinsics.columns.2.x, captured.intrinsics.columns.2.y))
        }
        if now - lastLog >= 5 {
            let elapsed = lastLog == 0 ? 0 : now - lastLog
            let rate = elapsed > 0 ? Double(framesSinceLog) / elapsed : 0
            let p = frame.camera.transform.columns.3
            log(String(format: "[AR] %@, camera %.1f fps, position (%.2f, %.2f, %.2f); %@", state, rate, p.x, p.y, p.z,
                       predictor.statusAndReset()))
            lastLog = now
            framesSinceLog = 0
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        SessionLog.shared.error("[AR] Session failed: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) { log("[AR] Session interrupted") }
    func sessionInterruptionEnded(_ session: ARSession) { log("[AR] Session interruption ended") }

    private func texture(from buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
                         cache: CVMetalTextureCache) -> (texture: MTLTexture, ref: CVMetalTexture)? {
        let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, width, height, plane, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        return (texture, cvTexture)
    }

    private static func describe(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "not available"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited (initializing)"
            case .excessiveMotion: return "limited (excessive motion)"
            case .insufficientFeatures: return "limited (insufficient features)"
            case .relocalizing: return "limited (relocalizing)"
            @unknown default: return "limited"
            }
        }
    }
}
