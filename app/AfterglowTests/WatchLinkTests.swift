import XCTest
import WatchConnectivity
@testable import Afterglow

/// The phone's side of the Apple Watch link. The end-to-end check, over a paired phone and watch
/// Simulator, is Tools/test_watch_link.sh.
final class WatchLinkTests: XCTestCase {
    /// WatchConnectivity delivers on its own queue, and the callbacks are set from main-actor code.
    /// They have to arrive on the main actor; called straight from that queue they stop the app.
    @MainActor func testMessagesFromTheSessionsQueueReachTheMainActor() async {
        let receiver = WatchReceiver()
        let selected = expectation(description: "the select arrives")
        let scrolled = expectation(description: "the scroll arrives")
        receiver.onSelect = {
            MainActor.assertIsolated()
            selected.fulfill()
        }
        receiver.onScroll = { dy in
            MainActor.assertIsolated()
            XCTAssertEqual(dy, 40)
            scrolled.fulfill()
        }
        DispatchQueue.global().async {
            receiver.session(WCSession.default, didReceiveMessage: ["action": "select"])
            receiver.session(WCSession.default, didReceiveMessage: ["action": "scroll", "dy": 40.0])
        }
        await fulfillment(of: [selected, scrolled], timeout: 2)
    }

    /// A message from something else, or a scroll without its distance, does nothing.
    @MainActor func testUnknownMessagesAreIgnored() async {
        let receiver = WatchReceiver()
        let nothing = expectation(description: "no callback")
        nothing.isInverted = true
        receiver.onSelect = { nothing.fulfill() }
        receiver.onScroll = { _ in nothing.fulfill() }
        DispatchQueue.global().async {
            receiver.session(WCSession.default, didReceiveMessage: ["action": "selfdestruct"])
            receiver.session(WCSession.default, didReceiveMessage: ["action": "scroll"])
        }
        await fulfillment(of: [nothing], timeout: 0.3)
    }
}
