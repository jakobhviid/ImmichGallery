import SwiftUI

/// Text that becomes a field when clicked, as Immich's album title, album description and person name are: the
/// header is where you name things. Return or clicking away saves; Escape cancels.
struct InlineEditableText: View {
    let text: String
    let placeholder: LocalizedStringKey
    var font: Font = .body
    var axis: Axis = .horizontal
    var enabled = true
    /// Empty text is saved too where that clears the value (a description); a name keeps its old value instead.
    var allowsEmpty = false
    let commit: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField(placeholder, text: $draft, axis: axis)
                .textFieldStyle(.plain)
                .font(font)
                .focused($focused)
                .onAppear { draft = text; focused = true }
                .onSubmit(finish)
                .onExitCommand { editing = false }
                .onChange(of: focused) { _, focused in if !focused { finish() } }
        } else if text.isEmpty {
            if enabled {
                Text(placeholder).font(font).foregroundStyle(.tertiary)
                    .onTapGesture { editing = true }
                    .accessibilityAddTraits(.isButton)
            }
        } else {
            Text(verbatim: text).font(font)
                .textSelection(.disabled)
                .onTapGesture { if enabled { editing = true } }
                .accessibilityAddTraits(enabled ? .isButton : [])
                .help(enabled ? Text("Click to edit") : Text(verbatim: ""))
        }
    }

    private func finish() {
        guard editing else { return }
        editing = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != text, allowsEmpty || !trimmed.isEmpty else { return }
        commit(trimmed)
    }
}
