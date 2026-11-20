import AppKit
import Carbon.HIToolbox
import Foundation
import SizeCore

/// Registers system-wide hotkeys with Carbon.
///
/// `RegisterEventHotKey` is deliberate: it needs no extra permission, does not
/// sit in the event stream, and keeps working while another app is frontmost.
/// A global monitor would require Input Monitoring and cannot intercept keys.
@MainActor
final class HotkeyCenter {
    private var registered: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    /// Actions whose shortcut the system refused, e.g. because another app owns
    /// the combination. Surfaced in Settings so the user knows why nothing happens.
    private(set) var failedActions: Set<WindowAction> = []

    /// Carbon callbacks are C function pointers, so the handlers live in a
    /// process-wide table keyed by hotkey id.
    nonisolated(unsafe) private static var handlers: [UInt32: @Sendable () -> Void] = [:]

    init() {
        installEventHandler()
    }

    /// Returns false when the system refuses the combination.
    @discardableResult
    func register(_ binding: HotkeyBinding, handler: @escaping @Sendable () -> Void) -> Bool {
        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x53495A45), id: id) // 'SIZE'
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            ActionLog.write("RegisterEventHotKey refused \(binding.display) status=\(status)")
            NSLog("Size: RegisterEventHotKey refused \(binding.display) (status=\(status))")
            return false
        }

        Self.handlers[id] = handler
        registered[id] = reference
        return true
    }

    func unregisterAll() {
        for (id, reference) in registered {
            UnregisterEventHotKey(reference)
            Self.handlers.removeValue(forKey: id)
        }
        registered.removeAll()
        failedActions.removeAll()
    }

    /// Replaces every registration with the shortcuts in `config`.
    func apply(config: SizeConfig, perform: @escaping @Sendable (WindowAction) -> Void) {
        unregisterAll()
        var succeeded = 0
        var attempted = 0
        for action in WindowAction.allCases where action.isHotkeyable {
            guard let binding = config.binding(for: action) else { continue }
            attempted += 1
            let registered = register(binding) { perform(action) }
            if registered {
                succeeded += 1
            } else {
                failedActions.insert(action)
            }
        }
        ActionLog.write("hotkeys registered=\(succeeded)/\(attempted)")
        if !failedActions.isEmpty {
            let names = failedActions.map(\.displayName).sorted().joined(separator: ", ")
            ActionLog.write("hotkeys unavailable: \(names)")
            NSLog("Size: these shortcuts are already taken: \(names)")
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let result = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      let handler = HotkeyCenter.handlers[hotKeyID.id] else {
                    ActionLog.write("hotkey event ignored (id=\(hotKeyID.id) status=\(status))")
                    return OSStatus(eventNotHandledErr)
                }
                ActionLog.write("hotkey callback fired id=\(hotKeyID.id)")
                DispatchQueue.main.async { handler() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        if result != noErr {
            NSLog("Size: could not install the hotkey event handler (status=\(result))")
        }
    }
}
