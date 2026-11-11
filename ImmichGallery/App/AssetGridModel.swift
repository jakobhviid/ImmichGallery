import AppKit
import Foundation
import Observation

/// What a grid shows.
enum GridSource: Hashable {
    case library, favorites, videos, archive, trash
    case locked // Explore: only shown in an unlocked Locked Folder session
    case largeFiles, geolocation // Assets
    case album(String)
    case partner(String) // Sharing
    case person(String)
    case search(String)
    case filteredSearch(SearchQuery) // Search

    case explore(ExploreSource) // Explore

    var isPartner: Bool { if case .partner = self { true } else { false } }

    var excludesArchived: Bool {
        switch self {
        case .library, .videos, .geolocation, .largeFiles, .person, .explore(.city), .explore(.folder): true
        case .explore(.map(let query)): !query.archived
        default: false
        }
    }

    var timelineQuery: TimelineQuery? {
        switch self {
        case .library: TimelineQuery(withPartners: true)
        case .geolocation: TimelineQuery(withPartners: false, withCoordinates: true)
        case .favorites: TimelineQuery(visibility: nil, isFavorite: true)
        case .archive: TimelineQuery(visibility: "archive")
        case .trash: TimelineQuery(visibility: nil, isTrashed: true)
        case .locked: TimelineQuery(visibility: "locked")
        case .album(let id): TimelineQuery(visibility: nil, albumId: id)
        case .partner(let id): TimelineQuery(userId: id) // Sharing
        case .person(let id): TimelineQuery(personId: id)
        case .explore(.tag(let id)): TimelineQuery(visibility: nil, tagId: id)
        case .explore(.map(let query)): query.timeline
        case .explore: nil
        case .videos, .search, .filteredSearch, .largeFiles: nil
        }
    }
}

extension GridSource {
    /// Grid pages with view options (GridArrangement).
    var gridPage: GridPage? {
        switch self {
        case .library: .library
        case .favorites: .favorites
        case .videos: .videos
        case .archive: .archive
        case .largeFiles: .largeFiles // Assets
        case .geolocation: .geolocation
        case .partner: .partner // Sharing
        case .person: .person
        case .explore(.tag): .tag // Explore
        case .locked: .locked // Explore
        default: nil
        }
    }
}

/// Lightweight asset used by grids and the viewer.
struct AssetItem: Identifiable, Hashable, Sendable {
    let id: String
    let ownerId: String?
    let isVideo: Bool
    var isFavorite: Bool
    var isTrashed: Bool
    let thumbhash: String?
    let ratio: Double
    let durationMS: Int?
    let date: Date?
    let livePhotoVideoID: String?
    let stackCount: Int?
    var fileSizeInBytes: Int64? = nil
    // Assign Location: only filled for timelines loaded with coordinates.
    var latitude: Double? = nil
    var longitude: Double? = nil
    var city: String? = nil
    var hasLocation: Bool { latitude != nil && longitude != nil }

    init(_ r: AssetResponse) {
        id = r.id
        ownerId = r.ownerId
        isVideo = r.type == .video
        isFavorite = r.isFavorite
        isTrashed = r.isTrashed
        thumbhash = r.thumbhash
        if let w = r.width, let h = r.height, h > 0 { ratio = Double(w) / Double(h) } else { ratio = 1 }
        durationMS = r.duration?.milliseconds
        date = ImmichDate.parse(r.localDateTime)
        livePhotoVideoID = r.livePhotoVideoId
        stackCount = r.stack?.assetCount
        fileSizeInBytes = r.exifInfo?.fileSizeInByte
        latitude = r.exifInfo?.latitude
        longitude = r.exifInfo?.longitude
        city = r.exifInfo?.city
    }

    static func from(_ c: TimeBucketAssets, includingLocked: Bool = false) -> [AssetItem] {
        c.id.indices.filter { includingLocked || c.visibility?.indices.contains($0) != true || c.visibility?[$0] != "locked" }.map { i in
            var item = AssetItem(
                id: c.id[i], ownerId: c.ownerId.flatMap { $0.indices.contains(i) ? $0[i] : nil }, isVideo: !c.isImage[i], isFavorite: c.isFavorite[i], isTrashed: c.isTrashed[i],
                thumbhash: c.thumbhash[i], ratio: c.ratio[i] ?? 1, durationMS: c.duration[i]?.milliseconds,
                date: ImmichDate.parse(c.fileCreatedAt[i]), livePhotoVideoID: c.livePhotoVideoId[i],
                stackCount: c.stack?[i].flatMap { $0.count > 1 ? Int($0[1]) : nil })
            item.latitude = c.latitude.flatMap { $0.indices.contains(i) ? $0[i] : nil }
            item.longitude = c.longitude.flatMap { $0.indices.contains(i) ? $0[i] : nil }
            item.city = c.city.flatMap { $0.indices.contains(i) ? $0[i] : nil }
            return item
        }
    }

    private init(id: String, ownerId: String?, isVideo: Bool, isFavorite: Bool, isTrashed: Bool, thumbhash: String?, ratio: Double,
                 durationMS: Int?, date: Date?, livePhotoVideoID: String?, stackCount: Int?) {
        self.ownerId = ownerId
        self.id = id; self.isVideo = isVideo; self.isFavorite = isFavorite; self.isTrashed = isTrashed
        self.thumbhash = thumbhash; self.ratio = ratio; self.durationMS = durationMS; self.date = date
        self.livePhotoVideoID = livePhotoVideoID; self.stackCount = stackCount
    }
}

struct GridSection: Identifiable {
    let id: String
    let title: String?
    var count: Int
    /// `nil` until the bucket has been fetched.
    var assets: [AssetItem]?
}

@MainActor @Observable
final class AssetGridModel {
    enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    let source: GridSource
    /// The session that owns this grid (Locked Folder: its own session, so menu commands use its client).
    @ObservationIgnored private(set) weak var session: LibrarySession?

    var albumOrder = "desc" // Albums
    /// The page's view options, read from its saved settings on every reload.
    private(set) var arrangement: GridArrangement?
    private(set) var sections: [GridSection] = []
    private(set) var state: LoadState = .idle
    private(set) var searchResultsLoaded = 0
    @ObservationIgnored private var sortedSmartResults: [AssetResponse]?
    var selection: Set<String> = []
    var viewerID: String?
    var viewerScrollTarget: String? // Viewer
    func viewerLoadSection(_ section: Int) async {
        guard sections.indices.contains(section), sections[section].assets == nil else { return }
        await loadSection(id: sections[section].id).value
    }

    /// Locate an asset even when media filters make the Library a paged search.
    func loadForReveal(_ asset: AssetResponse) async throws {
        if let arrangement {
            guard arrangement.isFavorite != true || asset.isFavorite,
                  arrangement.assetType == nil || arrangement.assetType == asset.type.rawValue else { return }
        }
        let generation = loadGeneration
        if isPaged {
            while item(asset.id) == nil, nextPage != nil {
                try Task.checkCancellation()
                guard generation == loadGeneration else { throw CancellationError() }
                if let pageTask { await pageTask.value }
                else { try await fetchNextPage() }
                if pageFailed { break }
            }
            guard generation == loadGeneration else { throw CancellationError() }
        } else if let month = sectionMonth(of: asset),
                  let section = sections.firstIndex(where: { $0.id.prefix(7) == month }) {
            await viewerLoadSection(section)
        }
    }

    func viewerAllItems() async throws -> [AssetItem] {
        for i in sections.indices { await viewerLoadSection(i) }
        while isPaged, nextPage != nil { try await fetchNextPage() }
        return sections.flatMap { $0.assets ?? [] }
    }

    @ObservationIgnored private var anchorID: String?
    @ObservationIgnored private var index: [String: (section: Int, item: Int)] = [:]
    @ObservationIgnored private var sectionTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var isStale = false
    @ObservationIgnored private var loadGeneration = UUID()
    // Paged sources (search, videos)
    @ObservationIgnored private var nextPage: ImmichClient.SearchPage?
    @ObservationIgnored private var pageFailed = false
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    /// The first load, shared so a second caller waits for it instead of returning early (Widget).
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadAllTask: Task<Void, Never>? // Assign Location

    init(source: GridSource, session: LibrarySession, reusing previous: AssetGridModel? = nil) {
        self.source = source
        self.session = session
        if case .filteredSearch(var query) = source, query.sort != .automatic,
           case .filteredSearch(var oldQuery) = previous?.source, oldQuery.sort != .automatic,
           previous?.isStale == false, let items = previous?.sortedSmartResults {
            let order = query.sort
            query.sort = .automatic; oldQuery.sort = .automatic
            if query == oldQuery {
                sortedSmartResults = items
                append(ImmichClient.sortSearchAssets(items, order: order).items.map(AssetItem.init))
                state = .loaded
            }
        }
    }

    var totalCount: Int { sections.reduce(0) { $0 + shownCount($1) } }

    /// Assign Location: a month shows once it has been checked for items without a location, instead of
    /// placeholders for items that are mostly located.
    func shownCount(_ section: GridSection) -> Int { arrangement?.hidesLocated == true && section.assets == nil ? 0 : section.count }
    /// Assign Location: still loading months to find the items without a location.
    private(set) var checkingLocations = false

    private var dateAdded: Bool { GridArrangement.supportsDateAdded(session?.version) }

    /// The source's timeline filters with the page's view options applied.
    private var timelineQuery: TimelineQuery? {
        guard let query = source.timelineQuery else { return nil }
        return arrangement.map { $0.applied(to: query, dateAdded: dateAdded) } ?? query
    }

    /// The ID prefix ("2026-11") of the section that holds an asset, following the view options.
    func sectionMonth(of asset: AssetResponse) -> Substring? {
        (arrangement ?? GridArrangement()).month(localDateTime: asset.localDateTime, createdAt: asset.createdAt, dateAdded: dateAdded)
    }

    /// A timeline page showing photos or videos only, through the search API.
    private var searchesTimeline: Bool { source.timelineQuery != nil && arrangement?.searchesTimeline == true }

    var isPaged: Bool { source.timelineQuery == nil || searchesTimeline }
    var showsSectionHeaders: Bool {
        switch source { case .search, .filteredSearch, .largeFiles: false; default: true }
    }

    func asset(_ section: Int, _ item: Int) -> AssetItem? {
        guard sections.indices.contains(section), let assets = sections[section].assets,
              assets.indices.contains(item) else { return nil }
        return assets[item]
    }

    func item(_ id: String) -> AssetItem? {
        guard let pos = index[id] else { return nil }
        return asset(pos.section, pos.item)
    }

    func canMutate(_ ids: [String]) -> Bool {
        guard !source.isPartner, source != .trash, !ids.isEmpty, let userID = session?.user?.id else { return false }
        return ids.allSatisfy { item($0)?.ownerId == userID }
    }

    func canDelete(_ ids: [String]) -> Bool {
        guard !source.isPartner, !ids.isEmpty, let userID = session?.user?.id else { return false }
        return ids.allSatisfy { item($0)?.ownerId == userID }
    }

    var selectedItems: [AssetItem] { selection.compactMap(item) }

    // MARK: Loading

    func loadIfNeeded() async {
        if let loadTask { await loadTask.value }
        // View options changed while this grid was off screen.
        let arrangementChanged = arrangement != source.gridPage.map { GridArrangement(page: $0) }
        guard state == .idle || isStale || arrangementChanged else { return }
        await reload()
    }

    // Explore: remove sensitive items immediately from every cached grid and viewer.
    func exploreRemove(_ ids: Set<String>) {
        if let viewerID, ids.contains(viewerID) { self.viewerID = nil }
        selection.subtract(ids)
        for i in sections.indices {
            sections[i].assets?.removeAll { ids.contains($0.id) }
            if let assets = sections[i].assets { sections[i].count = assets.count }
        }
        rebuildIndex()
        markStale()
    }

    func markStale() { isStale = true }

    func cancelLoading() {
        loadGeneration = UUID()
        loadTask?.cancel()
        pageTask?.cancel()
        loadAllTask?.cancel()
        sectionTasks.values.forEach { $0.cancel() }
    }

    func reload() async {
        loadGeneration = UUID()
        if let previous = loadTask {
            previous.cancel()
            await previous.value
        }
        let task = Task { await performReload() }
        loadTask = task
        await task.value
        if loadTask == task { loadTask = nil }
    }

    private func performReload() async {
        guard let session else { return }
        isStale = false
        sortedSmartResults = nil
        searchResultsLoaded = 0
        pageFailed = false
        sectionTasks.values.forEach { $0.cancel() }
        sectionTasks = [:]
        pageTask?.cancel()
        pageTask = nil
        loadAllTask?.cancel()
        loadAllTask = nil
        checkingLocations = false
        if sections.isEmpty { state = .loading }
        arrangement = source.gridPage.map { GridArrangement(page: $0) }
        do {
            if let query = timelineQuery, !searchesTimeline {
                var buckets = try await source.albumID != nil
                    ? session.client.albumTimeBuckets(query, order: albumOrder)
                    : session.client.timeBuckets(query)
                if case .explore(.map(let map)) = source {
                    buckets.removeAll { !map.includesMonth(start: ImmichDate.parse($0.timeBucket)) }
                }
                sections = buckets.map {
                    GridSection(id: $0.timeBucket, title: ImmichDate.monthTitle($0.timeBucket), count: $0.count)
                }
                rebuildIndex()
                state = .loaded
                // Load the first screenful right away.
                for i in sections.indices.prefix(2) { ensureLoaded(i) }
                if arrangement?.hidesLocated == true { loadAllSections() }
            } else {
                sections = []
                nextPage = .init(page: 1)
                rebuildIndex()
                try await fetchNextPage()
                state = .loaded
            }
        } catch {
            if error.isCancellation {
                if sections.isEmpty { state = .idle }
                return
            }
            session.handle(error)
            state = .failed(error.localizedDescription)
        }
    }

    /// Called as cells scroll into view.
    func cellAppeared(section: Int, item: Int) {
        if isPaged {
            if section == sections.count - 1, item >= sections[section].count - 60 { loadNextPage() }
        } else {
            ensureLoaded(section)
            if item > sections[section].count - 30 { ensureLoaded(section + 1) }
        }
    }

    func ensureLoaded(_ section: Int) {
        guard sections.indices.contains(section), sections[section].assets == nil else { return }
        _ = loadSection(id: sections[section].id)
    }

    @discardableResult
    private func loadSection(id: String) -> Task<Void, Never> {
        if let task = sectionTasks[id] { return task }
        let generation = loadGeneration
        let task = Task { [weak self] in
            guard let self, let session, let query = timelineQuery else { return }
            do {
                let columns = try await source.albumID != nil
                    ? session.client.albumTimeBucket(id, query, order: albumOrder)
                    : session.client.timeBucket(id, query)
                try Task.checkCancellation()
                guard generation == loadGeneration,
                      let i = sections.firstIndex(where: { $0.id == id }) else { return }
                var assets = AssetItem.from(columns, includingLocked: source == .locked).filter { self.source != .geolocation || (session.user?.id != nil && $0.ownerId == session.user?.id) }
                if case .explore(.map(let query)) = source { assets.removeAll { !query.includes($0.date) } }
                if arrangement?.hidesLocated == true { assets.removeAll(where: \.hasLocation) }
                sections[i].assets = assets
                sections[i].count = assets.count
                rebuildIndex()
            } catch {
                guard generation == loadGeneration, !error.isCancellation else { return }
                session.handle(error)
                sectionTasks[id] = nil // allow retry on next appearance
            }
        }
        sectionTasks[id] = task
        return task
    }

    /// Assign Location: without located items most months are empty or nearly so. Loading every month,
    /// one at a time, finds the items that are left and makes the item count true.
    private func loadAllSections() {
        let generation = loadGeneration
        let ids = sections.map(\.id)
        checkingLocations = true
        loadAllTask = Task { [weak self] in
            for id in ids {
                guard let self, generation == loadGeneration, !Task.isCancelled else { return }
                await loadSection(id: id).value
            }
            guard let self, generation == loadGeneration else { return }
            checkingLocations = false
        }
    }

    private func loadNextPage() {
        guard !pageFailed, pageTask == nil, nextPage != nil else { return }
        let generation = loadGeneration
        pageTask = Task { [weak self] in
            guard let self else { return }
            do { try await fetchNextPage() }
            catch { if generation == loadGeneration, !error.isCancellation { pageFailed = true; report(error) } }
            if generation == loadGeneration { pageTask = nil }
        }
    }

    private func fetchNextPage() async throws {
        try Task.checkCancellation()
        guard let session, let page = nextPage else { return }
        let generation = loadGeneration
        let result: SearchResponse.Assets
        switch source {
        case _ where searchesTimeline:
            // Photos or videos only on a timeline page: the timeline API has no type filter, search does.
            guard let query = source.timelineQuery, let arrangement else { return }
            result = try await session.client.metadataSearch(
                type: arrangement.mediaType == .videos ? .video : .image, visibility: query.visibility,
                isFavorite: query.isFavorite ?? arrangement.isFavorite, personIds: query.personId.map { [$0] },
                tagIds: query.tagId.map { [$0] }, order: arrangement.order.rawValue, page: page)
        case .largeFiles:
            let assets = try await session.client.assetsLargeFiles(type: arrangement?.assetType, isFavorite: arrangement?.isFavorite, serverVersion: session.version)
            try Task.checkCancellation()
            guard generation == loadGeneration else { throw CancellationError() }
            nextPage = nil
            append(assets.filter { $0.visibility != "locked" }.map(AssetItem.init))
            return
        case .search(let text):
            if session.features.smartSearch {
                result = try await session.client.smartSearch(text, page: page.page ?? 1)
            } else {
                result = try await session.client.metadataSearch(fileName: text, page: page)
            }
        case .filteredSearch(let query):
            result = try await session.client.advancedSearch(query, smartEnabled: session.features.smartSearch, page: page) { [weak self] count in
                guard self?.loadGeneration == generation else { return }
                self?.searchResultsLoaded = count
            }
            try Task.checkCancellation()
            guard generation == loadGeneration else { throw CancellationError() }
            if query.mode == .context, session.features.smartSearch,
               !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               query.sort != .automatic, result.nextPage == nil, result.nextCursor == nil {
                sortedSmartResults = result.items.filter { $0.visibility != "locked" }
            }
        case .explore(let source):
            result = try await session.client.exploreAssets(source, page: page)
        case .videos:
            // Live Photo motion components are hidden and have no standalone thumbnails.
            result = try await session.client.metadataSearch(type: .video, visibility: "timeline", isFavorite: arrangement?.isFavorite,
                                                             order: (arrangement?.order ?? .newestFirst).rawValue, page: page)
        default:
            return
        }
        try Task.checkCancellation()
        guard generation == loadGeneration else { throw CancellationError() }
        if let cursor = result.nextCursor {
            nextPage = .init(cursor: cursor)
        } else if let next = result.nextPage.flatMap(Int.init) {
            nextPage = .init(page: next)
        } else {
            nextPage = nil
        }
        // Search without a visibility also finds Live Photos' hidden video parts.
        let keepsLocked = source == .locked
        let visibleItems = result.items.filter { (keepsLocked || $0.visibility != "locked") && !(searchesTimeline && $0.visibility == "hidden") }
        append(visibleItems.map(AssetItem.init))
        // Any fully filtered page must advance, since it has no cells to trigger pagination.
        if visibleItems.isEmpty, nextPage != nil {
            try await fetchNextPage()
        }
    }

    /// Appends paged results. Search keeps the requested order in one section;
    /// other paged sources are grouped by month like the timeline.
    private func append(_ items: [AssetItem]) {
        guard !items.isEmpty else { return }
        if !showsSectionHeaders {
            if sections.isEmpty { sections = [GridSection(id: "results", title: nil, count: 0, assets: [])] }
            sections[0].assets!.append(contentsOf: items)
            sections[0].count = sections[0].assets!.count
        } else {
            for item in items {
                let key = item.date.map { String(ImmichDate.monthKey($0)) } ?? "unknown"
                if sections.last?.id != key {
                    sections.append(GridSection(id: key, title: ImmichDate.monthTitle(key), count: 0, assets: []))
                }
                sections[sections.count - 1].assets!.append(item)
                sections[sections.count - 1].count += 1
            }
        }
        rebuildIndex()
    }

    private func rebuildIndex() {
        var index: [String: (Int, Int)] = [:]
        for (s, section) in sections.enumerated() {
            for (i, asset) in (section.assets ?? []).enumerated() { index[asset.id] = (s, i) }
        }
        self.index = index
    }

    // MARK: Viewer navigation

    func neighbor(of id: String, delta: Int) async -> AssetItem? {
        guard let pos = index[id] else { return nil }
        var s = pos.section
        var i = pos.item + delta
        while sections.indices.contains(s) {
            if sections[s].assets == nil { await loadSection(id: sections[s].id).value }
            let count = sections[s].assets?.count ?? 0
            if i < 0 {
                s -= 1
                guard sections.indices.contains(s) else { return nil }
                if sections[s].assets == nil { await loadSection(id: sections[s].id).value }
                i = (sections[s].assets?.count ?? 0) - 1
            } else if i >= count {
                if isPaged, s == sections.count - 1, nextPage != nil, !pageFailed {
                    do { try await fetchNextPage() }
                    catch {
                        if !error.isCancellation { pageFailed = true; report(error) }
                        return nil
                    }
                    continue
                }
                s += 1
                i = 0
            } else {
                return sections[s].assets?[i]
            }
        }
        return nil
    }

    // MARK: Selection

    func click(_ id: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchorID = id
        } else if flags.contains(.shift), let anchor = anchorID ?? cursorID ?? orderedSelection.first, index[anchor] != nil {
            selection = range(from: anchor, to: id)
            anchorID = anchor
        } else {
            selection = [id]
            anchorID = id
        }
        cursorID = id
    }

    /// Every item from one to the other, in the grid's order, both included.
    private func range(from first: String, to last: String) -> Set<String> {
        guard let a = index[first], let b = index[last] else { return [last] }
        let (from, to) = (a.section, a.item) < (b.section, b.item) ? (a, b) : (b, a)
        var ids: Set<String> = []
        for s in from.section...to.section {
            guard let assets = sections[s].assets else { continue }
            let start = s == from.section ? from.item : 0
            let end = s == to.section ? to.item : assets.count - 1
            if start <= end { ids.formUnion(assets[start...end].map(\.id)) }
        }
        return ids
    }

    private var orderedSelection: [String] {
        selection.compactMap { id in index[id].map { (id, $0) } }
            .sorted { ($0.1.section, $0.1.item) < ($1.1.section, $1.1.item) }.map(\.0)
    }

    // MARK: Keyboard

    /// The item the arrow keys move from: the last one clicked or reached, as in Photos and Finder.
    @ObservationIgnored private var cursorID: String?
    /// How many items a row of the grid holds, set by the grid from its width.
    @ObservationIgnored var columns = 1
    /// The item the arrow keys reached, for the grid to scroll to.
    var keyboardScrollTarget: String?
    /// Whether a page header above the photos (an album's, a person's) is in view: while it is, it names the page
    /// and the toolbar doesn't repeat it.
    var headerInView = true
    /// Counts removals, so the grid animates the photos into their new places.
    private(set) var removals = 0
    /// The months of the photos in view, for the window's subtitle as in Photos.
    private(set) var visibleMonths: String?

    func showing(sections ids: some Sequence<String>) {
        let months = showsSectionHeaders ? ImmichDate.monthRange(ids) : nil
        if months != visibleMonths { visibleMonths = months }
    }

    enum Move { case left, right, up, down }

    /// Moves the cursor one item, or one row, and selects it; extending selects everything from where the
    /// selection started (the anchor) to it, as Shift does in Photos and Finder.
    func move(_ direction: Move, extending: Bool) async {
        let start = cursorID.flatMap { selection.contains($0) && index[$0] != nil ? $0 : nil }
            ?? (direction == .left || direction == .up ? orderedSelection.first : orderedSelection.last)
        guard let start else {
            // Nothing selected: the first item, as Photos does.
            guard let first = sections.lazy.compactMap({ $0.assets?.first }).first else { return }
            select(first.id)
            return
        }
        guard let target = await self.target(from: start, direction) else { return }
        cursorID = target
        if extending {
            let anchor = anchorID.flatMap { index[$0] != nil ? $0 : nil } ?? start
            anchorID = anchor
            selection = range(from: anchor, to: target)
        } else {
            selection = [target]
            anchorID = target
        }
        keyboardScrollTarget = target
    }

    private func select(_ id: String) {
        selection = [id]
        anchorID = id
        cursorID = id
        keyboardScrollTarget = id
    }

    /// The item one step away: across months for left and right, by row for up and down. Each month starts a new
    /// row, so moving down from its last row goes to the same column of the next month's first row.
    private func target(from id: String, _ direction: Move) async -> String? {
        switch direction {
        case .left: return await neighbor(of: id, delta: -1)?.id
        case .right: return await neighbor(of: id, delta: 1)?.id
        case .up, .down:
            guard let pos = index[id] else { return nil }
            let width = max(1, columns), column = pos.item % width
            let count = sections[pos.section].assets?.count ?? 0
            if direction == .down {
                if pos.item + width < count { return sections[pos.section].assets?[pos.item + width].id }
                // A shorter last row: its last item, as Finder does.
                if pos.item / width < (count - 1) / width { return sections[pos.section].assets?.last?.id }
                var s = pos.section + 1
                while sections.indices.contains(s) {
                    if sections[s].assets == nil { await loadSection(id: sections[s].id).value }
                    if let assets = sections[s].assets, !assets.isEmpty { return assets[min(column, assets.count - 1)].id }
                    s += 1
                }
            } else {
                if pos.item - width >= 0 { return sections[pos.section].assets?[pos.item - width].id }
                var s = pos.section - 1
                while sections.indices.contains(s) {
                    if sections[s].assets == nil { await loadSection(id: sections[s].id).value }
                    if let assets = sections[s].assets, !assets.isEmpty {
                        let lastRow = (assets.count - 1) / width * width
                        return assets[min(lastRow + column, assets.count - 1)].id
                    }
                    s -= 1
                }
            }
            return nil
        }
    }

    /// The items next to one, already loaded, for Quick Look to fetch ahead.
    func loadedNeighbours(of id: String) -> [String] {
        guard let pos = index[id], let assets = sections[pos.section].assets else { return [] }
        var ids: [String] = []
        if pos.item > 0 { ids.append(assets[pos.item - 1].id) }
        if pos.item + 1 < assets.count { ids.append(assets[pos.item + 1].id) }
        let width = max(1, columns)
        if pos.item + width < assets.count { ids.append(assets[pos.item + width].id) }
        if pos.item - width >= 0 { ids.append(assets[pos.item - width].id) }
        return ids
    }

    /// The selection's neighbours when one item is selected, else none.
    var quickLookAhead: [String] {
        selection.count == 1 ? selection.first.map(loadedNeighbours(of:)) ?? [] : []
    }

    /// Where an item sits, for scrolling to it.
    func position(of id: String) -> (section: String, item: Int)? {
        index[id].map { (sections[$0.section].id, $0.item) }
    }

    /// Every photo, as in Photos: the loaded ones now, and the months not loaded yet as they load, unless the selection
    /// changes meanwhile.
    func selectAll() {
        let loaded = Set(sections.flatMap { $0.assets ?? [] }.map(\.id))
        selection = loaded
        guard sections.contains(where: { $0.assets == nil }) || (isPaged && nextPage != nil) else { return }
        let generation = loadGeneration
        Task { [weak self] in
            guard let self, let all = try? await viewerAllItems(), generation == loadGeneration, selection == loaded else { return }
            selection = Set(all.map(\.id))
        }
    }

    func open(_ id: String) {
        selection = [id]
        anchorID = id
        viewerID = id
    }

    // MARK: Actions

    func setFavorite(_ ids: [String], _ value: Bool) async {
        guard canMutate(ids), let session else { return }
        do {
            try await session.client.setFavorite(ids, value)
            if (source == .favorites || arrangement?.show == .favorites) && !value {
                remove(ids)
            } else {
                update(ids) { $0.isFavorite = value }
            }
            session.invalidateGrids(except: self)
        } catch { report(error) }
    }

    func toggleFavorite(_ ids: [String]) async {
        let items = ids.compactMap(item)
        await setFavorite(ids, !items.allSatisfy(\.isFavorite))
    }

    func moveToLockedFolder(_ ids: [String]) async {
        guard canMutate(ids), source != .locked, let session else { return }
        do {
            try await session.client.setVisibility(ids, "locked")
            session.exploreRemoveFromGrids(Set(ids))
            session.pipeline.evict(ids: ids)
            Task {
                try? await Task.sleep(for: .seconds(2))
                session.pipeline.evict(ids: ids)
            }
            session.invalidateGrids()
            await reload()
        } catch { report(error) }
    }

    func removeFromLockedFolder(_ ids: [String]) async {
        guard canMutate(ids), source == .locked, let session else { return }
        do {
            try await session.client.setVisibility(ids, "timeline")
            remove(ids)
            session.services.hiddenAssetIDs.subtract(ids)
            session.invalidateGrids(except: self)
        } catch { report(error) }
    }

    func setArchived(_ ids: [String], _ archived: Bool) async {
        guard canMutate(ids), source != .locked, let session else { return }
        do {
            try await session.client.setVisibility(ids, archived ? "archive" : "timeline")
            if source == .archive || source.excludesArchived {
                remove(ids)
            }
            session.invalidateGrids(except: self)
        } catch { report(error) }
    }

    func delete(_ ids: [String], permanently: Bool) async {
        guard canDelete(ids), let session else { return }
        do {
            // Locked items are deleted permanently, as in Immich: trash doesn't show them.
            try await session.client.delete(ids, force: permanently || source == .locked)
            remove(ids)
            session.invalidateGrids(except: self)
            await session.reloadAlbums()
        } catch { report(error) }
    }

    /// Takes photos out of the album the grid shows; they stay in the library.
    func removeFromAlbum(_ ids: [String]) async throws {
        guard let albumID = source.albumID, let session else { return }
        try await session.client.changeAlbumAssets(albumID, ids: ids, removing: true)
        remove(ids)
    }

    func restore(_ ids: [String]) async {
        guard canDelete(ids), let session else { return }
        do {
            try await session.client.restore(ids)
            remove(ids)
            session.invalidateGrids(except: self)
        } catch { report(error) }
    }

    var lastError: String?

    private func report(_ error: Error) {
        session?.handle(error)
        lastError = error.localizedDescription
    }

    /// Assign Location: located items leave a Without Location list; elsewhere the GPS badges follow.
    func setLocation(_ ids: [String], latitude: Double, longitude: Double) {
        if arrangement?.hidesLocated == true { remove(ids) }
        else { update(ids) { $0.latitude = latitude; $0.longitude = longitude; $0.city = nil } }
    }

    private func update(_ ids: [String], _ change: (inout AssetItem) -> Void) {
        sortedSmartResults = nil
        for id in ids {
            guard let pos = index[id] else { continue }
            change(&sections[pos.section].assets![pos.item])
        }
    }

    private func remove(_ ids: [String]) {
        sortedSmartResults = nil
        let removed = Set(ids)
        // Move the viewer to a neighbour before the current asset disappears.
        if let viewerID, removed.contains(viewerID), let pos = index[viewerID] {
            let remaining = (sections[pos.section].assets ?? []).filter { !removed.contains($0.id) }
            self.viewerID = remaining.isEmpty ? nil : remaining[min(pos.item, remaining.count - 1)].id
        }
        for s in sections.indices {
            guard let assets = sections[s].assets else { continue }
            let kept = assets.filter { !removed.contains($0.id) }
            if kept.count != assets.count {
                sections[s].assets = kept
                sections[s].count = kept.count
            }
        }
        sections.removeAll { $0.count == 0 && $0.assets != nil }
        selection.subtract(removed)
        rebuildIndex()
        removals += 1
    }
}

extension Error {
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

extension ImmichDate {
    /// "2025-04-01" style key for grouping by month.
    static func monthKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d-01", c.year ?? 0, c.month ?? 0)
    }
}
