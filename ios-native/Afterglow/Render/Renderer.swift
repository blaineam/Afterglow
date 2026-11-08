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
    private var depthPassthroughPipeline: MTLRenderPipelineState!
    private var distortionPipeline: MTLRenderPipelineState!
    private var overlayPipeline: MTLRenderPipelineState!
    private var quadPipeline: MTLRenderPipelineState!
    private var mediaPipeline: MTLRenderPipelineState!
    private var mediaQuadPipeline: MTLRenderPipelineState!
    private var surfacePipeline: MTLRenderPipelineState!
    private var occlusionPipeline: MTLRenderPipelineState!
    private var overlayDepthPipeline: MTLRenderPipelineState!
    private var meshPipeline: MTLRenderPipelineState!
    private var meshBlendPipeline: MTLRenderPipelineState!
    private var glowPipeline: MTLRenderPipelineState!
    private var depthTestNoWriteState: MTLDepthStencilState!
    private var scene3D = Scene3D()
    private var glowBuffers: [MTLBuffer] = []
    private var glowBufferIndex = 0
    private var depthTexture: MTLTexture?
    private var depthTestState: MTLDepthStencilState!
    private var depthWriteState: MTLDepthStencilState!
    private var depthNoneState: MTLDepthStencilState!
    private var surfaceBuffers: [MTLBuffer] = []
    private var surfaceBufferIndex = 0
    private(set) var media: MediaApp?
    private(set) var places: PlacesApp?
    private var blitPipeline: MTLRenderPipelineState!
    private(set) var recorder: EyeRecorder?
    private(set) var games: GameHost?
    private let controllers = Controllers()
    private let watch = WatchReceiver()
    private(set) var windows: WindowManager?
    private var home: HomeMenu?
    private var settingsWindow: SettingsWindow?
    private var music: MusicApp?
    private(set) var lock: AppLock?
    private var pinchHeldFrames = 0
    private var promptingForPlace = false
    private var placePrompt = ""
    private var gridColor = SIMD4<Float>(0, 0, 0, 0)
    private var floorScroll: Float = 0
    /// A synthetic hand for the Simulator (`fakehand` in the test script).
    private var fakeHand: (pinched: Bool, punchUntil: Double)?
    private var castEye = 0
    private var surfaceDrawLogged = false
    private var environment = PlacesApp.Choice.synthwave
    private var panoramaKeep: MTLTexture?
    private var nightAmount: Float = 0
    private var overlayUnoccludedStart = 0
    private var surfacesAppear: Float = 0
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
    private var homeOpened = false
    private var wasImmersive = false
    /// The running game, by identity: a different game is a change as much as a start or a stop.
    private var lastGameID: ObjectIdentifier?
    /// When to re-hang the windows after a 6DoF/3DoF switch.
    private var recentreAfterSwitch: Double?
    private var summaryShown = false
    private var dofBeforeGame: Int?
    private var lastDrawnFrameTime: Double = 0
    private var drawnFrames = 0
    private var immersiveSince: Double = 0
    private var dofBeforeSession: Int?
    private var handHzBeforeSession: Int?
    private var rideTransform = matrix_identity_float4x4
    /// Phone view: a tap this frame at a point on the screen (0-1 across and down), which is
    /// where the pointer goes for the frame; the pointer otherwise sits at the screen's centre.
    private var tapPoint: SIMD2<Float>?
    private var pendingTapPoint: SIMD2<Float>?
    private var phoneFov: SIMD2<Float> = SIMD2(1, 1)   // tan of the half angles, x and y
    private(set) var hasTracking = false
    private var eyeTexturePhone = false
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
        controllers.start()
        watch.onSelect = { [weak self] in self?.tapRequests.value = 2 }
        watch.onScroll = { [weak self] dy in Task { @MainActor in self?.browser?.scroll(dy: dy) } }
        watch.start()
        let windows = WindowManager(device: device)
        windows.onClose = { [weak self] kind in self?.windowClosed(kind) }
        self.windows = windows
        let home = HomeMenu(device: device)
        // The app takes Home's place: Home closes first, so the window lands where it was.
        home.onLaunch = { [weak self] kind in self?.windows?.close(.home); self?.launch(kind) }
        home.onLock = { [weak self] in self?.lock?.lock(reason: "the menu") }
        self.home = home
        let lock = AppLock(device: device)
        self.lock = lock
        let settingsWindow = SettingsWindow(device: device, settings: settings)
        settingsWindow.hasPasscode = { [weak self] in self?.lock?.isSet ?? false }
        settingsWindow.onSetPasscode = { [weak self] in self?.lock?.beginSettingNew() }
        settingsWindow.onRemovePasscode = { [weak self] in self?.lock?.removePasscode() }
        self.settingsWindow = settingsWindow
        wireSource()
        let toolbar = Toolbar(device: device, settings: settings)
        toolbar.onLaunch = { [weak self] app in self?.launch(app) }
        toolbar.onMore = { [weak self] in self?.launch(WindowKind.home) }
        toolbar.onRestore = { [weak self] kind in self?.launch(kind) }
        toolbar.onMusic = { [weak self] action in
            guard let self else { return }
            if self.music == nil { self.music = MusicApp(device: self.device) }
            switch action { case "prev": self.music?.press("prevTrack"); case "next": self.music?.press("nextTrack"); default: self.music?.press("play") }
        }
        toolbar.onRecentre = { [weak self] in self?.recentre() }
        toolbar.onCloseApp = { [weak self] in self?.closeApp() }
        toolbar.onRecord = { [weak self] eye in self?.toggleRecording(eye: eye) }
        toolbar.isRecording = { [weak self] in self?.isRecording ?? false }
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

    /// Opens an app as a window (several can be open at once).
    func launch(_ kind: WindowKind) {
        guard let windows else { return }
        let aspect: Float
        switch kind {
        case .browser: aspect = 1280.0 / 800.0
        case .media, .files: aspect = 1.6
        case .games: aspect = 1600.0 / 560.0
        case .gameControls: aspect = 1600.0 / 300.0
        case .places: aspect = 1600.0 / 900.0
        case .settings: aspect = 1.4
        case .music: aspect = 1400.0 / 760.0
        case .home: aspect = 1600.0 / 900.0
        }
        // Music is a small remote, not a wall (owner, 2026-11-08: still giant).
        let window = windows.open(kind, head: lastHead, aspect: aspect, width: kind == .music ? 1.0 : nil)
        switch kind {
        case .browser:
            toolbar?.noteOpened(.browser)
            settings.browserOpen = true
            if browser == nil { openBrowser() }
            browser?.window = window.pane
            // The window's bar sits above the browser's own chrome.
            window.barGap = (chrome?.panel.pane.heightMeters ?? 0.23) + 0.03
        case .media, .files:
            toolbar?.noteOpened(kind == .media ? .media : .files)
            if media == nil || (media?.isFiles ?? false) != (kind == .files) {
                media?.close()
                let m = MediaApp(device: device)
                m.onPickFolder = { [weak self] in
                    guard let self, let root = self.uiWindow?.rootViewController, let files = self.media?.files else { return }
                    files.pickFolder(from: root)
                }
                if kind == .files { m.openFiles(head: lastHead) } else { m.open(head: lastHead) }
                media = m
            }
        case .games:
            toolbar?.noteOpened(.games)
            if games == nil {
                let g = GameHost(device: device)
                g.open(head: lastHead)
                if let ride = g.games.compactMap({ $0 as? GridRide }).first {
                    ride.onNextWorld = { [weak self] in
                        guard let self else { return }
                        if self.places == nil { self.launch(WindowKind.places); self.windows?.minimize(.places) }
                        self.places?.nextWorld()
                    }
                }
                if let portal = g.games.compactMap({ $0 as? PortalGame }).first {
                    // Through the gate is another place (a photosphere); back through is the room
                    // (owner, 2026-11-08: a colour change alone was lacklustre).
                    portal.onWorldChange = { [weak self] world in
                        guard let self else { return }
                        if world == 0 {
                            if let places = self.places { places.chooseRoom() } else { self.environment = .room; self.settings.passthrough = true }
                        } else {
                            if self.places == nil { self.launch(WindowKind.places); self.windows?.minimize(.places) }
                            self.places?.showWorld(world)
                        }
                    }
                }
                g.music = music
                games = g
            }
        case .places:
            toolbar?.noteOpened(.environments)
            if places == nil {
                let p = PlacesApp(device: device)
                p.open(head: lastHead)
                p.onChoice = { [weak self] choice in
                    self?.environment = choice
                    self?.settings.passthrough = (choice == .room)
                    if case .room = choice { self?.settings.surfaces = true }
                }
                p.onWantPrompt = { [weak self] in self?.promptingForPlace = true; self?.placePrompt = "" }
                places = p
            }
        case .music:
            if music == nil { music = MusicApp(device: device) }
            games?.music = music
        case .settings, .home, .gameControls:
            break
        }
        log("[Home] Opened \(kind.rawValue)")
    }

    private func windowClosed(_ kind: WindowKind) {
        switch kind {
        case .browser: settings.browserOpen = false; closeBrowser()
        case .media, .files: media?.close(); media = nil
        case .games: games = nil; gridColor = SIMD4(0, 0, 0, 0)
        case .places: places = nil
        case .music: music = nil
        case .settings, .home: break
        case .gameControls: games?.press("stop")   // closing a game's controls ends the game
        }
    }

    func launch(_ app: AppKind) {
        switch app {
        case .browser: launch(WindowKind.browser)
        case .media: launch(WindowKind.media)
        case .files: launch(WindowKind.files)
        case .games: launch(WindowKind.games)
        case .environments: launch(WindowKind.places)
        case .settings: launch(WindowKind.settings)
        }
        }

    var isPromptingForPlace: Bool { promptingForPlace }
    func endPlacePrompt() { promptingForPlace = false }
    func appBackgrounded() { lock?.backgrounded() }
    func appForegrounded() { lock?.foregrounded() }

    func closeApp() {
        if let last = windows?.visible.last { windows?.close(last.kind) }
    }

    /// Re-hangs the window and the toolbar where the head looks now.
    func recentre() {
        browser?.window.place(ahead: lastHead)
        toolbar?.place(ahead: lastHead)
        layoutPanels()
        log("[Home] Recentred")
    }

    /// Starts or stops recording one eye to a movie in Documents/Recordings.
    func toggleRecording(eye: Int) {
        if let recorder, recorder.isRecording {
            recorder.stop(saveToPhotos: true)
            return
        }
        guard let eyeTexture else { return }
        let recorder = EyeRecorder(device: device)
        recorder.start(eye: eye, width: eyeTexture.width, height: eyeTexture.height, frameRate: settings.targetFrameRate)
        self.recorder = recorder
    }

    var isRecording: Bool { recorder?.isRecording ?? false }

    /// A tap on the screen (desk mode, or the viewer's button): a select.
    func screenTapped() { tapRequests.value = 2 }
    /// A tap at a point on the screen (0-1 across and down): the phone view's select.
    func screenTapped(at point: SIMD2<Float>) { pendingTapPoint = point; tapRequests.value = 2 }
    /// Text from the system keyboard (the phone view's double tap) goes where dictation does.
    func typed(_ text: String) {
        if places != nil, promptingForPlace { placePrompt += text; return }
        if let media, media.isFiles { media.type(text) } else { browser?.type(text) }
    }
    func typedKey(_ key: String) {
        if places != nil, promptingForPlace {
            if key == "Backspace", !placePrompt.isEmpty { placePrompt.removeLast() }
            if key == "Enter" { promptingForPlace = false; places?.generate(prompt: placePrompt) }
            return
        }
        if let media, media.isFiles { media.key(key) } else { browser?.key(key) }
    }
    /// A drag on the screen: the desk look without tracking; with it, a scroll of the page or a
    /// swipe between the media viewer's items.
    func panned(dx: Float, dy: Float, ended: Bool, totalDx: Float) {
        if !hasTracking { deskLook(yawDelta: -dx * 0.004, pitchDelta: -dy * 0.004); return }
        if let media, media.screen == .viewing {
            if ended, abs(totalDx) > 80 { media.press(totalDx < 0 ? "nextItem" : "prevItem") }
        } else if let media, windows?.window(.media)?.minimized == false || windows?.window(.files)?.minimized == false {
            media.scrollBy(pixels: dy)
        } else {
            browser?.scroll(dy: -dy * 2)
        }
    }
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
            else if let places, places.panel.buttons.contains(where: { $0.id == argument }) { if places.press(argument) { settings.surfaces.toggle() } }
            else if let games, games.panel.buttons.contains(where: { $0.id == argument }) || games.controlsPanel.buttons.contains(where: { $0.id == argument })
                        || games.summaryPanel.buttons.contains(where: { $0.id == argument }) { games.press(argument) }
            else if let home, windows?.window(.home)?.minimized == false, home.panel.buttons.contains(where: { $0.id == argument }) { if home.press(argument) { windows?.close(.home) } }
            else if let settingsWindow, windows?.window(.settings)?.minimized == false, settingsWindow.panel.buttons.contains(where: { $0.id == argument }) { settingsWindow.press(argument) }
            else if let music, music.panel.buttons.contains(where: { $0.id == argument }) { music.press(argument) }
            else if let lock, lock.locked, lock.panel.buttons.contains(where: { $0.id == argument }) { lock.press(argument) }
            else if argument.hasPrefix("win:"), let windows {
                // win:<kind>:<button>
                let parts = argument.split(separator: ":").map(String.init)
                if parts.count == 3, let kind = WindowKind(rawValue: parts[1]), let w = windows.window(kind) { windows.press(w, id: parts[2]) }
                else { toolbar?.press(argument) }   // win:<kind> is a dock tray chip
            }
            else if let toolbar { log("[Actions] press \(argument): no panel has it; the dock (summary has \(games?.summaryPanel.buttons.map(\.id) ?? []))"); toolbar.press(argument) }
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
        case "record": toggleRecording(eye: Int(argument) ?? 0)
        case "fakehand":
            if argument == "off" { fakeHand = nil }
            else if argument == "punch" { fakeHand = (fakeHand?.pinched ?? false, now + 0.2) }
            else { fakeHand = (argument == "1", 0) }
        case "open": if let kind = WindowKind(rawValue: argument) { launch(kind) }
        case "dock": toolbar?.place(ahead: lastHead); toolbar?.showDock(time: CACurrentMediaTime())
        case "lock": lock?.lock(reason: "the script")
        case "place": places?.choose(named: argument)
        case "fakeplanes": (source as? ARController)?.room.addFake(floorY: floorHeight); settings.surfaces = true
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

    /// The predictor's callbacks (the lock's motion, the viewer's taps): set on whichever source
    /// is current, since a 6DoF/3DoF switch makes a new predictor (taps were lost in 3DoF, so a
    /// WebXR session could not be ended, 2026-11-07).
    private func wireSource() {
        source.predictor.onMotion = { [weak self] gravity, rate, time in
            Task { @MainActor in self?.lock?.motion(gravity: gravity, rotationRate: rate, time: time) }
        }
    }

    /// Starts the source; also swaps it when the setting changed (the strip's switch).
    func startSource() {
        if sourceDof != settings.degreesOfFreedom {
            source.stop()
            let hands = source.hands
            source = Self.makeSource(dof: settings.degreesOfFreedom, device: device, hands: hands, settings: settings)
            sourceDof = settings.degreesOfFreedom
            log("[Pose] Switched to \(sourceDof)DoF (\(source.cameraName) camera)")
            wireSource()
            // The new tracker has its own frame: once its first poses are in, the windows and
            // any WebXR session are hung again round the way the head faces.
            recentreAfterSwitch = CACurrentMediaTime() + 0.6
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
        func scene(_ vertex: String, _ fragment: String, blend: Bool = false, depthOnly: Bool = false, additive: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.depthAttachmentPixelFormat = .depth32Float
            if depthOnly { d.colorAttachments[0].writeMask = [] }
            if blend {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .one
                d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                d.colorAttachments[0].sourceAlphaBlendFactor = .one
                d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            if additive {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .one
                d.colorAttachments[0].destinationRGBBlendFactor = .one
                d.colorAttachments[0].sourceAlphaBlendFactor = .zero
                d.colorAttachments[0].destinationAlphaBlendFactor = .one
            }
            if amplifies { d.maxVertexAmplificationCount = 2 }
            // Writing render_target_array_index needs the topology stated up front.
            d.inputPrimitiveTopology = .triangle
            d.label = fragment
            return try device.makeRenderPipelineState(descriptor: d)
        }
        skyPipeline = try scene("fullscreenVertex", "skyFragment")
        floorPipeline = try scene("floorVertex", "floorFragment")
        passthroughPipeline = try scene("fullscreenVertex", "passthroughFragment")
        depthPassthroughPipeline = try scene("depthPassthroughVertex", "depthPassthroughFragment")
        overlayPipeline = try scene("overlayVertex", "overlayFragment")
        quadPipeline = try scene("quadVertex", "quadFragment", blend: true)
        mediaPipeline = try scene("fullscreenVertex", "mediaFragment")
        mediaQuadPipeline = try scene("quadVertex", "mediaQuadFragment")
        surfacePipeline = try scene("surfaceVertex", "surfaceFragment", blend: true)
        occlusionPipeline = try scene("fullscreenVertex", "occlusionFragment", depthOnly: true)
        overlayDepthPipeline = try scene("overlayVertex", "overlayFragment")
        meshPipeline = try scene("meshVertex", "meshFragment")
        meshBlendPipeline = try scene("meshVertex", "meshFragment", blend: true)
        glowPipeline = try scene("overlayVertex", "glowFragment", additive: true)
        let b = MTLRenderPipelineDescriptor()
        b.vertexFunction = library.makeFunction(name: "blitVertex")
        b.fragmentFunction = library.makeFunction(name: "blitFragment")
        b.colorAttachments[0].pixelFormat = .bgra8Unorm
        b.label = "blit"
        blitPipeline = try device.makeRenderPipelineState(descriptor: b)
        let test = MTLDepthStencilDescriptor()
        test.depthCompareFunction = .lessEqual
        test.isDepthWriteEnabled = true
        depthTestState = device.makeDepthStencilState(descriptor: test)
        let write = MTLDepthStencilDescriptor()
        write.depthCompareFunction = .always
        write.isDepthWriteEnabled = true
        depthWriteState = device.makeDepthStencilState(descriptor: write)
        let none = MTLDepthStencilDescriptor()
        none.depthCompareFunction = .always
        none.isDepthWriteEnabled = false
        depthNoneState = device.makeDepthStencilState(descriptor: none)
        let testOnly = MTLDepthStencilDescriptor()
        testOnly.depthCompareFunction = .lessEqual
        testOnly.isDepthWriteEnabled = false
        depthTestNoWriteState = device.makeDepthStencilState(descriptor: testOnly)

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
        let phone = settings.phoneView
        if eyeTexture != nil && eyeTextureScale == scale && eyeTexturePhone == phone { return }
        eyeTexturePhone = phone
        // The phone view draws the whole screen from one eye; the viewer half of it per eye.
        let width = max(16, Int((Float(screen.pixelWidth) * (phone ? 1 : 0.5) * scale).rounded()))
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
        let dd = MTLTextureDescriptor()
        dd.textureType = .type2DArray
        dd.arrayLength = 2
        dd.pixelFormat = .depth32Float
        dd.width = width
        dd.height = height
        dd.usage = .renderTarget
        dd.storageMode = amplifies ? .memoryless : .private
        depthTexture = device.makeTexture(descriptor: dd)
        depthTexture?.label = "eye depth"
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
        // The coaster carries the rider: its car's pose moves the camera through the world.
        cameraInWorld = rideTransform * cameraInWorld
        let frameDt = Float(min(max(t2 - lastDrawTime, 0), 0.1))
        let step = frameDt / 0.5
        lastDrawTime = t2
        // Passthrough for this frame: the setting, except on the coaster, which is a ride through
        // the scene and makes no sense over the room (owner, 2026-11-07).
        let passthroughNow = settings.passthrough && !((games?.current as? GridRide)?.riding ?? false)
        let target: Float = passthroughNow ? 1 : 0
        eyesAtCamera += min(max(target - eyesAtCamera, -step), step)
        let headInWorld = cameraInWorld * simd_float4x4.translation(cameraToEyes * (1 - eyesAtCamera))

        var uniforms = FrameUniforms()
        let phone = settings.phoneView
        hasTracking = source.predictedCameraTransform(at: predictTo) != nil
        for eye in Eye.allCases {
            // The phone view: one eye at the camera, a symmetric frustum the screen's shape, 58
            // degrees tall (the wide camera's, so passthrough fills it at its true scale).
            let eyeInWorld = phone ? headInWorld : headInWorld * simd_float4x4.translation(lens.eyeOffset(eye))
            let projection: simd_float4x4
            if phone {
                let tanV = tan(Float(29) * .pi / 180)
                let tanH = tanV * Float(eyeTexture.width) / Float(eyeTexture.height)
                phoneFov = SIMD2(tanH, tanV)
                projection = LensDistortion.frustum(left: -tanH * 0.05, right: tanH * 0.05, bottom: -tanV * 0.05, top: tanV * 0.05, near: 0.05, far: 500)
            } else {
                projection = lens.projectionMatrix(eye, near: 0.05, far: 500)
            }
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
            uniforms.worldFromCapture = frame.pose.transform
            let k = frame.intrinsics
            uniforms.captureIntrinsics = SIMD4(k.columns.0.x / Float(frame.imageWidth), k.columns.1.y / Float(frame.imageHeight),
                                               k.columns.2.x / Float(frame.imageWidth), k.columns.2.y / Float(frame.imageHeight))
            uniforms.captureVideoRange = frame.videoRange ? 1 : 0
        }
        uniforms.time = Float(t2 - launchTime)
        uniforms.floorHeight = (source as? ARController)?.room.floorHeight ?? floorHeight
        uniforms.gridColor = gridColor
        uniforms.floorScroll = floorScroll
        if case .place(let kind) = environment { uniforms.environment = Int32(kind) } else { uniforms.environment = 0 }
        nightAmount += ((places?.night ?? false) ? 1 : -1) * frameDt / 2
        nightAmount = min(max(nightAmount, 0), 1)
        uniforms.night = nightAmount
        uniforms.passthroughBlend = passthroughNow ? 1 : 0

        lastHead = headInWorld
        // A WebXR session runs on the ultra-wide camera in 3DoF (its wider view makes the hands
        // easier to use, owner 2026-11-07); the mode comes back when the session ends.
        let immersiveNow = browser?.isImmersive ?? false
        if immersiveNow != wasImmersive {
            wasImmersive = immersiveNow
            if immersiveNow {
                immersiveSince = t2
                source.hands?.pinchStartResults = 4
                dofBeforeSession = settings.degreesOfFreedom
                handHzBeforeSession = settings.handHzLive
                // More hand images a second while a page's pointer rides on them.
                settings.handHzLive = min(settings.handHzLive, 20)
            } else {
                if t2 - immersiveSince < 3 { log(String(format: "[WebXR] The session ended %.1f s after it began: the page's doing; see the Session ended line for its reason", t2 - immersiveSince)) }
                if let before = dofBeforeSession, before != settings.degreesOfFreedom { settings.degreesOfFreedom = before; log("[WebXR] Back to \(before)DoF") }
                if let hz = handHzBeforeSession { settings.handHzLive = hz }
                source.hands?.pinchStartResults = 3
                dofBeforeSession = nil
            }
        }
        // The switch to the ultra-wide 3DoF camera waits two seconds, so a session that is still
        // settling is not disturbed by the camera changing under it.
        if immersiveNow, dofBeforeSession != nil, settings.degreesOfFreedom != 3, t2 - immersiveSince > 2 {
            settings.degreesOfFreedom = 3
            log("[WebXR] 3DoF ultra-wide for the session")
        }
        // The pointer: the gaze, or in the phone view the point tapped this frame.
        tapPoint = pendingTapPoint
        pendingTapPoint = nil
        var pointerHead = headInWorld
        // The phone view's cursor sits at the screen's centre and a tap selects what it is on
        // (owner, 2026-11-07: easier to steer than tapping the element); `tapAtPoint` keeps the
        // older behaviour for a script.
        if phone, settings.tapAtPoint, let tap = tapPoint {
            let local = simd_normalize(SIMD3((tap.x * 2 - 1) * phoneFov.x, (1 - tap.y * 2) * phoneFov.y, -1))
            let worldDir = simd_normalize((headInWorld * SIMD4(local, 0)).xyz)
            let up = headInWorld.columns.1.xyz
            let right = simd_normalize(simd_cross(worldDir, up))
            let trueUp = simd_cross(right, worldDir)
            pointerHead.columns.0 = SIMD4(right, 0)
            pointerHead.columns.1 = SIMD4(trueUp, 0)
            pointerHead.columns.2 = SIMD4(-worldDir, 0)
        }
        let pointerOrigin = pointerHead.columns.3.xyz
        let pointerDirection = -pointerHead.columns.2.xyz
        // Home opens on its own a second in, over the surroundings: the launcher is the first thing seen.
        if !homeOpened, t2 - launchTime > 1, uiWindow != nil, lock?.locked != true { homeOpened = true; launch(WindowKind.home) }
        if settings.browserOpen && browser == nil && uiWindow != nil && windows?.window(.browser) == nil { launch(WindowKind.browser) }
        if !settings.browserOpen && browser != nil { windows?.close(.browser) }

        // The hands as of this frame, and the grab demo they drive.
        overlay.clear()
        var toolbarQuads: [(MTLTexture, Int)] = []
        var tracked: [TrackedHandState] = []
        if let hands = source.hands {
            tracked = hands.hands(at: predictTo)
            hands.hertz = settings.handHzLive
        }
        // The lock: while locked only the keypad draws and takes the gaze.
        var lockedNow = false
        if let lock, lock.locked {
            lockedNow = true
            if lock.panel.pane.centre == .zero || simd_distance(lock.panel.pane.centre, headInWorld.columns.3.xyz) > 3 {
                lock.panel.pane.place(ahead: headInWorld, distance: 1.0)
            }
            let origin = pointerOrigin
            let forward = pointerDirection
            let hit = lock.panel.pane.hit(origin: origin, direction: forward)
            _ = lock.panel.hover(hit?.uv)
            lock.render()
        }
        if let fake = fakeHand {
            // A flat hand 0.4 m ahead and a little right and down, punched forward when asked.
            let forward = -headInWorld.columns.2.xyz
            let right = headInWorld.columns.0.xyz
            let punch: Float = t2 < fake.punchUntil ? Float((fake.punchUntil - t2) / 0.2) * 0.4 : 0
            let origin = headInWorld.columns.3.xyz + forward * (0.4 + punch) + right * 0.15 - SIMD3(0, 0.12, 0)
            var joints = [SIMD3<Float>](repeating: origin, count: HandGeometry.jointCount)
            for (i, j) in joints.enumerated() { _ = j; joints[i] = origin + right * Float(i % 5) * 0.015 + forward * Float(i / 5) * 0.02 }
            let tips = fake.pinched ? origin + forward * 0.08 : origin + forward * 0.09
            joints[HandGeometry.thumbTip] = tips - right * (fake.pinched ? 0.005 : 0.05)
            joints[HandGeometry.indexTip] = tips + right * 0.005
            tracked.append(TrackedHandState(joints: joints, pinched: fake.pinched, pinchPoint: tips, handedness: 1, confidence: 1, distance: 0.4))
        }
        // Selects this frame: a pinch beginning, a screen tap, or a double tap on the viewer.
        var pinchNow = [false, false]
        for hand in tracked { pinchNow[hand.isRight ? 1 : 0] = pinchNow[hand.isRight ? 1 : 0] || hand.pinched }
        var select = (0..<2).contains { pinchNow[$0] && !pinchWas[$0] }
        pinchWas = pinchNow
        // A controller: A selects, B closes a menu or app, the left stick scrolls or looks, the
        // right stick looks in desk mode.
        let pad = controllers.take()
        if pad.select { select = true }
        if pad.menu { toolbar?.press("more") }
        if pad.back { if toolbar?.menuOpen == true { toolbar?.press("closemenu") } else { closeApp() } }
        if source.predictedCameraTransform(at: predictTo) == nil, simd_length(pad.rightStick) > 0.1 {
            deskLook(yawDelta: -pad.rightStick.x * frameDt * 2, pitchDelta: pad.rightStick.y * frameDt * 2)
        }
        if let browser, !browser.isImmersive, abs(pad.stick.y) > 0.15 {
            browser.scroll(dy: -pad.stick.y * 900 * frameDt)
        }
        let tap = tapRequests.value
        if tap != 0 {
            tapRequests.value = 0
            // Kind 1 is the first tap of a pair (the target is sampled now), kind 2 the second: a
            // double tap, which ends a WebXR session or the coaster and otherwise selects. The
            // exits sat under kind 1 by mistake, so a single tap ended things and a double never
            // reached them (owner, 2026-11-07).
            if tap == 2, browser?.isImmersive == true { browser?.endSession(); log("[WebXR] Session ended by the viewer's double tap") }
            else if tap == 2, games?.current is GridRide { games?.press("stop"); log("[Games] Coaster stopped by the viewer's double tap") }
            else if tap == 1 {
                doubleTapPending = true
                doubleTapTarget = browser?.window.gaze(from: pointerHead)?.uv
            } else {
                select = true
            }
        }
        if lockedNow, let lock {
            if select, lock.panel.pane.hit(origin: pointerOrigin, direction: pointerDirection) != nil, let id = lock.panel.hovered {
                lock.press(id)
            }
            select = false
        }
        if let at = recentreAfterSwitch, t2 >= at {
            recentreAfterSwitch = nil
            windows?.rearrange(head: headInWorld)
            browser?.recentreSession()
            toolbar?.place(ahead: headInWorld)
            if let games, games.current?.summary != nil { games.placeSummary(head: headInWorld) }
        }
        // The windows: title bars, drags, sizes; the app panes follow their windows.
        var pinchHeld = tracked.contains { $0.pinched }
        if fakeHand?.pinched == true { pinchHeld = true }
        let ridingNow = (games?.current as? GridRide)?.riding ?? false
        if let windows, !lockedNow, !ridingNow {
            let result = windows.frame(head: pointerHead, select: select, pinchHeld: pinchHeld, time: t2)
            if result.consumed { select = false }
            for w in windows.visible {
                switch w.kind {
                case .browser:
                    if let browser { browser.window = w.pane; browser.setTextScale(settings.textScaleLive) }
                    // The bar sits above the chrome, whose height follows the window's width.
                    if let chrome { w.barGap = chrome.panel.pane.heightMeters + 0.03 }
                case .media, .files:
                    if let media {
                        media.grid.pane.centre = w.pane.centre; media.grid.pane.right = w.pane.right; media.grid.pane.up = w.pane.up; media.grid.pane.widthMeters = w.pane.widthMeters
                        media.window = w.pane
                        media.controls.pane.right = w.pane.right; media.controls.pane.up = w.pane.up
                        media.controls.pane.centre = w.pane.centre - w.pane.up * (w.pane.heightMeters / 2 + 0.1)
                        media.controls.pane.widthMeters = w.pane.widthMeters
                    }
                case .games:
                    if let games { games.panel.pane.centre = w.pane.centre; games.panel.pane.right = w.pane.right; games.panel.pane.up = w.pane.up; games.panel.pane.widthMeters = w.pane.widthMeters }
                case .gameControls:
                    if let games { games.controlsPanel.pane = w.pane }
                case .places:
                    if let places { places.panel.pane.centre = w.pane.centre; places.panel.pane.right = w.pane.right; places.panel.pane.up = w.pane.up; places.panel.pane.widthMeters = w.pane.widthMeters }
                case .settings:
                    if let settingsWindow { settingsWindow.panel.pane = w.pane }
                case .music:
                    if let music { music.panel.pane = w.pane }
                case .home:
                    if let home { home.panel.pane = w.pane }
                }
                // A media viewer with its controls hidden hides its bar too.
                let barHidden = (w.kind == .media || w.kind == .files) && (media?.controlsHidden ?? false) && media?.screen == .viewing
                if !barHidden, let t = w.titleBar.texture { toolbarQuads.append((t, 8 + windows.visible.firstIndex { $0 === w }!)) }
            }
            // The home menu, the settings and music windows: panels with buttons.
            let origin = pointerOrigin
            let forward = pointerDirection
            if windows.window(.home)?.minimized == false, let home {
                home.layout(open: windows.windows.map(\.kind))
                let hit = home.panel.pane.hit(origin: origin, direction: forward)
                _ = home.panel.hover(hit?.uv)
                if select, hit != nil, let id = home.panel.hovered { if home.press(id) { windows.close(.home) }; select = false }
                home.render()
                if let t = home.panel.texture { toolbarQuads.append((t, 20)) }
            }
            if windows.window(.settings)?.minimized == false, let settingsWindow {
                let hit = settingsWindow.panel.pane.hit(origin: origin, direction: forward)
                _ = settingsWindow.panel.hover(hit?.uv)
                if select, hit != nil, let id = settingsWindow.panel.hovered { settingsWindow.press(id); select = false }
                settingsWindow.layout()
                settingsWindow.render()
                if let t = settingsWindow.panel.texture { toolbarQuads.append((t, 21)) }
            }
            if windows.window(.music)?.minimized == false, let music {
                let hit = music.panel.pane.hit(origin: origin, direction: forward)
                _ = music.panel.hover(hit?.uv)
                if select, hit != nil, let id = music.panel.hovered { music.press(id); select = false }
                music.render()
                if let t = music.panel.texture { toolbarQuads.append((t, 22)) }
            }
            // A prompt for a generated place: the keyboard types it, Go sends it.
            if promptingForPlace, let keyboard, let places {
                keyboard.panel.pane = places.panel.pane
                keyboard.panel.pane.centre = places.panel.pane.centre - places.panel.pane.up * (places.panel.pane.heightMeters / 2 + keyboard.panel.pane.heightMeters * 0.5)
                let hit = keyboard.panel.pane.hit(origin: origin, direction: forward)
                _ = keyboard.panel.hover(hit?.uv)
                if select, hit != nil, let id = keyboard.panel.hovered {
                    switch keyboard.press(id) {
                    case .text(let t): placePrompt += t
                    case .key("Backspace"): if !placePrompt.isEmpty { placePrompt.removeLast() }
                    case .key("Clear"): placePrompt = ""
                    case .key("Enter"): promptingForPlace = false; places.generate(prompt: placePrompt)
                    case .mic: onDictate?()
                    default: break
                    }
                    select = false
                }
                keyboard.render()
                if let t = keyboard.panel.texture { toolbarQuads.append((t, 2)) }
            }
        }
        // The grab demo's cubes are a launch option (`demo 1`), not part of the interface.
        if settings.demo && browser == nil && games == nil && !lockedNow {
            grabDemo.update(hands: tracked, time: predictTo)
            grabDemo.draw(into: &overlay)
        }
        if let games, !lockedNow {
            let origin = pointerOrigin
            let forward = pointerDirection
            let hit = windows?.window(.games)?.minimized == false ? games.panel.pane.hit(origin: origin, direction: forward) : nil
            _ = games.panel.hover(hit?.uv)
            var gameSelect = select
            if select, hit != nil, let id = games.panel.hovered {
                games.press(id)
                select = false
                gameSelect = false
            }
            // A game's start minimizes the launcher and opens the game's own controls; its stop
            // brings the launcher back (owner, 2026-11-07: the game, not the menu, until they exit).
            if games.currentID != lastGameID {
                lastGameID = games.currentID
                summaryShown = false
                if games.current != nil {
                    // Hands and a body in the room need the head's position: 6DoF while a game runs
                    // (the coaster is the one that does without).
                    if !(games.current is GridRide), settings.degreesOfFreedom == 3 { dofBeforeGame = 3; settings.degreesOfFreedom = 6; log("[Games] 6DoF for the game") }
                    windows?.minimize(.games)
                    if games.hasControls {
                        let existed = windows?.window(.gameControls) != nil
                        let w = windows?.open(.gameControls, head: headInWorld, aspect: 1600.0 / 300.0, width: 1.4)
                        if !existed { w?.pane.centre.y -= 0.35 }
                    }
                } else {
                    windows?.close(.gameControls)
                    windows?.open(.games, head: headInWorld, aspect: 1600.0 / 560.0)
                    if let before = dofBeforeGame { settings.degreesOfFreedom = before; dofBeforeGame = nil }
                }
            }
            if windows?.window(.gameControls)?.minimized == false, !ridingNow {
                let hit = games.controlsPanel.pane.hit(origin: origin, direction: forward)
                _ = games.controlsPanel.hover(hit?.uv)
                if select, hit != nil, let id = games.controlsPanel.hovered { games.press(id); select = false; gameSelect = false }
                games.renderControls()
                if let t = games.controlsPanel.texture { toolbarQuads.append((t, 26)) }
            }
            // A finished game's summary: its numbers, Play again and Exit, ahead of the player.
            var summaryHit = false
            if games.current?.summary != nil {
                if !summaryShown { games.placeSummary(head: headInWorld); summaryShown = true }
                let hit = games.summaryPanel.pane.hit(origin: origin, direction: forward)
                summaryHit = hit != nil
                _ = games.summaryPanel.hover(hit?.uv)
                if select, hit != nil, let id = games.summaryPanel.hovered, id == "again" || id == "exit" {
                    games.press(id); select = false; gameSelect = false
                    log("[Games] Summary: \(id == "again" ? "play again" : "exit")")
                }
                games.renderSummary()
                if games.current?.summary != nil, let t = games.summaryPanel.texture { toolbarQuads.append((t, 27)) }
            } else {
                summaryShown = false
            }
            // Whether the pointer is on the interface: a pinch there is for a button, not the game.
            let onWindow = windows?.visible.contains { w in
                (!w.barHidden && w.titleBar.pane.hit(origin: origin, direction: forward) != nil) || w.pane.hit(origin: origin, direction: forward) != nil
            } ?? false
            let onDock = (toolbar?.dockShown ?? false) && (toolbar?.panel.pane.hit(origin: origin, direction: forward) != nil || toolbar?.tray.pane.hit(origin: origin, direction: forward) != nil)
            let room = (source as? ARController)?.room
            var context = GameContext(head: headInWorld, hands: tracked, floorHeight: room?.floorHeight ?? floorHeight,
                                      surfaces: room?.all ?? [], time: t2, dt: frameDt, select: gameSelect, meshes: games.meshes)
            context.pointerOnInterface = onWindow || onDock || summaryHit
            scene3D.clear()
            scene3D.floorHeight = context.floorHeight
            games.frame(context, overlay: &overlay, scene: &scene3D)
            rideTransform = (games.current as? GridRide)?.riderTransform ?? matrix_identity_float4x4
            games.render()
            if windows?.window(.games)?.minimized == false, let t = games.panel.texture { toolbarQuads.append((t, 6)) }
            if let hit {
                let at = games.panel.pane.centre + games.panel.pane.right * ((hit.uv.x - 0.5) * games.panel.pane.widthMeters) + games.panel.pane.up * ((0.5 - hit.uv.y) * games.panel.pane.heightMeters)
                overlay.addSquare(at - forward * 0.01, size: 0.012, eye: origin, color: HandOverlay.pinchColor)
            }
        }
        // Everything before this point can hide behind the room; the hands and reticles cannot.
        overlayUnoccludedStart = overlay.vertices.count
        if settings.showHandsLive {
            let eyeMid = headInWorld.columns.3.xyz
            for hand in tracked { overlay.addHand(hand, eye: eyeMid) }
        }
        var quads: [(MTLBuffer?, MTLTexture, SIMD4<Float>, Int)] = []
        // The dock: hidden while the keyboard hangs where it would be.
        // The dock and its Apps button at the feet: neither during a WebXR session or 360 playback.
        if let toolbar, !(browser?.isImmersive ?? false), !lockedNow, !(browser?.keyboardShown ?? false), !(media?.isProjected ?? false) {
            let origin = pointerOrigin
            let forward = pointerDirection
            toolbar.tick(time: t2)
            toolbar.minimized = windows?.minimized.map(\.kind) ?? []
            toolbar.musicPlaying = (music?.hasQueue ?? false) ? music?.isPlaying : nil
            toolbar.riding = ridingNow
            if ridingNow { toolbar.hideDock() }
            let rideUp: SIMD3<Float>? = ridingNow ? (rideTransform * SIMD4<Float>(0, 1, 0, 0)).xyz : nil
            toolbar.placeFeet(head: headInWorld, floor: (source as? ARController)?.room.floorHeight ?? floorHeight, rideUp: rideUp)
            var hit: (ScenePanel, SIMD2<Float>)?
            if toolbar.dockShown, let h = toolbar.panel.pane.hit(origin: origin, direction: forward) { hit = (toolbar.panel, h.uv) }
            else if toolbar.trayShown, let h = toolbar.tray.pane.hit(origin: origin, direction: forward) { hit = (toolbar.tray, h.uv) }
            else if !toolbar.dockShown, let h = toolbar.menu.pane.hit(origin: origin, direction: forward) { hit = (toolbar.menu, h.uv) }
            _ = toolbar.panel.hover(hit?.0 === toolbar.panel ? hit?.1 : nil)
            _ = toolbar.tray.hover(hit?.0 === toolbar.tray ? hit?.1 : nil)
            _ = toolbar.menu.hover(hit?.0 === toolbar.menu ? hit?.1 : nil)
            if select, let (panel, _) = hit, let id = panel.hovered {
                if id == "feet" {
                    if ridingNow { games?.press("stop"); log("[Games] Coaster stopped from the button at the feet") }
                    else {
                        // The dock opens where the head looks now (it stayed where it was first hung,
                        // which after a turn or a 3DoF switch was off to the side).
                        toolbar.place(ahead: headInWorld)
                        toolbar.showDock(time: t2)
                    }
                } else { toolbar.press(id); toolbar.showDock(time: t2) }
                select = false
            }
            toolbar.render()
            if toolbar.dockShown, let t = toolbar.panel.texture { toolbarQuads.append((t, 3)) }
            if toolbar.trayShown, let t = toolbar.tray.texture { toolbarQuads.append((t, 28)) }
            if !toolbar.dockShown, let t = toolbar.menu.texture { toolbarQuads.append((t, 4)) }
            if let (panel, uv) = hit, browser == nil || panel === toolbar.menu {
                // The reticle on the dock when nothing else draws one.
                let at = panel.pane.centre + panel.pane.right * ((uv.x - 0.5) * panel.pane.widthMeters) + panel.pane.up * ((0.5 - uv.y) * panel.pane.heightMeters)
                overlay.addSquare(at - forward * 0.01, size: 0.012, eye: origin, color: HandOverlay.pinchColor)
            }
        }
        // Places: the panel, and the scan it asks for.
        if let places, windows?.window(.places)?.minimized == false, !lockedNow {
            let origin = pointerOrigin
            let forward = pointerDirection
            let hit = places.panel.pane.hit(origin: origin, direction: forward)
            _ = places.panel.hover(hit?.uv)
            if select, hit != nil, let id = places.panel.hovered {
                if places.press(id) { settings.surfaces.toggle() }
                select = false
            }
            places.render()
            if let t = places.panel.texture { toolbarQuads.append((t, 25)) }
            if let hit {
                let at = places.panel.pane.centre + places.panel.pane.right * ((hit.uv.x - 0.5) * places.panel.pane.widthMeters) + places.panel.pane.up * ((0.5 - hit.uv.y) * places.panel.pane.heightMeters)
                overlay.addSquare(at - forward * 0.01, size: 0.012, eye: origin, color: HandOverlay.pinchColor)
            }
        }
        if let ar = source as? ARController { ar.setScanning(settings.surfaces) }
        let room = (source as? ARController)?.room
        surfacesAppear += (settings.surfaces ? 1 : -1) * frameDt / 0.6
        surfacesAppear = min(max(surfacesAppear, 0), 1)
        var surfaceBuffer: MTLBuffer?
        var surfaceVertexCount = 0
        if surfacesAppear > 0.01, let room {
            var vertices: [SurfaceVertex] = []
            for surface in room.all {
                for i in surface.indices where Int(i) < surface.vertices.count { vertices.append(surface.vertices[Int(i)]) }
            }
            if !vertices.isEmpty {
                let bytes = vertices.count * MemoryLayout<SurfaceVertex>.stride
                while surfaceBuffers.count < 3 { surfaceBuffers.append(device.makeBuffer(length: 1 << 20, options: .storageModeShared)!) }
                surfaceBufferIndex = (surfaceBufferIndex + 1) % surfaceBuffers.count
                let buffer = surfaceBuffers[surfaceBufferIndex]
                if bytes <= buffer.length {
                    vertices.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
                    surfaceBuffer = buffer
                    surfaceVertexCount = vertices.count
                }
            }
        }
        var mediaTextures: (picture: MTLTexture?, eyes: MTLTexture?) = (nil, nil)
        var mediaUniforms = MediaUniforms()
        if let media, windows?.visible.contains(where: { $0.kind == .media || $0.kind == .files }) == false { media.pausePlayback() }
        if let media, windows?.visible.contains(where: { $0.kind == .media || $0.kind == .files }) == true, !lockedNow {
            let origin = pointerOrigin
            let forward = pointerDirection
            let panel = media.screen == .viewing ? media.controls : media.grid
            var hit = media.controlsHidden && media.screen == .viewing ? nil : panel.pane.hit(origin: origin, direction: forward)
            _ = panel.hover(hit?.uv)
            media.gaze(uv: hit?.uv, pinchHeld: pinchHeld, time: t2)
            if media.scrub(uv: hit?.uv, pinchHeld: pinchHeld, select: select) { select = false }
            if media.controlsHidden, media.screen == .viewing, select { media.showControls(); select = false }
            windows?.window(.media)?.barHidden = media.controlsHidden && media.screen == .viewing
            windows?.window(.files)?.barHidden = media.controlsHidden && media.screen == .viewing
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
                if !media.controlsHidden, let t = media.controls.texture { toolbarQuads.append((t, 5)) }
            } else if let t = media.grid.texture {
                toolbarQuads.append((t, 24))
            }
            if let hit {
                let at = panel.pane.centre + panel.pane.right * ((hit.uv.x - 0.5) * panel.pane.widthMeters) + panel.pane.up * ((0.5 - hit.uv.y) * panel.pane.heightMeters)
                overlay.addSquare(at - forward * 0.01, size: 0.012, eye: origin, color: HandOverlay.pinchColor)
            }
        }
        if let browser, let chrome, let keyboard, windows?.window(.browser)?.minimized == false, !lockedNow {
            // The gaze on the panels, before the page: a panel under the gaze takes the select.
            let origin = pointerOrigin
            let forward = pointerDirection
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
            let gaze = browser.frame(head: pointerHead, hands: tracked, select: pageSelect || (select && browser.isImmersive), time: predictTo,
                                     deltaTime: frameDt)
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
        if lockedNow, let t = lock?.panel.texture { toolbarQuads.append((t, 23)) }
        for (texture, slot) in toolbarQuads { quads.append((nil, texture, SIMD4(1, 1, 1, 1), slot)) }
        if !quads.isEmpty {
            // Five quads' vertices in one buffer: the window, the chrome, the keyboard, the toolbar, the menu.
            var vertices: [QuadVertex] = []
            vertices += browser?.window.quad ?? BrowserWindow().quad
            vertices += chrome?.panel.pane.quad ?? BrowserWindow().quad
            vertices += keyboard?.panel.pane.quad ?? BrowserWindow().quad
            vertices += toolbar?.panel.pane.quad ?? BrowserWindow().quad
            vertices += toolbar?.menu.pane.quad ?? BrowserWindow().quad
            vertices += media?.controls.pane.quad ?? BrowserWindow().quad   // 5
            vertices += games?.panel.pane.quad ?? BrowserWindow().quad   // 6
            vertices += media?.flatQuad() ?? BrowserWindow().quad   // 7... no: 7+ are title bars
            // Title bars 8..19, then home 20, settings 21, music 22, lock 23.
            while vertices.count < 8 * 6 { vertices += BrowserWindow().quad }
            for i in 0..<12 {
                if let w = windows?.visible.dropFirst(i).first { vertices += w.titleBar.pane.quad } else { vertices += BrowserWindow().quad }
            }
            vertices += home?.panel.pane.quad ?? BrowserWindow().quad
            vertices += settingsWindow?.panel.pane.quad ?? BrowserWindow().quad
            vertices += music?.panel.pane.quad ?? BrowserWindow().quad
            vertices += lock?.panel.pane.quad ?? BrowserWindow().quad   // 23
            vertices += media?.grid.pane.quad ?? BrowserWindow().quad    // 24
            vertices += places?.panel.pane.quad ?? BrowserWindow().quad  // 25
            vertices += games?.controlsPanel.pane.quad ?? BrowserWindow().quad  // 26
            vertices += games?.summaryPanel.pane.quad ?? BrowserWindow().quad   // 27
            vertices += toolbar?.tray.pane.quad ?? BrowserWindow().quad         // 28
            while quadBuffers.count < 3 { quadBuffers.append(device.makeBuffer(length: 65536, options: .storageModeShared)!) }
            quadBufferIndex = (quadBufferIndex + 1) % quadBuffers.count
            let buffer = quadBuffers[quadBufferIndex]
            vertices.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            quadBuffer = buffer
        }
        var glowBuffer: MTLBuffer?
        if (games?.current) == nil { scene3D.clear() }
        if !scene3D.glows.isEmpty {
            let bytes = scene3D.glows.count * MemoryLayout<OverlayVertex>.stride
            while glowBuffers.count < 3 { glowBuffers.append(device.makeBuffer(length: 1 << 20, options: .storageModeShared)!) }
            glowBufferIndex = (glowBufferIndex + 1) % glowBuffers.count
            let buffer = glowBuffers[glowBufferIndex]
            if bytes <= buffer.length {
                scene3D.glows.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
                glowBuffer = buffer
            }
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
        let passes: [Int?] = (browser?.isImmersive ?? false) ? [] : (phone ? [0] : (amplifies ? [nil] : [0, 1]))
        for slice in passes {
            let scenePass = MTLRenderPassDescriptor()
            scenePass.colorAttachments[0].texture = eyeTexture
            scenePass.colorAttachments[0].loadAction = .clear
            scenePass.colorAttachments[0].storeAction = .store
            scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            scenePass.depthAttachment.texture = depthTexture
            scenePass.depthAttachment.loadAction = .clear
            scenePass.depthAttachment.storeAction = .dontCare
            scenePass.depthAttachment.clearDepth = 1
            var passUniforms = uniforms
            if let slice {
                scenePass.colorAttachments[0].slice = slice
                scenePass.depthAttachment.slice = slice
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
            encoder.setDepthStencilState(depthNoneState)
            // A 360, 180 or panorama picture is the surroundings while it plays, passthrough or not
            // (the owner chose 360 and saw the room instead, 2026-11-07).
            if let media, media.isProjected, mediaTextures.picture != nil || mediaTextures.eyes != nil {
                encoder.setRenderPipelineState(mediaPipeline)
                encoder.setFragmentBytes(&mediaUniforms, length: MemoryLayout<MediaUniforms>.stride, index: 1)
                encoder.setFragmentTexture(mediaTextures.picture ?? mediaTextures.eyes, index: 0)
                encoder.setFragmentTexture(mediaTextures.eyes ?? eyeTexture, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            } else if passthroughNow, let frame {
                encoder.setRenderPipelineState(passthroughPipeline)
                encoder.setFragmentTexture(frame.luma, index: 0)
                encoder.setFragmentTexture(frame.chroma, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                // Over it, the same image laid on the LiDAR depth, so the room has stereo depth.
                if settings.depthPassthrough, let depth = frame.depth {
                    encoder.setRenderPipelineState(depthPassthroughPipeline)
                    encoder.setVertexTexture(depth, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 127 * 95 * 6)
                }
            } else if case .panorama = environment, let texture = places?.panoramaTexture ?? panoramaKeep {
                var u = MediaUniforms()
                let kind = places?.panoramaItem?.kind ?? .photo360
                u.projection = Int32(kind == .panorama ? MediaProjectionCylinder.rawValue : MediaProjectionEquirect360.rawValue)
                u.layout = Int32(MediaLayoutMono.rawValue)
                u.span = kind == .panorama ? min(2 * .pi, max(.pi / 3, Float(texture.width) / Float(max(texture.height, 1)) * .pi / 3)) : 2 * .pi
                u.height = tan(Float.pi / 6)
                u.brightness = 1
                encoder.setRenderPipelineState(mediaPipeline)
                encoder.setFragmentBytes(&u, length: MemoryLayout<MediaUniforms>.stride, index: 1)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentTexture(eyeTexture, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                panoramaKeep = texture
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
            // The real room's depth, so what follows can hide behind it; then its surfaces.
            if settings.occlusion, passthroughNow, let frame, let depth = frame.depth, let confidence = frame.depthConfidence {
                encoder.setRenderPipelineState(occlusionPipeline)
                encoder.setDepthStencilState(depthWriteState)
                encoder.setFragmentTexture(depth, index: 0)
                encoder.setFragmentTexture(confidence, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            if let surfaceBuffer, surfaceVertexCount > 0 {
                if !surfaceDrawLogged { surfaceDrawLogged = true; log("[Room] Drawing \(surfaceVertexCount / 3) surface triangles") }
                var su = SurfaceUniforms()
                su.color = SIMD4(0.55, 0.85, 1, 1)
                su.highlightColor = SIMD4(1, 0.8, 0.3, 1)
                su.gazePoint = SIMD4(0, 0, 0, 0)
                su.appear = surfacesAppear
                su.spacing = 0.2
                su.time = Float(t2 - launchTime)
                encoder.setRenderPipelineState(surfacePipeline)
                encoder.setDepthStencilState(depthNoneState)
                encoder.setVertexBuffer(surfaceBuffer, offset: 0, index: 1)
                encoder.setFragmentBytes(&su, length: MemoryLayout<SurfaceUniforms>.stride, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: surfaceVertexCount)
            }
            // The games' lit meshes, their shadows and their glows.
            if !scene3D.draws.isEmpty || glowBuffer != nil {
                var light = LightUniforms()
                let dusk = 1 - nightAmount
                light.lightDirection = SIMD4(simd_normalize(SIMD3<Float>(0.35, 0.8, 0.45)), 0)
                light.lightColor = SIMD4(1.0 * dusk + 0.35 * nightAmount, 0.92 * dusk + 0.4 * nightAmount, 0.85 * dusk + 0.6 * nightAmount, 1)
                light.skyColor = SIMD4(0.45 * dusk + 0.12 * nightAmount, 0.5 * dusk + 0.15 * nightAmount, 0.75 * dusk + 0.3 * nightAmount, 1)
                light.groundColor = SIMD4(0.3 * dusk + 0.08 * nightAmount, 0.15 * dusk + 0.06 * nightAmount, 0.35 * dusk + 0.12 * nightAmount, 1)
                light.time = Float(t2 - launchTime)
                encoder.setFragmentBytes(&light, length: MemoryLayout<LightUniforms>.stride, index: 2)
                encoder.setRenderPipelineState(meshPipeline)
                encoder.setDepthStencilState(depthTestState)
                for draw in scene3D.draws {
                    var instance = draw.instance
                    encoder.setVertexBuffer(draw.mesh.vertices, offset: 0, index: 1)
                    encoder.setVertexBytes(&instance, length: MemoryLayout<MeshInstance>.stride, index: 3)
                    encoder.drawIndexedPrimitives(type: .triangle, indexCount: draw.mesh.indexCount, indexType: .uint32, indexBuffer: draw.mesh.indices, indexBufferOffset: 0)
                }
                if !scene3D.shadows.isEmpty, let games {
                    encoder.setRenderPipelineState(meshBlendPipeline)
                    encoder.setDepthStencilState(depthTestNoWriteState)
                    let disc = games.meshes.disc
                    encoder.setVertexBuffer(disc.vertices, offset: 0, index: 1)
                    for (p, radius, strength) in scene3D.shadows {
                        var instance = MeshInstance(model: Scene3D.transform(position: p, scale: SIMD3(radius, 1, radius)), color: SIMD4(0, 0, 0, strength), roughness: 1, metallic: 0, emissive: 0, pattern: 9)
                        encoder.setVertexBytes(&instance, length: MemoryLayout<MeshInstance>.stride, index: 3)
                        encoder.drawIndexedPrimitives(type: .triangle, indexCount: disc.indexCount, indexType: .uint32, indexBuffer: disc.indices, indexBufferOffset: 0)
                    }
                }
                if let glowBuffer {
                    encoder.setRenderPipelineState(glowPipeline)
                    encoder.setDepthStencilState(depthTestNoWriteState)
                    encoder.setVertexBuffer(glowBuffer, offset: 0, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: scene3D.glows.count)
                }
            }
            encoder.setDepthStencilState(depthNoneState)
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
                // Placed things hide behind the real room; the hands and the reticle do not (the
                // LiDAR sees the hand itself, which would hide its own skeleton).
                encoder.setDepthStencilState(settings.occlusion && passthroughNow ? depthTestState : depthNoneState)
                encoder.setVertexBuffer(overlayBuffer, offset: 0, index: 1)
                if overlayUnoccludedStart > 0 {
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: overlayUnoccludedStart)
                }
                encoder.setDepthStencilState(depthNoneState)
                if overlay.vertices.count > overlayUnoccludedStart {
                    encoder.drawPrimitives(type: .triangle, vertexStart: overlayUnoccludedStart, vertexCount: overlay.vertices.count - overlayUnoccludedStart)
                }
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
            if phone {
                encoder.label = "phone view"
                encoder.setRenderPipelineState(blitPipeline)
                var slice: UInt32 = 0
                encoder.setFragmentBytes(&slice, length: MemoryLayout<UInt32>.stride, index: 0)
                encoder.setFragmentTexture(eyeTexture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            } else {
                encoder.label = "distortion"
                encoder.setRenderPipelineState(distortionPipeline)
                encoder.setVertexBuffer(meshBuffer, offset: 0, index: 0)
                encoder.setFragmentTexture(eyeTexture, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                              indexBuffer: indexBuffer, indexBufferOffset: 0)
            }
            encoder.endEncoding()
        }

        // A recording of one eye, and the flat copy for a mirrored screen.
        if let recorder, recorder.isRecording {
            recorder.capture(eyeTexture: eyeTexture, commandBuffer: commandBuffer, time: t2)
        }
        if ExternalDisplay.shared.isConnected {
            ExternalDisplay.shared.present(eyeTexture: eyeTexture, eye: castEye, commandBuffer: commandBuffer, device: device, pipeline: blitPipeline)
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

        if let frame, frame.pose.timestamp != lastDrawnFrameTime { lastDrawnFrameTime = frame.pose.timestamp; drawnFrames += 1 }
        if t2 - lastPoseLog >= 5 {
            if settings.passthrough { log(String(format: "[Passthrough] %.1f distinct camera images drawn a second", Double(drawnFrames) / 5)) }
            drawnFrames = 0
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
        case "text:-": settings.textScaleLive = max(50, settings.textScaleLive - 20)
        case "text:+": settings.textScaleLive = min(300, settings.textScaleLive + 20)
        case "home": browser.home()
        case "star": browser.toggleBookmark()
        case "size": browser.cycleSize(); layoutPanels()
        case "place": browser.togglePlacing()
        case "keys", "address": browser.toggleKeyboard()
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
