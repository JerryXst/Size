@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import SizeAX
import SizeCore

/// Moves windows between Spaces using SkyLight, the private framework behind
/// Mission Control.
///
/// Why this is isolated:
/// * The old `CGSSetWorkspace` entry point that SizeUp relied on no longer
///   exists on current macOS, so any private API here can vanish at any
///   update. Everything is resolved with `dlsym` at call time and a missing
///   symbol simply disables the feature.
/// * The feature is off by default and can be dropped wholesale.
@MainActor
public final class SkyLightSpaceMover: WindowSpaceMoving {
    private typealias DefaultConnectionFn = @convention(c) () -> UInt64
    private typealias CopySpacesForWindowsFn = @convention(c) (UInt64, Int32, CFArray) -> CFArray?
    private typealias AddWindowsToSpacesFn = @convention(c) (UInt64, CFArray, CFArray) -> Bool
    private typealias RemoveWindowsFromSpacesFn = @convention(c) (UInt64, CFArray, CFArray) -> Bool
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (UInt64) -> CFArray?

    private let connection: DefaultConnectionFn
    private let copySpacesForWindows: CopySpacesForWindowsFn
    private let addWindowsToSpaces: AddWindowsToSpacesFn
    private let removeWindowsFromSpaces: RemoveWindowsFromSpacesFn
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn

    /// Returns `nil` when the private symbols are not present, so callers can
    /// degrade instead of crashing.
    public init?() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ) else { return nil }

        func resolve<T>(_ name: String, as type: T.Type) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }

        guard let connection = resolve("_CGSDefaultConnection", as: DefaultConnectionFn.self),
              let copySpaces = resolve("SLSCopySpacesForWindows", as: CopySpacesForWindowsFn.self),
              let add = resolve("SLSAddWindowsToSpaces", as: AddWindowsToSpacesFn.self),
              let remove = resolve("SLSRemoveWindowsFromSpaces", as: RemoveWindowsFromSpacesFn.self),
              let managed = resolve("SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
        else { return nil }

        self.connection = connection
        self.copySpacesForWindows = copySpaces
        self.addWindowsToSpaces = add
        self.removeWindowsFromSpaces = remove
        self.copyManagedDisplaySpaces = managed
    }

    public static var isAvailable: Bool {
        SkyLightSpaceMover() != nil
    }

    public func move(_ direction: SpaceDirection, window: AXWindow) -> Bool {
        guard let windowID = window.windowID else { return false }

        let cid = connection()
        let windowIDs = [UInt64(windowID)].cfArrayOfUInt64

        // Which Space is the window in right now?
        guard let currentSpaces = copySpacesForWindows(cid, 0x7, windowIDs) as? [NSNumber],
              let currentSpace = currentSpaces.first?.uint64Value else { return false }

        let ordered = orderedSpaces()
        guard ordered.count > 1,
              let position = ordered.firstIndex(of: currentSpace) else { return false }

        // macOS arranges Spaces in a single row; above/below therefore map onto
        // the same sequence rather than a separate axis.
        let step: Int
        switch direction {
        case .previous, .above: step = -1
        case .next, .below: step = 1
        }
        let targetIndex = (position + step + ordered.count) % ordered.count
        let targetSpace = ordered[targetIndex]
        guard targetSpace != currentSpace else { return false }

        let targetSpaces = [targetSpace].cfArrayOfUInt64
        let sourceSpaces = [currentSpace].cfArrayOfUInt64

        // Add before remove: the window is never left in no Space at all.
        guard addWindowsToSpaces(cid, targetSpaces, windowIDs) else { return false }
        _ = removeWindowsFromSpaces(cid, sourceSpaces, windowIDs)
        return true
    }

    /// All user Spaces in display order, flattened.
    private func orderedSpaces() -> [UInt64] {
        let cid = connection()
        guard let displays = copyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }

        var result: [UInt64] = []
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                // type 0 marks a normal user Space; others are full-screen apps
                // and system Spaces which cannot be entered this way.
                if let type = space["type"] as? Int, type != 0 { continue }
                if let id = space["id64"] as? NSNumber {
                    result.append(id.uint64Value)
                }
            }
        }
        return result
    }
}

private extension Array where Element == UInt64 {
    var cfArrayOfUInt64: CFArray {
        let numbers = map { value -> CFNumber in
            var mutable = value
            return CFNumberCreate(nil, .sInt64Type, &mutable)
        }
        return numbers as CFArray
    }
}
