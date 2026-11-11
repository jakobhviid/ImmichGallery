import SwiftUI

struct AlbumsView: View {
    @Environment(LibrarySession.self) private var session
    // Albums: the same settings and defaults as the albums page of the Immich web app.
    @AppStorage("albums.filter") private var filter = AlbumsFilter.all
    @AppStorage("albums.groupBy") private var groupBy = AlbumsGroupBy.year
    @AppStorage("albums.groupOrder") private var groupOrder = AlbumsSortOrder.descending
    @AppStorage("albums.sortBy") private var sortBy = AlbumsSortBy.mostRecentPhoto
    @AppStorage("albums.sortOrder") private var sortOrder = AlbumsSortOrder.descending
    @AppStorage("albums.view") private var viewMode = AlbumsViewMode.cover
    @AppStorage("albums.collapsedGroups") private var collapsedGroups = "{}"
    @State private var listSelection: Set<Album.ID> = []
    @Environment(PageNavigation.self) private var navigation

    private var arrangement: AlbumsArrangement {
        AlbumsArrangement(filter: filter, groupBy: groupBy, groupOrder: groupOrder, sortBy: sortBy, sortOrder: sortOrder)
    }

    var body: some View {
        let groups = arrangement.groups(session.albums, userID: session.user?.id)
        Group {
            if groups.isEmpty && !session.albums.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Albums", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No albums match the selected filter.")
                } actions: {
                    Button("Show All Albums") { filter = .all }
                }
            } else if groups.isEmpty {
                ContentUnavailableView("No Albums", systemImage: "rectangle.stack",
                                       description: Text("Albums you create or that are shared with you appear here."))
            } else if viewMode == .list {
                list(groups)
            } else {
                covers(groups)
            }
        }
        .navigationTitle("Albums")
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(id: album.id)
        }
        .pageToolbar("albums") {
            ToolbarItem(id: "show", placement: .principal) {
                // The albums move to their new places.
                ToolbarModePicker(selection: $filter.animation(.smooth(duration: 0.35)), options: AlbumsFilter.allCases) { $0.title }
            }
            ToolbarItem(id: "viewOptions") { viewOptions }
            ToolbarItem(id: "newAlbum") { Button { session.albumActions.newAlbum() } label: { Label("New Album", systemImage: "plus") } }
        }
        .task { await session.reloadAlbums() }
    }

    private var collapsed: CollapsedGroups { CollapsedGroups(stored: collapsedGroups) }

    private func covers(_ groups: [AlbumsGroup]) -> some View {
        let groupBy = arrangement.effectiveGroupBy
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 20)], spacing: 24, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    let isCollapsed = collapsed.isCollapsed(group.id, in: groupBy.collapsingKey)
                    Section {
                        if !isCollapsed {
                            ForEach(group.albums) { album in
                                NavigationLink(value: album) { AlbumCell(album: album, pipeline: session.pipeline) }.buttonStyle(.plain)
                                    .contextMenu {
                                        MacAlbumWindowMenu(albumID: album.id) // MacIntegration
                                        Divider()
                                        CrosslinkMenuItems(item: .album(album.id)) // Crosslink
                                    }
                            }
                        }
                    } header: {
                        if let header = group.header {
                            // Like Immich, a group header collapses and expands its group.
                            Button {
                                var groups = collapsed
                                groups.toggle(group.id, in: groupBy.collapsingKey)
                                withAnimation(.smooth(duration: 0.3)) { collapsedGroups = groups.stored }
                            } label: {
                                SectionHeader(title: title(header), disclosure: isCollapsed ? .collapsed : .expanded, count: group.albums.count)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, -10)
                            .accessibilityHint(isCollapsed ? Text("Shows the albums in this group") : Text("Hides the albums in this group"))
                        }
                    }
                }
            }.padding(20)
        }
        .fastWheelScrolling()
    }

    private func list(_ groups: [AlbumsGroup]) -> some View {
        Table(of: Album.self, selection: $listSelection, sortOrder: tableSort) {
            TableColumn("Title", value: \Album.albumName, comparator: .localizedStandard) { album in
                HStack(spacing: 8) {
                    RemoteThumbnail(pipeline: session.pipeline, assetID: album.albumThumbnailAssetId)
                        .frame(width: 28, height: 28)
                        .clipShape(.rect(cornerRadius: 4))
                    Text(album.albumName).lineLimit(1)
                    if album.shared { Image(systemName: "person.2.fill").foregroundStyle(.secondary).help("Shared") }
                }
            }
            TableColumn("Item Count", value: \Album.assetCount) { Text($0.assetCount, format: .number) }
                .width(min: 60, ideal: 80)
            TableColumn("Date Modified", value: \Album.listDateModified) { Text(Self.instant($0.updatedAt)) }
            TableColumn("Date Created", value: \Album.listDateCreated) { Text(Self.instant($0.createdAt)) }
            TableColumn("Most Recent Photo", value: \Album.listMostRecentPhoto) { Text(Self.photoDay($0.endDate)) }
            TableColumn("Oldest Photo", value: \Album.listOldestPhoto) { Text(Self.photoDay($0.startDate)) }
        } rows: {
            ForEach(groups) { group in
                if let header = group.header {
                    Section(title(header)) {
                        ForEach(group.albums) { TableRow($0) }
                    }
                } else {
                    ForEach(group.albums) { TableRow($0) }
                }
            }
        }
        .contextMenu(forSelectionType: Album.ID.self) { ids in
            if ids.count == 1, let id = ids.first {
                MacAlbumWindowMenu(albumID: id) // MacIntegration
                Divider()
                CrosslinkMenuItems(item: .album(id)) // Crosslink
            }
        } primaryAction: { ids in
            if let album = session.albums.first(where: { ids.contains($0.id) }) { navigation.open(album) }
        }
    }

    /// The table's column headers choose the sort, like the headers of Immich's list view.
    private var tableSort: Binding<[KeyPathComparator<Album>]> {
        Binding {
            [Self.comparator(sortBy, sortOrder)]
        } set: { comparators in
            guard let first = comparators.first,
                  let option = AlbumsSortBy.allCases.first(where: { Self.comparator($0, .ascending).keyPath == first.keyPath }) else { return }
            if option != sortBy {
                sortBy = option
                sortOrder = option.defaultOrder
            } else {
                sortOrder = first.order == .forward ? .ascending : .descending
            }
        }
    }

    private static func comparator(_ option: AlbumsSortBy, _ order: AlbumsSortOrder) -> KeyPathComparator<Album> {
        let order: SortOrder = order == .ascending ? .forward : .reverse
        return switch option {
        case .title: KeyPathComparator(\Album.albumName, comparator: .localizedStandard, order: order)
        case .itemCount: KeyPathComparator(\Album.assetCount, order: order)
        case .dateModified: KeyPathComparator(\Album.listDateModified, order: order)
        case .dateCreated: KeyPathComparator(\Album.listDateCreated, order: order)
        case .mostRecentPhoto: KeyPathComparator(\Album.listMostRecentPhoto, order: order)
        case .oldestPhoto: KeyPathComparator(\Album.listOldestPhoto, order: order)
        }
    }

    /// Album edits happened at a moment in time: shown in the Mac's time zone.
    private static func instant(_ value: String?) -> String {
        value.flatMap(ImmichDate.parse)?.formatted(date: .abbreviated, time: .omitted) ?? ""
    }

    /// Photo dates are the photo's own wall-clock day at UTC midnight: shown in UTC so they don't shift.
    private static func photoDay(_ value: String?) -> String {
        value.flatMap(ImmichDate.parse)?.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC")!)) ?? ""
    }

    private var viewOptions: some View {
        Menu {
            Picker("View", selection: $viewMode) {
                ForEach(AlbumsViewMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            // No Section around these: an inline picker in a menu already shows its label as the heading.
            Group {
                Picker("Group By", selection: Binding(
                    get: { arrangement.effectiveGroupBy },
                    set: { option in
                        guard groupBy != option else { return }
                        withAnimation(.smooth(duration: 0.35)) {
                            groupBy = option
                            groupOrder = option.defaultOrder
                        }
                    }
                )) {
                    ForEach(AlbumsGroupBy.allCases) { option in
                        Text(option.title).tag(option).disabled(!arrangement.allows(option))
                    }
                }
                .pickerStyle(.inline)
                orderPicker("Group Order", $groupOrder.animation(.smooth(duration: 0.35))).disabled(arrangement.effectiveGroupBy == .none)
                if viewMode == .cover {
                    let groupBy = arrangement.effectiveGroupBy
                    Button("Expand All Groups") {
                        var groups = collapsed
                        groups.set([], in: groupBy.collapsingKey)
                        withAnimation(.smooth(duration: 0.3)) { collapsedGroups = groups.stored }
                    }
                    .disabled(groupBy == .none)
                    Button("Collapse All Groups") {
                        var groups = collapsed
                        groups.set(arrangement.groups(session.albums, userID: session.user?.id).map(\.id), in: groupBy.collapsingKey)
                        withAnimation(.smooth(duration: 0.3)) { collapsedGroups = groups.stored }
                    }
                    .disabled(groupBy == .none)
                }
            }
            Group {
                Picker("Sort By", selection: Binding(
                    get: { sortBy },
                    set: { option in
                        guard sortBy != option else { return }
                        withAnimation(.smooth(duration: 0.35)) {
                            sortBy = option
                            sortOrder = option.defaultOrder
                        }
                    }
                )) {
                    ForEach(AlbumsSortBy.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                orderPicker("Album Order", $sortOrder.animation(.smooth(duration: 0.35)))
            }
        } label: {
            Label("View Options", systemImage: "line.3.horizontal.decrease")
        }
        .menuIndicator(.hidden)
        .help("View Options")
    }

    private func orderPicker(_ title: LocalizedStringKey, _ order: Binding<AlbumsSortOrder>) -> some View {
        Picker(title, selection: order) {
            ForEach(AlbumsSortOrder.allCases) { Text($0.title).tag($0) }
        }
    }

    private func title(_ header: AlbumsGroup.Header) -> String {
        switch header {
        case .year(let year): String(year)
        case .unknownYear: String(localized: "Unknown Year")
        case .mine: String(localized: "My Albums")
        case .owner(let name): name
        }
    }
}

/// Sort keys for the list view's columns. Albums without the date sort as the oldest.
private extension Album {
    var listDateModified: Date { updatedAt.flatMap(ImmichDate.parse) ?? .distantPast }
    var listDateCreated: Date { createdAt.flatMap(ImmichDate.parse) ?? .distantPast }
    var listMostRecentPhoto: Date { endDate.flatMap(ImmichDate.parse) ?? .distantPast }
    var listOldestPhoto: Date { startDate.flatMap(ImmichDate.parse) ?? .distantPast }
}

private struct AlbumCell: View {
    let album: Album
    let pipeline: ImagePipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteThumbnail(pipeline: pipeline, assetID: album.albumThumbnailAssetId, size: .preview)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 10))
            Text(album.albumName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 4) {
                if album.shared { Image(systemName: "person.2.fill") }
                Text("\(album.assetCount) items")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
