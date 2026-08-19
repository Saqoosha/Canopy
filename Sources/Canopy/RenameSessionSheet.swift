import SwiftUI

/// Modal for renaming a session, opened from either the sidebar row's
/// context menu or a double-click on a pane header. The store owns when the
/// sheet is up — this view only edits and hands the text back through
/// `onCommit` / `onCancel`; the store trims and truncates it.
struct RenameSessionSheet: View {
    let target: SessionStore.RenameTarget
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        target: SessionStore.RenameTarget,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.target = target
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: target.currentTitle)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Session")
                .font(.system(size: 13, weight: .semibold))
            TextField("Session title", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { isFocused = true }
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}
