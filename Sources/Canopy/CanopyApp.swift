import os.log
import Sparkle
import SwiftUI
import UserNotifications

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "App")

// MARK: - FocusedValue for AppState (menu commands → focused tab's AppState)

private struct FocusedAppStateKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var appState: AppState? {
        get { self[FocusedAppStateKey.self] }
        set { self[FocusedAppStateKey.self] = newValue }
    }
}

@main
struct CanopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.appState) private var focusedAppState

    /// Single-window sidebar shell flag. Set `CANOPY_SIDEBAR=1` in the
    /// environment to opt in. PR 5 will flip the default and remove the
    /// legacy WindowGroup path.
    private static let useSidebar: Bool = {
        ProcessInfo.processInfo.environment["CANOPY_SIDEBAR"] == "1"
    }()

    /// Exposed for AppDelegate's window-config logic, which needs to skip
    /// legacy multi-window resize behaviour when the new shell is active.
    static var isUsingSidebar: Bool { useSidebar }

    @State private var sidebarStore = SessionStore()

    var body: some Scene {
        WindowGroup(id: "main") {
            // Branch inside the view body, not at Scene level — SceneBuilder
            // refuses if/else producing different Scene types. The legacy
            // multi-window code lives inside this same WindowGroup; when the
            // sidebar flag is on we render a fixed single-window UI.
            Group {
                if Self.useSidebar {
                    NavigationSplitView {
                        Sidebar(store: sidebarStore)
                            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
                    } detail: {
                        Detail(store: sidebarStore)
                    }
                    .navigationSplitViewStyle(.balanced)
                    // No explicit minWidth/minHeight: that re-asserts on every
                    // app reactivation and yanks user-resized windows back to
                    // the minimum. `defaultSize` (below) handles first launch.
                } else {
                    TabContentView()
                        .frame(minWidth: 400, minHeight: 600)
                }
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: Self.useSidebar ? 1200 : 500, height: Self.useSidebar ? 800 : 800)
        .commands {
            if Self.useSidebar {
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
                    // Cmd+1..9 — jump to N-th visible sidebar row.
                    ForEach(1...9, id: \.self) { idx in
                        Button("Switch to Row \(idx)") {
                            jumpToRow(at: idx - 1)
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(idx)")), modifiers: .command)
                    }
                }
                CommandMenu("Session") {
                    Button("Close Session") {
                        closeActiveSession()
                    }
                    .keyboardShortcut("w")
                    .disabled(sidebarStore.activeSession == nil)
                    Button("Close Window") {
                        NSApp.keyWindow?.close()
                    }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    Divider()
                    Button("Open Folder…") {
                        sidebarOpenFolder()
                    }
                    .keyboardShortcut("o")
                }
            }
        }
        // Disable scene state restoration so a closed session window cannot
        // come back as a stale instance after relaunch. Pairs with
        // applicationShouldHandleReopen, which handles the in-process case.
        .restorationBehavior(.disabled)
        .commands {
            // Legacy multi-window menu commands. Skip the entire block in
            // sidebar mode so we don't double-register Cmd+N / Cmd+W /
            // Cmd+1..9 (the sidebar's own `.commands { if useSidebar }`
            // block above already wires them).
            if !Self.useSidebar {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates...") {
                        appDelegate.updaterController.updater.checkForUpdates()
                    }
                }
                CommandGroup(after: .newItem) {
                    Button("New Tab") {
                        newTab()
                    }
                    .keyboardShortcut("t")

                    Divider()

                    Button("Back to Launcher") {
                        focusedAppState?.backToLauncher()
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(focusedAppState == nil)

                    Button("Open Folder...") {
                        openFolder()
                    }
                    .keyboardShortcut("o")
                    .disabled(focusedAppState == nil)

                    Divider()

                    Button("Close and Stop Session") {
                        // close() bypasses windowShouldClose/handleCloseButton, closing directly
                        NSApp.keyWindow?.close()
                    }
                    .keyboardShortcut("w", modifiers: [.command, .option])
                }
                CommandGroup(after: .toolbar) {
                    ForEach(1...9, id: \.self) { index in
                        Button("Select Tab \(index)") {
                            selectTab(at: index - 1)
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                    }
                }
            }
            if !Self.useSidebar {
                CommandGroup(after: .windowList) {
                    let hiddenWindows = NSApp.windows.filter {
                        isCanopyWindow($0) && !$0.isVisible && $0.tabbedWindows == nil
                    }
                    if !hiddenWindows.isEmpty {
                        Divider()
                        Section("Hidden Windows") {
                            ForEach(hiddenWindows, id: \.windowNumber) { window in
                                Button(window.title.isEmpty ? "Canopy" : window.title) {
                                    window.makeKeyAndOrderFront(nil)
                                }
                            }
                        }
                    }
                }
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

    private func sidebarOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let model = UserDefaults.standard.string(forKey: "launcher.model").flatMap { $0.isEmpty ? nil : $0 }
        let effort = UserDefaults.standard.string(forKey: "launcher.effortLevel").flatMap { $0.isEmpty ? nil : $0 }
        let permission = PermissionMode(rawValue: UserDefaults.standard.string(forKey: "launcher.permissionMode") ?? "") ?? .acceptEdits
        sidebarStore.openNew(directory: url, model: model, effortLevel: effort, permissionMode: permission)
    }

    private func openFolder() {
        guard let targetState = focusedAppState else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            let model = UserDefaults.standard.string(forKey: "launcher.model").flatMap { $0.isEmpty ? nil : $0 }
            let effort = UserDefaults.standard.string(forKey: "launcher.effortLevel").flatMap { $0.isEmpty ? nil : $0 }
            let permission = PermissionMode(rawValue: UserDefaults.standard.string(forKey: "launcher.permissionMode") ?? "") ?? .acceptEdits
            targetState.launchSession(directory: url, model: model, effortLevel: effort, permissionMode: permission)
        }
    }

    private func selectTab(at index: Int) {
        guard let window = NSApp.keyWindow,
              let tabs = window.tabbedWindows,
              index < tabs.count
        else { return }
        tabs[index].makeKeyAndOrderFront(nil)
    }

    private func newTab() {
        guard let existingWindow = NSApp.keyWindow else {
            openWindow(id: "main")
            return
        }

        let contentView = NSHostingView(rootView: TabContentView().frame(minWidth: 400, minHeight: 600))
        let newWindow = NSWindow(
            contentRect: existingWindow.contentLayoutRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        newWindow.contentView = contentView
        newWindow.identifier = NSUserInterfaceItemIdentifier("main-tab")
        newWindow.isReleasedWhenClosed = false
        existingWindow.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Window close interception

/// Whether a window is a Canopy app window (not a panel, settings, etc.)
@MainActor
func isCanopyWindow(_ window: NSWindow) -> Bool {
    window.identifier?.rawValue.hasPrefix("main") == true
        && window.styleMask.contains(.titled)
        && !window.isKind(of: NSPanel.self)
}

/// Reentrancy guard for hideOrCloseWindow — prevents stacked modal alerts.
@MainActor
private var isShowingCloseAlert = false

/// Decides whether to hide, close, or prompt for a window. Returns `true` if the close was handled
/// (hidden or cancelled). Shared by all three close-interception layers.
@MainActor
func hideOrCloseWindow(_ window: NSWindow) -> Bool {
    // App termination: allow real close
    if AppDelegate.isTerminating {
        logger.debug("Window close: allowing real close (terminating)")
        return false
    }

    // Tab in a group with other tabs: close just this tab
    if let tabs = window.tabbedWindows, tabs.count > 1 {
        logger.debug("Window close: closing tab (\(tabs.count) tabs in group)")
        return false
    }

    // No active session in this window: allow normal close
    if !ShimProcess.hasActiveSession(in: window) {
        logger.debug("Window close: no active session, allowing close")
        return false
    }

    // Prevent stacked alerts from rapid Cmd+W or double-clicks
    guard !isShowingCloseAlert else {
        logger.debug("Window close: alert already showing, ignoring")
        return true
    }
    isShowingCloseAlert = true
    defer { isShowingCloseAlert = false }

    // Active session: ask user what to do
    let alert = NSAlert()
    alert.messageText = "Session is Running"
    alert.informativeText = "This window has an active session. What would you like to do?"
    alert.addButton(withTitle: "Hide Window")
    alert.addButton(withTitle: "Stop Session and Close")
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
        // Stop the shim synchronously here — relying on SwiftUI's dismantleNSView
        // to do it later leaves the Node.js process running long enough for
        // applicationShouldTerminate to think a session is still active.
        ShimProcess.stopAllSessions(in: window)
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
/// Fallback layer — the close button override and key monitor are the primary mechanisms.
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
    private var resizeObservers: [NSObjectProtocol] = []
    private var delegateProxies: [ObjectIdentifier: WindowDelegateProxy] = [:]
    private var keyMonitor: Any?

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

        // Intercept Cmd+W to hide window instead of closing it.
        // This is more reliable than delegate proxy alone, since SwiftUI may override the delegate.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command,
                  event.charactersIgnoringModifiers == "w"
            else { return event }
            let handled = MainActor.assumeIsolated {
                guard let window = NSApp.keyWindow,
                      self.isAppWindow(window)
                else { return false }

                // Cmd+W: hide or close tab
                if !hideOrCloseWindow(window) {
                    window.close()
                }
                return true
            }
            return handled ? nil : event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logger.info("applicationShouldHandleReopen: hasVisibleWindows=\(flag)")
        // Sidebar shell: single window, no legacy restoration. Bring the
        // existing main window forward (or let the system create a fresh
        // one if it was actually closed).
        if CanopyApp.isUsingSidebar {
            if let main = NSApp.windows.first(where: { isAppWindow($0) }) {
                main.makeKeyAndOrderFront(nil)
                return false
            }
            return true
        }
        if !flag {
            let hiddenWindows = NSApp.windows.filter { isAppWindow($0) && !$0.isVisible }
            // hasRunningProcess (not hasActiveSession): "Stop and Close" leaves the
            // webView attached but kills the process, so the looser check would
            // misclassify those windows as active and resurrect a dead session.
            let active = hiddenWindows.filter { ShimProcess.hasRunningProcess(in: $0) }
            let stale = hiddenWindows.filter { !ShimProcess.hasRunningProcess(in: $0) }
            logger.info("reopen: hidden=\(hiddenWindows.count) active=\(active.count) stale=\(stale.count)")

            // SwiftUI's WindowGroup keeps closed windows around so the reopen
            // event can resurrect them. close() with isReleasedWhenClosed=true
            // tells AppKit to drop this one for real.
            for window in stale {
                window.isReleasedWhenClosed = true
                window.close()
            }

            if !active.isEmpty {
                for window in active {
                    window.makeKeyAndOrderFront(nil)
                }
                return false
            }

            // No window with an active session — surface a fresh launcher. Built by
            // hand instead of openWindow(id:) because a closed WindowGroup instance
            // would be reused, resurrecting the stale session state we just hid.
            openFreshLauncherWindow()
            return false
        }
        return true
    }

    private func openFreshLauncherWindow() {
        let defaults = UserDefaults.standard
        let savedWidth = defaults.object(forKey: "lastWindowWidth") != nil
            ? defaults.double(forKey: "lastWindowWidth") : 500
        let savedHeight = defaults.object(forKey: "lastWindowHeight") != nil
            ? defaults.double(forKey: "lastWindowHeight") : 800
        let width = max(savedWidth, 400)
        let height = max(savedHeight, 600)

        let hostingView = NSHostingView(rootView: TabContentView().frame(minWidth: 400, minHeight: 600))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.contentView = hostingView
        // "main-launcher" prefix keeps isAppWindow happy without colliding with
        // the WindowGroup id ("main") or the newTab id ("main-tab").
        window.identifier = NSUserInterfaceItemIdentifier("main-launcher")
        // Mirror .restorationBehavior(.disabled) on the WindowGroup; this window
        // is built outside the SwiftUI scene tree, so the modifier doesn't reach it.
        window.isRestorable = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        logger.info("opened fresh launcher window")
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

        // Install close interception (reinstall if SwiftUI reset the delegate)
        installDelegateProxy(for: window)

        // Override close button target/action (deferred so SwiftUI finishes its setup first).
        // This is the primary mechanism — more reliable than the delegate proxy.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let closeButton = window.standardWindowButton(.closeButton) {
                closeButton.target = self
                closeButton.action = #selector(self.handleCloseButton(_:))
            }
        }

        // First-time window configuration
        guard !configuredWindows.contains(window) else { return }
        configuredWindows.add(window)

        // Sidebar shell uses Window scene with defaultSize + macOS's built-in
        // window-state restoration. Don't reapply legacy lastWindowWidth /
        // lastWindowHeight on every reactivation — that yanks the window
        // back to the legacy default whenever the user switches apps.
        if CanopyApp.isUsingSidebar { return }

        let otherWindow = NSApp.windows.first {
            $0 !== window
                && $0.styleMask.contains(.titled)
                && $0.isVisible
                && !$0.isKind(of: NSPanel.self)
                && $0.identifier?.rawValue.contains("main") == true
        }
        // Use async to run after SwiftUI finishes its layout pass
        DispatchQueue.main.async {
            if let other = otherWindow, other.frame.width > 100 {
                var frame = window.frame
                frame.size = other.frame.size
                window.setFrame(frame, display: true)
            } else {
                // No other window — use saved size or default
                let defaults = UserDefaults.standard
                let savedWidth = defaults.object(forKey: "lastWindowWidth") != nil
                    ? defaults.double(forKey: "lastWindowWidth") : 500
                let savedHeight = defaults.object(forKey: "lastWindowHeight") != nil
                    ? defaults.double(forKey: "lastWindowHeight") : 800
                let width = max(savedWidth, 400)
                let height = max(savedHeight, 600)
                var frame = window.frame
                frame.size = NSSize(width: width, height: height)
                window.setFrame(frame, display: true)
            }
        }

        // Save window size on resize; clean up when window closes
        let resizeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window, queue: .main
        ) { note in
            guard let w = note.object as? NSWindow else { return }
            UserDefaults.standard.set(w.frame.width, forKey: "lastWindowWidth")
            UserDefaults.standard.set(w.frame.height, forKey: "lastWindowHeight")
        }
        resizeObservers.append(resizeToken)

        var closeToken: NSObjectProtocol?
        closeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            NotificationCenter.default.removeObserver(resizeToken)
            if let closeToken {
                NotificationCenter.default.removeObserver(closeToken)
            }
            self?.resizeObservers.removeAll { $0 === resizeToken }
            if let self {
                self.delegateProxies.removeValue(forKey: ObjectIdentifier(window))
            }
        }
    }
}

// MARK: - Tab content (each window/tab owns its own state)

struct TabContentView: View {
    @State private var appState = AppState()
    @State private var statusBarData = StatusBarData()
    @State private var connectionState = ConnectionState()
    @State private var crashMessage: String?

    var body: some View {
        Group {
            switch appState.screen {
            case .launcher:
                LauncherView(appState: appState)
            case .session:
                VStack(spacing: 0) {
                    WebViewContainer(
                        workingDirectory: appState.workingDirectory,
                        resumeSessionId: appState.resumeSessionId,
                        model: appState.model,
                        effortLevel: appState.effortLevel,
                        permissionMode: appState.permissionMode,
                        sessionTitle: appState.resumeSessionTitle,
                        statusBarData: statusBarData,
                        remoteHost: appState.remoteHost,
                        connectionState: connectionState,
                        onCrash: { status in
                            logger.error("Session crashed (status \(status)), returning to launcher")
                            crashMessage = "Claude process exited unexpectedly (exit code \(status))."
                            appState.backToLauncher()
                        }
                    )
                    .overlay {
                        ConnectionOverlayView(
                            connectionState: connectionState,
                            onBackToLauncher: {
                                connectionState.status = .connected
                                appState.backToLauncher()
                            }
                        )
                    }
                    .animation(.easeInOut(duration: 0.3), value: connectionState.isOverlayVisible)
                    StatusBarView(data: statusBarData)
                }
                .id(appState.webviewReloadToken)
                .onChange(of: appState.webviewReloadToken) {
                    connectionState.status = .connected
                    connectionState.onRetry = nil
                }
            }
        }
        // Only set title for launcher; session title is managed by ShimProcess
        .windowTitle(appState.screen == .launcher ? "Canopy" : nil)
        .alert("Session Ended", isPresented: Binding(get: { crashMessage != nil }, set: { if !$0 { crashMessage = nil } })) {
            Button("OK") { crashMessage = nil }
        } message: {
            Text(crashMessage ?? "")
        }
        .focusedSceneValue(\.appState, appState)
        .onAppear {
            appState.statusBarData = statusBarData
            // Debug: auto-launch session (defaults write sh.saqoo.Canopy debugAutoLaunchDir /tmp)
            if let dir = appState.debugAutoLaunchDir, appState.screen == .launcher {
                appState.debugAutoLaunchDir = nil
                let m = UserDefaults.standard.string(forKey: "launcher.model").flatMap { $0.isEmpty ? nil : $0 }
                let e = UserDefaults.standard.string(forKey: "launcher.effortLevel").flatMap { $0.isEmpty ? nil : $0 }
                let p = PermissionMode(rawValue: UserDefaults.standard.string(forKey: "launcher.permissionMode") ?? "") ?? .acceptEdits
                appState.launchSession(directory: URL(fileURLWithPath: dir), model: m, effortLevel: e, permissionMode: p)
            }
        }
    }
}

// MARK: - Window title helper

private struct WindowTitleSetter: NSViewRepresentable {
    let title: String?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let title else { return } // nil = don't touch the title (managed elsewhere)
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}

extension View {
    func windowTitle(_ title: String?) -> some View {
        background(WindowTitleSetter(title: title))
    }
}
