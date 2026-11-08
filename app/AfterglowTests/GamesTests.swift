import XCTest
import simd
import Speech
import AVFoundation
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

    /// A bumper's box lies along its wall, and no hole starts on a bumper (owner, 2026-11-08).
    @MainActor func testGolfBumpersLieAlongTheirWallsAndClearTheTee() {
        let rot = G.look(SIMD3(0, 0, -1))
        for direction in [SIMD2<Float>(1, 0), SIMD2(0, 1), SIMD2(-1, 0), SIMD2(0, -1), SIMD2(0.7071, 0.7071)] {
            let long = (rot * G.yaw(GolfGame.wallYaw(direction))).act(SIMD3(1, 0, 0))
            // In this frame the course's right is +x and its ahead is -z.
            XCTAssertEqual(long.x, direction.x, accuracy: 1e-4)
            XCTAssertEqual(-long.z, direction.y, accuracy: 1e-4)
        }
        let game = GolfGame()
        for hole in GolfGame.holes {
            for wall in game.walls(for: hole) {
                let ab = wall.b - wall.a
                let t = max(0, min(1, simd_dot(hole.tee - wall.a, ab) / simd_dot(ab, ab)))
                XCTAssertGreaterThan(simd_distance(hole.tee, wall.a + ab * t), 0.3, "\(hole.name): a bumper on the tee")
            }
        }
    }

    /// The tower keeps only what rests on the slab below; a clean miss keeps nothing.
    func testTowerOverlap() {
        let base = TowerGame.Slab(centre: .zero, size: SIMD2(0.16, 0.16))
        let kept = TowerGame.overlap(TowerGame.Slab(centre: SIMD2(0.06, 0), size: SIMD2(0.16, 0.16)), on: base)
        XCTAssertEqual(kept?.size.x ?? 0, 0.10, accuracy: 1e-5)
        XCTAssertEqual(kept?.size.y ?? 0, 0.16, accuracy: 1e-5)
        XCTAssertEqual(kept?.centre.x ?? 0, 0.03, accuracy: 1e-5)
        XCTAssertNil(TowerGame.overlap(TowerGame.Slab(centre: SIMD2(0.2, 0), size: SIMD2(0.16, 0.16)), on: base))
    }

    /// The garden plants on the nearest surface a ray crosses, else the floor, never upward.
    func testGardenLanding() {
        let eye = SIMD3<Float>(0, 1.6, 0)
        let down = SIMD3<Float>(0, -0.70710678, -0.70710678)
        XCTAssertEqual(GardenGame.landing(origin: eye, direction: down, floor: 0, tables: [])?.z ?? 0, -1.6, accuracy: 1e-4)
        let table = (centre: SIMD3<Float>(0, 0.8, -0.8), extent: SIMD2<Float>(0.5, 0.5))
        XCTAssertEqual(GardenGame.landing(origin: eye, direction: down, floor: 0, tables: [table])?.y ?? 0, 0.8, accuracy: 1e-4)
        XCTAssertNil(GardenGame.landing(origin: eye, direction: SIMD3(0, 1, 0), floor: 0, tables: []))
    }

    /// A ball left alone spirals out past the ring; a knock puts it back on a tighter orbit.
    func testOrbitSpiralsOutAndAKnockBringsItIn() {
        let r = OrbitalPong.ringRadius * 0.45
        var ball = OrbitalPong.Ball(position: SIMD2(r, 0), velocity: SIMD2(0, (0.22 / r).squareRoot()))
        var seconds: Float = 0
        while simd_length(ball.position) < OrbitalPong.ringRadius, seconds < 60 {
            ball = OrbitalPong.step(ball, thrust: OrbitalPong.baseThrust, dt: 1.0 / 240)
            seconds += 1.0 / 240
        }
        XCTAssertGreaterThan(seconds, 3, "time to reach it")
        XCTAssertLessThan(seconds, 60, "it does leave")
        let knocked = OrbitalPong.knocked(ball, speedUp: 1)
        XCTAssertLessThan(simd_length(knocked.position), OrbitalPong.ringRadius * 0.6)
    }

    /// Looking right steers right, ahead straight, at full lock by 25 degrees.
    func testDriveSteering() {
        let ahead = SIMD3<Float>(0, 0, -1), right = SIMD3<Float>(1, 0, 0)
        XCTAssertEqual(SkylineDrive.steering(forward: ahead, ahead: ahead, right: right), 0, accuracy: 1e-4)
        XCTAssertEqual(SkylineDrive.steering(forward: SIMD3(1, 0, -1), ahead: ahead, right: right), 1, accuracy: 1e-4)
        XCTAssertEqual(SkylineDrive.steering(forward: SIMD3(-0.1, 0, -1), ahead: ahead, right: right), -(atan(Float(0.1)) / (25 * .pi / 180)), accuracy: 1e-4)
    }

    /// The speech framework answers on its own thread: the callbacks must not be main-actor
    /// closures, or Swift stops the app there (owner, 2026-11-08: voice unlock crashed the app).
    @MainActor func testSpeechCallbacksSurviveOtherThreads() async {
        let status = await Dictation.askSpeechPermission { answer in
            nonisolated(unsafe) let answer = answer
            DispatchQueue.global().async { answer(.authorized) }
        }
        XCTAssertEqual(status, .authorized)

        let heard = expectation(description: "the result reaches the main actor")
        let handler = Dictation.resultHandler { text, done in
            XCTAssertNil(text)
            XCTAssertFalse(done)
            heard.fulfill()
        }
        DispatchQueue.global().async { handler(nil, nil) }
        await fulfillment(of: [heard], timeout: 2)

        let request = SFSpeechAudioBufferRecognitionRequest()
        let tap = Dictation.tap(into: request)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        nonisolated(unsafe) let unsafeBuffer = buffer
        let tapped = expectation(description: "the tap runs off the main thread")
        DispatchQueue.global().async {
            tap(unsafeBuffer, AVAudioTime(hostTime: 0))
            tapped.fulfill()
        }
        await fulfillment(of: [tapped], timeout: 2)
    }

    /// A panel hung under a window stays under it, from where the viewer stands (owner,
    /// 2026-11-08: the keyboard rode up over the window it types into).
    func testHungPanelClearsTheWindowFromTheEye() {
        var w = BrowserWindow()
        w.centre = SIMD3(0, 0.04, -1.4)
        w.right = SIMD3(1, 0, 0)
        w.up = SIMD3(0, 1, 0)
        let height: Float = 0.4
        let hung = w.hanging(height: height)
        let top = hung.centre + hung.up * (height / 2)
        let bottom = hung.centre - hung.up * (height / 2)
        // The window's bottom edge and the panel's top edge as the eye sees them (y over distance).
        let eye = SIMD3<Float>(0, 0, 0)
        func slope(_ p: SIMD3<Float>) -> Float { (p.y - eye.y) / (eye.z - p.z) }
        let windowBottom = w.centre - w.up * (w.heightMeters / 2)
        XCTAssertLessThan(slope(top), slope(windowBottom))
        XCTAssertLessThan(bottom.y, top.y)
        XCTAssertGreaterThan(bottom.z, top.z, "the bottom edge is nearer, like a keyboard on a desk")
    }

    /// Only this song's record gives a tempo: another song's is worse than none.
    func testTempoCatalogueMatching() {
        let hits = [
            TempoAnalyzer.CatalogueHit(id: "cover", title: "Dracula", artists: ["Someone Else"]),
            TempoAnalyzer.CatalogueHit(id: "other", title: "Dracula Teeth", artists: ["Tame Impala"]),
            TempoAnalyzer.CatalogueHit(id: "guest", title: "Dracula (with JENNIE)", artists: ["Tame Impala", "JENNIE"]),
            TempoAnalyzer.CatalogueHit(id: "master", title: "Dracula - Remastered 2024", artists: ["Tame Impala"]),
        ]
        XCTAssertEqual(TempoAnalyzer.matches(hits, title: "Dracula", artist: "Tame Impala"), ["guest", "master"])
        XCTAssertEqual(TempoAnalyzer.matches(hits, title: "Dracula", artist: ""), ["cover", "guest", "master"])
        XCTAssertEqual(TempoAnalyzer.matches(hits, title: "Dracula", artist: "Tame Impala & JENNIE"), ["guest", "master"])
        XCTAssertTrue(TempoAnalyzer.matches(hits, title: "Unwritten", artist: "Tame Impala").isEmpty)

        XCTAssertEqual(TempoAnalyzer.strippingVersion("Dracula (with JENNIE) - Remastered"), "Dracula")
        XCTAssertEqual(TempoAnalyzer.strippingVersion("Chop Suey!"), "Chop Suey!")

        XCTAssertEqual(TempoAnalyzer.tempo(ofTrack: ["audio_features": ["tempo": 115.0]]), 115)
        XCTAssertNil(TempoAnalyzer.tempo(ofTrack: ["audio_features": ["tempo": 0]]), "unknown tempos are not beats")
        XCTAssertNil(TempoAnalyzer.tempo(ofTrack: ["audio_features": NSNull()]))
    }
}
