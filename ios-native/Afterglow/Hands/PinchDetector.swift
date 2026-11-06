/// Whether the thumb and index fingertips are pinched together, from how far apart they are. A
/// pinch starts closer than it ends, so the state doesn't flicker near the threshold (the Unity
/// app's 2.5 cm to close, 4.5 cm to open), and ends only after the tips have stayed apart for a
/// few results, with the tips seen: a hand turning hides a fingertip, Vision then guesses it, and
/// one guessed result broke a held pinch (2026-11-06). A guessed tip holds the state as it is.
struct PinchDetector {
    let closeDistance: Float
    let openDistance: Float
    /// Results in a row past the open distance before a pinch ends (about 100 ms at 30 images/s).
    let releaseResults: Int
    private(set) var isPinched = false
    private var openRun = 0

    init(closeDistance: Float = 0.025, openDistance: Float = 0.045, releaseResults: Int = 3) {
        self.closeDistance = closeDistance
        self.openDistance = openDistance
        self.releaseResults = releaseResults
    }

    /// Takes the fingertips' distance in metres. `allowStart` false keeps an open hand open (the
    /// tips at the image's edge, where the model guesses); `tipsSure` false means a tip was not
    /// really seen, so nothing changes.
    @discardableResult
    mutating func update(tipDistance: Float, allowStart: Bool = true, tipsSure: Bool = true) -> Bool {
        guard tipsSure else { return isPinched }
        if isPinched {
            if tipDistance > openDistance {
                openRun += 1
                if openRun >= releaseResults {
                    isPinched = false
                    openRun = 0
                }
            } else {
                openRun = 0
            }
        } else if allowStart && tipDistance < closeDistance {
            isPinched = true
            openRun = 0
        }
        return isPinched
    }

    mutating func reset() {
        isPinched = false
        openRun = 0
    }
}
