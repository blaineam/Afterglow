import XCTest
@testable import Afterglow

/// The browser's pure parts: address normalisation, shortening, the store's rules, the bridge's
/// string escaping and config.
final class BrowserTests: XCTestCase {
    func testNormalizeAddress() {
        XCTAssertEqual(WebBridge.normalizeAddress("https://example.com/a"), "https://example.com/a")
        XCTAssertEqual(WebBridge.normalizeAddress("example.com"), "https://example.com")
        XCTAssertEqual(WebBridge.normalizeAddress("localhost:8080"), "https://localhost:8080")
        XCTAssertEqual(WebBridge.normalizeAddress("three.js cubes"), "https://duckduckgo.com/?q=three.js%20cubes")
        XCTAssertEqual(WebBridge.normalizeAddress("  "), "")
        XCTAssertEqual(WebBridge.normalizeAddress("afterglow://start"), "afterglow://start")
    }

    func testShorten() {
        XCTAssertEqual(WebBridge.shorten("https://www.example.com/"), "example.com")
        XCTAssertEqual(WebBridge.shorten("afterglow://start"), "Start")
        XCTAssertTrue(WebBridge.shorten("https://example.com/a/very/long/path/that/goes/on/and/on").hasSuffix("…"))
    }

    func testJsStringEscapes() {
        XCTAssertEqual(WebBridge.jsString("plain"), "\"plain\"")
        XCTAssertEqual(WebBridge.jsString("a\"b\\c"), "\"a\\\"b\\\\c\"")
        XCTAssertFalse(WebBridge.jsString("x\u{2028}y").contains("\u{2028}"))
    }

    func testConfigJsonCarriesTheViewer() {
        let config = WebBridge.Config(screenMeters: SIMD2(0.1584, 0.0729), screenToLens: 0.0393, interLens: 0.0639, yEyeOffset: 0.03645,
                                      k: [0.3358, 0.5535], fov: [SIMD4(1.0472, 0.8727, 1.0053, 1.0053), SIMD4(0.8727, 1.0472, 1.0053, 1.0053)],
                                      hasPosition: true, screenPixels: SIMD2(2868, 1320), renderScale: 100)
        let json = config.json
        let data = try! JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual((data["screen"] as! [Double])[0], 0.1584, accuracy: 1e-6)
        XCTAssertEqual((data["k"] as! [Double]).count, 2)
        XCTAssertEqual((data["fov"] as! [[Double]]).count, 2)
        XCTAssertEqual(data["hasPosition"] as! Bool, true)
        XCTAssertEqual((data["screenPixels"] as! [Int])[0], 2868)
        XCTAssertEqual(data["mono"] as! Bool, false)
    }

    func testHistoryAndBookmarks() {
        var state = BrowserState()
        BrowserStore.visited(BrowserRecord(url: "https://a.com", title: "A"), in: &state)
        BrowserStore.visited(BrowserRecord(url: "https://b.com", title: "B"), in: &state)
        BrowserStore.visited(BrowserRecord(url: "https://a.com", title: "A again"), in: &state)
        XCTAssertEqual(state.history.map(\.url), ["https://a.com", "https://b.com"])
        XCTAssertEqual(state.history.first?.title, "A again")
        XCTAssertTrue(BrowserStore.toggleBookmark(BrowserRecord(url: "https://a.com", title: "A"), in: &state))
        XCTAssertEqual(state.bookmarks.count, 1)
        XCTAssertFalse(BrowserStore.toggleBookmark(BrowserRecord(url: "https://a.com", title: "A"), in: &state))
        XCTAssertEqual(state.bookmarks.count, 0)
    }

    func testHeadsetTapTiming() {
        let detector = HeadsetTapDetector()
        // Fed with made-up motion: a spike, quiet, a spike within the window is a double tap.
        func sample(_ g: Double, at t: Double) -> Int {
            let motion = FakeMotion(magnitude: g, time: t)
            return detector.feed(magnitude: Float(motion.magnitude), time: motion.time)
        }
        XCTAssertEqual(sample(0.1, at: 0), 0)
        XCTAssertEqual(sample(1.5, at: 0.1), 1)
        XCTAssertEqual(sample(1.5, at: 0.15), 0)     // the same tap's ringing
        XCTAssertEqual(sample(1.5, at: 0.4), 2)      // the second tap
        XCTAssertEqual(sample(1.5, at: 2.0), 1)      // too late to pair: a new first
    }

    struct FakeMotion { var magnitude: Double; var time: Double }

    /// A site's say over the hands is its own, and the button cycles ask, always, never.
    func testHandAccessPerSite() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "afterglow.test.handaccess"))
        defaults.removePersistentDomain(forName: "afterglow.test.handaccess")
        XCTAssertEqual(HandAccess.policy(for: "a.example", in: defaults), .ask)
        HandAccess.set(.always, for: "a.example", in: defaults)
        XCTAssertEqual(HandAccess.policy(for: "a.example", in: defaults), .always)
        XCTAssertEqual(HandAccess.policy(for: "b.example", in: defaults), .ask, "one site's answer is not another's")
        XCTAssertEqual(HandAccess.ask.next, .always)
        XCTAssertEqual(HandAccess.always.next, .never)
        XCTAssertEqual(HandAccess.never.next, .ask)
        HandAccess.set(.ask, for: "a.example", in: defaults)
        XCTAssertEqual(HandAccess.policy(for: "a.example", in: defaults), .ask)
        defaults.removePersistentDomain(forName: "afterglow.test.handaccess")
    }

    /// A correction goes in at the cursor, and what comes after it stays (owner, 2026-11-08).
    func testTextEditCorrectsInPlace() {
        var edit = TextEdit("helo world")
        XCTAssertEqual(edit.caret, 10)
        for _ in 0..<7 { edit.left() }
        XCTAssertEqual(edit.before, "hel")
        edit.insert("l")
        XCTAssertEqual(edit.text, "hello world")
        XCTAssertEqual(edit.before, "hell")
        edit.backspace()
        XCTAssertEqual(edit.text, "helo world")
        edit.right()
        XCTAssertEqual(edit.before, "helo")
        for _ in 0..<20 { edit.right() }
        XCTAssertEqual(edit.caret, 10)
        for _ in 0..<20 { edit.left() }
        XCTAssertEqual(edit.caret, 0)
        edit.backspace()
        XCTAssertEqual(edit.text, "helo world", "nothing before the start to delete")
        var emoji = TextEdit("a😀b")
        emoji.left(); emoji.left()
        XCTAssertEqual(emoji.before, "a", "an emoji is one step")
        XCTAssertFalse(emoji.key("Enter"))
        emoji.key("Clear")
        XCTAssertEqual(emoji, TextEdit())
    }

    /// The bar shows the part round the cursor and says where it runs on.
    @MainActor func testKeyboardBarLine() {
        XCTAssertEqual(KeyboardPanel.fieldLine(before: "", after: ""), "▏")
        XCTAssertEqual(KeyboardPanel.fieldLine(before: "hel", after: "lo"), "hel▏lo")
        let long = String(repeating: "a", count: 100)
        let line = KeyboardPanel.fieldLine(before: long, after: long, fits: 40)
        XCTAssertTrue(line.hasPrefix("…"))
        XCTAssertTrue(line.hasSuffix("…"))
        XCTAssertTrue(line.contains("▏"))
        XCTAssertLessThanOrEqual(line.count, 43)
        XCTAssertTrue(KeyboardPanel.fieldLine(before: long, after: "", fits: 40).hasSuffix("▏"))
    }
}
