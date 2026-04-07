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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        requestNotificationPermission()

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification, object: nil
        )
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    @objc private func windowDidBecomeMain(_ note: Notification) {
        guard let window = note.object as? NSWindow,
              !configuredWindows.contains(window),
              window.styleMask.contains(.titled),
              !window.isKind(of: NSPanel.self)
        else { return }
        // Only handle app windows (WindowGroup id: "main" and newTab windows)
        let isAppWindow = window.identifier?.rawValue.contains("main") == true
        guard isAppWindow else { return }
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
