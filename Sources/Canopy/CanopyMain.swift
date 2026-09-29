import SwiftUI

/// Chooses between the GUI app and the daemon before either touches
/// NSApplication. `CanopyApp.main()` is SwiftUI's own entry; the daemon
/// never builds a scene, so it has to branch here rather than inside the App.
@main
enum CanopyMain {
    static func main() {
        // `main` runs on the main thread; both entries are main-actor isolated.
        MainActor.assumeIsolated {
            if CommandLine.arguments.contains("--unregister-daemon") {
                DaemonRegistration.unregisterAndExit()
            } else if CommandLine.arguments.contains("--daemon") {
                CanopyDaemon.run()
            } else {
                CanopyApp.main()
            }
        }
    }
}
