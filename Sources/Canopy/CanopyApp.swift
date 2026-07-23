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
        .windowStyle(.hiddenTitleBar)
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
                    if sidebarStore.panes.isEmpty {
                        sidebarStore.select(.launcher)
                    } else {
                        sidebarStore.openLauncherInFocusedPane()
                    }
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
                // Multi-pane: Cmd+W / this button closes the focused pane.
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
                // Cmd+1..9 — focus the N-th pane (browser-tab semantics).
                // Grayed out when fewer than N panes exist so the shortcut
                // never lands on a phantom pane.
                ForEach(1...9, id: \.self) { idx in
                    Button("Focus Pane \(idx)") {
                        focusPane(at: idx - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(idx)")), modifiers: .command)
                    .disabled(!sidebarStore.panes.indices.contains(idx - 1))
                }
            }
            CommandMenu("Panes") {
                Button("Focus Previous Pane") {
                    sidebarStore.moveFocus(delta: -1, wrap: true)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(sidebarStore.panes.count < 2)

                Button("Focus Next Pane") {
                    sidebarStore.moveFocus(delta: +1, wrap: true)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(sidebarStore.panes.count < 2)

                Divider()

                Button("Load Previous Session") {
                    sidebarStore.cycleFocusedPaneSession(delta: -1)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(sidebarStore.panes.isEmpty)

                Button("Load Next Session") {
                    sidebarStore.cycleFocusedPaneSession(delta: +1)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(sidebarStore.panes.isEmpty)

                Divider()

                // Cmd+Ctrl+1..9 — load the N-th visible open row into the
                // focused pane. If that session already lives in another
                // pane, focus jumps to it (openInFocusedPane fallback).
                // Cmd+Shift+3..6 conflict with macOS screenshot shortcuts,
                // and Cmd+Opt+arrows already move pane focus, so Cmd+Ctrl
                // is the cleanest unused modifier here.
                ForEach(1...9, id: \.self) { idx in
                    Button("Load Session \(idx) into Pane") {
                        loadSessionIntoFocusedPane(sidebarIndex: idx - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(idx)")), modifiers: [.command, .control])
                    .disabled(sidebarStore.panes.isEmpty || !visibleOpenSessionIds.indices.contains(idx - 1))
                }
            }
        }

        Settings {
            SettingsView()
        }
    }

    // MARK: - Sidebar shell helpers

    private func focusPane(at index: Int) {
        // Cmd+1..9: move focus to the N-th pane. Out-of-range is a no-op
        // (the menu button is also disabled, but guard here for safety).
        guard sidebarStore.panes.indices.contains(index) else { return }
        sidebarStore.setFocusedPaneIndex(index)
    }

    /// Sidebar's visible open session IDs, in the order they appear. Drives
    /// Cmd+Shift+1..9's target lookup and per-item enable state.
    private var visibleOpenSessionIds: [UUID] {
        sidebarStore.visibleRows.compactMap { row in
            if case .open(let s) = row { return s.id } else { return nil }
        }
    }

    private func loadSessionIntoFocusedPane(sidebarIndex: Int) {
        // Cmd+Shift+1..9: swap the focused pane's content to the N-th visible
        // open row. Out-of-range is a no-op (also disabled at the menu).
        guard !sidebarStore.panes.isEmpty,
              visibleOpenSessionIds.indices.contains(sidebarIndex) else { return }
        sidebarStore.openInFocusedPane(visibleOpenSessionIds[sidebarIndex])
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

/// Cmd+W behaviour (browser-style): with 2+ panes, close the focused
/// pane; otherwise fall through to the single-pane legacy path
/// (non-main window → active session → main window).
/// Shared by the SwiftUI File > Close Session menu button and the
/// AppDelegate keyDown monitor so both paths stay in lockstep.
@MainActor
func handleCloseShortcut() {
    // Non-Canopy window (Settings, Sparkle alert): close it first — the
    // keyDown monitor must handle this because File > Close is suppressed.
    if let key = NSApp.keyWindow, !isCanopyWindow(key) {
        logger.debug("Cmd+W: non-Canopy window, performClose")
        key.performClose(nil)
        return
    }
    guard let store = SessionStore.shared else {
        if let key = NSApp.keyWindow, isCanopyWindow(key) {
            windowCloseOnly(key)
        }
        return
    }
    if store.panes.count > 1 {
        logger.debug("Cmd+W: closing focused pane at \(store.focusedPaneIndex)")
        store.closePane(at: store.focusedPaneIndex)
    } else {
        legacyCloseAction()
    }
}

/// Single-pane / no-pane Cmd+W: close the focused non-main window
/// first (Settings, Sparkle alert), otherwise close the active session,
/// otherwise close the main window itself.
@MainActor
func legacyCloseAction() {
    if let key = NSApp.keyWindow, !isCanopyWindow(key) {
        key.performClose(nil)
        return
    }
    if let store = SessionStore.shared, let active = store.activeSession {
        logger.debug("Cmd+W: closing active session id=\(active.id.uuidString, privacy: .public)")
        store.closeSession(active.id)
    } else if let key = NSApp.keyWindow, isCanopyWindow(key) {
        logger.debug("Cmd+W: no active session, windowCloseOnly")
        windowCloseOnly(key)
    }
}

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
    private var paneFocusClickMonitor: Any?

    // NOTE: there is deliberately NO app-wide didResizeNotification observer
    // feeding pane state. An earlier iteration distributed manual window-
    // resize deltas into pane preferredWidths from such an observer, which
    // produced a runaway growth feedback loop (distribute grows panes,
    // SwiftUI grows the window to fit, observer sees the growth as a manual
    // drag, distributes again, forever). WeightedPaneLayout derives visual
    // pane widths from the proposed bounds, so manual resize needs no state
    // change; weights are re-synced to visual widths at every pane-list
    // mutation and at divider-drag start via
    // SessionStore.normalizePaneWeightsToVisualWidths(). The per-window
    // frame-persistence observer in configureCanopyWindow is separate and
    // only saves the frame.

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
        installPaneFocusClickMonitor()

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
            guard NSApp.keyWindow != nil else { return event }

            logger.debug("Cmd+W intercepted (pre-performClose)")
            handleCloseShortcut()
            return nil // consume — no flash
        }
    }

    /// Distributes manual window-width deltas across pane preferredWidths.
    /// Route left-mouse-down clicks inside the detail column to pane focus.
    /// WKWebView eats mouse events entirely, so the SwiftUI
    /// `.simultaneousGesture(TapGesture())` on `paneCell` never fires when
    /// the user clicks the chat input or any webview surface. A local
    /// NSEvent monitor intercepts the event before AppKit dispatch: we
    /// look at the click's window-space x, subtract sidebar width, and
    /// pick which pane owns that x range. Pass the event through
    /// unchanged so WKWebView still
    /// receives it.
    private func installPaneFocusClickMonitor() {
        guard paneFocusClickMonitor == nil else { return }
        paneFocusClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window, isCanopyWindow(window),
                  let store = SessionStore.shared,
                  store.panes.count > 1 else { return event }

            // Click location in window coordinates (bottom-left origin).
            let loc = event.locationInWindow
            let contentHeight = window.contentView?.bounds.height ?? window.frame.height
            let clickX = loc.x
            let clickYFromTop = contentHeight - loc.y

            // Only route clicks inside the detail column area.
            let sidebar = PaneWindowSizer.measuredSidebarWidthTrustingCollapse(in: window)
            guard clickX > sidebar else { return event }

            // Skip the title bar so window-drag clicks don't move focus.
            let titleBarHeight: CGFloat = 28
            guard clickYFromTop > titleBarHeight else { return event }

            // preferredWidth is a weight. Use the same layout algorithm
            // (WeightedPaneLayout via PaneLayoutMetrics) as Detail.swift
            // so click hit-testing exactly matches the visual layout.
            let contentWidth = window.contentView?.bounds.width ?? window.frame.width
            let detailW = max(0, contentWidth - sidebar)
            let widths = PaneLayoutMetrics.paneWidths(
                detailWidth: detailW,
                weights: store.panes.map(\.preferredWidth),
                dividerWidth: SessionStore.paneDividerWidth,
                minimumWidth: SessionStore.paneMinDragWidth
            )
            var xCursor = sidebar
            for index in store.panes.indices {
                let paneW = index < widths.count ? widths[index] : 0
                let paneEnd = xCursor + paneW
                if clickX >= xCursor && clickX < paneEnd {
                    if index != store.focusedPaneIndex {
                        store.setFocusedPaneIndex(index)
                    }
                    break
                }
                xCursor = paneEnd + SessionStore.paneDividerWidth
            }
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        normalizeSavedFrameForSinglePane()
        if let monitor = cmdWMonitor {
            NSEvent.removeMonitor(monitor)
            cmdWMonitor = nil
        }
        if let paneFocusClickMonitor {
            NSEvent.removeMonitor(paneFocusClickMonitor)
            self.paneFocusClickMonitor = nil
        }
    }

    /// Quitting with 2+ panes leaves the multi-pane window width in the
    /// saved frame, but panes are NOT restored on launch (Phase A: no
    /// auto-spawn) — so the next session would open as one giant pane
    /// spanning the whole multi-pane-wide window. Rewrite the saved width
    /// to sidebar + the focused pane's current visual width, i.e. the
    /// window the user would get by closing the other panes before quit.
    private func normalizeSavedFrameForSinglePane() {
        guard let store = SessionStore.shared,
              store.panes.count > 1,
              let window = NSApp.windows.first(where: { isCanopyWindow($0) })
        else { return }
        let sidebar = PaneWindowSizer.measuredSidebarWidthTrustingCollapse(in: window)
        let detailW = max(0, window.frame.width - sidebar)
        let widths = PaneLayoutMetrics.paneWidths(
            detailWidth: detailW,
            weights: store.panes.map(\.preferredWidth),
            dividerWidth: SessionStore.paneDividerWidth,
            minimumWidth: SessionStore.paneMinDragWidth
        )
        let focusedW = widths.indices.contains(store.focusedPaneIndex)
            ? widths[store.focusedPaneIndex]
            : (widths.first ?? SessionStore.paneDefaultWidth)
        var frame = window.frame
        frame.size.width = sidebar + focusedW
        logger.info("normalizeSavedFrameForSinglePane: \(Int(window.frame.width)) → \(Int(frame.size.width)) (sidebar=\(Int(sidebar)) focusedPane=\(Int(focusedW)))")
        saveWindowFrame(frame)
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

/// Resizes the main window to fit the current pane layout, applying the
/// "grow on add / shrink on close" contract from the spec. Falls back to
/// equal-share across all panes when the desired width exceeds the current
/// screen.
enum PaneWindowSizer {
    /// Matches the ideal from navigationSplitViewColumnWidth(min:220, ideal:280, max:360)
    /// in CanopyApp.swift's NavigationSplitView; the fallback branch tolerates
    /// drift at min/max ranges.
    static let assumedSidebarWidth: CGFloat = 280

    @MainActor
    static func applyForCurrentPanes(store: SessionStore) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && isCanopyWindow($0) })
                          ?? NSApp.windows.first(where: { isCanopyWindow($0) }),
              let screen = window.screen ?? NSScreen.main else {
            logger.info("PaneWindowSizer: no Canopy window found; skipping resize")
            return
        }
        // Empty panes → leave the window alone. Resizing to sidebar-only
        // would collapse the frame while closeSession is still settling
        // selection onto the next open session / launcher.
        guard !store.panes.isEmpty else {
            logger.info("[Pane] Sizer: panes empty; skipping resize")
            return
        }

        let sidebar = measuredSidebarWidthTrustingCollapse(in: window)
        let dividers = CGFloat(max(0, store.panes.count - 1)) * SessionStore.paneDividerWidth
        let sumPaneW = store.panes.reduce(0) { $0 + $1.preferredWidth }
        let target = sidebar + sumPaneW + dividers
        let screenMax = screen.visibleFrame.width
        let currentW = window.frame.width

        let paneWidths = store.panes.map { Int($0.preferredWidth) }
        logger.info("[Pane] Sizer.apply: panes=\(paneWidths) sidebar=\(Int(sidebar)) sumPaneW=\(Int(sumPaneW)) dividers=\(Int(dividers)) target=\(Int(target)) screenMax=\(Int(screenMax)) currentWindowW=\(Int(currentW))")

        var newFrame = window.frame
        if target <= screenMax {
            newFrame.size.width = target
            logger.info("[Pane] Sizer: target fits (\(Int(target))<=\(Int(screenMax))); setting window width to target")
        } else {
            // Fallback: cap at screen and equal-share the detail column.
            let detailBudget = max(0, screenMax - sidebar - dividers)
            let share = detailBudget / CGFloat(store.panes.count)
            logger.warning("[Pane] Sizer FALLBACK: target=\(Int(target))>screenMax=\(Int(screenMax)); equal-share each pane to \(Int(share))pt")
            for i in store.panes.indices {
                store.forceSetPaneWidth(at: i, to: share)
            }
            newFrame.size.width = screenMax
        }

        // Clamp origin.x so the wider window doesn't shoot off-screen.
        if newFrame.maxX > screen.visibleFrame.maxX {
            newFrame.origin.x = max(screen.visibleFrame.minX, screen.visibleFrame.maxX - newFrame.width)
        }

        // Non-animated: setFrame(_:display:) grows/shrinks the window in
        // a single frame. Animation caused the embedded WKWebView's
        // scroll position to drift while intermediate frames sized the
        // web content column mid-flight.
        logger.info("[Pane] Sizer: resizing window \(Int(currentW)) → \(Int(newFrame.size.width))")
        window.setFrame(newFrame, display: true)
    }

    /// The single sidebar-width measurement shared by ALL consumers — the
    /// sizer (`applyForCurrentPanes`), the click monitor's hit-testing,
    /// quit-time frame normalization, and
    /// `SessionStore.normalizePaneWeightsToVisualWidths`. Trusts any
    /// laid-out split view verbatim: a measured 0 means the user really
    /// collapsed the sidebar, and treating it as 280 would shift pane
    /// hit-tests right by the phantom sidebar (click pane N → focus pane
    /// N−1, Cmd+W closes the wrong pane) or inflate the sizer's window
    /// target by 280 pt per pane operation. The `split.frame.width > 0`
    /// guard covers the startup false positive (split view not yet laid
    /// out reads as zero-width — sizing from that once caused a window
    /// grow/shrink loop back when a didResize observer fed pane state;
    /// that observer is gone, but the guard stays cheap and correct).
    /// All consumers MUST share one measurement: an earlier iteration
    /// where the sizer distrusted a collapsed sidebar (assumed 280) while
    /// weight normalization trusted it made every pane add/close drift
    /// the window ~280 pt wider whenever the sidebar was collapsed.
    @MainActor
    static func measuredSidebarWidthTrustingCollapse(in window: NSWindow) -> CGFloat {
        guard let split = findSplitView(in: window), split.frame.width > 0,
              let sidebar = split.arrangedSubviews.first
        else { return assumedSidebarWidth }
        return sidebar.frame.width
    }

    /// NavigationSplitView is backed by an NSSplitView on macOS; BFS the
    /// content view for it.
    @MainActor
    private static func findSplitView(in window: NSWindow) -> NSSplitView? {
        guard let root = window.contentView else { return nil }
        var queue: [NSView] = [root]
        while let view = queue.first {
            queue.removeFirst()
            if let split = view as? NSSplitView { return split }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}
