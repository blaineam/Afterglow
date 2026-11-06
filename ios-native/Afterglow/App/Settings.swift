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
    /// Prefer the ultra-wide camera's formats when ARKit lists any.
    let ultraWide: Bool
    /// Hold the render scale and frame rate down while the phone is serious or critical, as the
    /// Unity app does; off compares the two at their set values.
    let thermalCap: Bool
    /// Where the eyes' midpoint sits relative to the camera, in camera axes (x right, y up, z back),
    /// in millimetres; a launch option per axis.
    let cameraToEyesMm: SIMD3<Int>
    /// Save the left eye's texture to Documents/eye-left.png this many seconds after launch (0: never).
    let dumpAfterSeconds: Int
    /// The owner vouches the phone is cold (`cold 1`), overriding the fifteen-minute rule.
    let assertedCold: Bool
    /// Hand tracking on, its image rate, whether the scene depth (LiDAR) teaches the palm size,
    /// and whether the tracked hands are drawn.
    let hands: Bool
    let handHz: Int
    let handDepth: Bool
    let showHands: Bool
    /// An experiment: open the ultra-wide camera through AVFoundation this many seconds after
    /// ARKit starts, to see whether ARKit keeps tracking beside it (0: never).
    let ultraTestSeconds: Int

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
        ultraWide = Self.read("camUltraWide", options: options, default: 1) != 0
        thermalCap = Self.read("thermalCap", options: options, default: 1) != 0
        cameraToEyesMm = SIMD3(Self.read("eyesX", options: options, default: 60),
                               Self.read("eyesY", options: options, default: -10),
                               Self.read("eyesZ", options: options, default: 66))
        dumpAfterSeconds = Self.read("dump", options: options, default: 0)
        assertedCold = Self.read("cold", options: options, default: 0) != 0
        hands = Self.read("hands", options: options, default: 1) != 0
        handHz = min(max(Self.read("handHz", options: options, default: 20), 1), 60)
        handDepth = Self.read("handDepth", options: options, default: 1) != 0
        showHands = Self.read("showHands", options: options, default: 1) != 0
        ultraTestSeconds = Self.read("ultraTest", options: options, default: 0)
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
