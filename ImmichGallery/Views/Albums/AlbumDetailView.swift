import SwiftUI

struct AlbumDetailView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let id: String
    var onClose: (() -> Void)?
    @State private var album: AlbumDetails?
    @State private var error: String?
    @State private var editing = false
    @State private var sharing = false
    @State private var deleting = false
    @State private var leaving = false
    @State private var showActivity = false
    @State private var removed = false

    private var model: AssetGridModel { session.gridModel(for: .album(id)) }

    var body: some View {
        Group {
            if removed {
                ContentUnavailableView("Album Closed", systemImage: "rectangle.stack")
            } else if let album {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        // As in Immich, the album's header is where it is named, described and shared; it scrolls away
                        // with the photos, and the toolbar shows the name once it has.
                        AssetGridContainer(source: .album(id), title: Text(verbatim: album.albumName), headerScrolls: true) {
                            header(album)
                        }
                        if showActivity && album.shared && album.isActivityEnabled == true {
                            Divider()
                            AlbumActivityPanel(album: album, assetID: model.viewerID)
                                .id(model.viewerID ?? "album")
                                .frame(width: 280)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                .toolbar(id: "album") {
                    if model.viewerID == nil {
                        ToolbarItem(id: "albumMenu") { albumMenu(album) }
                    }
                }
            } else if let error {
                ContentUnavailableView { Label("Couldn't Load Album", systemImage: "rectangle.stack.badge.minus") }
                description: { Text(error) } actions: { Button("Try Again") { Task { await load() } } }
                .pageToolbar("albumError")
            } else { ProgressView().pageToolbar("albumLoading") }
        }
        .task(id: id) { await load() }
        .onChange(of: session.albumActions.revisions[id, default: 0]) {
            guard !removed else { return }
            Task { await load(); await model.reload() }
        }
        .sheet(isPresented: $editing) {
            if let album {
                AlbumNameSheet(title: "Edit Album", name: album.albumName, description: album.description ?? "") { name, description in
                    self.album = try await session.client.updateAlbum(id, AlbumUpdate(albumName: name, description: description))
                    session.albumActions.details[id] = self.album
                    await session.reloadAlbums()
                }
            }
        }
        .sheet(isPresented: $sharing, onDismiss: { Task { await load() } }) {
            if let album { AlbumSharingSheet(album: album) }
        }
        .confirmationDialog("Delete Album?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Album", role: .destructive) { closeAlbum(leaving: false) }
        } message: { Text("The album will be deleted for everyone. Its photos and videos stay in the library.") }
        .confirmationDialog("Leave Album?", isPresented: $leaving, titleVisibility: .visible) {
            Button("Leave Album", role: .destructive) { closeAlbum(leaving: true) }
        } message: { Text("You will lose access to this album until the owner invites you again.") }
        .alert("Album Error", isPresented: Binding(get: { album != nil && error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    /// The album's actions, in a toolbar menu of their own beside the photos' controls: what Immich puts in its
    /// album page's menu.
    private func albumMenu(_ album: AlbumDetails) -> some View {
        let isOwner = album.isOwner(session.user?.id)
        let isMember = album.albumUsers?.contains(where: { $0.id == session.user?.id }) == true
        return Menu {
            if isOwner {
                Button("Edit Album…") { editing = true }
                Button("Manage Sharing…") { sharing = true }
            } else if isMember {
                Button("View Members…") { sharing = true }
            }
            Button("Download Album as ZIP…") { AssetsDownloader.start(album: album.id, session: session) }
            if isOwner {
                Divider()
                Menu("Sort Photos") {
                    Button("Oldest First") { update(AlbumUpdate(order: "asc")) }
                    Button("Newest First") { update(AlbumUpdate(order: "desc")) }
                }
                if album.isActivityEnabled != nil {
                    Button(album.isActivityEnabled == true ? "Disable Activity" : "Enable Activity") {
                        update(AlbumUpdate(isActivityEnabled: album.isActivityEnabled != true))
                    }
                }
            }
            if album.shared && album.isActivityEnabled == true {
                Toggle("Show Activity", isOn: $showActivity.animation(.smooth(duration: 0.3)))
            }
            if isOwner || isMember {
                Divider()
                if isOwner {
                    Button("Delete Album…", role: .destructive) { deleting = true }
                } else {
                    Button("Leave Album…", role: .destructive) { leaving = true }
                }
            }
        } label: { Label("Album", systemImage: "rectangle.stack") }
        .menuIndicator(.hidden)
        .help("Album")
    }

    /// Immich's album header: the name and description, edited in place by the owner, the dates and count, and who
    /// the album is shared with.
    private func header(_ album: AlbumDetails) -> some View {
        let isOwner = album.isOwner(session.user?.id)
        return VStack(alignment: .leading, spacing: 8) {
            InlineEditableText(text: album.albumName, placeholder: "Album Name", font: .largeTitle.bold(), enabled: isOwner) { name in
                update(AlbumUpdate(albumName: name))
            }
            HStack(spacing: 6) {
                Text("\(album.assetCount) items")
                if let start = album.startDate.flatMap(ImmichDate.parse) {
                    Text(verbatim: "·")
                    Text(start, style: .date)
                    if let end = album.endDate.flatMap(ImmichDate.parse), end != start { Text("–"); Text(end, style: .date) }
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            InlineEditableText(text: album.description ?? "", placeholder: "Add a Description", axis: .vertical, enabled: isOwner, allowsEmpty: true) { description in
                update(AlbumUpdate(description: description))
            }
            .frame(maxWidth: 640, alignment: .leading)
            members(album, isOwner: isOwner)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }

    /// The owner and the people the album is shared with, and, for the owner, a button to share it with more.
    private func members(_ album: AlbumDetails, isOwner: Bool) -> some View {
        let owner = album.albumOwner
        let others = (album.albumUsers ?? []).filter { $0.user.id != owner?.id }.map(\.user)
        return HStack(spacing: 6) {
            ForEach([owner].compactMap { $0 } + others) { user in
                UserAvatar(user: user, size: 26)
                    .help(user.id == owner?.id ? Text("\(user.name) (owner)") : Text(verbatim: user.name))
                    .accessibilityLabel(Text(verbatim: user.name))
            }
            if isOwner {
                Button { sharing = true } label: {
                    Image(systemName: "plus").font(.callout.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Manage Sharing…")
                .accessibilityLabel("Manage Sharing…")
            }
        }
        .padding(.top, 2)
    }

    private func load() async {
        do {
            let detail = try await session.client.albumDetails(id)
            if model.albumOrder != detail.order ?? "desc" { model.markStale() }
            model.albumOrder = detail.order ?? "desc"
            session.albumActions.details[id] = detail
            album = detail
            error = nil
        } catch { session.handle(error); self.error = error.localizedDescription }
    }

    private func update(_ update: AlbumUpdate) {
        Task {
            do {
                album = try await session.client.updateAlbum(id, update)
                session.albumActions.details[id] = album
                model.albumOrder = album?.order ?? "desc"
                await model.reload()
                await session.reloadAlbums()
            } catch { session.handle(error); self.error = error.localizedDescription }
        }
    }

    private func closeAlbum(leaving: Bool) {
        Task {
            do {
                if leaving { try await session.client.removeAlbumUser(id, userID: "me") }
                else { try await session.client.deleteAlbum(id) }
                removed = true
                session.discardAlbumGrid(id)
                await session.reloadAlbums()
                if let onClose { onClose() } else { dismiss() }
            } catch { session.handle(error); self.error = error.localizedDescription }
        }
    }
}
