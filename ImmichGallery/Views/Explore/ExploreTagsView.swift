import SwiftUI

struct ExploreTagsView: View {
    @Environment(LibrarySession.self) private var session
    @State private var editing: ExploreTag?
    @State private var deleting: ExploreTag?
    @State private var name = ""
    @State private var color = ""
    @State private var showingEditor = false
    @State private var error: String?
    var body: some View {
        List(ExploreTagNode.tree(session.exploreTags), children: \.children) { node in
            let tag = node.tag
            NavigationLink(value: GridRoute(source: .explore(.tag(tag.id)), title: tag.value)) {
                Label(tag.name, systemImage: "tag").foregroundStyle(tagColor(tag.color))
            }
            .contextMenu {
                Button("Edit Tag…") { editing = tag; name = tag.name; color = tag.color ?? ""; showingEditor = true }
                Button("Delete Tag…", role: .destructive) { deleting = tag }
            }
        }
        .pageToolbar("tags") {
            ToolbarItem(id: "newTag") {
                Button { editing = nil; name = ""; color = ""; showingEditor = true } label: { Label("New Tag", systemImage: "plus") }
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showingEditor) {
            Form {
                TextField(editing == nil ? "Tag path (parent/child)" : "Name", text: $name)
                if editing != nil { TextField("Color (#RRGGBB, empty to clear)", text: $color) }
                HStack {
                    Button("Cancel", role: .cancel) { showingEditor = false }
                    Button("Save") {
                        Task {
                            do {
                                if let editing { try await session.client.exploreUpdateTag(editing, name: name, color: color) }
                                else { try await session.client.exploreCreateTag(name) }
                                showingEditor = false
                                await reload()
                            } catch { self.error = error.localizedDescription }
                        }
                    }.keyboardShortcut(.defaultAction).disabled(!valid)
                }
            }.padding().frame(width: 380)
        }
        .confirmationDialog("Delete tag \(deleting?.value ?? "") and its child tags?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Tag", role: .destructive) {
                guard let tag = deleting else { return }
                Task { do { try await session.client.exploreDeleteTag(tag.id); await reload() } catch { self.error = error.localizedDescription } }
            }
        } message: { Text("Photos are kept. Tag assignments are removed.") }
        .alert("Tags", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (editing == nil || !name.contains("/")) &&
        (color.isEmpty || color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil)
    }
    private func reload() async {
        await session.loadExploreTags(refresh: true)
    }
    private func tagColor(_ hex: String?) -> Color {
        guard let hex, hex.count == 7, let value = UInt(hex.dropFirst(), radix: 16) else { return .primary }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct ExploreAssetActions: View {
    @Environment(LibrarySession.self) private var session
    let ids: [String]
    let model: AssetGridModel
    let onTags: (Bool) -> Void

    var body: some View {
        Menu("Tags") {
            if !session.exploreTagsEnabled {
                Text("Enable Tags in Immich Account Settings")
            } else {
                Button("Add Tag…") { onTags(false) }
                Button("Remove Tag…") { onTags(true) }
            }
        }
        Button("Move to Locked Folder") { Task { await model.moveToLockedFolder(ids) } }
    }
}
