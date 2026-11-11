import SwiftUI
import AppKit

@MainActor enum SharingClipboard {
    static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

struct SharedLinksView: View {
    @Environment(LibrarySession.self) private var session
    @State private var editing: SharedLink?
    @State private var sharingLink: SharedLink?
    @State private var deleting: SharedLink?
    @State private var showCreate = false
    @State private var albumID = ""
    // Shared links: the Immich web app's tabs, as view options.
    @AppStorage("sharedLinks.filter") private var filter = SharedLinksFilter.all
    @AppStorage("sharedLinks.hideExpired") private var hideExpired = false

    private var arrangement: SharedLinksArrangement { SharedLinksArrangement(filter: filter, hideExpired: hideExpired) }

    var body: some View {
        @Bindable var sharing = session.sharing
        let links = arrangement.links(sharing.links)
        Group {
            if !sharing.linksAvailable {
                ContentUnavailableView("Shared Links Unavailable", systemImage: "link", description: Text("Shared links are disabled or unavailable on this server."))
            } else if links.isEmpty && !sharing.links.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Links", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No links match the selected view options.")
                } actions: {
                    Button("Show All Links") { filter = .all; hideExpired = false }
                }
            } else {
                List {
                    if sharing.links.isEmpty { Text("No public links. Select photos or choose an album to create one.").foregroundStyle(.secondary) }
                    ForEach(links) { link in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(link.title, systemImage: link.type == "ALBUM" ? "rectangle.stack" : "photo.on.rectangle")
                                Spacer()
                                Button("Copy Link") { Task { await copy(link) } }
                                Button("Share…") { sharingLink = link }
                                Button("Edit…") { editing = link }
                                Button("Delete…", role: .destructive) { deleting = link }
                            }
                            Text(link.expiresAt.flatMap(ImmichDate.parse).map { $0 <= Date() ? "Expired" : "Expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Never expires").font(.caption).foregroundStyle(.secondary)
                            if link.type == "INDIVIDUAL" {
                                NavigationLink("Manage \(link.assets.count) Photos", value: SharedLinkRoute(id: link.id))
                            }
                        }.padding(.vertical, 6)
                    }
                }
            }
        }
        .navigationTitle("Shared Links")
        .navigationDestination(for: SharedLinkRoute.self) { SharedLinkAssetsView(linkID: $0.id) }
        .pageToolbar("sharedLinks") {
            ToolbarItem(id: "viewOptions") { viewOptions.disabled(!sharing.linksAvailable) }
            ToolbarItem(id: "shareAlbum") {
                Menu("Share Album", systemImage: "plus") {
                    ForEach(session.albums) { album in
                        Button(album.albumName) { albumID = album.id; showCreate = true }
                    }
                }
                .menuIndicator(.hidden)
                .disabled(!sharing.linksAvailable || session.albums.isEmpty)
            }
            ToolbarItem(id: "refresh") { Button("Refresh", systemImage: "arrow.clockwise") { Task { await sharing.reload() } } }
        }
        .sheet(item: $sharingLink) { SharedLinkURLSheet(link: $0) }
        .sheet(item: $editing) { SharedLinkEditor(link: $0) }
        .sheet(isPresented: $showCreate) { SharedLinkEditor(albumID: albumID) }
        .confirmationDialog("Delete public link?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Link", role: .destructive) {
                if let link = deleting { Task { await sharing.perform { try await session.client.deleteSharedLink(link.id) } } }
            }
        } message: { Text("Anyone with this link will lose access. The photos remain in your library.") }
        .sharingError()
        .task { await sharing.reload() }
    }

    private var viewOptions: some View {
        Menu {
            Picker("Show", selection: $filter.animation(.smooth(duration: 0.35))) {
                ForEach(SharedLinksFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Hide Expired Links", isOn: $hideExpired.animation(.smooth(duration: 0.35)))
        } label: {
            Label("View Options", systemImage: arrangement.isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .menuIndicator(.hidden)
        .help("View Options")
    }

    private func copy(_ link: SharedLink) async {
        do { SharingClipboard.copy(try await session.client.sharingPublicURL(link)) }
        catch { session.sharing.error = error.localizedDescription }
    }
}

struct SharedLinkRoute: Hashable {
    let id: String
}

struct SharedLinkAssetsView: View {
    @Environment(LibrarySession.self) private var session
    let linkID: String
    @State private var link: SharedLink?
    @State private var selected: Set<String> = []

    var body: some View {
        VStack {
            Text("To add photos, select them in Library and choose Share → Add to Public Link.").foregroundStyle(.secondary).padding()
            List(selection: $selected) {
                ForEach(link?.assets ?? []) { asset in
                    HStack {
                        RemoteThumbnail(pipeline: session.pipeline, assetID: asset.id).frame(width: 48, height: 48)
                        Text(asset.originalFileName)
                    }.tag(asset.id)
                }
            }
        }
        .navigationTitle(link?.title ?? "Shared Photos")
        .pageToolbar("sharedLink") {
            ToolbarItem(id: "removePhotos") {
                Button("Remove Selected Photos", systemImage: "minus.circle") {
                    Task {
                        await session.sharing.perform { try await session.client.changeSharedLinkAssets(linkID, assetIDs: Array(selected), adding: false) }
                        await load()
                    }
                }.disabled(selected.isEmpty || session.sharing.busy)
            }
        }
        .sharingError()
        .task { await load() }
    }
    private func load() async {
        do { link = try await session.client.sharedLink(linkID); selected = [] }
        catch { session.sharing.error = error.localizedDescription }
    }
}

private struct SharingErrorModifier: ViewModifier {
    @Environment(LibrarySession.self) private var session
    func body(content: Content) -> some View {
        content.alert("Sharing Failed", isPresented: Binding(get: { session.sharing.error != nil }, set: { if !$0 { session.sharing.error = nil } })) {
            Button("OK") { session.sharing.error = nil }
        } message: { Text(session.sharing.error ?? "") }
    }
}
extension View {
    func sharingError() -> some View { modifier(SharingErrorModifier()) }
}

private struct SharedLinkURLSheet: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let link: SharedLink
    @State private var url: URL?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(link.title).font(.title2.bold())
            if let url {
                Text(url.absoluteString).textSelection(.enabled)
                HStack {
                    Button("Copy Link") { SharingClipboard.copy(url) }
                    ShareLink(item: url)
                }
            } else if let error { Text(error).foregroundStyle(.red) }
            else { ProgressView("Loading Public URL…") }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(24).frame(width: 440)
        .task {
            do { url = try await session.client.sharingPublicURL(link) }
            catch { self.error = error.localizedDescription }
        }
    }
}
