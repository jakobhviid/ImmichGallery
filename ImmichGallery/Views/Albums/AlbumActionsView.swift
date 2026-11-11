import SwiftUI

struct AlbumSelectionMenu: View {
    let session: LibrarySession
    let model: AssetGridModel?
    let ids: [String]

    var body: some View {
        Menu("Add to Album") {
            Button("New Album with Selection…") { session.albumActions.newAlbum(ids: ids, model: model) }
            Divider()
            ForEach(session.albums.filter { $0.canEdit(session.user?.id) }) { album in
                Button(album.albumName) {
                    session.albumActions.perform(session: session, albumID: album.id) {
                        try await session.client.changeAlbumAssets(album.id, ids: ids)
                    }
                }
            }
        }
        .disabled(ids.isEmpty || model?.source == .trash)
        if let id = model?.source.albumID {
            Button("Remove from Album") {
                session.albumActions.perform(session: session, albumID: id) {
                    try await session.client.changeAlbumAssets(id, ids: ids, removing: true)
                    model?.selection.subtract(ids)
                }
            }
            .disabled(ids.isEmpty || session.albumActions.details[id]?.canEdit(session.user?.id) != true)
            Button("Use as Album Cover") {
                guard let assetID = ids.first else { return }
                session.albumActions.perform(session: session, albumID: id, reloadTimeline: false) {
                    _ = try await session.client.updateAlbum(id, AlbumUpdate(albumThumbnailAssetId: assetID))
                }
            }
            .disabled(ids.count != 1 || session.albumActions.details[id]?.isOwner(session.user?.id) != true)
        }
    }
}

struct AlbumPresentation: ViewModifier {
    @Environment(LibrarySession.self) private var session

    func body(content: Content) -> some View {
        @Bindable var actions = session.albumActions
        content
            .sheet(isPresented: $actions.creating) {
                AlbumNameSheet(title: "New Album", name: "", description: "") { name, description in
                    let album = try await session.client.createAlbum(name: name, description: description, assetIDs: actions.initialAssetIDs)
                    await session.reloadAlbums()
                    actions.didCreate(album.id)
                }
            }
            .alert("Album Error", isPresented: Binding(get: { actions.error != nil }, set: { if !$0 { actions.error = nil } })) {
                Button("OK") { actions.error = nil }
            } message: { Text(actions.error ?? "") }
    }
}

struct AlbumNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var name: String
    @State var description: String?
    let save: (String, String?) async throws -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            TextField("Album Name", text: $name)
            if description != nil {
                TextField("Description", text: Binding(get: { description ?? "" }, set: { description = $0 }), axis: .vertical)
                    .lineLimit(3...6)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Save") {
                    busy = true
                    Task {
                        do { try await save(name.trimmingCharacters(in: .whitespacesAndNewlines), description); dismiss() }
                        catch { self.error = error.localizedDescription; busy = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24).frame(width: 420)
        .interactiveDismissDisabled(busy)
    }
}

struct AlbumSidebarRows: View {
    @Environment(LibrarySession.self) private var session

    let shared: Bool
    @Binding var storedLayout: String
    @Binding var selection: SidebarItem?

    var body: some View {
        let layout = SidebarLayout(stored: storedLayout)
        ForEach(session.sidebarAlbums(in: (shared ? SidebarGroup.sharedAlbums : .myAlbums).rawValue, layout: layout)) { album in
            SidebarSelectionRow(item: .album(album.id), selection: $selection) {
                Label {
                    Text(album.albumName)
                } icon: {
                    if let assetID = album.albumThumbnailAssetId {
                        RemoteThumbnail(pipeline: session.pipeline, assetID: assetID,
                                        placeholderSystemImage: shared ? "person.2.crop.square.stack" : "rectangle.stack")
                            .frame(width: 24, height: 24)
                            .clipShape(.rect(cornerRadius: 4))
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: shared ? "person.2.crop.square.stack" : "rectangle.stack")
                    }
                }
            }
                .modifier(AlbumRowUploadDrop(queue: session.upload, albumID: album.id, addAssets: { add($0, to: album) })) // Upload
                .id(SidebarItem.album(album.id))
                .contextMenu {
                    MacAlbumWindowMenu(albumID: album.id)
                    CrosslinkMenuItems(item: .album(album.id)) // Crosslink
                    Divider()
                    Button("Hide from Sidebar") {
                        var layout = SidebarLayout(stored: storedLayout)
                        layout.setDynamicItemHidden(true, key: session.sidebarItemKey("album:" + album.id))
                        storedLayout = layout.stored
                    }
                }
                .modifier(AlbumRowAssetDrop { add($0, to: album) })
        }
    }

    private func add(_ ids: [String], to album: Album) -> Bool {
        guard album.canEdit(session.user?.id),
              !ids.isEmpty, ids.allSatisfy({ UUID(uuidString: $0) != nil }) else { return false }
        session.albumActions.perform(session: session, albumID: album.id) {
            try await session.client.changeAlbumAssets(album.id, ids: ids)
        }
        return true
    }
}
