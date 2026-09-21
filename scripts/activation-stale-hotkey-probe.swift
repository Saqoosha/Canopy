#!/usr/bin/env swift
// Reproduce the refusal MacroPadController.retireStaleCurrentEvent works around,
// and check the workaround against it, without building Canopy.
//
// Usage:
//   swift scripts/activation-stale-hotkey-probe.swift [target-app] [method]
//     target-app  app to bring frontmost first (default Arc — the one the
//                 refusal was measured under; Finder also refuses in this rig)
//     method      plain    NSApp.activate(ignoringOtherApps: true) as-is
//                 retire   dequeue one applicationDefined event first (the fix)
//                 ls       NSWorkspace.openApplication(at: own bundle)
//
// Steps: activate self; bring <target> frontmost via `open -a`; plant a
// system-defined hot-key-shaped event (subtype 6) with a 6-hour-old timestamp
// as NSApp.currentEvent; activate by <method>; report NSApp.isActive.
// Expected on macOS 27.0 (measured 2026-09-21): plain → refused, with
// `CPS: Rejecting expired request` in the WindowServer log
// (`/usr/bin/log show --last 2m --predicate 'process == "WindowServer" AND
// eventMessage CONTAINS "Rejecting expired"'`); retire → active; ls → refused.
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
    let p = Process(); p.launchPath = "/usr/bin/open"; p.arguments = ["-a", name]; p.launch(); p.waitUntilExit()
}
func plantStaleHotKeyEvent() {
    let stale = ProcessInfo.processInfo.systemUptime - 6 * 3600
    guard let e = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                                     timestamp: stale, windowNumber: 0, context: nil,
                                     subtype: 6, data1: 0, data2: 0) else { log("could not make event"); return }
    NSApp.postEvent(e, atStart: true)
    _ = NSApp.nextEvent(matching: .systemDefined, until: nil, inMode: .default, dequeue: true)
    log("planted: \(describeCurrent())")
}
func retireStaleCurrentEvent() {
    guard let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                     subtype: 0, data1: 0, data2: 0) else { return }
    NSApp.postEvent(e, atStart: true)
    _ = NSApp.nextEvent(matching: .applicationDefined, until: nil, inMode: .default, dequeue: true)
    log("retired: \(describeCurrent())")
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
at(1.5) { log("front=\(front()) isActive=\(NSApp.isActive)"); plantStaleHotKeyEvent() }
at(0.3) {
    log("front=\(front()); method=\(method)")
    switch method {
    case "retire":
        retireStaleCurrentEvent()
        NSApp.activate(ignoringOtherApps: true)
    case "ls":
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, err in
            log("openApplication completion err=\(String(describing: err))")
        }
    default:
        NSApp.activate(ignoringOtherApps: true)
    }
    win.makeKeyAndOrderFront(nil)
}
at(1.5) { log("RESULT method=\(method) target=\(target): isActive=\(NSApp.isActive) front=\(front())"); exit(0) }
app.run()
