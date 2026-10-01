import Foundation

/// Whether Canopy holds Full Disk Access. Without it every new daemon process
/// is asked "Canopy would like to access data from other apps" once a session
/// starts, and the resumed CLI waits on that dialog: after an unattended
/// upgrade restart, sessions fail ("Subprocess initialization did not
/// complete") until someone clicks Allow. With it the prompt never runs —
/// measured 2026-10-01: CLI start 645 ms and no AppData request, against
/// 57–61 s blocked on a build without it. The daemon is the same bundle, so
/// the GUI's answer stands for both.
enum FullDiskAccess {
    /// System Settings › Privacy & Security › Full Disk Access.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// The user's TCC database opens only with Full Disk Access.
    static func isGranted(home: String = NSHomeDirectory()) -> Bool {
        let fd = open(home + "/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return isGranted(openErrno: errno)
    }

    /// Only a permission refusal means "no". Anything else (no such file, a
    /// different layout on a future macOS) is unknown, and unknown must not nag.
    static func isGranted(openErrno: Int32) -> Bool {
        openErrno != EPERM && openErrno != EACCES
    }
}
