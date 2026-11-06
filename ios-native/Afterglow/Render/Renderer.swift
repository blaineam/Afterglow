@preconcurrency import Metal
import QuartzCore
import UIKit
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The stereo rig. Each frame: the head pose predicted to the frame's display time, both eyes drawn
/// in one pass with vertex amplification into a two-slice texture array (the eye texture), then
/// that texture warped onto the screen through the viewer's lens distortion. The eye texture's
/// size follows the render scale; the lens geometry follows the screen's physical size.
@MainActor
final class Renderer {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private var skyPipeline: MTLRenderPipelineState!
    private var floorPipeline: MTLRenderPipelineState!
    private var passthroughPipeline: MTLRenderPipelineState!
    private var distortionPipeline: MTLRenderPipelineState!
    private var overlayPipeline: MTLRenderPipelineState!
    private var overlay = HandOverlay()
    private var grabDemo = GrabDemo()
    private var overlayBuffers: [MTLBuffer] = []
    private var overlayBufferIndex = 0

    private let screen: ScreenMetrics
    private let lens: LensDistortion
    private var meshBuffer: MTLBuffer!
    private var indexBuffer: MTLBuffer!
    private var indexCount = 0

    private var eyeTexture: MTLTexture?
    private var eyeTextureScale: Float = 0
    private var currentScale: Float = 1
    private var cappedScale: Float = 1

    private let inflight = DispatchSemaphore(value: 2)
    private let frames = FrameTimingLog()
    private let lastGpuMs = LockedValue<Double>(0)
    /// How long after the display link's target time frames actually reach the screen, smoothed:
    /// the drawable's presented time against the target it was built for. Added to the prediction
    /// horizon, so the head pose is predicted to when the picture is really seen.
    private let presentLagMs = LockedValue<Double>(0)
    private let launchTime = CACurrentMediaTime()
    private var lastPoseLog: Double = 0
    private var lastSettingsText = ""
    private var dumped = false
    private let amplifies: Bool

    let ar: ARController
    let settings: Settings
    let thermal: ThermalLog

    /// The eyes' midpoint relative to the camera, in camera axes (x right, y up, z back), metres.
    private let cameraToEyes: SIMD3<Float>
    private let floorHeight: Float = -1.6
    /// How far the eyes have moved onto the camera (1) from their real place (0): with passthrough
    /// on they sit at the camera, so the hands and anything placed line up with the camera image,
    /// which is drawn as if seen from there. Eased over half a second, as the Unity app does.
    private var eyesAtCamera: Float = 0
    private var lastDrawTime: Double = 0
    private var ultraProbe: UltraWideProbe?

    init?(settings: Settings, thermal: ThermalLog, screen uiScreen: UIScreen) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            SessionLog.shared.error("[Stereo] No Metal device")
            return nil
        }
        self.device = device
        self.commandQueue = queue
        self.library = library
        self.settings = settings
        self.thermal = thermal
        self.screen = ScreenMetrics.of(uiScreen)
        self.lens = LensDistortion(viewer: .afterglowViewer, screenWidthMeters: screen.widthMeters,
                                   screenHeightMeters: screen.heightMeters)
        self.cameraToEyes = SIMD3<Float>(settings.cameraToEyesMm) / 1000
        let hands = settings.hands ? HandTracker(hertz: settings.handHz, useDepth: settings.handDepth) : nil
        self.ar = ARController(device: device, preferUltraWide: settings.ultraWide, hands: hands, wantsDepth: settings.handDepth)

        // The simulator's Metal has no vertex amplification: there each eye gets its own pass
        // into its slice (drawEyes), which is the same picture at twice the draw calls.
        amplifies = device.supportsVertexAmplificationCount(2)
        do {
            try buildPipelines()
        } catch {
            SessionLog.shared.error("[Stereo] Pipelines: \(error)")
            return nil
        }
        buildDistortionMesh()
        FrameTimingLog.screenMaximum = uiScreen.maximumFramesPerSecond
        logSetup()
    }

    private func logSetup() {
        let fov = lens.fieldOfView(.left)
        let degrees = 180 / Float.pi
        log(String(format: "[Stereo] %@: screen %.4f x %.4f m (iOS %@ %dx%d px at %.0f dpi (%@ screen)), left eye fov L%.1f R%.1f B%.1f T%.1f",
                   lens.viewer.model, screen.widthMeters, screen.heightMeters, screen.modelIdentifier,
                   screen.pixelWidth, screen.pixelHeight, screen.pixelsPerInch, screen.known ? "known" : "assumed",
                   fov.x * degrees, fov.y * degrees, fov.z * degrees, fov.w * degrees))
        let v = lens.viewer
        log(String(format: "[Stereo] Viewer lens: screenToLens %.4f interLens %.4f trayToLens %.4f alignment %d fov %.2f,%.2f,%.2f,%.2f k %@",
                   v.screenToLensDistance, v.interLensDistance, v.trayToLensDistance, v.verticalAlignment.rawValue,
                   v.leftEyeFieldOfViewAngles[0], v.leftEyeFieldOfViewAngles[1], v.leftEyeFieldOfViewAngles[2], v.leftEyeFieldOfViewAngles[3],
                   v.distortionCoefficients.map { String(format: "%.5f", $0) }.joined(separator: ",")))
        log(String(format: "[Stereo] Camera to eyes (%.3f, %.3f, %.3f) m in camera axes; rendering both eyes in one pass with vertex amplification, lens warp mesh %dx%d per eye",
                   cameraToEyes.x, cameraToEyes.y, cameraToEyes.z, LensDistortion.meshResolution, LensDistortion.meshResolution))
        if !amplifies {
            log("[Stereo] No vertex amplification on this GPU (the simulator): one pass per eye instead")
        }
    }

    private func buildPipelines() throws {
        func scene(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            if amplifies { d.maxVertexAmplificationCount = 2 }
            // Writing render_target_array_index needs the topology stated up front.
            d.inputPrimitiveTopology = .triangle
            d.label = fragment
            return try device.makeRenderPipelineState(descriptor: d)
        }
        skyPipeline = try scene("fullscreenVertex", "skyFragment")
        floorPipeline = try scene("floorVertex", "floorFragment")
        passthroughPipeline = try scene("fullscreenVertex", "passthroughFragment")
        overlayPipeline = try scene("overlayVertex", "overlayFragment")

        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "distortionVertex")
        d.fragmentFunction = library.makeFunction(name: "distortionFragment")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        d.label = "distortion"
        distortionPipeline = try device.makeRenderPipelineState(descriptor: d)
    }

    // Both eyes' meshes in one buffer, drawn in one call; each vertex carries its eye.
    private func buildDistortionMesh() {
        var vertices: [DistortionVertex] = []
        var indices: [UInt32] = []
        for eye in Eye.allCases {
            let mesh = lens.distortionMesh(eye)
            let base = UInt32(vertices.count)
            vertices += mesh.vertices.map { DistortionVertex(position: $0.position, uv: $0.uv, eye: $0.eye) }
            indices += mesh.indices.map { $0 + base }
        }
        meshBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<DistortionVertex>.stride, options: .storageModeShared)
        indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        indexCount = indices.count
    }

    /// The render scale in use after the thermal cap, and the frame rate to ask for.
    func applySettings() -> Int {
        var scale = Float(settings.renderScalePercent) / 100
        var fps = settings.targetFrameRate
        if settings.thermalCap {
            switch thermal.currentState {
            case "serious": scale = min(scale, 0.8)
            case "critical": scale = min(scale, 0.6); fps = min(fps, 30)
            default: break
            }
        }
        cappedScale = scale
        let text = String(format: "target %d fps, render scale %.2f, passthrough %@, thermal %@", fps, scale,
                          settings.passthrough ? "on" : "off", thermal.currentState)
        if text != lastSettingsText {
            lastSettingsText = text
            log("[Stereo] Settings applied: \(text)")
        }
        frames.targetFrameRate = fps
        return fps
    }

    private func ensureEyeTexture() {
        let scale = cappedScale
        if eyeTexture != nil && eyeTextureScale == scale { return }
        let width = max(16, Int((Float(screen.pixelWidth) * 0.5 * scale).rounded()))
        let height = max(16, Int((Float(screen.pixelHeight) * scale).rounded()))
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.arrayLength = 2
        d.pixelFormat = .bgra8Unorm
        d.width = width
        d.height = height
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        eyeTexture = device.makeTexture(descriptor: d)
        eyeTexture?.label = "eyes"
        eyeTextureScale = scale
        log(String(format: "[Stereo] Eye textures %dx%d each (render scale %.2f), two slices of one array", width, height, scale))
    }

    /// One frame. `timestamp` is the display link's time for this callback and `targetTimestamp`
    /// when the frame is due on the screen, which is what the head pose is predicted to.
    func draw(to layer: CAMetalLayer, timestamp: Double, targetTimestamp: Double) {
        let t0 = CACurrentMediaTime()
        inflight.wait()
        guard let drawable = layer.nextDrawable() else {
            inflight.signal()
            return
        }
        let t2 = CACurrentMediaTime()
        ensureEyeTexture()
        guard let eyeTexture, let commandBuffer = commandQueue.makeCommandBuffer() else {
            inflight.signal()
            return
        }

        // The head: the latest ARKit pose predicted ahead to the display time.
        let frame = ar.latestFrame
        let measuredLag = presentLagMs.value
        let predictTo = targetTimestamp + (measuredLag + Double(settings.extraPredictionMs)) / 1000
        var cameraInWorld = matrix_identity_float4x4
        var horizonMs = 0.0
        if let frame {
            cameraInWorld = ar.predictor.predict(frame.pose, to: predictTo)
            horizonMs = (predictTo - frame.pose.timestamp) * 1000
        }
        let step = Float(min(max(t2 - lastDrawTime, 0), 0.1)) / 0.5
        lastDrawTime = t2
        let target: Float = settings.passthrough ? 1 : 0
        eyesAtCamera += min(max(target - eyesAtCamera, -step), step)
        let headInWorld = cameraInWorld * simd_float4x4.translation(cameraToEyes * (1 - eyesAtCamera))

        var uniforms = FrameUniforms()
        for eye in Eye.allCases {
            let eyeInWorld = headInWorld * simd_float4x4.translation(lens.eyeOffset(eye))
            let projection = lens.projectionMatrix(eye, near: 0.05, far: 500)
            let view = eyeInWorld.inverse
            var worldFromView = eyeInWorld
            worldFromView.columns.3 = SIMD4(0, 0, 0, 1)
            let eyeUniforms = EyeUniforms(viewProjection: projection * view, inverseProjection: projection.inverse,
                                          worldFromView: worldFromView, eyePosition: eyeInWorld.columns.3)
            if eye == .left { uniforms.eyes.0 = eyeUniforms } else { uniforms.eyes.1 = eyeUniforms }
        }
        if let frame {
            // Rotation only, inverted: a rotation's inverse is its transpose.
            var captureFromWorld = frame.pose.transform.transpose
            captureFromWorld.columns.0.w = 0
            captureFromWorld.columns.1.w = 0
            captureFromWorld.columns.2.w = 0
            captureFromWorld.columns.3 = SIMD4(0, 0, 0, 1)
            uniforms.captureFromWorld = captureFromWorld
            let k = frame.intrinsics
            uniforms.captureIntrinsics = SIMD4(k.columns.0.x / Float(frame.imageWidth), k.columns.1.y / Float(frame.imageHeight),
                                               k.columns.2.x / Float(frame.imageWidth), k.columns.2.y / Float(frame.imageHeight))
            uniforms.captureVideoRange = frame.videoRange ? 1 : 0
        }
        uniforms.time = Float(t2 - launchTime)
        uniforms.floorHeight = floorHeight
        uniforms.passthroughBlend = settings.passthrough ? 1 : 0

        // The hands as of this frame, and the grab demo they drive.
        overlay.clear()
        if let hands = ar.hands {
            let tracked = hands.hands(at: predictTo)
            grabDemo.update(hands: tracked, time: predictTo)
            let eyeMid = headInWorld.columns.3.xyz
            if settings.showHands {
                for hand in tracked { overlay.addHand(hand, eye: eyeMid) }
            }
            grabDemo.draw(into: &overlay)
        }
        var overlayBuffer: MTLBuffer?
        if !overlay.vertices.isEmpty {
            let bytes = overlay.vertices.count * MemoryLayout<OverlayVertex>.stride
            if overlayBuffers.count < 3 {
                while overlayBuffers.count < 3 {
                    overlayBuffers.append(device.makeBuffer(length: 1 << 20, options: .storageModeShared)!)
                }
            }
            overlayBufferIndex = (overlayBufferIndex + 1) % overlayBuffers.count
            let buffer = overlayBuffers[overlayBufferIndex]
            if bytes <= buffer.length {
                overlay.vertices.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
                overlayBuffer = buffer
            }
        }

        // Pass 1: the scene, both eyes at once (or one pass per eye without amplification).
        let passes: [Int?] = amplifies ? [nil] : [0, 1]
        for slice in passes {
            let scenePass = MTLRenderPassDescriptor()
            scenePass.colorAttachments[0].texture = eyeTexture
            scenePass.colorAttachments[0].loadAction = .clear
            scenePass.colorAttachments[0].storeAction = .store
            scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            var passUniforms = uniforms
            if let slice {
                scenePass.colorAttachments[0].slice = slice
                // The shaders index the eyes by the amplification id, which is 0 here.
                if slice == 1 { passUniforms.eyes.0 = uniforms.eyes.1 }
            } else {
                scenePass.renderTargetArrayLength = 2
            }
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) else { continue }
            encoder.label = "scene"
            if slice == nil {
                var mappings = [MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 0, renderTargetArrayIndexOffset: 0),
                                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 0, renderTargetArrayIndexOffset: 1)]
                encoder.setVertexAmplificationCount(2, viewMappings: &mappings)
            }
            encoder.setVertexBytes(&passUniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&passUniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            if settings.passthrough, let frame {
                encoder.setRenderPipelineState(passthroughPipeline)
                encoder.setFragmentTexture(frame.luma, index: 0)
                encoder.setFragmentTexture(frame.chroma, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            } else {
                encoder.setRenderPipelineState(skyPipeline)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.setRenderPipelineState(floorPipeline)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            if let overlayBuffer {
                encoder.setRenderPipelineState(overlayPipeline)
                encoder.setVertexBuffer(overlayBuffer, offset: 0, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: overlay.vertices.count)
            }
            encoder.endEncoding()
        }

        // Pass 2: the lens warp onto the screen.
        let screenPass = MTLRenderPassDescriptor()
        screenPass.colorAttachments[0].texture = drawable.texture
        screenPass.colorAttachments[0].loadAction = .clear
        screenPass.colorAttachments[0].storeAction = .store
        screenPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: screenPass) {
            encoder.label = "distortion"
            encoder.setRenderPipelineState(distortionPipeline)
            encoder.setVertexBuffer(meshBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(eyeTexture, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                          indexBuffer: indexBuffer, indexBufferOffset: 0)
            encoder.endEncoding()
        }

        let lastGpuMs = self.lastGpuMs
        let inflight = self.inflight
        commandBuffer.addCompletedHandler { buffer in
            lastGpuMs.value = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            inflight.signal()
        }
        if settings.ultraTestSeconds > 0 && ultraProbe == nil && t2 - launchTime >= Double(settings.ultraTestSeconds) {
            ultraProbe = UltraWideProbe()
            ultraProbe?.start()
        }
        if settings.dumpAfterSeconds > 0 && !dumped && t2 - launchTime >= Double(settings.dumpAfterSeconds) {
            dumped = true
            dumpEye(0, from: eyeTexture, in: commandBuffer)
            dumpEye(1, from: eyeTexture, in: commandBuffer)
        }
        #if !targetEnvironment(simulator)
        // The simulator's drawables report no presented time.
        let presentLagMs = self.presentLagMs
        drawable.addPresentedHandler { presented in
            // presentedTime is 0 when the drawable was dropped unshown.
            if presented.presentedTime > 0 {
                let lag = (presented.presentedTime - targetTimestamp) * 1000
                presentLagMs.value = presentLagMs.value * 0.9 + lag * 0.1
            }
        }
        #endif
        commandBuffer.present(drawable)
        commandBuffer.commit()
        let t3 = CACurrentMediaTime()
        let gpuMs = lastGpuMs.value
        frames.record(timestamp: timestamp,
                      sample: FrameTimingLog.Sample(mainMs: (t3 - t2) * 1000, presentWaitMs: (t2 - t0) * 1000, gpuMs: gpuMs),
                      thermalState: thermal.currentState)

        if t2 - lastPoseLog >= 5 {
            lastPoseLog = t2
            let p = headInWorld.columns.3
            log(String(format: "[Pose] 6DoF: head (%.2f, %.2f, %.2f), predicted %.0f ms ahead of the camera image (display %.0f ms + presented %.1f ms after target + %d ms), camera frame age %.0f ms",
                       p.x, p.y, p.z, horizonMs, (targetTimestamp - timestamp) * 1000, measuredLag, settings.extraPredictionMs,
                       frame.map { (t2 - $0.pose.timestamp) * 1000 } ?? 0))
        }
    }
}

extension Renderer {
    /// Copies an eye's slice into a readable texture and writes it as a PNG once the GPU is done,
    /// for checking the picture from the Mac (`--ei dump 3`): eye-left.png and eye-right.png.
    fileprivate func dumpEye(_ slice: Int, from eyeTexture: MTLTexture, in commandBuffer: MTLCommandBuffer) {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: eyeTexture.width,
                                                         height: eyeTexture.height, mipmapped: false)
        d.storageMode = .shared
        d.usage = .shaderRead
        guard let copy = device.makeTexture(descriptor: d), let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: eyeTexture, sourceSlice: slice, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: eyeTexture.width, height: eyeTexture.height, depth: 1),
                  to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        let copied = copy
        commandBuffer.addCompletedHandler { _ in
            let width = copied.width, height = copied.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            copied.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(slice == 0 ? "eye-left.png" : "eye-right.png")
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                log("[Stereo] Eye dump failed")
                return
            }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            log("[Stereo] Eye texture written to \(url.lastPathComponent) (\(width)x\(height))")
        }
    }
}

/// A value shared between the frame loop and the GPU's completion handlers.
final class LockedValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
