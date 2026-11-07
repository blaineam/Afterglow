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
        let items = query.items ?? []
        let match = items.first { ($0.artist ?? "").localizedCaseInsensitiveContains(artist) || artist.isEmpty } ?? items.first
        var bpm: Double?
        if let url = match?.assetURL {
            bpm = await Self.measure(url: url)
        } else {
            log("[Tempo] \(title) is protected or not on the device: asking the catalogue")
        }
        // No audio to read (a protected stream), or a measurement that failed: a public music
        // catalogue that lists tempos, by title and artist.
        if bpm == nil { bpm = await Self.lookup(title: title, artist: artist) }
        if let bpm {
            cache[id] = bpm
            UserDefaults.standard.set(cache, forKey: cacheKey)
            log(String(format: "[Tempo] %@: %.1f bpm", title, bpm))
        } else {
            log("[Tempo] \(title): could not be measured")
        }
        return bpm
    }

    /// The catalogue: a search for the track, then its record, which carries a tempo when known.
    nonisolated static func lookup(title: String, artist: String) async -> Double? {
        var query = "track:\"\(title)\""
        if !artist.isEmpty { query += " artist:\"\(artist)\"" }
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://api.deezer.com/search?q=\(q)&limit=3") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: searchURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let hits = json["data"] as? [[String: Any]] else { return nil }
            for hit in hits {
                guard let id = hit["id"] as? Int, let trackURL = URL(string: "https://api.deezer.com/track/\(id)") else { continue }
                let (trackData, _) = try await URLSession.shared.data(from: trackURL)
                if let track = try JSONSerialization.jsonObject(with: trackData) as? [String: Any], let bpm = track["bpm"] as? Double, bpm > 40 {
                    log(String(format: "[Tempo] Catalogue: %@ at %.1f bpm", title, bpm))
                    return bpm
                }
            }
            log("[Tempo] Catalogue has no tempo for \(title)")
        } catch {
            log("[Tempo] Catalogue lookup failed: \(error.localizedDescription)")
        }
        return await lookupKeyed(title: title, artist: artist)
    }

    /// A second catalogue of tempos that needs a key: `Documents/tempo-api-key.txt` holds it
    /// (dropped in through the Files app or Finder); without the file this is skipped.
    nonisolated static func lookupKeyed(title: String, artist: String) async -> Double? {
        let keyURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("tempo-api-key.txt")
        guard let key = try? String(contentsOf: keyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        let lookup = "song:\(title)" + (artist.isEmpty ? "" : " artist:\(artist)")
        guard let q = lookup.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.getsongbpm.com/search/?api_key=\(key)&type=both&lookup=\(q)") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let hits = json["search"] as? [[String: Any]] else { return nil }
            for hit in hits {
                if let text = hit["tempo"] as? String, let bpm = Double(text), bpm > 40 {
                    log(String(format: "[Tempo] Second catalogue: %@ at %.1f bpm", title, bpm))
                    return bpm
                }
            }
        } catch {
            log("[Tempo] Second catalogue failed: \(error.localizedDescription)")
        }
        return nil
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
