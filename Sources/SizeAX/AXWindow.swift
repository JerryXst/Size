@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import SizeCore

/// Thin, safe wrapper around one Accessibility window element.
///
/// Every read guards against a dead process: a target app that hangs must never
/// stall the menu bar, which is why a short messaging timeout is installed on
/// construction.
@MainActor
public final class AXWindow {
    /// `AXFullScreen` has no public Swift constant, so it is addressed by name.
    private static let fullScreenAttribute = "AXFullScreen"
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"

    public let pid: pid_t
    public let element: AXUIElement

    /// Stable identity used to key snapshots. Resolved lazily because the
    /// private accessor is not guaranteed to exist on every OS build.
    public private(set) lazy var windowID: Int? = Self.resolveWindowID(element)

    public init(pid: pid_t, element: AXUIElement) {
        self.pid = pid
        self.element = element
        AXUIElementSetMessagingTimeout(element, 0.5)
    }

    public var title: String? { stringAttribute(kAXTitleAttribute) }
    public var role: String? { stringAttribute(kAXRoleAttribute) }
    public var subrole: String? { stringAttribute(kAXSubroleAttribute) }
    public var isFullScreen: Bool { boolAttribute(Self.fullScreenAttribute) ?? false }
    public var isMinimized: Bool { boolAttribute(kAXMinimizedAttribute) ?? false }

    public var bundleID: String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    public var appName: String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    /// Stable key for snapshot storage; falls back to pid plus title when the
    /// private window id is unavailable.
    public var snapshotKey: String {
        if let windowID {
            return "\(pid)-\(windowID)"
        }
        return "\(pid)-\(title ?? "untitled")"
    }

    /// Frame in NS coordinates (origin bottom-left).
    public func frame(mainScreenFrame: CGRect) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute),
              let size = sizeAttribute(kAXSizeAttribute) else { return nil }
        let cgRect = CGRect(origin: position, size: size)
        return ScreenGeometry.nsRect(fromCG: cgRect, mainScreenFrame: mainScreenFrame)
    }

    @discardableResult
    public func setFullScreen(_ value: Bool) -> Bool {
        set(Self.fullScreenAttribute, value as CFBoolean)
    }

    /// Some apps refuse frame changes until raised; harmless when unsupported.
    @discardableResult
    public func raise() -> Bool {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
    }

    @discardableResult
    public func setPosition(_ point: CGPoint) -> Bool {
        var mutable = point
        guard let value = AXValueCreate(.cgPoint, &mutable) else { return false }
        return set(kAXPositionAttribute, value)
    }

    @discardableResult
    public func setSize(_ size: CGSize) -> Bool {
        var mutable = size
        guard let value = AXValueCreate(.cgSize, &mutable) else { return false }
        return set(kAXSizeAttribute, value)
    }

    // MARK: - Private

    private func stringAttribute(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(_ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private func pointAttribute(_ attribute: String) -> CGPoint? {
        guard let value = copyAXValue(attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ attribute: String) -> CGSize? {
        guard let value = copyAXValue(attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private func copyAXValue(_ attribute: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    private func set(_ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    /// `_AXUIElementGetWindow` is the conventional private bridge from an AX
    /// element to its CGWindowID. Resolved dynamically so a missing symbol is a
    /// soft failure rather than a launch crash.
    private static func resolveWindowID(_ element: AXUIElement) -> Int? {
        typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        let function = unsafeBitCast(symbol, to: GetWindowFn.self)
        var windowID: CGWindowID = 0
        guard function(element, &windowID) == .success else { return nil }
        return Int(windowID)
    }
}
