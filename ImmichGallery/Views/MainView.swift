import SwiftUI

enum SidebarItem: Hashable {
    case library, favorites, videos, people, albums, archive, trash
    case album(String)
    case search
    case sharedLinks // Sharing
    case partners // Sharing
    case partner(String) // Sharing
    case duplicates, largeFiles, geolocation // Assets
    case explore(ExplorePage) // Explore
}

struct MainView: View {
    @Environment(LibrarySession.self) private var session
    @State private var selection: SidebarItem? = .library
    @State private var searchText = ""
    @State private var submittedSearch = ""
    @State private var showSearchFilters = false
    @State private var editingSidebar = false
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var path = NavigationPath() // Crosslink: a person or a place a link names, and pushed pages
    @Environment(\.openWindow) private var openWindow
    @FocusState private var searchFocused: Bool

    init(initialAlbumID: String? = nil, initialSearch: String? = nil) {
        _selection = State(initialValue: initialAlbumID.map(SidebarItem.album) ?? (initialSearch == nil ? .library : .search))
        _searchText = State(initialValue: initialSearch ?? "")
        _submittedSearch = State(initialValue: initialSearch ?? "")
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: Binding(get: { selection }, set: { select($0) }), editing: $editingSidebar)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .navigationDestination(for: CrosslinkDestination.self) { destination in // Crosslink
                        AssetGridContainer(source: destination.source, title: Text(verbatim: destination.title))
                    }
            }
            .id(selection)
            .modifier(AccountPasswordBanner())
            .modifier(GlobalToolbar(session: session, level: .detailStack))
        }
        .modifier(UploadDropModifier(queue: session.upload)) // Upload
        .modifier(GlobalToolbar(session: session, level: .splitView))
        .modifier(AlbumPresentation()) // Albums
        .onChange(of: session.albumActions.navigationAlbumID) { _, id in
            if let id {
                select(.album(id))
                session.albumActions.navigationAlbumID = nil
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: session.features.smartSearch ? "Search photos" : "Search file names")
        .searchSuggestions { SearchFieldSuggestions(text: searchText) }
        .searchFocused($searchFocused)
        .focusedSceneValue(\.sidebarActions, SidebarActions(editing: $editingSidebar))
        .onChange(of: editingSidebar) { _, editing in if editing { columnVisibility = .all } }
        .focusedSceneValue(\.librarySession, session)
        .focusedSceneValue(\.searchActions, SearchActions(
            find: { select(.search); searchFocused = true },
            filters: { select(.search); showSearchFilters = true }))
        .onReceive(NotificationCenter.default.publisher(for: .viewerShowLibrary, object: session)) { _ in select(.library) }
        .onReceive(NotificationCenter.default.publisher(for: .crosslinkShow, object: session)) { note in // Crosslink
            if let item = note.userInfo?["item"] as? Crosslink.Item { showCrosslink(item) }
        }
        .onSubmit(of: .search) {
            let query = searchText.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return }
            submittedSearch = query
            select(.search)
        }
        .onChange(of: selection) { _, newValue in
            if newValue != .search { searchText = ""; submittedSearch = ""; showSearchFilters = false }
        }
        .onChange(of: session.sharing.receivedPartners.map(\.id)) { _, ids in
            if case .partner(let id) = selection, !ids.contains(id) { select(.partners) }
        }
        .onChange(of: searchText) { _, text in
            if text.isEmpty, selection == .search { submittedSearch = "" }
        }
    }

    /// Changes the page, clearing pages pushed on the old one first, so the new page's stack never sees them.
    private func select(_ item: SidebarItem?) {
        path = NavigationPath()
        selection = item
    }

    // Crosslink: shows what a link from another app names, in the page Immich's web app would show it on.
    private func showCrosslink(_ item: Crosslink.Item) {
        switch item {
        case .page(let page):
            let target: SidebarItem = switch page {
            case .photos: .library
            case .albums: .albums
            case .people: .people
            case .places: .explore(.places)
            case .favorites: .favorites
            case .archive: .archive
            }
            select(target)
        case .album(let id): select(.album(id))
        case .person(let id): openPerson(id)
        case .place(let place): open(.explore(.places), pushing: CrosslinkDestination.place(place))
        case .asset(let id, let context):
            let alone = { openWindow(id: "widget-photo", value: id) } // as the desktop widget shows a photo
            switch context {
            case .album(let album)?:
                select(.album(album))
                session.crosslinkReveal(id, in: .album(album), alone: alone)
            case .person(let person)?:
                openPerson(person) { session.crosslinkReveal(id, in: .person(person), alone: alone) }
            case .favorites?:
                select(.favorites)
                session.crosslinkReveal(id, in: .favorites, alone: alone)
            case .archive?:
                select(.archive)
                session.crosslinkReveal(id, in: .archive, alone: alone)
            case .search(let place)?:
                let destination = CrosslinkDestination.place(place)
                open(.explore(.places), pushing: destination)
                session.crosslinkReveal(id, in: destination.source, alone: alone)
            case nil:
                select(.library)
                session.crosslinkReveal(id, in: .library, alone: alone)
            }
        }
    }

    /// Selects a page, then pushes onto it once its stack exists (a new selection makes a new stack).
    private func open(_ page: SidebarItem, pushing value: some Hashable) {
        select(page)
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard selection == page else { return } // the user, or the link, moved on meanwhile
            path = NavigationPath()
            path.append(value)
        }
    }

    private func openPerson(_ id: String, then: @escaping () -> Void = {}) {
        Task {
            do {
                let person = try await session.client.person(id)
                open(.people, pushing: person)
                then()
            } catch { CrosslinkReceiver.cannotShow(error, session: session) }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .library {
        case .library:
            AssetGridContainer(source: .library, title: Text("Library"))
        case .favorites:
            AssetGridContainer(source: .favorites, title: Text("Favorites"))
        case .videos:
            AssetGridContainer(source: .videos, title: Text("Videos"))
        case .archive:
            AssetGridContainer(source: .archive, title: Text("Archive"))
        case .trash:
            AssetGridContainer(source: .trash, title: Text("Recently Deleted"))
        case .people:
            PeopleView()
        case .albums:
            AlbumsView()
        case .album(let id):
            AlbumDetailView(id: id, onClose: { select(.albums) }) // Albums
        case .sharedLinks: SharedLinksView() // Sharing
        case .partners: PartnersView() // Sharing
        case .partner(let id): AssetGridContainer(source: .partner(id), title: Text(session.sharing.receivedPartners.first { $0.id == id }?.name ?? "Partner Library")) // Sharing
        case .duplicates: AssetsDuplicatesView()
        case .largeFiles: AssetGridContainer(source: .largeFiles, title: Text("Large Files"))
        case .geolocation: AssetGridContainer(source: .geolocation, title: Text("Assign Location"))
        case .explore(let page): ExploreView(page: page) // Explore
        case .search:
            SearchView(text: submittedSearch, chooseText: { searchText = $0; submittedSearch = $0 }, showFilters: $showSearchFilters)
        }
    }
}

/// The Import item. macOS 26 attaches it to the split view, so it stays visible on pushed
/// pages too. On macOS 15 that combination with a pushed page's own toolbar loops forever
/// (100% CPU, frozen window), so there it belongs to the detail stack: shown on the main
/// pages, hidden on pushed ones (Back brings it back; File > Import… covers it). Account and
/// notifications live at the bottom of the sidebar instead.
private struct GlobalToolbar: ViewModifier {
    enum Level { case splitView, detailStack }
    let session: LibrarySession
    let level: Level

    func body(content: Content) -> some View {
        if attached {
            content
                .toolbar { UploadToolbar(queue: session.upload) } // Upload
        } else {
            content
        }
    }

    private var attached: Bool {
        if #available(macOS 26, *) { level == .splitView } else { level == .detailStack }
    }
}
