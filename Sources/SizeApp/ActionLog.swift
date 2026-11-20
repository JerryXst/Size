import Foundation

/// Appends one line per layout action to `~/Library/Logs/Size/actions.log`.
///
/// Kept deliberately simple: when a shortcut appears to do nothing, the first
/// question is always "did the app see it, and on which window", and that
/// answer is not visible anywhere else.
enum ActionLog {
    private static let maximumBytes = 512 * 1024

    static var url: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/Size/actions.log")
    }

    static func write(_ message: String) {
        let line = "\(timestamp()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !manager.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            return
        }

        // Keep the file bounded without pulling in a logging framework.
        if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > maximumBytes {
            try? manager.removeItem(at: url)
            try? data.write(to: url, options: .atomic)
            return
        }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
