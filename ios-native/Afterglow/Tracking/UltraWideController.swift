import AVFoundation
import Metal
import CoreVideo
import simd

/// The ultra-wide camera through AVFoundation, for the 3DoF mode: ARKit has no world-tracking
/// format for it on the iPhone, and cannot run beside it (measured 2026-11-06), so this mode gives
/// up positional tracking for its 106-degree view. The head's rotation comes from the motion
/// sensors (the predictor's attitude, extrapolated to the display time), the camera sits at the
/// origin, and each image goes to the hand tracker with the connection's intrinsics; there is no
/// LiDAR depth here, so the hands are placed by the flat fit at the learned palm size.
final class UltraWideController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, CameraSource, @unchecked Sendable {
    let degreesOfFreedom = 3
    let cameraName = "ultra-wide"
    let hands: HandTracker?
    let predictor = PosePredictor()
    private let device: MTLDevice
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "afterglow.ultrawide", qos: .userInteractive)
    private var textureCache: CVMetalTextureCache?
    private let lock = NSLock()
    private var latest: CapturedFrame?
    private var intrinsics: simd_float3x3?
    private var frames = 0
    private var lastLog: Double = 0
    private var loggedImage = false
    private var fieldOfView: Float = 0

    init(device: MTLDevice, hands: HandTracker?) {
        self.device = device
        self.hands = hands
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    var latestFrame: CapturedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func predictedCameraTransform(at time: Double) -> simd_float4x4? {
        predictor.attitudeCameraTransform(at: time)
    }

    func start() {
        predictor.start()
        queue.async { [self] in configureAndRun() }
    }

    func stop() {
        queue.async { [self] in
            session.stopRunning()
            log("[Camera] Ultra-wide session stopped")
        }
        predictor.stop()
    }

    private func configureAndRun() {
        guard let camera = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) else {
            log("[Camera] No ultra-wide camera on this phone")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            guard session.canAddInput(input) else { log("[Camera] Ultra-wide: cannot add the input"); return }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { log("[Camera] Ultra-wide: cannot add the output"); return }
            session.addOutput(output)

            // The format: 4:3 at 60 fps, the largest no wider than 1920, 8-bit 420 by preference.
            var lines = ["[Camera] \(camera.formats.count) ultra-wide formats:"]
            var chosen: AVCaptureDevice.Format?
            for (index, format) in camera.formats.enumerated() {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let maxRate = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
                let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                let fourcc = String(bytes: [UInt8(subtype >> 24 & 0xff), UInt8(subtype >> 16 & 0xff), UInt8(subtype >> 8 & 0xff), UInt8(subtype & 0xff)], encoding: .ascii) ?? "?"
                lines.append(String(format: "  %d: %dx%d @%.0ffps %@ fov %.0f%@", index, dims.width, dims.height, maxRate, fourcc,
                                    format.videoFieldOfView, format.isMultiCamSupported ? " multicam" : ""))
                let fourByThree = abs(Float(dims.width) / Float(dims.height) - 4.0 / 3.0) < 0.05
                if maxRate >= 60 && dims.width <= 1920 && fourByThree && fourcc == "420f" {
                    if let c = chosen, CMVideoFormatDescriptionGetDimensions(c.formatDescription).width >= dims.width { continue }
                    chosen = format
                }
            }
            log(lines.joined(separator: "\n"))
            try camera.lockForConfiguration()
            if let chosen {
                camera.activeFormat = chosen
                camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
                camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
            }
            fieldOfView = camera.activeFormat.videoFieldOfView
            camera.unlockForConfiguration()
            if let connection = output.connection(with: .video) {
                if connection.isCameraIntrinsicMatrixDeliverySupported {
                    connection.isCameraIntrinsicMatrixDeliveryEnabled = true
                }
                // The sensor's own orientation, landscape right, as ARKit's images come.
                if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            }
            session.commitConfiguration()
            let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
            session.startRunning()
            log(String(format: "[Camera] Ultra-wide running: %dx%d, field of view %.0f deg, intrinsics %@", dims.width, dims.height, fieldOfView,
                       output.connection(with: .video)?.isCameraIntrinsicMatrixDeliveryEnabled == true ? "from the connection" : "from the field of view"))
        } catch {
            log("[Camera] Ultra-wide failed: \(error.localizedDescription)")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)

        // Intrinsics: the connection's, else from the format's field of view.
        var k: simd_float3x3
        if let data = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data,
           data.count >= MemoryLayout<matrix_float3x3>.size {
            k = data.withUnsafeBytes { $0.load(as: matrix_float3x3.self) }
        } else {
            let fx = Float(width) / 2 / tan(fieldOfView * .pi / 180 / 2)
            k = simd_float3x3(columns: (SIMD3(fx, 0, 0), SIMD3(0, fx, 0), SIMD3(Float(width) / 2, Float(height) / 2, 1)))
        }
        guard let cameraTransform = predictor.attitudeCameraTransform(at: timestamp) else { return }
        let pose = PoseSample(timestamp: timestamp, transform: cameraTransform)

        var captured: CapturedFrame?
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let videoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        if let cache = textureCache,
           let luma = texture(from: buffer, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm, cache: cache),
           let chroma = texture(from: buffer, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm, cache: cache) {
            captured = CapturedFrame(pose: pose, intrinsics: k, imageWidth: width, imageHeight: height,
                                     luma: luma.texture, chroma: chroma.texture, lumaRef: luma.ref, chromaRef: chroma.ref,
                                     pixelBuffer: buffer, videoRange: videoRange)
        }
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
        lock.lock()
        if let captured { latest = captured }
        frames += 1
        lock.unlock()
        hands?.submit(HandImage(pixelBuffer: buffer, timestamp: timestamp, intrinsics: k, width: width, height: height,
                                cameraTransform: cameraTransform, sceneDepth: nil))

        if !loggedImage, let captured {
            loggedImage = true
            let degrees = 180 / Float.pi
            let h = 2 * atan(Float(width) / (2 * k.columns.0.x)) * degrees
            let v = 2 * atan(Float(height) / (2 * k.columns.1.y)) * degrees
            let fourcc = String(bytes: [UInt8(format >> 24 & 0xff), UInt8(format >> 16 & 0xff), UInt8(format >> 8 & 0xff), UInt8(format & 0xff)], encoding: .ascii) ?? "?"
            log(String(format: "[Passthrough] Camera image %dx%d %@ (%@, %@), %.0f x %.0f deg (ultra-wide camera), intrinsics fx %.1f fy %.1f cx %.1f cy %.1f",
                       width, height, fourcc, captured.luma.pixelFormat == .r16Unorm ? "16-bit" : "8-bit", videoRange ? "video range" : "full range",
                       h, v, k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y))
        }
        if timestamp - lastLog >= 5 {
            let elapsed = lastLog == 0 ? 0 : timestamp - lastLog
            lock.lock(); let n = frames; frames = 0; lock.unlock()
            log(String(format: "[AR] 3DoF, ultra-wide camera %.1f fps; %@", elapsed > 0 ? Double(n) / elapsed : 0, predictor.statusAndReset()))
            lastLog = timestamp
        }
    }

    private func texture(from buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
                         cache: CVMetalTextureCache) -> (texture: MTLTexture, ref: CVMetalTexture)? {
        let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, width, height, plane, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, cvTexture)
    }
}
