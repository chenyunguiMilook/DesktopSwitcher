// Feasibility probe for private Space-switching APIs.
//
//   swiftc -O Tools/cgs-probe.swift -o /tmp/cgs-probe && /tmp/cgs-probe
//
// Answers one question: can a normal (SIP-on, non-injected) process make the display
// actually move to another Space? It walks every plausible CGS/SkyLight route and judges
// each by a downsampled screen capture rather than by what the API reports, because the
// two disagree.
//
// Result on macOS 26.5 (2026-07-26): all nine routes report success and move nothing.
// Re-run on a new macOS release before assuming that is still true. If a row ever prints
// DISPLAY MOVED, that route can replace the synthetic ⌃←/⌃→ in SpaceSwitcher.swift.
//
// Requires Screen Recording permission for the invoking terminal. Needs at least two
// desktops on the main display.

import Cocoa

let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
guard let handle else { print("cannot dlopen SkyLight"); exit(1) }
func sym(_ n: String) -> UnsafeMutableRawPointer? { dlsym(handle, n) }

typealias ConnFn = @convention(c) () -> Int32
typealias CopyFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias ActiveFn = @convention(c) (Int32) -> UInt64
typealias SetSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void
typealias TxCreateFn = @convention(c) (Int32) -> CFTypeRef?
typealias TxCommitFn = @convention(c) (CFTypeRef, Int32) -> Void
typealias TxSetSpaceFn = @convention(c) (CFTypeRef, CFString, UInt64) -> Void
typealias ShowHideFn = @convention(c) (Int32, CFArray) -> Void
typealias MoveWindowsFn = @convention(c) (Int32, CFArray, UInt64) -> Void

guard let connPtr = sym("SLSMainConnectionID") ?? sym("CGSMainConnectionID"),
      let copyPtr = sym("SLSCopyManagedDisplaySpaces") ?? sym("CGSCopyManagedDisplaySpaces"),
      let activePtr = sym("SLSGetActiveSpace") ?? sym("CGSGetActiveSpace")
else { print("core read symbols missing"); exit(1) }

let cid = unsafeBitCast(connPtr, to: ConnFn.self)()
let copySpaces = unsafeBitCast(copyPtr, to: CopyFn.self)
let getActive = unsafeBitCast(activePtr, to: ActiveFn.self)

func displays() -> [[String: Any]] { (copySpaces(cid)?.takeRetainedValue() as? [[String: Any]]) ?? [] }

// MARK: - Ground truth: what is actually on screen

let shotPath = NSTemporaryDirectory() + "cgs-probe-shot.png"
let fpWidth = 64, fpHeight = 36

func fingerprint() -> [UInt8] {
    try? FileManager.default.removeItem(atPath: shotPath)
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-t", "png", shotPath]
    try? capture.run()
    capture.waitUntilExit()

    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: shotPath) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }

    var pixels = [UInt8](repeating: 0, count: fpWidth * fpHeight)
    guard let ctx = CGContext(data: &pixels, width: fpWidth, height: fpHeight,
                              bitsPerComponent: 8, bytesPerRow: fpWidth,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: fpWidth, height: fpHeight))
    return pixels
}

/// Mean absolute difference in 0...255. A ticking menu-bar clock scores ~0.
func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return -1 }
    return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
}

// MARK: - Topology

guard let display = displays().first,
      let identifier = display["Display Identifier"] as? String else {
    print("no displays reported"); exit(1)
}
let desktops = (display["Spaces"] as? [[String: Any]] ?? [])
    .filter { ($0["type"] as? Int) == 0 }
    .compactMap { $0["ManagedSpaceID"] as? UInt64 }
let home = getActive(cid)

print("display    : \(identifier)")
print("desktops   : \(desktops)")
print("current    : \(home)")

guard let target = desktops.first(where: { $0 != home }) else {
    print("\nneed at least two desktops to test switching"); exit(0)
}
print("target     : \(target)\n")

// MARK: - Routes

let legacySet = (sym("SLSManagedDisplaySetCurrentSpace") ?? sym("CGSManagedDisplaySetCurrentSpace"))
    .map { unsafeBitCast($0, to: SetSpaceFn.self) }
let txCreate = sym("SLSTransactionCreate").map { unsafeBitCast($0, to: TxCreateFn.self) }
let txCommit = sym("SLSTransactionCommit").map { unsafeBitCast($0, to: TxCommitFn.self) }
let txSetSpace = sym("SLSTransactionSetManagedDisplayCurrentSpace").map { unsafeBitCast($0, to: TxSetSpaceFn.self) }
let showSpaces = sym("SLSShowSpaces").map { unsafeBitCast($0, to: ShowHideFn.self) }
let hideSpaces = sym("SLSHideSpaces").map { unsafeBitCast($0, to: ShowHideFn.self) }
let moveWindows = sym("SLSMoveWindowsToManagedSpace").map { unsafeBitCast($0, to: MoveWindowsFn.self) }

func viaTransaction(_ space: UInt64, synchronous: Int32) {
    guard let txCreate, let txCommit, let txSetSpace, let tx = txCreate(cid) else { return }
    txSetSpace(tx, identifier as CFString, space)
    txCommit(tx, synchronous)
}

// An NSApplication plus a real window, so the window-based routes below have something
// to park on the target space and activate.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let probeWindow = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 360, height: 240),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
probeWindow.title = "cgs-probe"
probeWindow.orderFront(nil)
let windowID = UInt32(probeWindow.windowNumber)

func parkWindowOnTarget() {
    moveWindows?(cid, [NSNumber(value: windowID)] as CFArray, target)
}

/// The signature of `SLSTransactionRequestSwitchToSpaceForWindow` is unpublished, so all
/// three plausible argument orders are tried.
func requestSwitchForWindow(argumentOrder: Int) {
    guard let pointer = sym("SLSTransactionRequestSwitchToSpaceForWindow"),
          let txCreate, let txCommit, let tx = txCreate(cid) else { return }
    parkWindowOnTarget()
    switch argumentOrder {
    case 0:
        typealias F = @convention(c) (CFTypeRef, UInt32) -> Void
        unsafeBitCast(pointer, to: F.self)(tx, windowID)
    case 1:
        typealias F = @convention(c) (CFTypeRef, UInt32, UInt64) -> Void
        unsafeBitCast(pointer, to: F.self)(tx, windowID, target)
    default:
        typealias F = @convention(c) (CFTypeRef, UInt64, UInt32) -> Void
        unsafeBitCast(pointer, to: F.self)(tx, target, windowID)
    }
    txCommit(tx, 1)
}

func activateOnTarget() {
    parkWindowOnTarget()
    NSApp.activate(ignoringOtherApps: true)
    probeWindow.makeKeyAndOrderFront(nil)
}

let routes: [(name: String, run: () -> Void)] = [
    ("SLSManagedDisplaySetCurrentSpace", { legacySet?(cid, identifier as CFString, target) }),
    ("SLSTransactionSet… + Commit(async)", { viaTransaction(target, synchronous: 0) }),
    ("SLSTransactionSet… + Commit(sync)", { viaTransaction(target, synchronous: 1) }),
    ("ShowSpaces + set + HideSpaces", {
        let previous = getActive(cid)
        showSpaces?(cid, [target] as CFArray)
        legacySet?(cid, identifier as CFString, target)
        if previous != target { hideSpaces?(cid, [previous] as CFArray) }
    }),
    ("move window to space + activate", { activateOnTarget() }),
    ("RequestSwitchToSpaceForWindow(tx,wid)", { requestSwitchForWindow(argumentOrder: 0) }),
    ("RequestSwitchToSpaceForWindow(tx,wid,sid)", { requestSwitchForWindow(argumentOrder: 1) }),
    ("RequestSwitchToSpaceForWindow(tx,sid,wid)", { requestSwitchForWindow(argumentOrder: 2) }),
    ("EnsureSpaceSwitchToActiveProcess", {
        activateOnTarget()
        if let pointer = sym("SLSEnsureSpaceSwitchToActiveProcess") {
            typealias F = @convention(c) (Int32) -> Void
            unsafeBitCast(pointer, to: F.self)(cid)
        }
    }),
]

func goHome() {
    legacySet?(cid, identifier as CFString, home)
    viaTransaction(home, synchronous: 1)
    Thread.sleep(forTimeInterval: 1.2)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

// The whole run is synchronous on a background queue so the AppKit run loop stays live
// for the window-based routes.
DispatchQueue.global().async {
    goHome()
    let noiseA = fingerprint()
    Thread.sleep(forTimeInterval: 1.5)
    let noiseFloor = meanDifference(noiseA, fingerprint())
    print(String(format: "noise floor (same desktop, 1.5s apart): %.2f\n", noiseFloor))

    let movedThreshold = max(3.0, noiseFloor * 10)

    print(pad("route", 44) + pad("reported", 12) + pad("pixel diff", 12) + "verdict")
    print(String(repeating: "-", count: 84))

    for route in routes {
        goHome()
        let before = fingerprint()

        DispatchQueue.main.sync { route.run() }
        Thread.sleep(forTimeInterval: 2.0)

        let after = fingerprint()
        let reported = getActive(cid)
        let difference = meanDifference(before, after)

        print(pad(route.name, 44)
              + pad(reported == target ? "switched" : "unchanged", 12)
              + pad(String(format: "%.2f", difference), 12)
              + (difference > movedThreshold ? "DISPLAY MOVED" : "no visual change"))
    }

    goHome()
    print("\nrestored to \(getActive(cid))")
    try? FileManager.default.removeItem(atPath: shotPath)
    exit(0)
}

app.run()
