import Foundation

/// Text being typed with a cursor in it, for what the app owns itself: the address bar, the Files
/// search, a place's prompt. Typing and deleting happen at the cursor, and the arrows move it, so
/// a mistake can be fixed without deleting everything after it (owner, 2026-11-08). The cursor
/// counts whole characters, so an emoji is one step.
struct TextEdit: Equatable, Sendable {
    private(set) var text: String
    private(set) var caret: Int

    init(_ text: String = "") {
        self.text = text
        caret = text.count
    }

    var before: String { String(text.prefix(caret)) }
    var after: String { String(text.dropFirst(caret)) }

    mutating func insert(_ new: String) {
        text = before + new + after
        caret += new.count
    }

    mutating func backspace() {
        guard caret > 0 else { return }
        text = String(text.prefix(caret - 1)) + after
        caret -= 1
    }

    mutating func left() { caret = max(0, caret - 1) }
    mutating func right() { caret = min(text.count, caret + 1) }
    mutating func clear() { text = ""; caret = 0 }

    /// A key from the keyboard panel. False for one this doesn't handle (Enter).
    @discardableResult
    mutating func key(_ name: String) -> Bool {
        switch name {
        case "Backspace": backspace()
        case "Clear": clear()
        case "ArrowLeft": left()
        case "ArrowRight": right()
        default: return false
        }
        return true
    }
}
