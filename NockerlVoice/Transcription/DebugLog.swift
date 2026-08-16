import Foundation

/// Lightweight append-only file logger for on-device debugging. The unified log
/// was not surfacing this self-signed app's `os_log` over SSH, so we write a file
/// that can be read directly: `~/Library/Logs/<namespace>/debug.log`, under the
/// production bundle id that is `~/Library/Logs/NockerlVoice/debug.log`.
enum DebugLog {
    private static let fileURL: URL? = {
        // Per-install log directory, derived from the bundle id. Byte-identical
        // to `~/Library/Logs/NockerlVoice` under the production bundle id; a fork logs
        // to its own directory.
        let dir = AppPaths.logDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    static func write(_ message: String) {
        guard let fileURL else { return }
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
