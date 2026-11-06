import Foundation
import UIKit

/// Logs the achieved frame rate every five seconds with the [Frames] tag, and each hitch with the
/// [Hitch] tag, in the same line shapes as the Unity app's `FrameTimingLog.cs`, so the two apps'
/// logs compare line for line:
///
///     [Frames] 60.1 fps (target 60), worst 18.2 ms, 0.4% late, display 60 Hz; typical cpu 3.1 ms:
///     main 1.2, render 0.0, present wait 1.9, gpu 2.4; thermal state nominal, screen maximum 120 fps
///
/// "main" is the time the frame loop spent encoding, "render" is always 0.0 (there is no render
/// thread: encoding happens on the frame loop's own thread), "present wait" is the time blocked on
/// a drawable or on the GPU finishing the frame before last, and "gpu" is the command buffer's own
/// time. "cpu" is the sum of main and present wait, as Unity's cpuFrameTime covers both.
final class FrameTimingLog {
    struct Sample {
        var mainMs: Double
        var presentWaitMs: Double
        var gpuMs: Double
    }

    private let interval: Double = 5
    private let hitchMilliseconds: Double = 30
    private var frames = 0
    private var lateFrames = 0
    private var elapsed: Double = 0
    private var worstFrame: Double = 0
    private var lastTimestamp: Double?
    private var recent: [Sample] = []
    private let recentCount = 8

    /// The frame budget in use, for counting late frames.
    var targetFrameRate = 60

    /// Records a frame that just completed its CPU work. `timestamp` is the display link's time for
    /// the frame, `sample` where its CPU and GPU time went (the GPU time is the previous frame's,
    /// since this one's has not run yet).
    func record(timestamp: Double, sample: Sample, thermalState: String) {
        defer { lastTimestamp = timestamp }
        guard let last = lastTimestamp else { return }
        let deltaTime = timestamp - last
        recent.append(sample)
        if recent.count > recentCount { recent.removeFirst() }

        if deltaTime * 1000 > hitchMilliseconds {
            let stamp = Self.clock(Date())
            log(String(format: "[Hitch] %.1f ms at %@, frame %d; cpu %.1f ms: main %.1f, render 0.0, present wait %.1f, gpu %.1f",
                       deltaTime * 1000, stamp, frames, sample.mainMs + sample.presentWaitMs,
                       sample.mainMs, sample.presentWaitMs, sample.gpuMs))
        }

        frames += 1
        elapsed += deltaTime
        worstFrame = max(worstFrame, deltaTime)
        let budget = 1.0 / Double(max(targetFrameRate, 1))
        if deltaTime > budget * 1.5 { lateFrames += 1 }
        if elapsed < interval { return }

        let count = Double(max(recent.count, 1))
        let main = recent.reduce(0) { $0 + $1.mainMs } / count
        let present = recent.reduce(0) { $0 + $1.presentWaitMs } / count
        let gpu = recent.reduce(0) { $0 + $1.gpuMs } / count
        let display = Self.displayHz
        log(String(format: "[Frames] %.1f fps (target %d), worst %.1f ms, %.1f%% late, display %d Hz; typical cpu %.1f ms: main %.1f, render 0.0, present wait %.1f, gpu %.1f; thermal state %@, screen maximum %d fps",
                   Double(frames) / elapsed, targetFrameRate, worstFrame * 1000,
                   100 * Double(lateFrames) / Double(max(frames, 1)), display,
                   main + present, main, present, gpu, thermalState, Self.screenMaximum))
        frames = 0
        lateFrames = 0
        elapsed = 0
        worstFrame = 0
    }

    /// The refresh rate the display link is running at, set by the renderer each time it changes.
    nonisolated(unsafe) static var displayHz = 60
    nonisolated(unsafe) static var screenMaximum = 60

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }
}
