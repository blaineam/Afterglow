import AVFoundation
import Accelerate
import MediaPlayer

/// The tempo of a song in the library, from its own audio: the first ninety seconds are read
/// through AVAssetReader as mono samples, an onset strength curve is taken from the energy's
/// rises in 23 ms hops, and the lag with the strongest autocorrelation between 70 and 180 bpm is
/// the beat. Only songs the device holds unprotected can be read (purchased, matched or ripped);
/// a protected Apple Music stream gives no samples, and the game keeps the tempo the player
/// set. Results are kept by song id. Logs [Tempo].
@MainActor
final class TempoAnalyzer {
    private var cache: [String: Double] = [:]
    private var running: Set<String> = []
    private let cacheKey = "tempo.cache"

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: Double] { cache = saved }
    }

    func cached(_ id: String) -> Double? { cache[id] }

    /// Finds the song's file in the device's media library by its title and artist and measures it.
    func tempo(forTitle title: String, artist: String, id: String) async -> Double? {
        if let known = cache[id] { return known }
        guard !running.contains(id) else { return nil }
        running.insert(id)
        defer { running.remove(id) }
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: title, forProperty: MPMediaItemPropertyTitle, comparisonType: .equalTo))
        guard let items = query.items else { log("[Tempo] No library match for \(title)"); return nil }
        let match = items.first { ($0.artist ?? "").localizedCaseInsensitiveContains(artist) || artist.isEmpty } ?? items.first
        guard let url = match?.assetURL else {
            log("[Tempo] \(title) is protected or not on the device: no audio to read")
            return nil
        }
        let bpm = await Self.measure(url: url)
        if let bpm {
            cache[id] = bpm
            UserDefaults.standard.set(cache, forKey: cacheKey)
            log(String(format: "[Tempo] %@: %.1f bpm", title, bpm))
        } else {
            log("[Tempo] \(title): could not be measured")
        }
        return bpm
    }

    nonisolated static func measure(url: URL) async -> Double? {
        await Task.detached(priority: .userInitiated) { () -> Double? in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 22050, AVNumberOfChannelsKey: 1,
                                           AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: 20, preferredTimescale: 600), duration: CMTime(seconds: 90, preferredTimescale: 600))
            guard reader.startReading() else { return nil }
            let hop = 512   // 23 ms at 22.05 kHz
            var energies: [Float] = []
            var carry: [Float] = []
            while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { continue }
                let count = length / 4
                let samples = pointer.withMemoryRebound(to: Float.self, capacity: count) { Array(UnsafeBufferPointer(start: $0, count: count)) }
                carry += samples
                while carry.count >= hop {
                    let frame = Array(carry.prefix(hop))
                    carry.removeFirst(hop)
                    var energy: Float = 0
                    vDSP_svesq(frame, 1, &energy, vDSP_Length(hop))
                    energies.append(energy)
                }
            }
            guard energies.count > 200 else { return nil }
            // Onset strength: the positive rises of the log energy.
            var onsets = [Float](repeating: 0, count: energies.count)
            for i in 1..<energies.count {
                let d = log(energies[i] + 1e-6) - log(energies[i - 1] + 1e-6)
                onsets[i] = max(0, d)
            }
            let mean = onsets.reduce(0, +) / Float(onsets.count)
            for i in onsets.indices { onsets[i] -= mean }
            // Autocorrelation over the beat lags: 70-180 bpm at 23.2 ms a hop is 14-37 hops.
            let hopSeconds = Double(hop) / 22050
            let minLag = Int(60 / 180 / hopSeconds), maxLag = Int(60 / 70 / hopSeconds)
            var bestLag = minLag
            var best: Float = -.infinity
            for lag in minLag...maxLag {
                var sum: Float = 0
                onsets.withUnsafeBufferPointer { p in
                    vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &sum, vDSP_Length(onsets.count - lag))
                }
                // Prefer the fundamental over its double: a mild penalty on long lags.
                let score = sum * (1 - 0.15 * Float(lag - minLag) / Float(maxLag - minLag))
                if score > best { best = score; bestLag = lag }
            }
            // Refine the lag with a parabola through its neighbours.
            var refined = Double(bestLag)
            if bestLag > minLag && bestLag < maxLag {
                func corr(_ lag: Int) -> Float {
                    var sum: Float = 0
                    onsets.withUnsafeBufferPointer { p in vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &sum, vDSP_Length(onsets.count - lag)) }
                    return sum
                }
                let a = corr(bestLag - 1), b = corr(bestLag), c = corr(bestLag + 1)
                let denominator = a - 2 * b + c
                if abs(denominator) > 1e-6 { refined += Double((a - c) / (2 * denominator)) }
            }
            let bpm = 60 / (refined * hopSeconds)
            return bpm.isFinite ? bpm : nil
        }.value
    }
}
