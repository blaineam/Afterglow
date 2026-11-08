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

    /// The catalogue: audiometa.io's free music data API. A search by title and artist, then the
    /// closest track's record, whose audio features carry a tempo when known. Only the title and
    /// artist are sent, and only when the song's own audio can't be read.
    nonisolated static func lookup(title: String, artist: String) async -> Double? {
        guard let key = apiKey() else {
            log("[Tempo] No catalogue key in this build")
            return nil
        }
        var components = URLComponents(string: "https://api.audiometa.io/v1/search")
        components?.queryItems = [URLQueryItem(name: "q", value: artist.isEmpty ? title : "\(title) \(artist)"),
                                  URLQueryItem(name: "type", value: "track"), URLQueryItem(name: "limit", value: "10")]
        guard let searchURL = components?.url else { return nil }
        do {
            guard let search = try await catalogue(searchURL, key: key), let tracks = search["tracks"] as? [String: Any],
                  let items = tracks["items"] as? [[String: Any]] else { return nil }
            let hits = items.compactMap { item -> CatalogueHit? in
                guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                return CatalogueHit(id: id, title: name, artists: artists)
            }
            for id in matches(hits, title: title, artist: artist).prefix(3) {
                guard let trackURL = URL(string: "https://api.audiometa.io/v1/tracks/\(id)"), let track = try await catalogue(trackURL, key: key),
                      let bpm = tempo(ofTrack: track) else { continue }
                log(String(format: "[Tempo] Catalogue: %@ at %.1f bpm", title, bpm))
                return bpm
            }
            log("[Tempo] Catalogue has no tempo for \(title)")
        } catch {
            log("[Tempo] Catalogue lookup failed: \(error.localizedDescription)")
        }
        return nil
    }

    struct CatalogueHit: Sendable {
        var id: String
        var title: String
        var artists: [String]
    }

    /// The hits that are this song, best first: the same title once versions and guests are set
    /// aside ("(feat. …)", "- Remastered 2011"), by the same artist when one is known. Another
    /// song's tempo is worse than none, so anything else is left out.
    nonisolated static func matches(_ hits: [CatalogueHit], title: String, artist: String) -> [String] {
        let wanted = plain(title)
        let by = artist.lowercased()
        let same = hits.filter { plain($0.title) == wanted }
        guard !by.isEmpty else { return same.map(\.id) }
        return same.filter { hit in
            hit.artists.contains { name in
                let n = name.lowercased()
                return by.contains(n) || n.contains(by)
            }
        }.map(\.id)
    }

    nonisolated private static func plain(_ title: String) -> String {
        var t = title.lowercased()
        for pattern in [#"\s*[\(\[][^\)\]]*[\)\]]"#, #"\s+-\s+.*$"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// A track record's tempo, when it has a believable one.
    nonisolated static func tempo(ofTrack track: [String: Any]) -> Double? {
        guard let features = track["audio_features"] as? [String: Any], let bpm = (features["tempo"] as? NSNumber)?.doubleValue, bpm > 40 else { return nil }
        return bpm
    }

    nonisolated private static func catalogue(_ url: URL, key: String) async throws -> [String: Any]? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")   // the key stays out of the URL and any log of it
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            log("[Tempo] Catalogue answered \(http.statusCode)")
            return nil
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The catalogue's key: written into the app at build time from the builder's Keychain by
    /// Tools/embed_tempo_key.sh, so it is never in the repository. Masked, not secret: anyone can
    /// dig it out of the app, and all it allows is reading a free catalogue.
    nonisolated private static func apiKey() -> String? {
        guard let url = Bundle.main.url(forResource: "tempo-key", withExtension: "dat"), let data = try? Data(contentsOf: url) else { return nil }
        let key = String(decoding: data.map { $0 ^ 0x5A }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
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
