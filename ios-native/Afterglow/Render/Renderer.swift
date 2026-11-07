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
    private var quadPipeline: MTLRenderPipelineState!
    private var mediaPipeline: MTLRenderPipelineState!
    private var mediaQuadPipeline: MTLRenderPipelineState!
    private(set) var media: MediaApp?
    private var quadBuffers: [MTLBuffer] = []
    private var quadBufferIndex = 0
    /// The browser and its panels in the scene; nil until opened.
    private(set) var browser: Browser?
    private var chrome: ChromePanel?
    private var keyboard: KeyboardPanel?
    private var uiWindow: UIWindow?
    private var toolbar: Toolbar?
    private(set) var openApp: AppKind?
    /// Input for the frame: a pinch that began, a tap, a double tap on the viewer.
    private var pinchWas = [false, false]
    private let tapRequests = LockedValue<Int>(0)
    private var doubleTapTarget: SIMD2<Float>?
    private var doubleTapPending = false
    /// Desk mode: with no tracking (the Simulator), a drag turns the head.
    private(set) var deskYaw: Float = 0
    private(set) var deskPitch: Float = 0
    var onDictate: (() -> Void)?
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

    /// The camera and head pose source in use; swapped when the degrees of freedom change.
    private(set) var source: CameraSource
    private var sourceDof = 0
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
        self.source = Self.makeSource(dof: settings.degreesOfFreedom, device: device, hands: hands, settings: settings)
        self.sourceDof = settings.degreesOfFreedom

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

    private static func makeSource(dof: Int, device: MTLDevice, hands: HandTracker?, settings: Settings) -> CameraSource {
        if dof == 3 {
            return UltraWideController(device: device, hands: hands)
        }
        return ARController(device: device, preferUltraWide: settings.ultraWide, hands: hands, wantsDepth: settings.handDepth)
    }

    /// The window the app is in: the browser's veiled web view lives in it.
    func attach(window: UIWindow) {
        uiWindow = window
        keyboard = KeyboardPanel(device: device)
        let toolbar = Toolbar(device: device, settings: settings)
        toolbar.onLaunch = { [weak self] app in self?.launch(app) }
        toolbar.onRecentre = { [weak self] in self?.recentre() }
        toolbar.onCloseApp = { [weak self] in self?.closeApp() }
        toolbar.place(ahead: lastHead)
        self.toolbar = toolbar
        source.predictor.onTap = { [weak self] kind in
            self?.tapRequests.value = kind
        }
    }

    func openBrowser() {
        guard browser == nil, let uiWindow else { return }
        let fovs = Eye.allCases.map { lens.fieldOfView($0) }
        let config = WebBridge.Config(screenMeters: SIMD2(screen.widthMeters, screen.heightMeters),
                                      screenToLens: lens.viewer.screenToLensDistance, interLens: lens.viewer.interLensDistance,
                                      yEyeOffset: lens.yEyeOffsetMeters, k: lens.viewer.distortionCoefficients, fov: fovs,
                                      hasPosition: source.degreesOfFreedom == 6,
                                      screenPixels: SIMD2(screen.pixelWidth, screen.pixelHeight), renderScale: settings.renderScalePercent)
        let browser = Browser(device: device, config: config, textScalePercent: settings.textScalePercent)
        self.browser = browser
        chrome = ChromePanel(device: device)
        browser.open(in: uiWindow, head: lastHead, launchURL: settings.launchURL.flatMap { URL(string: WebBridge.normalizeAddress($0)) })
        layoutPanels()
    }

    func closeBrowser() {
        browser?.close()
        browser = nil
        chrome = nil
    }

    func launch(_ app: AppKind) {
        toolbar?.noteOpened(app)
        if app != openApp { closeApp() }
        switch app {
        case .browser:
            settings.browserOpen = true
            openApp = .browser
        case .media, .files:
            let media = MediaApp(device: device)
            media.onPickFolder = { [weak self] in
                guard let self, let root = self.uiWindow?.rootViewController, let files = self.media?.files else { return }
                files.pickFolder(from: root)
            }
            if app == .files { media.openFiles(head: lastHead) } else { media.open(head: lastHead) }
            self.media = media
            openApp = app
        default:
            log("[Home] \(app.rawValue) is not built yet")
        }
        log("[Home] Opened \(app.rawValue)")
    }

    func closeApp() {
        if openApp == .browser { settings.browserOpen = false }
        if openApp == .media || openApp == .files { media?.close(); media = nil }
        openApp = nil
    }

    /// Re-hangs the window and the toolbar where the head looks now.
    func recentre() {
        browser?.window.place(ahead: lastHead)
        toolbar?.place(ahead: lastHead)
        layoutPanels()
        log("[Home] Recentred")
    }

    /// A tap on the screen (desk mode, or the viewer's button): a select.
    func screenTapped() { tapRequests.value = 2 }
    /// A long press on the screen ends an immersive session.
    func screenHeld() { browser?.endSession() }
    func deskLook(yawDelta: Float, pitchDelta: Float) {
        deskYaw += yawDelta
        deskPitch = min(max(deskPitch + pitchDelta, -1.4), 1.4)
    }

    private var lastHead = matrix_identity_float4x4
    private var actionIndex = 0
    private var actionWaitUntil: Double = 0

    /// Runs the next step of the `actions` script when its time has come (the Simulator harness).
    private func runActions(now: Double) {
        guard actionIndex < settings.actions.count, now >= actionWaitUntil else { return }
        let step = settings.actions[actionIndex]
        actionIndex += 1
        let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1] : ""
        log("[Actions] \(step)")
        switch verb {
        case "wait": actionWaitUntil = now + (Double(argument) ?? 1)
        case "press":
            if let keyboard, keyboard.panel.buttons.contains(where: { $0.id == argument }) {
                if let media, media.isFiles {
                    switch keyboard.press(argument) {
                    case .text(let t): media.type(t)
                    case .key(let k): media.key(k)
                    default: break
                    }
                } else {
                    pressPanel(keyboard.panel, id: argument)
                }
            }
            else if let chrome, chrome.panel.buttons.contains(where: { $0.id == argument }) { pressPanel(chrome.panel, id: argument) }
            else if let media, (media.screen == .viewing ? media.controls : media.grid).buttons.contains(where: { $0.id == argument }) { media.press(argument) }
            else if let toolbar { toolbar.press(argument) }
        case "type": if let media, media.isFiles { media.type(argument) } else { browser?.type(argument) }
        case "key": if let media, media.isFiles { media.key(argument) } else { browser?.key(argument) }
        case "look":
            let numbers = argument.split(separator: " ").compactMap { Float($0) }
            if numbers.count == 2 { deskYaw = numbers[0] * .pi / 180; deskPitch = numbers[1] * .pi / 180 }
        case "tap": tapRequests.value = 2
        case "dump": dumped = false; actionWaitUntil = now + 0.5; dumpNext = true
        case "screenshot": log("[Actions] screenshot")
        case "immersive":
            // The page's Enter VR control: a button or link whose text mentions VR or XR.
            let script = "(function(){var els=Array.from(document.querySelectorAll('button,a,[role=button]'));"
                + "var b=els.find(function(e){return /\\b(vr|xr)\\b/i.test(e.textContent||'');})||els.find(function(e){return e.tagName==='BUTTON';});"
                + "if(b){b.click();return 'clicked '+(b.textContent||'').trim().slice(0,40);}return 'no button';})()"
            browser?.current?.webView.evaluateJavaScript(script) { result, _ in log("[Actions] immersive: \(result ?? "?")") }
        case "end": browser?.endSession()
        case "js":
            browser?.current?.webView.evaluateJavaScript(argument) { result, error in
                log("[Actions] js: \(result.map { "\($0)" } ?? error?.localizedDescription ?? "nil")")
            }
        default: break
        }
    }
    private var dumpNext = false

    private func layoutPanels() {
        guard let browser, let chrome, let keyboard else { return }
        let w = browser.window
        chrome.panel.pane.widthMeters = w.widthMeters
        chrome.panel.pane.right = w.right
        chrome.panel.pane.up = w.up
        chrome.panel.pane.centre = w.centre + w.up * (w.heightMeters / 2 + chrome.panel.pane.heightMeters / 2 + 0.02)
        keyboard.panel.pane.widthMeters = w.widthMeters
        keyboard.panel.pane.right = w.right
        // Tilted up a little, below the window and nearer.
        let tilt = simd_quatf(angle: -0.35, axis: w.right)
        keyboard.panel.pane.up = tilt.act(w.up)
        keyboard.panel.pane.centre = w.centre - w.up * (w.heightMeters / 2 + keyboard.panel.pane.heightMeters / 2 * 0.9 + 0.03) - w.normal * 0.15
    }

    /// Starts the source; also swaps it when the setting changed (the strip's switch).
    func startSource() {
        if sourceDof != settings.degreesOfFreedom {
            source.stop()
            let hands = source.hands
            source = Self.makeSource(dof: settings.degreesOfFreedom, device: device, hands: hands, settings: settings)
            sourceDof = settings.degreesOfFreedom
            log("[Pose] Switched to \(sourceDof)DoF (\(source.cameraName) camera)")
        }
        source.start()
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
        quadPipeline = try scene("quadVertex", "quadFragment")
        mediaPipeline = try scene("fullscreenVertex", "mediaFragment")
        mediaQuadPipeline = try scene("quadVertex", "mediaQuadFragment")

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

        // The head: the latest pose predicted ahead to the display time.
        if sourceDof != settings.degreesOfFreedom { startSource() }
        let frame = source.latestFrame
        let measuredLag = presentLagMs.value
        let predictTo = targetTimestamp + (measuredLag + Double(settings.extraPredictionMs)) / 1000
        var cameraInWorld = matrix_identity_float4x4
        var horizonMs = 0.0
        if let predicted = source.predictedCameraTransform(at: predictTo) {
            cameraInWorld = predicted
            if let frame { horizonMs = (predictTo - frame.pose.timestamp) * 1000 }
        } else {
            // No tracking (the Simulator): the desk look.
            let yaw = simd_quatf(angle: deskYaw, axis: SIMD3(0, 1, 0))
            let pitch = simd_quatf(angle: deskPitch, axis: SIMD3(1, 0, 0))
            cameraInWorld = simd_float4x4(yaw * pitch)
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

        lastHead = headInWorld
        if settings.browserOpen && browser == nil && uiWindow != nil { openBrowser() }
        if !settings.browserOpen && browser != nil { closeBrowser() }

        // The hands as of this frame, and the grab demo they drive.
        overlay.clear()
        var tracked: [TrackedHandState] = []
        if let hands = source.hands {
            tracked = hands.hands(at: predictTo)
            let eyeMid = headInWorld.columns.3.xyz
            if settings.showHandsLive {
                for hand in tracked { overlay.addHand(hand, eye: eyeMid) }
            }
            hands.hertz = settings.handHzLive
        }
        // Selects this frame: a pinch beginning, a screen tap, or a double tap on the viewer.
        var pinchNow = [false, false]
        for hand in tracked { pinchNow[hand.isRight ? 1 : 0] = pinchNow[hand.isRight ? 1 : 0] || hand.pinched }
        var select = (0..<2).contains { pinchNow[$0] && !pinchWas[$0] }
        pinchWas = pinchNow
        let tap = tapRequests.value
        if tap != 0 {
            tapRequests.value = 0
            if tap == 1 {
                doubleTapPending = true
                doubleTapTarget = browser?.window.gaze(from: headInWorld)?.uv
            } else {
                select = true
            }
        }
        if browser == nil {
            grabDemo.update(hands: tracked, time: predictTo)
            grabDemo.draw(into: &overlay)
        }
        var quads: [(MTLBuffer?, MTLTexture, SIMD4<Float>, Int)] = []
        var toolbarQuads: [(MTLTexture, Int)] = []
        if let toolbar, !(browser?.isImmersive ?? false) {
            let origin = headInWorld.columns.3.xyz
            let forward = -headInWorld.columns.2.xyz
            var hit: (ScenePanel, SIMD2<Float>)?
            if toolbar.menuOpen, let h = toolbar.menu.pane.hit(origin: origin, direction: forward) { hit = (toolbar.menu, h.uv) }
            else if let h = toolbar.panel.pane.hit(origin: origin, direction: forward) { hit = (toolbar.panel, h.uv) }
            _ = toolbar.panel.hover(hit?.0 === toolbar.panel ? hit?.1 : nil)
            _ = toolbar.menu.hover(hit?.0 === toolbar.menu ? hit?.1 : nil)
            if select, let (panel, _) = hit, let id = panel.hovered {
                toolbar.press(id)
                select = false
            }
            toolbar.render()
            if let t = toolbar.panel.texture { toolbarQuads.append((t, 3)) }
            if toolbar.menuOpen, let t = toolbar.menu.texture { toolbarQuads.append((t, 4)) }
            if hit != nil, browser == nil || toolbar.menuOpen {
                // The reticle on the toolbar when nothing else draws one.
                let (panel, uv) = hit!
                let at = panel.pane.centre + panel.pane.right * ((uv.x - 0.5) * panel.pane.widthMeters) + panel.pane.up * ((0.5 - uv.y) * panel.pane.heightMeters)
                overlay.addSquare(at - forward * 0.01, size: 0.012, eye: origin, color: HandOverlay.pinchColor)
            }
        }
        var mediaTextures: (picture: MTLTexture?, eyes: MTLTexture?) = (nil, nil)
        var mediaUniforms = MediaUniforms()
        if let media {
            let origin = headInWorld.columns.3.xyz
            let forward = -headInWorld.columns.2.xyz
            let panel = media.screen == .viewing ? media.controls : media.grid
            var hit = panel.pane.hit(origin: origin, direction: forward)
            _ = panel.hover(hit?.uv)
            // The keyboard under the Files grid types the search.
            let filesKeys = media.isFiles && media.screen == .items
            if filesKeys, let keyboard {
                keyboard.panel.pane.right = media.grid.pane.right
                keyboard.panel.pane.up = simd_quatf(angle: -0.35, axis: media.grid.pane.right).act(media.grid.pane.up)
                keyboard.panel.pane.widthMeters = media.grid.pane.widthMeters
                keyboard.panel.pane.centre = media.grid.pane.centre - media.grid.pane.up * (media.grid.pane.heightMeters / 2 + keyboard.panel.pane.heightMeters * 0.45) - media.grid.pane.normal * 0.15
                let keyHit = keyboard.panel.pane.hit(origin: origin, direction: forward)
                _ = keyboard.panel.hover(keyHit?.uv)
                if select, keyHit != nil, let id = keyboard.panel.hovered {
                    switch keyboard.press(id) {
                    case .text(let t): media.type(t)
                    case .key(let k): media.key(k)
                    case .mic: onDictate?()
                    case .none: break
                    }
                    select = false
                }
                keyboard.render()
                if let t = keyboard.panel.texture { toolbarQuads.append((t, 2)) }
                if hit == nil, let keyHit { hit = keyHit; _ = keyHit }
            }
            if select, hit != nil, let id = panel.hovered {
                media.press(id)
                select = false
            }
            media.render()
            mediaTextures = media.frame(hostTime: t2)
            mediaUniforms = media.uniforms()
            if media.screen == .viewing {
                if let t = media.controls.texture { toolbarQuads.append((t, 5)) }
            } else if let t = media.grid.texture {
                toolbarQuads.append((t, 6))
            }
            if let hit {
                let at = panel.pane.centre + panel.pane.right * ((hit.uv.x - 0.5) * panel.pane.widthMeters) + panel.pane.up * ((0.5 - hit.uv.y) * panel.pane.heightMeters)
                overlay.addSquare(at - forward * 0.01, size: 0.012, eye: origin, color: HandOverlay.pinchColor)
            }
        }
        if let browser, let chrome, let keyboard {
            // The gaze on the panels, before the page: a panel under the gaze takes the select.
            let origin = headInWorld.columns.3.xyz
            let forward = -headInWorld.columns.2.xyz
            let eyeMid = origin
            var panelHit: (ScenePanel, SIMD2<Float>)?
            let showKeyboard = browser.keyboardShown || browser.fieldFocused || !browser.typed.isEmpty
            for panel in [chrome.panel] + (showKeyboard ? [keyboard.panel] : []) {
                if let hit = panel.pane.hit(origin: origin, direction: forward) { panelHit = (panel, hit.uv); break }
            }
            _ = chrome.panel.hover(panelHit?.0 === chrome.panel ? panelHit?.1 : nil)
            _ = keyboard.panel.hover(panelHit?.0 === keyboard.panel ? panelHit?.1 : nil)
            var pageSelect = select && !browser.isImmersive
            if select, !browser.isImmersive, let (panel, _) = panelHit, let id = panel.hovered {
                pageSelect = false
                pressPanel(panel, id: id)
            }
            if doubleTapPending && select { doubleTapPending = false }
            let gaze = browser.frame(head: headInWorld, hands: tracked, select: pageSelect || (select && browser.isImmersive), time: predictTo,
                                     deltaTime: Float(min(max(t2 - lastDrawTime, 0), 0.1)))
            if !browser.isImmersive {
                chrome.update(browser: browser)
                chrome.render(typing: !browser.typed.isEmpty)
                keyboard.render()
                layoutPanels()
                if let texture = browser.current?.texture { quads.append((nil, texture, SIMD4(1, 1, 1, 1), 0)) }
                if let texture = chrome.panel.texture { quads.append((nil, texture, SIMD4(1, 1, 1, 1), 1)) }
                if showKeyboard, let texture = keyboard.panel.texture { quads.append((nil, texture, SIMD4(1, 1, 1, 1), 2)) }
                // The reticle: a small ring where the gaze lands, on the page or a panel, else ahead.
                let reticleAt: SIMD3<Float>
                if let (panel, uv) = panelHit {
                    reticleAt = panel.pane.centre + panel.pane.right * ((uv.x - 0.5) * panel.pane.widthMeters) + panel.pane.up * ((0.5 - uv.y) * panel.pane.heightMeters)
                } else if let gaze {
                    reticleAt = gaze.point
                } else {
                    reticleAt = origin + forward * 1.3
                }
                let hot = panelHit != nil || gaze != nil
                overlay.addSquare(reticleAt - forward * 0.01, size: hot ? 0.012 : 0.008, eye: eyeMid, color: hot ? HandOverlay.pinchColor : SIMD4(1, 1, 1, 0.8))
            }
        }
        var quadBuffer: MTLBuffer?
        for (texture, slot) in toolbarQuads { quads.append((nil, texture, SIMD4(1, 1, 1, 1), slot)) }
        if !quads.isEmpty {
            // Five quads' vertices in one buffer: the window, the chrome, the keyboard, the toolbar, the menu.
            var vertices: [QuadVertex] = []
            vertices += browser?.window.quad ?? BrowserWindow().quad
            vertices += chrome?.panel.pane.quad ?? BrowserWindow().quad
            vertices += keyboard?.panel.pane.quad ?? BrowserWindow().quad
            vertices += toolbar?.panel.pane.quad ?? BrowserWindow().quad
            vertices += toolbar?.menu.pane.quad ?? BrowserWindow().quad
            vertices += media?.controls.pane.quad ?? BrowserWindow().quad
            vertices += media?.grid.pane.quad ?? BrowserWindow().quad
            vertices += media?.flatQuad() ?? BrowserWindow().quad
            while quadBuffers.count < 3 { quadBuffers.append(device.makeBuffer(length: 8192, options: .storageModeShared)!) }
            quadBufferIndex = (quadBufferIndex + 1) % quadBuffers.count
            let buffer = quadBuffers[quadBufferIndex]
            vertices.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            quadBuffer = buffer
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

        // Pass 1: the scene, both eyes at once (or one pass per eye without amplification). In an
        // immersive session the page has the screen, so the scene is skipped.
        let passes: [Int?] = (browser?.isImmersive ?? false) ? [] : (amplifies ? [nil] : [0, 1])
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
            } else if let media, media.isProjected, mediaTextures.picture != nil || mediaTextures.eyes != nil {
                encoder.setRenderPipelineState(mediaPipeline)
                encoder.setFragmentBytes(&mediaUniforms, length: MemoryLayout<MediaUniforms>.stride, index: 1)
                encoder.setFragmentTexture(mediaTextures.picture ?? mediaTextures.eyes, index: 0)
                encoder.setFragmentTexture(mediaTextures.eyes ?? eyeTexture, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            } else {
                encoder.setRenderPipelineState(skyPipeline)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.setRenderPipelineState(floorPipeline)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            if let quadBuffer {
                encoder.setRenderPipelineState(quadPipeline)
                encoder.setVertexBuffer(quadBuffer, offset: 0, index: 1)
                for (_, texture, tint, slot) in quads {
                    var tint = tint
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
                    encoder.drawPrimitives(type: .triangle, vertexStart: slot * 6, vertexCount: 6)
                }
                if let media, media.screen == .viewing, !media.isProjected, mediaTextures.picture != nil || mediaTextures.eyes != nil {
                    encoder.setRenderPipelineState(mediaQuadPipeline)
                    encoder.setFragmentBytes(&mediaUniforms, length: MemoryLayout<MediaUniforms>.stride, index: 1)
                    encoder.setFragmentTexture(mediaTextures.picture ?? mediaTextures.eyes, index: 0)
                    encoder.setFragmentTexture(mediaTextures.eyes ?? eyeTexture, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 7 * 6, vertexCount: 6)
                }
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
        runActions(now: t2)
        if dumpNext && !dumped {
            dumpNext = false
            dumped = true
            dumpEye(0, from: eyeTexture, in: commandBuffer)
            dumpEye(1, from: eyeTexture, in: commandBuffer)
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
            log(String(format: "[Pose] %dDoF: head (%.2f, %.2f, %.2f), predicted %.0f ms ahead of the camera image (display %.0f ms + presented %.1f ms after target + %d ms), camera frame age %.0f ms",
                       source.degreesOfFreedom, p.x, p.y, p.z, horizonMs, (targetTimestamp - timestamp) * 1000, measuredLag, settings.extraPredictionMs,
                       frame.map { (t2 - $0.pose.timestamp) * 1000 } ?? 0))
        }
    }
}

extension Renderer {
    /// A press on a panel's button.
    fileprivate func pressPanel(_ panel: ScenePanel, id: String) {
        guard let browser else { return }
        if let keyboard, panel === keyboard.panel {
            switch keyboard.press(id) {
            case .text(let t): browser.type(t)
            case .key(let k): browser.key(k)
            case .mic: onDictate?()
            case .none: break
            }
            return
        }
        switch id {
        case "new": browser.newTab(private: false, url: nil)
        case "private": browser.newTab(private: true, url: nil)
        case "back": browser.back()
        case "forward": browser.forward()
        case "reload": browser.reload()
        case "home": browser.home()
        case "star": browser.toggleBookmark()
        case "size": browser.cycleSize(); layoutPanels()
        case "place": browser.togglePlacing()
        case "keys": browser.toggleKeyboard()
        case "mic": onDictate?()
        case "close": browser.closeTab()
        case "yes": browser.answerPrompt(yes: true)
        case "no": browser.answerPrompt(yes: false)
        default:
            if id.hasPrefix("tab:"), let i = Int(id.dropFirst(4)) { browser.switchTab(i) }
        }
    }

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
