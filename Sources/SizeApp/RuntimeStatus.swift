import Foundation
import SizeCore

/// A small file the running app keeps up to date.
///
/// It exists because Accessibility cannot always see a status item (macOS
/// occasionally does not expose `AXExtrasMenuBar`), so scripts and the test
/// harness need a non-AX way to tell that the app is up and which process owns
/// the menu bar item.
enum RuntimeStatus {
    /// Posted by scripts (and the test harness) to ask the app to show Settings.
    static let openSettingsNotification = Notification.Name("com.jerryxst.size.openSettings")

    struct Payload: Codable {
        var pid: Int32
        var launchedAt: Date
        var menuBarItemVisible: Bool
        var version: String
    }

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Size/status.json")
    }

    static func write(menuBarItemVisible: Bool) {
        let payload = Payload(
            pid: ProcessInfo.processInfo.processIdentifier,
            launchedAt: Date(),
            menuBarItemVisible: menuBarItemVisible,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(payload).write(to: url, options: .atomic)
        } catch {
            NSLog("Size: could not write runtime status: \(error.localizedDescription)")
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    static func read() -> Payload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Payload.self, from: data)
    }

    /// True when the file was written by the process that is running now.
    static func isReady(pid: Int32) -> Bool {
        guard let payload = read() else { return false }
        return payload.pid == pid
    }
}
