import AppKit
import Foundation

/// A deliberately boring, fully resizeable window used by `size-cli selftest`.
///
/// The self-test drives this window instead of anything the user owns, so
/// verification can run unattended without disturbing real work.
@main
@MainActor
struct SizeTestHost {
    /// Kept at file scope so the window survives for the whole run.
    private static var window: NSWindow?

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: CGRect(x: 300, y: 300, width: 700, height: 500),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Size Self Test Window"
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        Self.window = window

        application.activate(ignoringOtherApps: true)
        application.run()
    }
}
