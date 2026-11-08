/// Whether the thumb and index fingertips are pinched together, from how far apart they are. A
/// pinch starts closer than it ends, so the state doesn't flicker near the threshold (the Unity
/// app's 2.5 cm to close, 4.5 cm to open), and ends only after the tips have stayed apart for a
/// few results, with the tips seen: a hand turning hides a fingertip, Vision then guesses it, and
/// one guessed result broke a held pinch (2026-11-06). A guessed tip holds the state as it is.
struct PinchDetector {
    let closeDistance: Float
    let openDistance: Float
    /// Results in a row past the open distance before a pinch ends, and within the close distance
    /// (with a start allowed) before one begins: a C-shaped hand turned so its tips cross in the
    /// image passes through that in less time than a pinch is held (owner, 2026-11-06).
    let releaseResults: Int
    var startResults: Int
    private(set) var isPinched = false
    private var openRun = 0
    private var closeRun = 0
    private var pausedRun = 0

    /// 2 cm to close and three results in a row: the phone's log had real pinches start at a median
    /// 1.6 cm, and the quarter that started between 2.2 and 3 cm fired before the fingers met
    /// (owner, 2026-11-08). 4.5 cm to open.
    init(closeDistance: Float = 0.02, openDistance: Float = 0.045, releaseResults: Int = 3, startResults: Int = 3) {
        self.closeDistance = closeDistance
        self.openDistance = openDistance
        self.releaseResults = releaseResults
        self.startResults = startResults
    }

    /// Takes the fingertips' distance in metres. `allowStart` false keeps an open hand open (the
    /// tips at the image's edge, or the palm edge-on); `tipsSure` false means a tip was not really
    /// seen, so a held pinch stays as it is; `startCounts` false (both tips guessed) neither counts
    /// towards a start nor clears one under way.
    ///
    /// A start counts results under the close distance and keeps its count through results
    /// between the close and open distances and through results that cannot count, for a few of
    /// them: a quick pinch and release had to be held, since one guessed or wobbling result
    /// anywhere in it cleared the count (owner, 2026-11-08: "I have to pinch and hold every time").
    @discardableResult
    mutating func update(tipDistance: Float, allowStart: Bool = true, tipsSure: Bool = true, startCounts: Bool = true) -> Bool {
        if isPinched {
            guard tipsSure else { return isPinched }
            if tipDistance > openDistance {
                openRun += 1
                if openRun >= releaseResults {
                    isPinched = false
                    openRun = 0
                }
            } else {
                openRun = 0
            }
        } else if !allowStart || tipDistance > openDistance {
            closeRun = 0
            pausedRun = 0
        } else if tipDistance < closeDistance && startCounts {
            closeRun += 1
            pausedRun = 0
            if closeRun >= startResults {
                isPinched = true
                openRun = 0
                closeRun = 0
            }
        } else if closeRun > 0 {
            // Between the distances, or a guessed tip: the count waits, for a few results.
            pausedRun += 1
            if pausedRun > Self.maxPausedResults { closeRun = 0; pausedRun = 0 }
        }
        return isPinched
    }

    /// Results a start's count waits through before it clears: about a sixth of a second.
    static let maxPausedResults = 4

    /// A hand back in view: its pinch stands only if the tips are still together.
    mutating func resume(tipDistance: Float) {
        if isPinched && tipDistance > closeDistance { isPinched = false }
        openRun = 0
        closeRun = 0
        pausedRun = 0
    }

    mutating func reset() {
        isPinched = false
        openRun = 0
        closeRun = 0
        pausedRun = 0
    }
}
