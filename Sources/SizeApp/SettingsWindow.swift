import AppKit
import ServiceManagement
import SizeCore
import SwiftUI

/// Preferences, built on SwiftUI and hosted in a plain AppKit window.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: ConfigStore
    private let failedHotkeys: () -> Set<WindowAction>

    init(store: ConfigStore, failedHotkeys: @escaping () -> Set<WindowAction>) {
        self.store = store
        self.failedHotkeys = failedHotkeys
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(store: store, failedHotkeys: failedHotkeys)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Size Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    let failedHotkeys: () -> Set<WindowAction>

    @State private var recording: WindowAction?
    @State private var monitor: Any?
    @State private var recordingMessage: String?
    @State private var launchAtLogin = SMAppServiceBox().isEnabled

    private var shortcutActions: [WindowAction] {
        WindowAction.allCases.filter(\.isHotkeyable)
    }

    var body: some View {
        TabView {
            general.tabItem { Text("General") }
            shortcuts.tabItem { Text("Shortcuts") }
            margins.tabItem { Text("Margins") }
            advanced.tabItem { Text("Advanced") }
        }
        .frame(width: 480, height: 420)
        .padding()
        .onDisappear { stopRecording() }
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section("Startup") {
                Toggle("Start at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { value in
                        // Registering only works from a real app bundle.
                        let login = SMAppServiceBox()
                        do {
                            if value {
                                try login.register()
                            } else {
                                try login.unregister()
                            }
                        } catch {
                            NSLog("Size: launch at login failed: \(error.localizedDescription)")
                        }
                        launchAtLogin = login.isEnabled
                    }
                ))
            }

            Section("Grid") {
                Stepper(
                    "Columns: \(store.config.gridColumns)",
                    value: Binding(
                        get: { store.config.gridColumns },
                        set: { value in store.update { $0.gridColumns = value } }
                    ),
                    in: 1...12
                )
                Stepper(
                    "Rows: \(store.config.gridRows)",
                    value: Binding(
                        get: { store.config.gridRows },
                        set: { value in store.update { $0.gridRows = value } }
                    ),
                    in: 1...12
                )
                Text("A 6×6 grid supports halves, thirds and quadrants at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Gap between windows") {
                HStack {
                    Slider(
                        value: Binding(
                            get: { store.config.gap },
                            set: { value in store.update { $0.gap = value.rounded() } }
                        ),
                        in: 0...40,
                        step: 2
                    )
                    Text("\(Int(store.config.gap)) pt")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                Text("Applied to every layout action so tiled windows leave a visible channel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Shortcuts

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recordingMessage ?? "Click a shortcut, then press the keys you want. Escape cancels.")
                .font(.caption)
                .foregroundStyle(recordingMessage == nil ? .secondary : .primary)

            let failed = failedHotkeys()
            if !failed.isEmpty {
                Text("Already taken by another app: "
                    + failed.map(\.displayName).sorted().joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shortcutActions, id: \.rawValue) { action in
                        shortcutRow(for: action)
                        Divider().opacity(0.35)
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private func shortcutRow(for action: WindowAction) -> some View {
        let binding = store.config.binding(for: action)
        let isRecording = recording == action

        return HStack {
            Text(action.displayName)
            Spacer()
            if store.config.isCustomised(action) {
                Button {
                    store.update { $0.resetBinding(for: action) }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Restore the default shortcut")
            }
            Button {
                startRecording(action)
            } label: {
                Text(isRecording ? "Press keys…" : (binding?.display ?? "—"))
                    .monospaced()
                    .frame(minWidth: 74)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Margins

    private var margins: some View {
        Form {
            Section("Inset from the screen edge") {
                marginField("Top", keyPath: \.top)
                marginField("Bottom", keyPath: \.bottom)
                marginField("Left", keyPath: \.left)
                marginField("Right", keyPath: \.right)
                Text("Useful for keeping windows clear of the Dock or a menu bar overhang.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Apply the same value to all four sides") {
                HStack {
                    Text("Uniform")
                    Spacer()
                    TextField("Value", value: Binding(
                        get: { Int(store.config.defaultMargin.top >= 0 ? store.config.defaultMargin.top : 0) },
                        set: { value in
                            store.update {
                                let margin = Double(max(0, value))
                                $0.defaultMargin = Margin(top: margin, bottom: margin, left: margin, right: margin)
                            }
                        }
                    ), format: .number)
                    .frame(width: 70)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func marginField(_ label: String, keyPath: WritableKeyPath<Margin, Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("pts", value: Binding(
                get: { Int(store.config.defaultMargin[keyPath: keyPath]) },
                set: { value in store.update { $0.defaultMargin[keyPath: keyPath] = Double(value) } }
            ), format: .number)
            .frame(width: 70)
        }
    }

    // MARK: - Advanced

    private var advanced: some View {
        Form {
            Section("Spaces") {
                Toggle(
                    "Enable Space moves",
                    isOn: Binding(
                        get: { store.config.enableSpaceActions },
                        set: { value in store.update { $0.enableSpaceActions = value } }
                    )
                )
                Text("Uses private system interfaces. If a macOS update removes them, the feature turns itself off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ignored apps") {
                if store.config.ignoredBundleIDs.isEmpty {
                    Text("None. Use “Disable Shortcuts in …” in the menu to add the frontmost app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.config.ignoredBundleIDs, id: \.self) { bundleID in
                        HStack {
                            Text(bundleID)
                            Spacer()
                            Button("Remove") {
                                store.update { $0.ignoredBundleIDs.removeAll { $0 == bundleID } }
                            }
                        }
                    }
                }
            }

            Section {
                Button("Reset all settings") { store.reset() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Recording

    private func startRecording(_ action: WindowAction) {
        stopRecording()
        recording = action
        recordingMessage = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleRecordingEvent(event, for: action)
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recording = nil
    }

    private func handleRecordingEvent(_ event: NSEvent, for action: WindowAction) -> NSEvent? {
        if event.keyCode == 53 { // Escape
            stopRecording()
            recordingMessage = nil
            return nil
        }

        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= HotkeyModifiers.control }
        if event.modifierFlags.contains(.option) { modifiers |= HotkeyModifiers.option }
        if event.modifierFlags.contains(.shift) { modifiers |= HotkeyModifiers.shift }
        if event.modifierFlags.contains(.command) { modifiers |= HotkeyModifiers.command }

        let binding = HotkeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        guard binding.isValid else {
            recordingMessage = "Add ⌃, ⌥, ⇧ or ⌘ — a plain key would block normal typing."
            return nil
        }

        store.update { $0.setBinding(binding, for: action) }
        recordingMessage = "\(action.displayName) is now \(binding.display)."
        stopRecording()
        return nil
    }
}
