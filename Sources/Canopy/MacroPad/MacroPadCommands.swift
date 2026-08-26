import SwiftUI

/// The one-click switch the whole remote transport is built around: the user
/// changes source where they are sitting, not where the pad is.
///
/// A `View` in its own file rather than inline in `CanopyApp` so `@Bindable`
/// can track `CanopySettings` — a `Commands` body is not a tracked scope, so
/// checkmarks written there would not update when the source changes from
/// Settings.
///
/// No key equivalents. Nothing here is urgent enough to spend shortcut space
/// that Panes and Sessions already crowd.
struct MacroPadCommands: View {
    @Bindable private var settings = CanopySettings.shared

    var body: some View {
        // `Label(_:systemImage:)` with an empty symbol name was the brief's
        // literal shape, and it does not draw a broken-image glyph on this
        // toolchain — but it also does not reserve the checkmark's column
        // for the rows that lack one, so the checked row's text sits
        // indented past its checkmark while the other two sit flush left:
        // a ragged, inconsistent menu (confirmed via a zoomed screen
        // capture of the open menu, not by reading the code). `Toggle`
        // keeps the brief's intent — a mark on exactly the current source —
        // by handing the checkmark to AppKit's native menu-item state
        // instead, which reserves that column for every row regardless of
        // its own check state, matching how every other checked menu in
        // macOS lines up. The `set` closure ignores the toggled-off case:
        // these three act as a radio group, not three independent
        // switches, so unchecking the current source has no meaning.
        Toggle(isOn: Binding(get: { settings.macroPadSource.isOff }, set: { _ in settings.macroPadSource = .off })) {
            Text("Off")
        }
        Toggle(isOn: Binding(get: { isLocal }, set: { _ in settings.macroPadSource = .local })) {
            Text("Use Local")
        }
        Toggle(isOn: Binding(get: { isRemote }, set: { _ in selectRemote() })) {
            Text(remoteTitle)
        }
        .disabled(remoteEndpoint == nil)
    }

    private var remoteEndpoint: MacroPadRemoteEndpoint? {
        MacroPadRemoteEndpoint.parse(settings.macroPadRemoteHost)
    }

    private var isLocal: Bool { settings.macroPadSource == .local }

    private var isRemote: Bool {
        if case .remote = settings.macroPadSource { return true }
        return false
    }

    /// Names the host so the menu says which machine, not just "remote" —
    /// the whole point of the switch is knowing which pad you are about to
    /// drive. Falls back to a hint when no address is configured, because a
    /// disabled item with no explanation reads as a bug.
    private var remoteTitle: String {
        guard let remoteEndpoint else { return "Use Remote (set an address in Settings)" }
        return "Use \(remoteEndpoint.host)"
    }

    private func selectRemote() {
        guard let remoteEndpoint else { return }
        settings.macroPadSource = .remote(remoteEndpoint)
    }
}
