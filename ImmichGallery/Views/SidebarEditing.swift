import SwiftUI

/// A section heading, which the sidebar list styles and gives its collapse chevron. While editing, a checkbox
/// shows or hides it and custom sections can be renamed in place.
struct SidebarSectionHeader<MenuItems: View>: View {
    let section: SidebarSection
    let editing: Bool
    @Binding var renaming: String?
    let setHidden: (Bool) -> Void
    let rename: (String) -> Void
    @Binding var name: String
    @ViewBuilder let menu: MenuItems
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if editing {
                Toggle(isOn: Binding(get: { !section.hidden }, set: { setHidden(!$0) })) { section.label }
                    .toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel(Text("Show in Sidebar") + Text(verbatim: ": ") + section.label)
            }
            if renaming == section.id {
                TextField("Section name", text: $name)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .focused($nameFocused)
                    .onAppear { name = section.name ?? ""; nameFocused = true }
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = nil }
                    .onChange(of: nameFocused) { _, focused in if !focused { commitRename() } }
            } else {
                section.label
                    .opacity(editing && section.hidden ? 0.55 : 1)
                    .onTapGesture(count: 2) { if editing && section.isCustom { renaming = section.id } }
            }
        }
        .contextMenu { menu }
    }

    private func commitRename() {
        guard renaming == section.id else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { rename(trimmed) }
        renaming = nil
    }
}

/// An item while editing the sidebar: a checkbox that shows or hides it, dimmed while hidden.
struct SidebarEditRow<Content: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder let content: Content

    var body: some View {
        Toggle(isOn: $isOn) {
            content.opacity(isOn ? 1 : 0.55)
        }
        .toggleStyle(.checkbox)
    }
}

struct SidebarHiddenItem: Identifiable {
    let id: String
    let title: Text
    let icon: String?
    let show: () -> Void
}

/// Next to the account: a menu with the sidebar's options and Settings, which becomes Done while editing.
struct SidebarFooterControls: View {
    @Environment(\.openSettings) private var openSettings
    @Binding var editing: Bool
    let hidden: [SidebarHiddenItem]
    let newSection: () -> Void
    let reset: () -> Void

    var body: some View {
        if editing {
            Button("Done") { editing = false }
                .buttonStyle(.borderedProminent).controlSize(.small)
        } else {
            Menu {
                Button("Edit Sidebar") { editing = true }
                Button("New Section", action: newSection)
                if !hidden.isEmpty {
                    Menu("Show in Sidebar") {
                        ForEach(hidden) { item in
                            Button(action: item.show) {
                                if let icon = item.icon { Label { item.title } icon: { Image(systemName: icon) } } else { item.title }
                            }
                        }
                    }
                }
                Divider()
                Button("Reset Sidebar…", action: reset)
                Divider()
                // The app's Settings, also in the app menu (⌘,), found where the account's own settings are.
                Button("Settings…") { openSettings() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Options")
            .accessibilityLabel("Options")
        }
    }
}
