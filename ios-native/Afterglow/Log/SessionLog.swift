import Foundation
import os

/// The app's tagged log lines ([Stereo], [Pose], [Frames], [Thermal] and so on) written to
/// Documents/session.log, replaced at each launch with the previous one kept as
/// session-previous.log, so `Tools/native_build_and_run.sh` can copy it back as the Unity app's
/// scripts do. Lines carry the same shape as Unity's player log on the phone:
/// `HH:mm:ss.fff Log [Tag] message`, so the two logs can be read by the same tools.
final class SessionLog: Sendable {
    static let shared = SessionLog()

    private let handle: FileHandle?
    private let lock = NSLock()
    private let formatter: DateFormatter
    private let console = Logger(subsystem: "com.wemiller.afterglow.native", category: "session")

    private init() {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let path = documents.appendingPathComponent("session.log")
        let previous = documents.appendingPathComponent("session-previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: path, to: previous)
        FileManager.default.createFile(atPath: path.path, contents: nil)
        handle = try? FileHandle(forWritingTo: path)
        log("[Stereo] Session log: \(path.path)")
    }

    func log(_ message: String, level: String = "Log") {
        let line = "\(formatter.string(from: Date())) \(level) \(message)\n"
        console.log("\(message, privacy: .public)")
        lock.lock()
        defer { lock.unlock() }
        if let data = line.data(using: .utf8) {
            try? handle?.write(contentsOf: data)
        }
    }

    func warning(_ message: String) { log(message, level: "Warning") }
    func error(_ message: String) { log(message, level: "Error") }
}

/// Shorthand used throughout the app.
func log(_ message: String) { SessionLog.shared.log(message) }
