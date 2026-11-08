import Foundation
import Combine

/// What the app runs with, from three places in order: a launch option (the environment variable
/// `AFTERGLOW_<name>`, which `Tools/native_build_and_run.sh --ei name value` sets, as the Unity
/// app's scripts do), a value saved from the on-screen controls, then the default. Numbers only,
/// as on the Unity side: percentages and on/off flags are whole numbers.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    /// Passthrough on (1) or the synthwave surroundings (0).
    @Published var passthrough: Bool { didSet { save("passthrough", passthrough ? 1 : 0) } }
    /// Eye texture size relative to half the screen each, in percent.
    @Published var renderScalePercent: Int { didSet { save("renderScale", renderScalePercent) } }
    /// The frame rate asked of the display: 60 holds the camera's own rate and the thermal budget.
    @Published var targetFrameRate: Int { didSet { save("fps", targetFrameRate) } }
    /// Milliseconds added to the display latency when predicting the head pose, to tune by eye.
    @Published var extraPredictionMs: Int { didSet { save("predictionMs", extraPredictionMs) } }
    /// How much the head's rotation is smoothed, in percent (0: off), so fast or shaky movement
    /// doesn't shake the world (owner, 2026-11-08).
    @Published var headSmoothing: Int { didSet { save("headSmoothing", headSmoothing) } }
    /// 6: ARKit world tracking on the wide camera. 3: the ultra-wide through AVFoundation with the
    /// head's rotation from the motion sensors and no positional tracking (ARKit cannot run beside
    /// the ultra-wide, and has no world-tracking format for it on the iPhone).
    @Published var degreesOfFreedom: Int { didSet { save("dof", degreesOfFreedom) } }
    /// Prefer the ultra-wide camera's formats when ARKit lists any.
    let ultraWide: Bool
    /// Occlusion of virtual things by the real room, from the LiDAR depth (6DoF only).
    @Published var occlusion: Bool { didSet { save("occlusion", occlusion ? 1 : 0) } }
    /// Passthrough laid over the LiDAR depth, so the room has its own stereo depth and virtual
    /// things sit on it (owner, 2026-11-08: dust and floors looked far above the real floor).
    @Published var depthPassthrough: Bool { didSet { save("depthPassthrough", depthPassthrough ? 1 : 0) } }
    /// Show the detected surfaces (scan the room).
    @Published var surfaces: Bool { didSet { save("surfaces", surfaces ? 1 : 0) } }
    /// Hold the render scale and frame rate down while the phone is serious or critical, as the
    /// Unity app does; off compares the two at their set values.
    let thermalCap: Bool
    /// Where the eyes' midpoint sits relative to the camera, in camera axes (x right, y up, z back),
    /// in millimetres; a launch option per axis.
    let cameraToEyesMm: SIMD3<Int>
    /// Save the left eye's texture to Documents/eye-left.png this many seconds after launch (0: never).
    let dumpAfterSeconds: Int
    /// Open the browser at launch, and the page zoom in percent for text readable in the viewer.
    @Published var browserOpen: Bool { didSet { save("web", browserOpen ? 1 : 0) } }
    let textScalePercent: Int
    /// A page to open at launch instead of the saved tabs (a launch option only; text, not a number).
    let launchURL: String?
    /// A test script for the Simulator: steps separated by ";", each "wait N", "press <button id>",
    /// "type <text>", "key <Backspace|Clear|Enter>", "look <yaw> <pitch>" (degrees), "tap", "dump",
    /// "screenshot" (logs a marker for the harness to screenshot), "immersive" (asks the page's
    /// first WebXR button), "end".
    let actions: [String]
    /// The owner vouches the phone is cold (`cold 1`), overriding the fifteen-minute rule.
    let assertedCold: Bool
    /// Hand tracking on, its image rate, whether the scene depth (LiDAR) teaches the palm size,
    /// and whether the tracked hands are drawn.
    let hands: Bool
    let handHz: Int
    let handDepth: Bool
    let showHands: Bool
    /// The same, changeable from the menu while running.
    @Published var showHandsLive: Bool { didSet { save("showHands", showHandsLive ? 1 : 0) } }
    @Published var handHzLive: Int { didSet { save("handHz", handHzLive) } }
    @Published var textScaleLive: Int { didSet { save("textScale", textScaleLive) } }
    /// Phone view: one eye, the screen's shape, no lens warp, for the phone in the hand instead
    /// of the viewer; taps select where they land and a double tap brings the system keyboard.
    @Published var phoneView: Bool { didSet { save("view", phoneView ? 1 : 0) } }
    /// An experiment: open the ultra-wide camera through AVFoundation this many seconds after
    /// ARKit starts, to see whether ARKit keeps tracking beside it (0: never).
    let ultraTestSeconds: Int
    /// The phase-two grab demo (cubes to pinch), off unless asked for.
    let demo: Bool
    /// Phone view: a tap selects where it lands (1) instead of what the centre cursor is on (0).
    let tapAtPoint: Bool

    private var loading = true
    private var options: [String: String] = [:]

    private init() {
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("AFTERGLOW_") {
            options[String(key.dropFirst("AFTERGLOW_".count))] = value
        }
        passthrough = Self.read("passthrough", options: options, default: 0) != 0
        renderScalePercent = min(max(Self.read("renderScale", options: options, default: 100), 25), 200)
        targetFrameRate = Self.read("fps", options: options, default: 60)
        extraPredictionMs = Self.read("predictionMs", options: options, default: 0)
        headSmoothing = min(max(Self.read("headSmoothing", options: options, default: 50), 0), 100)
        degreesOfFreedom = Self.read("dof", options: options, default: 6) == 3 ? 3 : 6
        ultraWide = Self.read("camUltraWide", options: options, default: 1) != 0
        occlusion = Self.read("occlusion", options: options, default: 1) != 0
        depthPassthrough = Self.read("depthPassthrough", options: options, default: 1) != 0
        surfaces = Self.read("surfaces", options: options, default: 0) != 0
        thermalCap = Self.read("thermalCap", options: options, default: 1) != 0
        cameraToEyesMm = SIMD3(Self.read("eyesX", options: options, default: 60),
                               Self.read("eyesY", options: options, default: -10),
                               Self.read("eyesZ", options: options, default: 66))
        dumpAfterSeconds = Self.read("dump", options: options, default: 0)
        // A launch option only: the browser is an app the launcher opens, not a saved state.
        browserOpen = (options["web"].flatMap(Int.init) ?? 0) != 0
        textScalePercent = min(max(Self.read("textScale", options: options, default: 220), 50), 300)
        launchURL = options["url"]
        actions = (options["actions"] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        assertedCold = Self.read("cold", options: options, default: 0) != 0
        hands = Self.read("hands", options: options, default: 1) != 0
        handHz = min(max(Self.read("handHz", options: options, default: 20), 1), 60)
        handDepth = Self.read("handDepth", options: options, default: 1) != 0
        showHands = Self.read("showHands", options: options, default: 1) != 0
        showHandsLive = showHands
        handHzLive = min(max(Self.read("handHz", options: options, default: 20), 1), 60)
        textScaleLive = min(max(Self.read("textScale", options: options, default: 220), 50), 300)
        phoneView = Self.read("view", options: options, default: 0) != 0
        ultraTestSeconds = Self.read("ultraTest", options: options, default: 0)
        demo = (options["demo"].flatMap(Int.init) ?? 0) != 0
        tapAtPoint = (options["tapAtPoint"].flatMap(Int.init) ?? 0) != 0
        loading = false
        let given = options.keys.sorted().map { "\($0) \(options[$0]!)" }.joined(separator: ", ")
        log("[Stereo] Launch options: \(given.isEmpty ? "none" : given)")
    }

    private static func read(_ name: String, options: [String: String], default value: Int) -> Int {
        if let text = options[name], let number = Int(text) { return number }
        if let saved = UserDefaults.standard.object(forKey: "setting." + name) as? Int { return saved }
        return value
    }

    private func save(_ name: String, _ value: Int) {
        if loading { return }
        UserDefaults.standard.set(value, forKey: "setting." + name)
    }
}
