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
                // This Mac's sessions run in the daemon. Not under the probe: its
                // fixtures close `.local` sessions and expect them gone.
                if ProcessInfo.processInfo.environment["CANOPY_RUN_LOGIC_PROBE"] != "1" {
                    OpenSession.localSessionsRunInDaemon = true
                }
                CanopyApp.main()
            }
        }
    }
}
