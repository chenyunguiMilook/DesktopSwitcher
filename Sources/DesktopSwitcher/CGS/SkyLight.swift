import Foundation

/// Typed access to the handful of private SkyLight (CoreGraphics Services) symbols
/// this app needs.
///
/// Everything is resolved at runtime with `dlsym`, so a symbol that disappears in a
/// future macOS release degrades to a disabled feature instead of a launch crash.
///
/// Only *read* entry points are bound here. The write entry points
/// (`SLSManagedDisplaySetCurrentSpace`, `SLSTransactionSetManagedDisplayCurrentSpace`, …)
/// are deliberately absent: on macOS 26 they update WindowServer bookkeeping without
/// moving the rendered display, which leaves `SLSGetActiveSpace` disagreeing with what
/// is actually on screen. See `Tools/cgs-probe.swift` and the design doc for the
/// measurements behind that decision.
enum SkyLight {

    private nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    /// Newer systems export the `SLS*` spelling; older ones only the `CGS*` alias.
    private static func lookup(_ names: String...) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        for name in names {
            if let pointer = dlsym(handle, name) { return pointer }
        }
        return nil
    }

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias ActiveSpaceFn = @convention(c) (Int32) -> UInt64

    private static let mainConnectionIDFn: ConnectionFn? =
        lookup("SLSMainConnectionID", "CGSMainConnectionID")
            .map { unsafeBitCast($0, to: ConnectionFn.self) }

    private static let copyManagedDisplaySpacesFn: CopyManagedDisplaySpacesFn? =
        lookup("SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces")
            .map { unsafeBitCast($0, to: CopyManagedDisplaySpacesFn.self) }

    private static let activeSpaceFn: ActiveSpaceFn? =
        lookup("SLSGetActiveSpace", "CGSGetActiveSpace")
            .map { unsafeBitCast($0, to: ActiveSpaceFn.self) }

    /// The window server connection for this process, resolved once.
    private static let connectionID: Int32? = mainConnectionIDFn?()

    /// True when every symbol we depend on resolved successfully.
    static var isAvailable: Bool {
        connectionID != nil && copyManagedDisplaySpacesFn != nil
    }

    /// Raw per-display space topology, in Mission Control's left-to-right order.
    ///
    /// Each element describes one display and carries `Display Identifier`,
    /// `Current Space` and `Spaces` keys.
    static func managedDisplaySpaces() -> [[String: Any]] {
        guard let connectionID, let copyManagedDisplaySpacesFn else { return [] }
        guard let array = copyManagedDisplaySpacesFn(connectionID)?.takeRetainedValue() else { return [] }
        return (array as? [[String: Any]]) ?? []
    }

    /// The window server's notion of the active space.
    ///
    /// Only used for diagnostics — the per-display `Current Space` value from
    /// `managedDisplaySpaces()` is what drives the UI, since it is correct per display.
    static func activeSpaceID() -> UInt64? {
        guard let connectionID, let activeSpaceFn else { return nil }
        return activeSpaceFn(connectionID)
    }
}
