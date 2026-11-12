import SwiftUI

enum ExplorePage: String, CaseIterable, Hashable {
    case map = "Map", places = "Places", memories = "Memories", tags = "Tags", folders = "Folders", locked = "Locked Folder"
    var title: LocalizedStringResource {
        switch self {
        case .map: "Map"
        case .places: "Places"
        case .memories: "Memories"
        case .tags: "Tags"
        case .folders: "Folders"
        case .locked: "Locked Folder"
        }
    }
    var icon: String {
        switch self {
        case .map: "map"
        case .places: "globe.europe.africa"
        case .memories: "sparkles.rectangle.stack"
        case .tags: "tag"
        case .folders: "folder"
        case .locked: "lock"
        }
    }
}

struct ExploreView: View {
    let page: ExplorePage
    var body: some View {
        Group {
            switch page {
            case .map: ExploreMapView()
            case .places: ExplorePlacesView()
            case .memories: ExploreMemoriesView()
            case .tags: ExploreTagsView()
            case .folders: ExploreFoldersView()
            case .locked: ExploreLockedView()
            }
        }.navigationTitle(String(localized: page.title))
    }
}

struct ExplorePlacesView: View {
    @Environment(LibrarySession.self) private var session
    @State private var cities: [AssetResponse] = []
    @State private var error: String?
    // Places: Immich's grouping setting and default. Grouped by country, the page shows a card per country
    // that opens its cities, since one long page of country sections is hard to find your way in.
    @AppStorage("places.groupBy") private var groupBy = PlacesGroupBy.none
    var body: some View {
        let groups = PlacesArrangement(groupBy: groupBy).groups(cities)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240))], spacing: 20) {
                if groupBy == .country {
                    ForEach(groups) { group in
                        NavigationLink(value: PlacesCountryRoute(title: Self.title(group.header), ids: group.places.map(\.id))) {
                            ExploreCountryCard(title: Self.title(group.header), places: group.places)
                        }.buttonStyle(.plain)
                    }
                } else {
                    ForEach(cities) { ExplorePlaceCell(asset: $0, showsCountry: true) }
                }
            }
            .padding(20)
            // Switching between cities and countries replaces the grid with a transition, as Photos switches views.
            .id(groupBy)
            .transition(.blurReplace)
        }
        .navigationDestination(for: PlacesCountryRoute.self) { route in
            ExplorePlacesCountryView(title: route.title, places: cities.filter { route.ids.contains($0.id) })
        }
        .pageToolbar("places") {
            ToolbarItem(id: "show", placement: .principal) {
                ToolbarModePicker(selection: $groupBy.animation(.smooth(duration: 0.35)), options: PlacesGroupBy.allCases) { $0.title }
            }
        }
        .overlay { if let error { ContentUnavailableView("Places Unavailable", systemImage: "globe", description: Text(error)) } }
        .task {
            do { cities = try await session.client.exploreCities().filter { $0.visibility != "locked" } }
            catch { self.error = error.localizedDescription }
        }
    }

    static func title(_ header: PlacesGroup.Header?) -> String {
        switch header {
        case .country(let country): country
        case .unknownCountry, nil: String(localized: "Unknown Country")
        }
    }
}

struct PlacesCountryRoute: Hashable {
    let title: String
    let ids: [String]
}

/// A country's cities, opened from its card.
struct ExplorePlacesCountryView: View {
    let title: String
    let places: [AssetResponse]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240))], spacing: 20) {
                ForEach(places) { ExplorePlaceCell(asset: $0, showsCountry: false) }
            }.padding(20)
        }
        .navigationTitle(title)
        .pageToolbar("placesCountry")
    }
}

/// A country: a mosaic of its first four places (or the first one's photo), its name and how many places.
private struct ExploreCountryCard: View {
    @Environment(LibrarySession.self) private var session
    let title: String
    let places: [AssetResponse]
    var body: some View {
        VStack(alignment: .leading) {
            Group {
                if places.count >= 4 {
                    VStack(spacing: 2) {
                        ForEach(0..<2, id: \.self) { row in
                            HStack(spacing: 2) {
                                ForEach(0..<2, id: \.self) { column in
                                    RemoteThumbnail(pipeline: session.pipeline, assetID: places[row * 2 + column].id)
                                }
                            }
                        }
                    }
                } else {
                    RemoteThumbnail(pipeline: session.pipeline, assetID: places.first?.id)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 10))
            Text(title).font(.headline).lineLimit(1)
            Text("\(places.count) places").foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

private struct ExplorePlaceCell: View {
    @Environment(LibrarySession.self) private var session
    let asset: AssetResponse
    let showsCountry: Bool
    var body: some View {
        if let city = asset.exifInfo?.city {
            NavigationLink(value: GridRoute(source: .explore(.city(city)), title: city)) {
                VStack(alignment: .leading) {
                    RemoteThumbnail(pipeline: session.pipeline, assetID: asset.id).aspectRatio(1, contentMode: .fit).clipShape(.rect(cornerRadius: 10))
                    Text(city).font(.headline)
                    if showsCountry { Text(asset.exifInfo?.country ?? "").foregroundStyle(.secondary) }
                }
            }.buttonStyle(.plain)
            .contextMenu { CrosslinkMenuItems(item: .place(.init(city: city, country: asset.exifInfo?.country))) } // Crosslink
        }
    }
}

struct ExploreFoldersView: View {
    @Environment(LibrarySession.self) private var session
    @State private var roots: [ExploreFolderNode] = []
    @State private var error: String?
    var body: some View {
        List(roots, children: \.children) { node in
            NavigationLink(value: node) {
                Label(node.name, systemImage: "folder")
            }.help(node.id)
        }
        .navigationDestination(for: ExploreFolderNode.self) { node in
            ExploreFolderView(node: node)
        }
        .overlay { if let error { ContentUnavailableView("Folders Unavailable", systemImage: "folder", description: Text(error)) } }
        .pageToolbar("folders")
        .task {
            do { roots = ExploreFolderNode.tree(try await session.client.explorePaths()) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct ExploreFolderView: View {
    let node: ExploreFolderNode

    var body: some View {
        // Like an album's or a person's page: the folder's name, its path and its subfolders head the page and scroll
        // away with its photos, and the toolbar shows the name once they have.
        AssetGridContainer(source: .explore(.folder(node.id)), title: Text(verbatim: node.name), headerScrolls: true) {
            header
        }
        // The subfolders are what a folder without photos of its own holds, so its empty page only says so quietly.
        .environment(\.gridEmptyNote, node.children == nil ? nil : "No photos directly in this folder")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: node.name).font(.largeTitle.bold()).lineLimit(1)
                .help(node.name)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: node.id).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                .textSelection(.enabled)
            if let children = node.children {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 8)], spacing: 8) {
                    ForEach(children) { ExploreSubfolderTile(node: $0) }
                }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }
}

/// A subfolder, as Finder's icon view shows one: opening it shows its photos and its own subfolders.
private struct ExploreSubfolderTile: View {
    let node: ExploreFolderNode
    @State private var hovering = false

    var body: some View {
        NavigationLink(value: node) {
            VStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                    .frame(height: 44)
                    .accessibilityHidden(true)
                Text(verbatim: node.name).font(.callout).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10).padding(.horizontal, 6)
            .background(.quaternary.opacity(hovering ? 1 : 0), in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(node.id)
    }
}
