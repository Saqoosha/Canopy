import SwiftUI

@main
struct HangarApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                switch appState.screen {
                case .launcher:
                    LauncherView(appState: appState)
                case .session:
                    WebViewContainer(
                        workingDirectory: appState.workingDirectory,
                        resumeSessionId: appState.resumeSessionId,
                        permissionMode: appState.permissionMode
                    )
                    .id(appState.webviewReloadToken)
                    .windowTitle(appState.workingDirectory.lastPathComponent)
                }
            }
            .frame(minWidth: 400, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 500, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session") {
                    appState.backToLauncher()
                }
                .keyboardShortcut("n")

                Button("Open Folder...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Open"
                    if panel.runModal() == .OK, let url = panel.url {
                        appState.launchSession(directory: url)
                    }
                }
                .keyboardShortcut("o")
            }
        }
    }
}

// MARK: - Window title helper

/// Sets the hosting NSWindow title by injecting an empty NSView via .background()
/// and accessing its window property on the next run loop.
private struct WindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Delay to next run loop — window may not yet be assigned during initial layout
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}

extension View {
    func windowTitle(_ title: String) -> some View {
        background(WindowTitleSetter(title: title))
    }
}
