import Foundation

/// What the browser remembers between runs: open tabs (their URLs and titles), history and
/// bookmarks, as JSON in Documents. Private tabs are never written.
struct BrowserRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var url: String
    var title: String
    var date: Date = Date()
}

struct BrowserState: Codable, Sendable {
    var tabs: [BrowserRecord] = []
    var currentTab: Int = 0
    var history: [BrowserRecord] = []
    var bookmarks: [BrowserRecord] = []
}

enum BrowserStore {
    private static let maxHistory = 500
    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("browser.json")
    }

    static func load() -> BrowserState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(BrowserState.self, from: data) else {
            return BrowserState()
        }
        return state
    }

    static func save(_ state: BrowserState) {
        var trimmed = state
        if trimmed.history.count > maxHistory { trimmed.history = Array(trimmed.history.prefix(maxHistory)) }
        if let data = try? JSONEncoder().encode(trimmed) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Adds a visit to the front of the history, replacing an older visit to the same URL.
    static func visited(_ record: BrowserRecord, in state: inout BrowserState) {
        state.history.removeAll { $0.url == record.url }
        state.history.insert(record, at: 0)
    }

    static func toggleBookmark(_ record: BrowserRecord, in state: inout BrowserState) -> Bool {
        if let index = state.bookmarks.firstIndex(where: { $0.url == record.url }) {
            state.bookmarks.remove(at: index)
            return false
        }
        state.bookmarks.insert(record, at: 0)
        return true
    }
}
