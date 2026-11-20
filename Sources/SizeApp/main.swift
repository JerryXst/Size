import AppKit
import Foundation

// `Size --unregister-login` drops a login item that earlier runs may have left
// behind, so scripts and tests can restore a clean state.
if CommandLine.arguments.contains("--unregister-login") {
    MainActor.assumeIsolated {
        Foundation.exit(Diagnostics.unregisterLoginItem())
    }
}

// `Size --diagnose` reports permission and display state without starting the
// menu bar item, so it can be run from a script.
if CommandLine.arguments.contains("--diagnose") {
    MainActor.assumeIsolated {
        Foundation.exit(Diagnostics.run())
    }
}

// Menu bar only: no Dock icon, no main window.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)

// A second copy would register the same global shortcuts and steal their
// events, leaving both instances half-working. Hand off to the existing copy
// instead. Tests that intentionally run a scratch instance set the escape hatch.
if ProcessInfo.processInfo.environment["SIZE_ALLOW_MULTIPLE"] == nil,
   let identifier = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication
        .runningApplications(withBundleIdentifier: identifier)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if let existing = others.first {
        ActionLog.write("another instance is running (pid \(existing.processIdentifier)); handing off")
        existing.activate()
        Foundation.exit(0)
    }
}

application.run()
