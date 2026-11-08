@preconcurrency import WebKit
import Foundation

/// The contract between the app and a page, the same as the Unity app's (`AfterglowWebXR.mm`):
/// three user scripts at document start (the helper, `window.__afterglowConfig`, the WebXR shim),
/// one message handler named `afterglow` whose messages carry an `event`, and a handful of
/// `window.__afterglow*` functions the app calls. The JavaScript is shared with the Unity app:
/// the shim and the start page come from `Assets/StreamingAssets/webxr/`, the helper is a copy
/// of the plugin's.
enum WebBridge {
    static let handlerName = "afterglow"

    /// The viewer, lens and screen the shim builds its stereo rendering from.
    struct Config {
        var screenMeters: SIMD2<Float>
        var screenToLens: Float
        var interLens: Float
        var yEyeOffset: Float
        var k: [Float]
        var fov: [SIMD4<Float>]      // per eye, radians, (left, right, bottom, top)
        var hasPosition: Bool
        var screenPixels: SIMD2<Int>
        var renderScale: Int
        var eyeHeight: Float = 1.6

        var json: String {
            func f(_ v: Float) -> String { String(format: "%.6f", v) }
            let fovText = fov.map { "[\(f($0.x)),\(f($0.y)),\(f($0.z)),\(f($0.w))]" }.joined(separator: ",")
            return "{\"screen\":[\(f(screenMeters.x)),\(f(screenMeters.y))],\"screenToLens\":\(f(screenToLens)),\"interLens\":\(f(interLens))," +
                "\"yEyeOffset\":\(f(yEyeOffset)),\"k\":[\(k.map(f).joined(separator: ","))],\"fov\":[\(fovText)],\"hasPosition\":\(hasPosition)," +
                "\"screenPixels\":[\(screenPixels.x),\(screenPixels.y)],\"renderScale\":\(renderScale),\"mono\":false,\"monoFov\":1.0472,\"eyeHeight\":\(f(eyeHeight))}"
        }
    }

    @MainActor
    static func userScripts(config: Config) -> [WKUserScript] {
        var scripts: [WKUserScript] = []
        if let helper = Bundle.main.url(forResource: "afterglow-helper", withExtension: "js"), let text = try? String(contentsOf: helper, encoding: .utf8) {
            scripts.append(WKUserScript(source: text, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        } else {
            log("[WebXR] The helper script is missing from the bundle")
        }
        scripts.append(WKUserScript(source: "window.__afterglowConfig = \(config.json);", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if let shim = Bundle.main.url(forResource: "afterglow-webxr", withExtension: "js"), let text = try? String(contentsOf: shim, encoding: .utf8) {
            scripts.append(WKUserScript(source: text, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        } else {
            log("[WebXR] The WebXR shim is missing from the bundle")
        }
        return scripts
    }

    /// The native app's own start page, else the one shared with the Unity app.
    static var startPage: URL? { Bundle.main.url(forResource: "start", withExtension: "html") ?? Bundle.main.url(forResource: "index", withExtension: "html") }
    static let startPageAddress = "afterglow://start"

    /// A JavaScript string literal, escaped the way the plugin does it.
    static func jsString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]), var literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        literal.removeFirst()
        literal.removeLast()
        return literal.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    // The calls, as the plugin makes them.
    static func pose(_ p: SIMD3<Float>, _ q: simd_quatf) -> String {
        String(format: "window.__afterglowPose&&window.__afterglowPose(%.5f,%.5f,%.5f,%.6f,%.6f,%.6f,%.6f)", p.x, p.y, p.z, q.vector.x, q.vector.y, q.vector.z, q.vector.w)
    }
    static func hands(_ values: [Float]) -> String {
        "window.__afterglowHands&&window.__afterglowHands([" + values.prefix(256).map { String(format: "%.4f", $0) }.joined(separator: ",") + "])"
    }
    static let select = "window.__afterglowSelect&&window.__afterglowSelect()"
    static let endSession = "window.__afterglowEndSession&&window.__afterglowEndSession()"
    static func click(_ u: Float, _ v: Float) -> String { String(format: "window.__afterglowClick&&window.__afterglowClick(%.5f,%.5f)", u, v) }
    static func hover(_ u: Float, _ v: Float) -> String { String(format: "window.__afterglowHover&&window.__afterglowHover(%.5f,%.5f)", u, v) }
    static func scroll(_ u: Float, _ v: Float, _ dx: Float, _ dy: Float) -> String {
        String(format: "window.__afterglowScroll&&window.__afterglowScroll(%.5f,%.5f,%.2f,%.2f)", u, v, dx, dy)
    }
    static func type(_ text: String) -> String { "window.__afterglowType&&window.__afterglowType(\(jsString(text)))" }
    static func key(_ name: String) -> String { "window.__afterglowKey&&window.__afterglowKey(\(jsString(name)))" }
    static func fill(_ user: String, _ pass: String) -> String { "window.__afterglowFill&&window.__afterglowFill(\(jsString(user)),\(jsString(pass)))" }
    static func lists(_ json: String) -> String { "window.__afterglowLists&&window.__afterglowLists(\(json))" }

    /// What a typed address means: a URL as given, a host with https added, or a search.
    /// The Unity app's `WebBrowser.NormalizeAddress`.
    static func normalizeAddress(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.contains("://") || trimmed.hasPrefix("about:") || trimmed.hasPrefix("afterglow:") { return trimmed }
        let looksLikeHost = !trimmed.contains(" ") && (trimmed.contains(".") || trimmed.hasPrefix("localhost")) && !trimmed.hasSuffix(".")
        if looksLikeHost { return "https://" + trimmed }
        let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "&", with: "%26") ?? trimmed
        return "https://duckduckgo.com/?q=" + escaped
    }

    /// A page URL shortened for the address bar: the host and a little of the path.
    static func shorten(_ url: String) -> String {
        if url == startPageAddress || url.hasPrefix("file://") { return "Start" }
        guard let u = URL(string: url), let host = u.host else { return url }
        let path = u.path == "/" ? "" : u.path
        let shown = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return path.count > 24 ? shown + String(path.prefix(22)) + "…" : shown + path
    }
}
