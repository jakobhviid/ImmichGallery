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
                        NavigationLink {
                            ExplorePlacesCountryView(title: Self.title(group.header), places: group.places)
                        } label: {
                            ExploreCountryCard(title: Self.title(group.header), places: group.places)
                        }.buttonStyle(.plain)
                    }
                } else {
                    ForEach(cities) { ExplorePlaceCell(asset: $0, showsCountry: true) }
                }
            }.padding(20)
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Show", selection: $groupBy) {
                        ForEach(PlacesGroupBy.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("View Options", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("View Options")
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
            NavigationLink {
                AssetGridContainer(source: .explore(.city(city)), title: Text(city))
            } label: {
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
            NavigationLink {
                AssetGridContainer(source: .explore(.folder(node.id)), title: Text(node.name))
            } label: { Label(node.name, systemImage: "folder") }.help(node.id)
        }
        .overlay { if let error { ContentUnavailableView("Folders Unavailable", systemImage: "folder", description: Text(error)) } }
        .task {
            do { roots = ExploreFolderNode.tree(try await session.client.explorePaths()) }
            catch { self.error = error.localizedDescription }
        }
    }
}
