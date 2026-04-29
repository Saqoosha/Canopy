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
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    sidebarStore.select(.launcher)
                }
                .keyboardShortcut("n")
            }
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
            CommandMenu("Session") {
                // Cmd+W closes the active session ONLY when the main
                // Canopy window is key. If Settings, the Sparkle update
                // alert, or another window is key, fall through to its
                // own close handler — otherwise Cmd+W in Settings would
                // kill the user's session.
                Button(closeShortcutTitle) {
                    handleCloseShortcut()
                }
                .keyboardShortcut("w")
                Button("Close Window") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                Button("Open Folder…") {
                    sidebarOpenFolder()
                }
                .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
        }
    }

    // MARK: - Sidebar shell helpers

    private func jumpToRow(at index: Int) {
        let rows = sidebarStore.visibleRows
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

    /// Cmd+W menu-item title. Reflects what the shortcut will do given
    /// the current key window + active-session state.
    private var closeShortcutTitle: String {
        let key = NSApp.keyWindow
        if let key, !isCanopyWindow(key) {
            return "Close Window"
        }
        return sidebarStore.activeSession == nil ? "Close Window" : "Close Session"
    }

    /// Cmd+W behaviour: close the focused non-main window first
    /// (Settings, Sparkle alert), otherwise close the active session,
    /// otherwise fall through to closing the main window.
    private func handleCloseShortcut() {
        if let key = NSApp.keyWindow, !isCanopyWindow(key) {
            key.performClose(nil)
            return
        }
        if sidebarStore.activeSession != nil {
            closeActiveSession()
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    private func showMainWindow() {
        if let main = NSApp.windows.first(where: { isCanopyWindow($0) }) {
            main.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Window was closed (e.g. via "Stop Sessions and Close") and the
            // SwiftUI WindowGroup released it — ask the scene to spawn a
            // fresh one.
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

/// Reentrancy guard for hideOrCloseWindow — prevents stacked modal alerts.
@MainActor
private var isShowingCloseAlert = false

/// Decides whether to hide, close, or prompt for a window. Returns `true` if the close was handled
/// (hidden or cancelled).
@MainActor
func hideOrCloseWindow(_ window: NSWindow) -> Bool {
    // App termination: allow real close
    if AppDelegate.isTerminating {
        logger.debug("Window close: allowing real close (terminating)")
        return false
    }

    // No active session: allow normal close
    if !ShimProcess.hasActiveSession {
        logger.debug("Window close: no active sessions, allowing close")
        return false
    }

    // Prevent stacked alerts from rapid Cmd+W or double-clicks
    guard !isShowingCloseAlert else {
        logger.debug("Window close: alert already showing, ignoring")
        return true
    }
    isShowingCloseAlert = true
    defer { isShowingCloseAlert = false }

    let count = ShimProcess.activeCount
    let alert = NSAlert()
    alert.messageText = count == 1 ? "Session is Running" : "Sessions are Running"
    alert.informativeText = "Closing the window keeps \(count) session\(count == 1 ? "" : "s") running in the background. Stop them or hide the window?"
    alert.addButton(withTitle: "Hide Window")
    alert.addButton(withTitle: "Stop Sessions and Close")
    alert.addButton(withTitle: "Cancel")
    alert.buttons[2].keyEquivalent = "\u{1b}" // Esc key for Cancel
    alert.alertStyle = .informational

    let response = alert.runModal()
    switch response {
    case .alertFirstButtonReturn:
        logger.debug("Window close: user chose hide")
        window.orderOut(nil)
        return true
    case .alertSecondButtonReturn:
        logger.debug("Window close: user chose stop and close")
        // Stop every running shim AND clear the SessionStore. Killing
        // shims alone leaves dead `OpenSession` rows behind; the App
        // scene's `@State sidebarStore` survives the window destroy, so a
        // Cmd+0 reopen + click would otherwise re-mount one of those rows
        // whose cached shim already exited — `WebViewContainer.buildWebView`
        // would skip the start path and the user would see a stale WebView
        // with no live CLI.
        ShimProcess.stopAllSessions()
        SessionStore.shared?.closeAllSessions()
        return false // Let the caller close the window
    case .alertThirdButtonReturn:
        logger.debug("Window close: user cancelled")
        return true
    default:
        logger.warning("Window close: unexpected modal response \(response.rawValue), treating as cancel")
        return true
    }
}

/// Proxy that intercepts windowShouldClose to hide windows instead of closing them.
/// Fallback layer — the close button override is the primary mechanism.
@MainActor
final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var originalDelegate: (any NSWindowDelegate)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if hideOrCloseWindow(sender) {
            return false // Was hidden, don't close
        }
        return originalDelegate?.windowShouldClose?(sender) ?? true
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
    /// `-2`, ...), so a "Stop Sessions and Close" + Cmd+0 round-trip
    /// keeps creating new keys and never restores the user's frame.
    private let savedFrameKey = "canopy.mainWindowFrame"

    /// Minimum sane size for a restored frame. Sub-minimum frames are
    /// dropped on read AND skipped on save, otherwise a transient
    /// teardown frame would persist and then silently fail to restore.
    private let minRestoredSize = NSSize(width: 600, height: 400)

    /// Set during app termination to bypass hide-on-close behavior.
    static var isTerminating = false

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

        // SwiftUI may make the first window main before our observer is
        // registered, in which case `didBecomeMainNotification` fires
        // before this point and we miss the chance to install the close
        // proxy / restore the saved frame. Sweep existing windows here.
        for window in NSApp.windows where isAppWindow(window) {
            configureCanopyWindow(window)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Sweep up shims orphaned by mid-flight reconnects so they don't trigger
        // the "session still running" prompt below — they have no UI anyway.
        ShimProcess.stopOrphanedSessions()

        guard ShimProcess.hasActiveSession else {
            Self.isTerminating = true
            return .terminateNow
        }

        let count = ShimProcess.activeCount
        let alert = NSAlert()
        alert.messageText = "Active Sessions Running"
        alert.informativeText = "\(count) session\(count == 1 ? " is" : "s are") still running. Quitting will stop all sessions."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertSecondButtonReturn {
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
        if !hideOrCloseWindow(window) {
            window.close()
        }
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
