import Foundation

/// Photospheres from an AI world generator: a hosted service that turns a
/// prompt into an equirectangular 360 image. The API key is read from Documents/skybox-api-key.txt
/// (dropped in through the Files app or Finder); the generated image is saved to
/// Documents/Environments and becomes a place. Logs [Skybox].
final class SkyboxGenerator: @unchecked Sendable {
    static let keyFile = "skybox-api-key.txt"
    private let base = URL(string: "https://backend.blockadelabs.com/api/v1")!

    static var key: String? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(keyFile)
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var environmentsFolder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Environments")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Asks for a skybox and waits for it (a minute or two), returning the saved file.
    func generate(prompt: String, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        guard let key = Self.key, !key.isEmpty else { throw Failure(description: String(localized: "No API key in Documents/\(Self.keyFile)")) }
        var request = URLRequest(url: base.appendingPathComponent("skybox"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": prompt])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = json["id"] as? Int else {
            throw Failure(description: String(localized: "The generator refused the request (\((response as? HTTPURLResponse)?.statusCode ?? 0))"))
        }
        log("[Skybox] Generating \(id): \(prompt)")
        progress(String(localized: "Generating…"))
        for attempt in 0..<90 {
            try await Task.sleep(for: .seconds(3))
            var poll = URLRequest(url: base.appendingPathComponent("imagine/requests/\(id)"))
            poll.setValue(key, forHTTPHeaderField: "x-api-key")
            let (pollData, _) = try await URLSession.shared.data(for: poll)
            guard let pollJson = try JSONSerialization.jsonObject(with: pollData) as? [String: Any],
                  let req = pollJson["request"] as? [String: Any] else { continue }
            let status = req["status"] as? String ?? "?"
            progress("\(status)… (\(attempt * 3) s)")
            if status == "complete", let file = req["file_url"] as? String, let url = URL(string: file) {
                let (image, _) = try await URLSession.shared.data(from: url)
                let name = "skybox-\(id)-" + prompt.prefix(24).replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression) + ".jpg"
                let saved = Self.environmentsFolder.appendingPathComponent(name)
                try image.write(to: saved)
                log("[Skybox] Saved \(name) (\(image.count / 1024) KB)")
                return saved
            }
            if status == "error" || status == "abort" { throw Failure(description: "The generator failed: \(req["error_message"] ?? status)") }
        }
        throw Failure(description: String(localized: "The generator took too long"))
    }
}
