import Combine
import Foundation
import SizeCore

/// Owns the on-disk configuration and publishes changes to the UI.
@MainActor
final class ConfigStore: ObservableObject {
    @Published private(set) var config: SizeConfig

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
        self.config = Store.load(from: self.url)
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Size/config.json")
    }

    func load() {
        config = Store.load(from: url)
    }

    /// Applies a change and persists it immediately.
    func update(_ mutate: (inout SizeConfig) -> Void) {
        var copy = config
        mutate(&copy)
        config = copy.sanitised()
        Store.save(config, to: url)
    }

    func reset() {
        config = .default
        Store.save(config, to: url)
    }

    // MARK: - Non-observable helpers used off the UI path

    enum Store {
        static func load(from url: URL) -> SizeConfig {
            guard let data = try? Data(contentsOf: url) else { return .default }
            return SizeConfig.decode(from: data)
        }

        static func save(_ config: SizeConfig, to url: URL) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try config.encoded().write(to: url, options: .atomic)
            } catch {
                NSLog("Size: could not save config: \(error.localizedDescription)")
            }
        }
    }
}
