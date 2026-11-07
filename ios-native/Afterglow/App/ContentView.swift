import SwiftUI

/// The stereo view with a control strip over it that a tap shows and hides: passthrough on or off,
/// the render scale, the frame rate asked for. The strip is for the desk; in the viewer the screen
/// is covered, so every setting also has a launch option.
struct ContentView: View {
    @StateObject private var settings = Settings.shared
    @StateObject private var model = StereoModel()
    @State private var controlsShown = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        // The strip is an overlay, so its size never changes the Metal view's: as a sibling in a
        // stack it stretched the view past the screen and SwiftUI animated the drawable's width.
        MetalView(model: model)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onReceive(NotificationCenter.default.publisher(for: .afterglowToggleStrip)) { _ in toggleControls() }
            .overlay(alignment: .bottom) {
                if controlsShown {
                    controls
                        .padding(14)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                        .padding(.bottom, 24)
                        .transition(.opacity)
                }
            }
            .background(Color.black)
            .onAppear { scheduleHide() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 24) {
                Toggle("Phone view", isOn: $settings.phoneView)
                    .toggleStyle(.switch)
                    .fixedSize()
                Toggle("Passthrough", isOn: $settings.passthrough)
                    .toggleStyle(.switch)
                    .fixedSize()
                Stepper("Render scale \(settings.renderScalePercent)%", value: $settings.renderScalePercent, in: 25...200, step: 10)
                    .fixedSize()
                Stepper("\(settings.targetFrameRate) fps", value: $settings.targetFrameRate, in: 30...120, step: 30)
                    .fixedSize()
            }
            HStack(spacing: 24) {
                Toggle("3DoF ultra-wide", isOn: Binding(get: { settings.degreesOfFreedom == 3 },
                                                        set: { settings.degreesOfFreedom = $0 ? 3 : 6 }))
                    .toggleStyle(.switch)
                    .fixedSize()
                Stepper("Predict +\(settings.extraPredictionMs) ms", value: $settings.extraPredictionMs, in: 0...60, step: 4)
                    .fixedSize()
                Text(model.status)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .foregroundStyle(.white)
        .onChange(of: settings.passthrough) { _, _ in scheduleHide() }
        .onChange(of: settings.renderScalePercent) { _, _ in scheduleHide() }
        .onChange(of: settings.targetFrameRate) { _, _ in scheduleHide() }
        .onChange(of: settings.extraPredictionMs) { _, _ in scheduleHide() }
        .onChange(of: settings.degreesOfFreedom) { _, _ in scheduleHide() }
        .onChange(of: settings.phoneView) { _, _ in scheduleHide() }
    }

    private func toggleControls() {
        withAnimation { controlsShown.toggle() }
        if controlsShown { scheduleHide() }
    }

    // In the viewer nothing should be drawn over the eyes, so the strip goes after a few seconds.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled {
                withAnimation { controlsShown = false }
            }
        }
    }
}

/// Owns the renderer and the AR session for the view's lifetime, and a one-line status for the strip.
@MainActor
final class StereoModel: ObservableObject {
    @Published var status = "starting"
    let thermal = ThermalLog()
    let dictation = Dictation()
    private(set) var renderer: Renderer?
    private var started = false

    /// Builds the renderer for the screen the view landed on, then starts tracking. The screen's
    /// size is what the lens geometry is built from, so nothing can start before there is one.
    func start(on screen: UIScreen) {
        guard !started else { return }
        started = true
        renderer = Renderer(settings: Settings.shared, thermal: thermal, screen: screen)
        guard let renderer else {
            status = "no renderer; see the session log"
            return
        }
        renderer.onDictate = { [weak self] in self?.dictate() }
        renderer.startSource()
        NotificationCenter.default.addObserver(forName: .afterglowBackground, object: nil, queue: .main) { _ in MainActor.assumeIsolated { renderer.appBackgrounded() } }
        NotificationCenter.default.addObserver(forName: .afterglowForeground, object: nil, queue: .main) { _ in MainActor.assumeIsolated { renderer.appForegrounded() } }
    }

    /// Push to talk: a press starts listening, the next stops it and types what was heard.
    func dictate() {
        guard let renderer else { return }
        if dictation.listening {
            dictation.stop()
            return
        }
        Task { @MainActor in
            guard await dictation.requestPermission() else { return }
            dictation.start { text in
                guard !text.isEmpty else { return }
                if renderer.places != nil, renderer.isPromptingForPlace { renderer.places?.generate(prompt: text); renderer.endPlacePrompt() }
                else if let media = renderer.media, media.isFiles { media.type(text) } else { renderer.browser?.type(text) }
            }
        }
    }

    func updateStatus(fps: Double) {
        let camera = renderer?.source.cameraName ?? "-"
        status = String(format: "%.0f fps, %dDoF %@ camera, %@", fps, renderer?.source.degreesOfFreedom ?? 0, camera, thermal.currentState)
    }
}

/// A UIView whose layer is a CAMetalLayer at the screen's native resolution, driven by a display
/// link at the frame rate the settings ask for.
struct MetalView: UIViewRepresentable {
    let model: StereoModel

    func makeUIView(context: Context) -> MetalLayerView {
        let view = MetalLayerView()
        view.model = model
        return view
    }

    func updateUIView(_ uiView: MetalLayerView, context: Context) {}
}

final class MetalLayerView: UIView, UIKeyInput {
    var model: StereoModel?
    private var displayLink: CADisplayLink?
    private var frameRate = 0
    private var fpsFrames = 0
    private var fpsSince: Double = 0
    private var lastSizeLog: Double = 0

    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // Three drawables. With two the loop blocked a whole frame on every drawable and the rate
        // halved to 30 fps (measured 2026-11-06); with three it runs up to two frames ahead of the
        // display, and the renderer measures how late each frame really appears and predicts the
        // head pose to that moment instead.
        metalLayer.maximumDrawableCount = 3
        metalLayer.presentsWithTransaction = false
        metalLayer.device = MTLCreateSystemDefaultDevice()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            model?.start(on: window.screen)
            model?.renderer?.attach(window: window)
            if let device = model?.renderer?.device { metalLayer.device = device }
            installGestures()
            updateDrawableSize()
            startDisplayLink()
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let scale = window?.screen.nativeScale else { return }
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0 && size.height > 0 && metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            let now = CACurrentMediaTime()
            if now - lastSizeLog > 1 {
                lastSizeLog = now
                log("[Stereo] Drawable \(Int(size.width))x\(Int(size.height)) px (scale \(scale))")
            }
        }
    }

    private var gesturesInstalled = false
    private var lastPan = CGPoint.zero

    // A tap selects where it lands (the phone view) or at the gaze, a double tap brings up the
    // system keyboard for typing, a long press ends an immersive session, a drag turns the head
    // when nothing tracks it (the Simulator) and otherwise scrolls the page or swipes between
    // pictures. The SwiftUI tap on the view (the control strip) stays as well.
    private func installGestures() {
        guard !gesturesInstalled else { return }
        gesturesInstalled = true
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        // Two fingers show and hide the control strip; one finger selects (owner, 2026-11-07: the
        // strip could not be reached after launch).
        let twoFinger = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped(_:)))
        twoFinger.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFinger)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 3.0
        addGestureRecognizer(hold)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let p = gesture.location(in: self)
        guard bounds.width > 0, bounds.height > 0 else { return }
        if Settings.shared.phoneView {
            model?.renderer?.screenTapped(at: SIMD2(Float(p.x / bounds.width), Float(p.y / bounds.height)))
        } else {
            model?.renderer?.screenTapped()
        }
    }

    @objc private func twoFingerTapped(_ gesture: UITapGestureRecognizer) {
        NotificationCenter.default.post(name: .afterglowToggleStrip, object: nil)
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if isFirstResponder { resignFirstResponder() } else { becomeFirstResponder() }
        log("[Phone] Keyboard \(isFirstResponder ? "shown" : "hidden")")
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { model?.renderer?.screenHeld() }
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.translation(in: self)
        if gesture.state == .began { lastPan = .zero }
        let dx = Float(point.x - lastPan.x), dy = Float(point.y - lastPan.y)
        lastPan = point
        model?.renderer?.panned(dx: dx, dy: dy, ended: gesture.state == .ended, totalDx: Float(point.x))
    }

    // The system keyboard's text, for the phone view's double tap.
    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var keyboardType: UIKeyboardType = .webSearch
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    func insertText(_ text: String) {
        if text == "\n" { model?.renderer?.typedKey("Enter"); resignFirstResponder() } else { model?.renderer?.typed(text) }
    }
    func deleteBackward() { model?.renderer?.typedKey("Backspace") }

    private func startDisplayLink() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        applyFrameRate(force: true)
    }

    private func applyFrameRate(force: Bool = false) {
        guard let renderer = model?.renderer, let link = displayLink else { return }
        let fps = renderer.applySettings()
        if fps != frameRate || force {
            frameRate = fps
            link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
            FrameTimingLog.displayHz = fps
            log("[Stereo] Target \(fps) fps, max queued frames 2, display link \(fps) Hz")
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let renderer = model?.renderer else { return }
        applyFrameRate()
        renderer.draw(to: metalLayer, timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
        fpsFrames += 1
        if fpsSince == 0 { fpsSince = link.timestamp }
        if link.timestamp - fpsSince >= 1 {
            model?.updateStatus(fps: Double(fpsFrames) / (link.timestamp - fpsSince))
            fpsFrames = 0
            fpsSince = link.timestamp
        }
    }
}

extension Notification.Name {
    static let afterglowToggleStrip = Notification.Name("afterglowToggleStrip")
}
