import SwiftUI

/// Text that becomes a field when clicked, as Immich's album title, album description and person name are: the
/// header is where you name things. It is a button, so the keyboard and VoiceOver can start editing too. Return or
/// clicking away saves; Escape cancels.
struct InlineEditableText: View {
    let text: String
    let placeholder: LocalizedStringKey
    var font: Font = .body
    var axis: Axis = .horizontal
    var enabled = true
    /// Empty text is saved too where that clears the value (a description); a name keeps its old value instead.
    var allowsEmpty = false
    let commit: (String) -> Void
    @State private var edit = InlineEdit()
    @FocusState private var focused: Bool

    var body: some View {
        if edit.editing {
            TextField(placeholder, text: $edit.draft, axis: axis)
                .textFieldStyle(.plain)
                .font(font)
                .focused($focused)
                .accessibilityLabel(Text(placeholder))
                .onAppear { focused = true }
                .onSubmit(finish)
                .onExitCommand { edit.cancel() }
                .onChange(of: focused) { _, focused in if !focused { finish() } }
        } else if enabled {
            Button { edit.begin(text) } label: {
                Group {
                    if text.isEmpty {
                        Text(placeholder).foregroundStyle(.tertiary)
                    } else {
                        Text(verbatim: text)
                    }
                }
                .font(font)
                .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(placeholder))
            .accessibilityValue(Text(verbatim: text))
            .help("Click to edit")
        } else if !text.isEmpty {
            Text(verbatim: text).font(font)
        }
    }

    private func finish() {
        if let value = edit.finish(current: text, allowsEmpty: allowsEmpty) { commit(value) }
    }
}

/// One edit of an `InlineEditableText`: Return and focus leaving finish it once, Escape ends it without saving.
struct InlineEdit: Equatable {
    private(set) var editing = false
    var draft = ""

    mutating func begin(_ text: String) {
        editing = true
        draft = text
    }

    /// The value to save, at most once per edit: nil when cancelled, already finished, unchanged, or an empty value
    /// where empty isn't allowed.
    mutating func finish(current: String, allowsEmpty: Bool) -> String? {
        guard editing else { return nil }
        editing = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != current, allowsEmpty || !trimmed.isEmpty else { return nil }
        return trimmed
    }

    mutating func cancel() {
        editing = false
    }
}
