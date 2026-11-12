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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: SidebarItem? = .library
    @State private var search = SearchFieldModel()
    @State private var toolbarCompact = false
    @State private var navigation = PageNavigation()
    @State private var submittedSearch = ""
    @State private var showSearchFilters = false
    @State private var editingSidebar = false
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @Environment(\.openWindow) private var openWindow

    init(initialAlbumID: String? = nil, initialSearch: String? = nil) {
        _selection = State(initialValue: initialAlbumID.map(SidebarItem.album) ?? (initialSearch == nil ? .library : .search))
        let search = SearchFieldModel()
        search.text = initialSearch ?? ""
        _search = State(initialValue: search)
        _submittedSearch = State(initialValue: initialSearch ?? "")
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection, editing: $editingSidebar)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            detail
                .pageNavigation(navigation, item: selection ?? .library)
                .id(selection)
                .modifier(AccountPasswordBanner())
                .modifier(GlobalToolbar(session: session, level: .detailStack))
                .onGeometryChange(for: Bool.self) { $0.size.width < 980 } action: { toolbarCompact = $0 }
        }
        // On the split view, not the detail column: toolbar items of pages opened from a page only see the
        // environment from here up.
        .environment(search)
        .environment(\.toolbarCompact, toolbarCompact)
        .environment(navigation)
        .modifier(UploadDropModifier(queue: session.upload)) // Upload
        .modifier(GlobalToolbar(session: session, level: .splitView))
        .modifier(AlbumPresentation()) // Albums
        .onChange(of: session.albumActions.navigationAlbumID) { _, id in
            if let id {
                selection = .album(id)
                session.albumActions.navigationAlbumID = nil
            }
        }
        .focusedSceneValue(\.sidebarActions, SidebarActions(editing: $editingSidebar))
        .onChange(of: editingSidebar) { _, editing in if editing { columnVisibility = .all } }
        .focusedSceneValue(\.librarySession, session)
        .focusedSceneValue(\.searchActions, SearchActions(
            find: { selection = .search; search.focus() },
            filters: { selection = .search; showSearchFilters = true }))
        .onReceive(NotificationCenter.default.publisher(for: .viewerShowLibrary, object: session)) { _ in selection = .library }
        .onReceive(NotificationCenter.default.publisher(for: .crosslinkShow, object: session)) { note in // Crosslink
            if let item = note.userInfo?["item"] as? Crosslink.Item { showCrosslink(item) }
        }
        // Crosslink: another link came, or the window closed (also on signing out or switching accounts): what this
        // window was still doing for a link is stale. Choosing, pushing and popping pages end it in `PageNavigation`.
        .onReceive(NotificationCenter.default.publisher(for: .crosslinkArrived)) { _ in navigation.links.invalidate() }
        .onDisappear { navigation.links.invalidate() }
        .onChange(of: search.submissions) {
            let query = search.text.trimmingCharacters(in: .whitespaces)
            if query.isEmpty {
                if selection == .search { submittedSearch = "" }
                return
            }
            submittedSearch = query
            selection = .search
        }
        .onChange(of: selection, initial: true) { _, newValue in
            navigation.selectionChanged(to: newValue)
            if newValue != .search { search.text = ""; submittedSearch = ""; showSearchFilters = false }
        }
        .onChange(of: session.sharing.receivedPartners.map(\.id)) { _, ids in
            if case .partner(let id) = selection, !ids.contains(id) { selection = .partners }
        }
        .onChange(of: search.text) { _, text in
            if text.isEmpty, selection == .search { submittedSearch = "" }
        }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil; transaction.disablesAnimations = true }
        }
    }

    // Crosslink: shows what a link from another app names. `PageNavigation` owns the link's tasks.
    private func showCrosslink(_ item: Crosslink.Item) {
        let session = session
        let client = session.client
        navigation.showCrosslink(item, in: CrosslinkWindow(
            select: { selection = $0 },
            person: { try await client.person($0) },
            reveal: { [openWindow, navigation] id, source, ticket in
                session.crosslinkReveal(id, in: source, ticket: ticket, navigation: navigation.links,
                                        alone: { openWindow(id: "widget-photo", value: id) }) // as a widget photo opens
            },
            cannotShow: { CrosslinkReceiver.cannotShow($0, session: session) }))
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
            AlbumDetailView(id: id, onClose: { selection = .albums }) // Albums
        case .sharedLinks: SharedLinksView() // Sharing
        case .partners: PartnersView() // Sharing
        case .partner(let id): AssetGridContainer(source: .partner(id), title: Text(session.sharing.receivedPartners.first { $0.id == id }?.name ?? "Partner Library")) // Sharing
        case .duplicates: AssetsDuplicatesView()
        case .largeFiles: AssetGridContainer(source: .largeFiles, title: Text("Large Files"))
        case .geolocation: AssetGridContainer(source: .geolocation, title: Text("Assign Location"))
        case .explore(let page): ExploreView(page: page) // Explore
        case .search:
            SearchView(text: submittedSearch, chooseText: { search.text = $0; submittedSearch = $0 }, showFilters: $showSearchFilters)
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
                // The window's customizable toolbar: every page adds its items to it.
                .toolbar(id: "library") { UploadToolbar(queue: session.upload) } // Upload
        } else {
            content
        }
    }

    private var attached: Bool {
        if #available(macOS 26, *) { level == .splitView } else { level == .detailStack }
    }
}
