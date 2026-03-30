import SwiftUI
import UserNotifications

@main
struct HangarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            TabContentView()
                .frame(minWidth: 400, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 500, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") {
                    newTab()
                }
                .keyboardShortcut("t")

                Divider()

                Button("Back to Launcher") {
                    ActiveTabState.shared.backToLauncher()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Open Folder...") {
                    ActiveTabState.shared.openFolder()
                }
                .keyboardShortcut("o")
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
        newWindow.isReleasedWhenClosed = false
        existingWindow.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Active tab state bridge (menu commands → active tab's AppState)

/// Tracks the active tab's AppState so menu commands can target it.
@MainActor
final class ActiveTabState {
    static let shared = ActiveTabState()
    weak var current: AppState?

    func backToLauncher() {
        current?.backToLauncher()
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            current?.launchSession(directory: url)
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var configuredWindows = NSHashTable<NSWindow>.weakObjects()

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
              // Exclude panels (NSOpenPanel, NSSavePanel, etc.)
              !window.isKind(of: NSPanel.self)
        else { return }
        configuredWindows.add(window)

        let otherWindow = NSApp.windows.first {
            $0 !== window && $0.styleMask.contains(.titled) && $0.isVisible
                && !$0.isKind(of: NSPanel.self)
        }
        if let other = otherWindow, other.frame.width > 100 {
            var frame = window.frame
            frame.size = other.frame.size
            window.setFrame(frame, display: false)
        }
    }
}

// MARK: - Tab content (each window/tab owns its own state)

struct TabContentView: View {
    @State private var appState = AppState()

    var body: some View {
        Group {
            switch appState.screen {
            case .launcher:
                LauncherView(appState: appState)
            case .session:
                WebViewContainer(
                    workingDirectory: appState.workingDirectory,
                    resumeSessionId: appState.resumeSessionId,
                    permissionMode: appState.permissionMode,
                    sessionTitle: appState.resumeSessionTitle
                )
                .id(appState.webviewReloadToken)
            }
        }
        // Only set title for launcher; session title is managed by ShimProcess
        .windowTitle(appState.screen == .launcher ? "Hangar" : nil)
        .onAppear {
            ActiveTabState.shared.current = appState
            // Debug: auto-launch session (defaults write sh.saqoo.Hangar debugAutoLaunchDir /tmp)
            if let dir = appState.debugAutoLaunchDir, appState.screen == .launcher {
                appState.debugAutoLaunchDir = nil
                appState.launchSession(directory: URL(fileURLWithPath: dir))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { _ in
            ActiveTabState.shared.current = appState
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
