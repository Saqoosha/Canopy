#!/usr/bin/env swift
// Reproduce the refusal MacroPadController.retireStaleCurrentEvent works around,
// and check the workaround against it, without building Canopy.
//
// Usage:
//   swift scripts/activation-stale-hotkey-probe.swift [target-app] [method]
//     target-app  app to bring frontmost first (default Arc — the one the
//                 refusal was measured under; Finder also refuses in this rig,
//                 whose planted timestamp is older than any recent activation)
//     method      plain    NSApp.activate(ignoringOtherApps: true) as-is
//                 retire   dequeue one applicationDefined event first (the fix)
//
// Steps: activate self; bring <target> frontmost via `open -a`; plant a
// system-defined hot-key-shaped event (subtype 6) with a 6-hour-old timestamp
// as NSApp.currentEvent; activate by <method>; report NSApp.isActive.
// Expected on macOS 27.0 (measured 2026-09-21): plain → refused, with
// `CPS: Rejecting expired request` in the WindowServer log
// (`/usr/bin/log show --last 2m --predicate 'process == "WindowServer" AND
// eventMessage CONTAINS "Rejecting expired"'`); retire → active. Exit status:
// 0 when the RESULT matched that expectation, 1 when it did not, 2 when a
// precondition failed (<target> not frontmost, stale event not planted,
// retire did not replace currentEvent) — so `… Arc plain && … Arc retire`
// is the A/B, and a RESULT line is always a run where another app held
// activation over a planted stale event. `NSWorkspace.openApplication(at:)` is
// deliberately not an arm: under `swift <script>` Bundle.main is the
// toolchain's usr/bin, not an app bundle, so the call fails for its own
// reason and measures nothing about the refusal.
// The run steals focus for a few seconds; it exits on its own.
import AppKit

let args = CommandLine.arguments
let target = args.count > 1 ? args[1] : "Arc"
let method = args.count > 2 ? args[2] : "plain"

func front() -> String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }
func log(_ s: String) { print(s); fflush(stdout) }
func describe(_ e: NSEvent) -> String {
    let t = e.type.rawValue
    // `subtype` traps on event types where it is invalid (KeyUp, for one).
    let sub = (t == 13 || t == 14 || t == 15) ? "\(e.subtype.rawValue)" : "-"
    return "type=\(t) subtype=\(sub) ts=\(e.timestamp)"
}
func describeCurrent() -> String {
    guard let e = NSApp.currentEvent else { return "currentEvent=nil" }
    return "currentEvent " + describe(e)
}
func openApp(_ name: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-a", name]
    do { try p.run() } catch { log("could not run /usr/bin/open: \(error)"); exit(2) }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { log("open -a \(name) failed rc=\(p.terminationStatus)"); exit(2) }
}
func plantStaleHotKeyEvent() {
    let stale = ProcessInfo.processInfo.systemUptime - 6 * 3600
    guard let e = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                                     timestamp: stale, windowNumber: 0, context: nil,
                                     subtype: 6, data1: 0, data2: 0) else { log("could not make the stale event"); exit(2) }
    NSApp.postEvent(e, atStart: true)
    _ = NSApp.nextEvent(matching: .systemDefined, until: nil, inMode: .default, dequeue: true)
    log("planted: \(describeCurrent())")
    guard let c = NSApp.currentEvent, c.type == .systemDefined, c.subtype.rawValue == 6, abs(c.timestamp - stale) < 0.001 else {
        log("precondition failed: currentEvent is not the planted stale event"); exit(2)
    }
}
func retireStaleCurrentEvent() {
    guard let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                     subtype: 0, data1: 0, data2: 0) else { log("could not make the retire event"); exit(2) }
    NSApp.postEvent(e, atStart: true)
    _ = NSApp.nextEvent(matching: .applicationDefined, until: nil, inMode: .default, dequeue: true)
    log("retired: \(describeCurrent())")
    guard NSApp.currentEvent?.type == .applicationDefined else {
        log("precondition failed: retire did not replace currentEvent"); exit(2)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 120),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
win.title = "activation probe"
win.makeKeyAndOrderFront(nil)

var t = 0.5
func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }

at(0)   { NSApp.activate(ignoringOtherApps: true); log("activated self; \(describeCurrent())") }
at(1.0) { log("bringing \(target) front"); openApp(target) }
at(1.5) {
    log("front=\(front()) isActive=\(NSApp.isActive)")
    guard front() == target, !NSApp.isActive else { log("precondition failed: \(target) is not frontmost (front=\(front()))"); exit(2) }
    plantStaleHotKeyEvent()
}
at(0.3) {
    log("front=\(front()); method=\(method)")
    if method == "retire" { retireStaleCurrentEvent() }
    NSApp.activate(ignoringOtherApps: true)
    win.makeKeyAndOrderFront(nil)
}
at(1.5) {
    let expected = method == "retire"
    let ok = NSApp.isActive == expected
    log("RESULT method=\(method) target=\(target): isActive=\(NSApp.isActive) expected=\(expected) ok=\(ok) front=\(front())")
    exit(ok ? 0 : 1)
}
app.run()
