import os.log
import Sparkle
import SwiftUI
import UserNotifications

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "App")

@main
struct CanopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    @State private var sidebarStore = SessionStore()

    var body: some Scene {
        WindowGroup(id: "main") {
            NavigationSplitView {
                Sidebar(store: sidebarStore)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
            } detail: {
                Detail(store: sidebarStore)
            }
            .navigationSplitViewStyle(.balanced)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    appDelegate.updaterController.updater.checkForUpdates()
                }
            }
            // File menu: browser-style — New Session / Open Folder above the
            // Close pair. SwiftUI's auto-generated "Close" item is suppressed
            // by the empty `.saveItem` / `.printItem` replacements below.
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    sidebarStore.select(.launcher)
                }
                .keyboardShortcut("n")
                Button("Open Folder…") {
                    sidebarOpenFolder()
                }
                .keyboardShortcut("o")
                Divider()
                // Browser-style: label is always "Close Session" regardless
                // of selection state. The actual handler is the keyDown monitor
                // (handleCloseShortcut here is only reached on mouse click);
                // both fall back to closing the window when no session is open.
                Button("Close Session") {
                    handleCloseShortcut()
                }
                .keyboardShortcut("w")
                Button("Close Window") {
                    if let key = NSApp.keyWindow, isCanopyWindow(key) {
                        windowCloseOnly(key)
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            // SwiftUI auto-injects a "Close" item with Cmd+W under the
            // .saveItem placement (and another under .printItem on some
            // macOS versions), duplicating our File > Close Session. We
            // have no Save / Revert / Print UX, so empty replacements are
            // the cleanest way to suppress those auto items.
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .printItem) {}
            CommandGroup(replacing: .windowList) {
                Button("Show Main Window") {
                    showMainWindow()
                }
                .keyboardShortcut("0", modifiers: .command)
                Divider()
                // Cmd+1..9 — jump to N-th visible sidebar row.
                ForEach(1...9, id: \.self) { idx in
                    Button("Switch to Row \(idx)") {
                        jumpToRow(at: idx - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(idx)")), modifiers: .command)
                }
            }
        }

        Settings {
            SettingsView()
        }
    }

    // MARK: - Sidebar shell helpers

    private func jumpToRow(at index: Int) {
        let rows = sidebarStore.displayRows
        guard index < rows.count else { return }
        let row = rows[index]
        switch row {
        case .open(let s):
            sidebarStore.select(.session(s.id))
        case .closedLocal(let entry):
            sidebarStore.openLocal(entry)
        case .closedCloud(let session):
            // openCloud schedules its own Task internally — the synchronous
            // call here is intentional (matches `Sidebar.handleClick`).
            sidebarStore.openCloud(session)
        }
    }

    private func closeActiveSession() {
        if let active = sidebarStore.activeSession {
            sidebarStore.closeSession(active.id)
        }
    }

    /// Cmd+W behaviour (browser-style): close the focused non-main window
    /// first (Settings, Sparkle alert), otherwise close the active session,
    /// otherwise close the main window itself.
    private func handleCloseShortcut() {
        if let key = NSApp.keyWindow, !isCanopyWindow(key) {
            key.performClose(nil)
            return
        }
        if sidebarStore.activeSession != nil {
            closeActiveSession()
        } else if let key = NSApp.keyWindow, isCanopyWindow(key) {
            windowCloseOnly(key)
        }
    }

    private func showMainWindow() {
        if let main = NSApp.windows.first(where: { isCanopyWindow($0) }) {
            main.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Window was closed and the SwiftUI WindowGroup released it —
            // ask the scene to spawn a fresh one.
            openWindow(id: "main")
        }
    }

    private func sidebarOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let model = UserDefaults.standard.string(forKey: "launcher.model").flatMap { $0.isEmpty ? nil : $0 }
        let effort = UserDefaults.standard.string(forKey: "launcher.effortLevel").flatMap { $0.isEmpty ? nil : $0 }
        // Use the same recents-default preference as sidebar reopens —
        // bypassing it here would leave the menu's "Open Folder…" entry as
        // the one place that ignored Settings → Default for Recents.
        sidebarStore.openNew(
            directory: url,
            model: model,
            effortLevel: effort,
            permissionMode: CanopySettings.shared.defaultPermissionMode
        )
    }
}

// MARK: - Window close interception

/// Whether a window is a Canopy app window (not a panel, settings, etc.).
/// SwiftUI's `WindowGroup(id: "main")` doesn't always preserve the literal
/// identifier — observed values in the wild include `main`, `main-AppWindow-1`,
/// and the same series for the AppKit autosave name. Settings is its own
/// scene with a `com_apple_SwiftUI_Settings_window` identifier, the Sparkle
/// updater alert is an `NSPanel`. Match permissively on either signal.
@MainActor
func isCanopyWindow(_ window: NSWindow) -> Bool {
    guard window.styleMask.contains(.titled),
          !window.isKind(of: NSPanel.self)
    else { return false }
    let id = window.identifier?.rawValue ?? ""
    let autosave = window.frameAutosaveName
    return id == "main"
        || id.hasPrefix("main-AppWindow")
        || autosave.hasPrefix("main-AppWindow")
}

/// Close or hide the window without touching any sessions. Browser-style:
/// the red title-bar button and Cmd+Shift+W always operate on the *window*,
/// never on individual sessions. If background shims are still running we
/// hide so Cmd+0 can bring the window back; if nothing is running we let
/// the window actually close.
///
/// Uses `window.close()` for the close path (bypasses delegate) so this is
/// safe to call from `windowShouldClose` without re-entering the proxy.
@MainActor
func windowCloseOnly(_ window: NSWindow) {
    if AppDelegate.isTerminating {
        window.close()
        return
    }
    if ShimProcess.hasActiveSession {
        logger.debug("Window: hiding (background sessions still running)")
        window.orderOut(nil)
    } else {
        logger.debug("Window: closing (no active sessions)")
        window.close()
    }
}

/// Proxy that intercepts windowShouldClose to hide windows instead of closing them.
/// Fallback layer — the close button override is the primary mechanism.
@MainActor
final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var originalDelegate: (any NSWindowDelegate)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if AppDelegate.isTerminating {
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }
        // Defensive fallback only. Cmd+W is intercepted upstream by the
        // global keyDown monitor; the red button and Cmd+Shift+W call
        // `windowCloseOnly` directly. If something else manages to invoke
        // `performClose(_:)` on a Canopy window, fall back to
        // window-only behaviour to avoid surprising session loss.
        logger.debug("windowShouldClose: unexpected performClose path, windowCloseOnly")
        windowCloseOnly(sender)
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(NSWindowDelegate.windowShouldClose(_:)) {
            return true
        }
        return originalDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        return originalDelegate
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var configuredWindows = NSHashTable<NSWindow>.weakObjects()
    private var delegateProxies: [ObjectIdentifier: WindowDelegateProxy] = [:]

    /// UserDefaults key holding the last main-window frame. We persist
    /// this ourselves rather than relying on AppKit's autosave because
    /// SwiftUI's `WindowGroup(id: "main")` assigns each fresh window
    /// instance its own internal autosave name (`main-AppWindow-1`,
    /// `-2`, ...), so a close + Cmd+0 round-trip
    /// keeps creating new keys and never restores the user's frame.
    private let savedFrameKey = "canopy.mainWindowFrame"

    /// Minimum sane size for a restored frame. Sub-minimum frames are
    /// dropped on read AND skipped on save, otherwise a transient
    /// teardown frame would persist and then silently fail to restore.
    private let minRestoredSize = NSSize(width: 600, height: 400)

    /// Set during app termination to bypass hide-on-close behavior.
    static var isTerminating = false

    /// Local event monitor that intercepts Cmd+W on the main window before
    /// AppKit dispatches it to `performClose(_:)`. Without this, Cmd+W flashes
    /// the red title-bar button (because performClose simulates a button click)
    /// even when we end up just closing the active session. Catching the
    /// keyDown here keeps the title bar still.
    private var cmdWMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        SidebarLogicProbe.runIfRequested()
        #endif
        NSWindow.allowsAutomaticWindowTabbing = false
        requestNotificationPermission()

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification, object: nil
        )

        installCmdWMonitor()

        // SwiftUI may make the first window main before our observer is
        // registered, in which case `didBecomeMainNotification` fires
        // before this point and we miss the chance to install the close
        // proxy / restore the saved frame. Sweep existing windows here.
        for window in NSApp.windows where isAppWindow(window) {
            configureCanopyWindow(window)
        }
    }

    /// Install a `.keyDown` local monitor that swallows Cmd+W on Canopy
    /// windows. The monitor runs before responder-chain dispatch, so neither
    /// `performClose(_:)` nor the SwiftUI menu's keyEquivalent ever fires —
    /// we route the keystroke straight to our session/window logic.
    /// Cmd+Shift+W (Close Window) is NOT consumed: only plain Cmd+W matches.
    private func installCmdWMonitor() {
        guard cmdWMonitor == nil else { return }
        cmdWMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "w"
            else { return event }
            guard let key = NSApp.keyWindow else { return event }

            // Non-Canopy window (Settings, Sparkle alert): close it normally.
            // We also have to handle this here because removing the auto File
            // > Close item from the menu would otherwise leave Cmd+W with no
            // handler in those windows.
            if !isCanopyWindow(key) {
                logger.debug("Cmd+W: non-Canopy window, performClose")
                key.performClose(nil)
                return nil
            }

            logger.debug("Cmd+W intercepted (pre-performClose)")
            if let store = SessionStore.shared, let active = store.activeSession {
                logger.debug("  → closing active session id=\(active.id.uuidString, privacy: .public)")
                store.closeSession(active.id)
            } else {
                logger.debug("  → no active session, windowCloseOnly")
                windowCloseOnly(key)
            }
            return nil // consume — no flash
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = cmdWMonitor {
            NSEvent.removeMonitor(monitor)
            cmdWMonitor = nil
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logger.info("applicationShouldHandleReopen: hasVisibleWindows=\(flag)")
        // Sidebar shell: single window. Bring the existing main window forward,
        // or let the system create a fresh one if it was actually closed.
        if let main = NSApp.windows.first(where: { isAppWindow($0) }) {
            main.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    /// Set when "Restart Now" is clicked. The actual relaunch helper is
    /// spawned inside `applicationShouldTerminate` once we have committed to
    /// quitting (and crucially while the run loop is still healthy enough to
    /// run a modal alert if the spawn fails). A canceled terminate clears
    /// this flag, so no `/bin/sh` waiter is ever left polling for our pid.
    @MainActor
    private static var shouldRelaunchOnExit = false

    /// Schedule Canopy to relaunch by routing through `NSApp.terminate(nil)`
    /// so `applicationShouldTerminate`'s active-sessions prompt and shim
    /// cleanup still run. The `/bin/sh` waiter that re-`open`s the bundle is
    /// only spawned once we've decided to terminate.
    @MainActor
    static func relaunch() {
        Self.shouldRelaunchOnExit = true
        NSApp.terminate(nil)
    }

    /// Spawn a detached `/bin/sh` that polls our pid via `kill -0` and, once
    /// we exit, `exec`s `/usr/bin/open` against the current bundle. Pid and
    /// bundle path are passed as positional args so the bundle path is never
    /// re-interpreted by the shell. Returns `true` on success; on failure
    /// the user is shown an alert and `false` is returned so the caller can
    /// abort the quit instead of leaving them with no Canopy at all.
    private func spawnRelaunchHelper() -> Bool {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open "$2""#,
            "canopy-relaunch",
            String(pid),
            bundlePath,
        ]
        // Detach stdio so the helper isn't anchored to launchd's pipes after
        // we exit. The Process object goes out of scope after run() returns,
        // which is fine — we're about to exit and launchd reaps the orphan.
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            logger.info("Relaunch helper scheduled (pid=\(pid, privacy: .public))")
            return true
        } catch {
            logger.error("Relaunch helper failed to spawn: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Couldn't Restart Canopy Automatically"
            alert.informativeText = "Quit Canopy and reopen it manually to finish applying the extension update.\n\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Sweep up shims orphaned by mid-flight reconnects so they don't trigger
        // the "session still running" prompt below — they have no UI anyway.
        ShimProcess.stopOrphanedSessions()

        if ShimProcess.hasActiveSession {
            let count = ShimProcess.activeCount
            let alert = NSAlert()
            alert.messageText = "Active Sessions Running"
            alert.informativeText = "\(count) session\(count == 1 ? " is" : "s are") still running. Quitting will stop all sessions."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if alert.runModal() == .alertSecondButtonReturn {
                // User backed out — clear the relaunch flag so the next normal
                // quit doesn't unexpectedly re-open Canopy.
                Self.shouldRelaunchOnExit = false
                return .terminateCancel
            }
        }

        // If "Restart Now" triggered this terminate, spawn the waiter now —
        // before the run loop starts winding down — so the failure alert is
        // delivered cleanly and the user can decide what to do.
        if Self.shouldRelaunchOnExit, !spawnRelaunchHelper() {
            Self.shouldRelaunchOnExit = false
            return .terminateCancel
        }

        Self.isTerminating = true
        return .terminateNow
    }

    private func isAppWindow(_ window: NSWindow) -> Bool {
        isCanopyWindow(window)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    @objc private func handleCloseButton(_ sender: NSButton) {
        guard let window = sender.window else {
            logger.warning("handleCloseButton: sender has no window reference")
            return
        }
        // The Cmd+W path is intercepted by `cmdWMonitor` before AppKit dispatches
        // `performClose(_:)`, so this only fires for real mouse clicks on the
        // red title-bar button — always window-only, never session-close.
        logger.debug("handleCloseButton: red close button clicked")
        windowCloseOnly(window)
    }

    /// Install or reinstall the close-interception delegate proxy on a window.
    private func installDelegateProxy(for window: NSWindow) {
        let windowId = ObjectIdentifier(window)
        // Already installed and still active
        if let existing = delegateProxies[windowId], window.delegate === existing { return }

        let proxy = WindowDelegateProxy()
        proxy.originalDelegate = window.delegate
        window.delegate = proxy
        delegateProxies[windowId] = proxy
    }

    @objc private func windowDidBecomeMain(_ note: Notification) {
        guard let window = note.object as? NSWindow,
              isAppWindow(window)
        else { return }
        configureCanopyWindow(window)
    }

    /// Installs the close proxy / overrides the close button / restores
    /// the saved frame and registers the resize+move+close observers.
    /// Idempotent: only the per-window-instance bits run once.
    private func configureCanopyWindow(_ window: NSWindow) {
        // Install close interception (reinstall if SwiftUI reset the delegate)
        installDelegateProxy(for: window)

        // Override close button target/action (deferred so SwiftUI finishes its setup first).
        // This is the primary close-protection mechanism.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let closeButton = window.standardWindowButton(.closeButton) {
                closeButton.target = self
                closeButton.action = #selector(self.handleCloseButton(_:))
            }
        }

        // First-time window configuration: restore the saved frame
        // ourselves (overriding SwiftUI's defaultSize / per-instance
        // autosave) and start tracking resizes so the frame survives a
        // window destroy-recreate cycle.
        guard !configuredWindows.contains(window) else { return }
        configuredWindows.add(window)

        let savedAutosave = window.frameAutosaveName
        logger.debug("configureCanopyWindow: id=\(window.identifier?.rawValue ?? "nil", privacy: .public) autosave=\(savedAutosave, privacy: .public) frame=\(NSStringFromRect(window.frame), privacy: .public)")

        if let saved = readSavedWindowFrame(forScreen: window.screen) {
            // SwiftUI applies `defaultSize` synchronously during window
            // creation, then runs view updates on this RunLoop pass. A
            // single `setFrame` call here would race against any
            // late-arriving SwiftUI restore, so we apply twice: once now,
            // once one runloop later. Both calls are no-ops if the user
            // has already started resizing.
            logger.debug("  restoring saved frame: \(NSStringFromRect(saved), privacy: .public)")
            window.setFrame(saved, display: true)
            DispatchQueue.main.async {
                window.setFrame(saved, display: true)
            }
        } else {
            logger.debug("  no saved frame yet — leaving SwiftUI defaultSize")
        }

        let resizeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window, queue: .main
        ) { [weak self] note in
            guard let self, let w = note.object as? NSWindow else { return }
            self.saveWindowFrame(w.frame)
        }

        let moveToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window, queue: .main
        ) { [weak self] note in
            guard let self, let w = note.object as? NSWindow else { return }
            self.saveWindowFrame(w.frame)
        }

        var closeToken: NSObjectProtocol?
        closeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            NotificationCenter.default.removeObserver(resizeToken)
            NotificationCenter.default.removeObserver(moveToken)
            if let closeToken {
                NotificationCenter.default.removeObserver(closeToken)
            }
            if let self {
                self.delegateProxies.removeValue(forKey: ObjectIdentifier(window))
            }
        }
    }

    private func saveWindowFrame(_ frame: NSRect) {
        // Skip below-minimum sizes so a transient zero/tiny frame during
        // teardown doesn't get persisted and then silently rejected by
        // `readSavedWindowFrame`'s `>= 600 / >= 400` clamp on next launch.
        guard frame.size.width >= minRestoredSize.width,
              frame.size.height >= minRestoredSize.height
        else { return }
        let dict: [String: Double] = [
            "x": frame.origin.x,
            "y": frame.origin.y,
            "w": frame.size.width,
            "h": frame.size.height,
        ]
        UserDefaults.standard.set(dict, forKey: savedFrameKey)
        logger.debug("saveWindowFrame: \(NSStringFromRect(frame), privacy: .public)")
    }

    /// Read the saved frame and clamp it onto the given screen so a
    /// window saved on a now-disconnected display doesn't materialize
    /// off-screen. Size is shrunk first if it exceeds the screen, then
    /// origin is clamped — otherwise `visible.maxX - rect.width` would
    /// go negative for oversized rects and the origin clamp would push
    /// the window off the left edge.
    private func readSavedWindowFrame(forScreen screen: NSScreen?) -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: savedFrameKey),
              let x = dict["x"] as? Double,
              let y = dict["y"] as? Double,
              let w = dict["w"] as? Double,
              let h = dict["h"] as? Double,
              w >= 600, h >= 400
        else { return nil }
        var rect = NSRect(x: x, y: y, width: w, height: h)
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            let clampedW = min(rect.width, visible.width)
            let clampedH = min(rect.height, visible.height)
            rect.size = NSSize(width: clampedW, height: clampedH)
            rect.origin.x = min(max(rect.origin.x, visible.minX), visible.maxX - clampedW)
            rect.origin.y = min(max(rect.origin.y, visible.minY), visible.maxY - clampedH)
        }
        return rect
    }
}
