import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` so the settings UI, diagnostics and
/// the UI test all agree on one state and one set of error messages.
///
/// The UI test flips the "start at login" switch, so it also has to put it back:
/// leaving it on makes launchd respawn the app, which in turn produces two
/// instances fighting over the same global shortcuts.
@MainActor
struct SMAppServiceBox {
    var isSupported: Bool { true }
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    /// Turns the login item off when it is on, and reports what happened.
    @discardableResult
    func restoreDisabled() -> Bool {
        guard isEnabled else { return true }
        do {
            try unregister()
            return true
        } catch {
            return false
        }
    }
}
