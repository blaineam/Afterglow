import XCTest
import simd
@testable import Afterglow

/// The coaster's course and the lock's spoken digits: the parts of the 2026-11-08 round that are
/// pure computation, checked without the phone.
final class GamesTests: XCTestCase {
    /// The course is one smooth closed curve: no gap anywhere, the end runs back into the start,
    /// no sudden turn of the car, and the brakes bring it to rest (owner, 2026-11-08: the track
    /// "jetted" up to the start and the car jumped back to the station).
    @MainActor
    func testCoasterCourseIsClosedAndSmooth() {
        for wantLoop in [true, false] {
            let course = GridRide.makeCourse(radius: 120, liftHeight: 20, turn: wantLoop ? 1 : -1,
                                             wobble: [(2, 0.1), (3, -0.05)], hills: [13, 9, 6, 4], wantLoop: wantLoop)
            let poses = course.poses
            XCTAssertGreaterThan(poses.count, 500)
            // The start is under the rider, heading -z.
            XCTAssertLessThan(simd_length(poses[0].position), 0.01)
            XCTAssertLessThan(simd_distance(poses[0].orientation.act(SIMD3(0, 0, -1)), SIMD3(0, 0, -1)), 0.05)
            var worstGap: Float = 0, worstTurn: Float = 0, worstAt = 0
            for i in 0..<poses.count {
                let a = poses[i], b = poses[(i + 1) % poses.count]
                worstGap = max(worstGap, simd_distance(a.position, b.position))
                let turn = acos(min(1, abs(simd_dot(a.orientation.vector, b.orientation.vector)))) * 2
                if turn > worstTurn { worstTurn = turn; worstAt = i }
            }
            XCTAssertLessThan(worstGap, 0.75, "a gap in the track (the end back to the start included)")
            let up = poses[worstAt].orientation.act(SIMD3(0, 1, 0)), f = poses[worstAt].orientation.act(SIMD3(0, 0, -1))
            XCTAssertLessThan(worstTurn, 0.35, "the car turns too sharply between poses \(worstAt) and \(worstAt + 1) of \(poses.count) (loop \(String(describing: course.loop)), forward \(f), up \(up))")
            // At rest at the station, moving everywhere else.
            XCTAssertLessThan(course.speeds.last ?? 99, 1.0)
            XCTAssertGreaterThan(course.speeds.dropLast(60).min() ?? 0, 0.3)
            XCTAssertGreaterThan(course.seconds, 40)
            XCTAssertLessThan(course.seconds, 400)
            if wantLoop { XCTAssertNotNil(course.loop, "a 20 m lift gives the speed for a loop") }
            else { XCTAssertNil(course.loop) }
        }
    }

    /// A spoken passcode: numerals and the words for digits, whatever the recogniser wrote.
    func testSpokenDigits() {
        XCTAssertEqual(AppLock.digits(from: "one two three four five six"), "123456")
        XCTAssertEqual(AppLock.digits(from: "123 456"), "123456")
        XCTAssertEqual(AppLock.digits(from: "Four, oh, Eight. Nine two zero"), "408920")
        XCTAssertEqual(AppLock.digits(from: "hello"), "")
        XCTAssertEqual(AppLock.digits(from: "12-34-56"), "123456")
    }
}
