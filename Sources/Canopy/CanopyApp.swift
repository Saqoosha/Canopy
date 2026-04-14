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

    var body: some Scene {
        WindowGroup(id: "main") {
            TabContentView()
                .frame(minWidth: 400, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 500, height: 800)
        .commands {
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

        Settings {
            SettingsView()
        }
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
        return false // Let the caller close the window (kills session)
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
        if !flag {
            let hiddenWindows = NSApp.windows.filter { isAppWindow($0) && !$0.isVisible }
            if !hiddenWindows.isEmpty {
                for window in hiddenWindows {
                    window.makeKeyAndOrderFront(nil)
                }
                return false
            }
            // No hidden windows — let SwiftUI open a new one
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
