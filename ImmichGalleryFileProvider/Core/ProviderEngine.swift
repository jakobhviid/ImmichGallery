import Foundation

/// The Immich operations the File Provider uses. `ImmichProviderRemote` talks to the server; the offline checks use
/// a fake.
protocol ProviderRemote: Sendable {
    func albums() async throws -> [RemoteAlbum]
    /// Nil when the album no longer exists or isn't shared with the user any more.
    func album(_ id: String) async throws -> RemoteAlbum?
    /// The months of the user's own timeline that have photos.
    func timelineMonths() async throws -> [RemoteMonth]
    /// Changes whenever favorites may have changed.
    func favoritesSignature() async throws -> String
    func monthAssets(year: Int, month: Int) async throws -> [RemoteAsset]
    /// `known` lets assets already listed keep their details without asking the server again.
    func albumAssets(_ albumID: String, known: [String: RemoteAsset]) async throws -> [RemoteAsset]
    func favoriteAssets() async throws -> [RemoteAsset]
    /// Nil when the asset doesn't exist or can't be seen.
    func asset(_ id: String) async throws -> RemoteAsset?
    func downloadOriginal(_ id: String, into directory: URL, progress: Progress) async throws -> URL
    func thumbnail(_ id: String, large: Bool) async throws -> Data
    /// Lowercased extensions with a leading dot that the server accepts.
    func uploadExtensions() async throws -> Set<String>
    func upload(_ file: URL, name: String, created: Date?, modified: Date?, progress: Progress) async throws -> (id: String, duplicate: Bool)
    func createAlbum(_ name: String) async throws -> RemoteAlbum
    func renameAlbum(_ id: String, to name: String) async throws -> RemoteAlbum
    func deleteAlbum(_ id: String) async throws
    func addToAlbum(_ albumID: String, assets: [String]) async throws
    func removeFromAlbum(_ albumID: String, assets: [String]) async throws
    func setFavorite(_ id: String, _ favorite: Bool) async throws
    /// False when the server has its Trash turned off, where Immich deletes "trashed" assets at once.
    func trashAvailable() async throws -> Bool
    func trash(_ ids: [String]) async throws
    func restore(_ ids: [String]) async throws
}

/// Messages shown on items Finder couldn't sync. Localized by the extension.
struct ProviderMessages: Sendable {
    var changesOff = "Changes from Finder are turned off for this account in Immich Gallery Settings."
    var removingOff = "Removing from Finder is turned off for this account in Immich Gallery Settings."
    var foldersOnlyInAlbums = "New folders can only be made in Albums, where each folder is an album."
    var cannotAddHere = "Items can't be added to this folder."
    var albumReadOnly = "You can't add to this album."
    var unsupportedType = "Immich doesn't accept this kind of file."
    var cannotReplace = "Photos in Immich can't be replaced. Add the edited file as a new item instead."
    var unavailable = "This item is already in Immich but can't be shown here."
    var archived = "This photo is already in Immich's Archive, so it isn't shown in Library or Favorites."
    var notOwner = "Only the photo's owner can do this."
    var trashOff = "This server's Trash is turned off, so photos can't be removed from Finder: Immich would delete them for good."
}

/// Translates File Provider calls into Immich operations.
///
/// - Finder folders are memberships: removing a photo from an album folder takes it out of the album; from Favorites,
///   unfavorites it; from Library, moves it to Immich's Trash (never deletes it permanently). Deleting an album folder
///   deletes the album, not its photos. All removals need Settings ▸ Finder ▸ Allow Removing.
/// - Dragging a photo to an album or Favorites adds it there. Between two albums it moves when removing is allowed;
///   otherwise, and from Library or Favorites, the photo stays where it was too.
/// - Photos can't be renamed or replaced in Immich, so those changes are refused and Finder shows the server's state.
final class ProviderEngine: Sendable {
    let remote: any ProviderRemote
    let store: ProviderStore
    let userID: String
    let names: ProviderFolderNames
    let messages: ProviderMessages
    let settings: @Sendable () -> (options: ProviderOptions, refreshRequested: Date?)
    let now: @Sendable () -> Date
    /// Tells the system to ask for working-set changes (signalEnumerator).
    let signal: @Sendable () -> Void
    private let gate = RefreshGate()

    /// Folders not listed again for this long are listed again even if their signature didn't change.
    static let maximumSignatureAge: TimeInterval = 6 * 3600
    /// Working-set checks closer together than this only report queued changes.
    static let minimumRefreshInterval: TimeInterval = 20

    init(remote: any ProviderRemote, store: ProviderStore, userID: String, names: ProviderFolderNames = ProviderFolderNames(),
         messages: ProviderMessages = ProviderMessages(),
         settings: @escaping @Sendable () -> (options: ProviderOptions, refreshRequested: Date?),
         now: @escaping @Sendable () -> Date = { Date() }, signal: @escaping @Sendable () -> Void = {}) {
        self.remote = remote
        self.store = store
        self.userID = userID
        self.names = names
        self.messages = messages
        self.settings = settings
        self.now = now
        self.signal = signal
    }

    var options: ProviderOptions { settings().options }

    // MARK: Listings

    private struct Context {
        var albums: [String: RemoteAlbum] = [:]
        var albumsList: [RemoteAlbum]?
        var months: [RemoteMonth]?
        var favorites: String?

        func signature(_ node: ProviderNode) -> String? {
            switch node {
            case .album(let id): albums[id]?.signature
            case .month(let year, let month): months.map { list in String(list.first { $0.year == year && $0.month == month }?.count ?? 0) }
            case .favorites: favorites
            default: nil
            }
        }
    }

    private func months(_ context: Context?) async throws -> [RemoteMonth] {
        if let months = context?.months { return months }
        return try await remote.timelineMonths()
    }

    private func listing(_ node: ProviderNode, previous: [ProviderItem], context: Context?) async throws -> (items: [ProviderItem], signature: String?) {
        let options = options
        switch node {
        case .root:
            return ([ProviderRendering.folder(.albums, name: names.albums, options: options),
                     ProviderRendering.folder(.library, name: names.library, options: options),
                     ProviderRendering.folder(.favorites, name: names.favorites, options: options)], nil)
        case .albums:
            let albums: [RemoteAlbum]
            if let list = context?.albumsList { albums = list } else { albums = try await remote.albums() }
            return (albums.map { album in
                ProviderRendering.folder(.album(album.id), name: ProviderNaming.sanitize(album.name, fallback: "Untitled"),
                                         options: options, album: album, childCount: album.assetCount)
            }, nil)
        case .library:
            let months = try await months(context)
            let years = Dictionary(grouping: months, by: \.year)
            return (years.keys.sorted().map { year in
                ProviderRendering.folder(.year(year), name: String(format: "%04d", year), options: options, childCount: years[year]?.count)
            }, nil)
        case .year(let year):
            let months = try await months(context)
            return (months.filter { $0.year == year }.map { month in
                ProviderRendering.folder(.month(year, month.month), name: names.month(month.month), options: options, childCount: month.count)
            }, nil)
        case .month(let year, let month):
            let assets = try await remote.monthAssets(year: year, month: month).filter {
                $0.ownerID == userID && $0.inTimeline && $0.localYear == year && $0.localMonth == month
            }
            return (assets.map { ProviderRendering.asset($0, in: node, options: options, album: nil, userID: userID) },
                    context?.signature(node))
        case .album(let id):
            let album: RemoteAlbum
            if let known = context?.albums[id] { album = known }
            else if let fetched = try await remote.album(id) { album = fetched }
            else { throw ProviderFailure.noSuchItem }
            let known = Dictionary(previous.compactMap { $0.asset.map { ($0.id, $0) } }, uniquingKeysWith: { first, _ in first })
            let assets = try await remote.albumAssets(id, known: known).filter(\.isListable)
            return (assets.map { ProviderRendering.asset($0, in: node, options: options, album: album, userID: userID) }, album.signature)
        case .favorites:
            let assets = try await remote.favoriteAssets().filter { $0.ownerID == userID && $0.favorite && $0.inTimeline }
            return (assets.map { ProviderRendering.asset($0, in: node, options: options, album: nil, userID: userID) },
                    context?.signature(node))
        case .asset:
            throw ProviderFailure.noSuchItem
        }
    }

    /// Lists a folder from the server (enumerateItems). Removals found here are reported with the next working-set
    /// changes too.
    func list(_ identifier: String) async throws -> [ProviderItem] {
        guard let node = ProviderNode(identifier: identifier), node.isFolder else { throw ProviderFailure.noSuchItem }
        do {
            let previous = await store.items(in: identifier)
            let (items, signature) = try await listing(node, previous: previous, context: nil)
            try await store.apply(container: identifier, items: items, signature: signature, now: now(), report: .deletions)
            return await store.items(in: identifier)
        } catch { throw Self.failure(error) }
    }

    /// Everything the system has seen, without asking the server (enumerateItems on the working set).
    func knownItems() async -> [ProviderItem] {
        let options = options
        return await store.allItems().map { ProviderRendering.rerender($0, options: options, userID: userID) }
    }

    /// Lists again the folders the system has seen and returns every change not yet acknowledged (working-set
    /// changes): those of this check and of earlier ones that failed or weren't delivered. Acknowledge them with
    /// `store.issueAnchor(acknowledging:)` once the system has them.
    func changes(force: Bool = false) async throws -> ProviderStore.Pending {
        do {
            try await gate.run { try await self.refreshAll(force: force) }
            return await store.pending()
        } catch { throw Self.failure(error) }
    }

    /// One folder's changes (enumerateChanges on a folder's own enumerator). They stay queued for the working set too.
    func changes(in identifier: String) async throws -> ProviderChanges {
        guard let node = ProviderNode(identifier: identifier), node.isFolder else { throw ProviderFailure.noSuchItem }
        do {
            let previous = await store.items(in: identifier)
            let (items, signature) = try await listing(node, previous: previous, context: nil)
            return try await store.apply(container: identifier, items: items, signature: signature, now: now())
        } catch { throw Self.failure(error) }
    }

    /// Brings the replica up to date. Every difference is queued in the store as it is applied, so a failure halfway
    /// (timeout, 5xx, 429, a full disk) keeps what earlier folders found for the next report.
    private func refreshAll(force requested: Bool) async throws {
        let (options, refreshRequested) = settings()
        let lastFull = await store.lastFullRefresh
        let force = requested || refreshRequested.map { requested in lastFull.map { requested > $0 } ?? true } ?? false
        // Capabilities follow the Settings options even without a server change.
        for container in await store.containers {
            try await store.rerender(container: container) { ProviderRendering.rerender($0, options: options, userID: self.userID) }
        }
        let recent = await store.lastRefresh.map { now().timeIntervalSince($0) < Self.minimumRefreshInterval } ?? false
        if !force, recent {
            // Within the minimum interval only folders marked stale by a change from Finder (a photo added to an album
            // by a move that Finder undid) are listed, so the change shows now rather than at the next full check.
            for container in await store.staleContainers {
                guard let node = ProviderNode(identifier: container) else { continue }
                try await refresh(container, node, previous: await store.items(in: container), context: nil)
            }
        } else {
            var context = Context()
            let containers = await store.containers
            if containers.contains(where: { $0 == "albums" || $0.hasPrefix("album:") }) {
                let albums = try await remote.albums()
                context.albumsList = albums
                context.albums = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            }
            if containers.contains(where: { $0 == "library" || $0.hasPrefix("year:") || $0.hasPrefix("month:") }) {
                context.months = try await remote.timelineMonths()
            }
            if containers.contains("favorites") { context.favorites = try await remote.favoritesSignature() }
            // Parents first, so a removed album or month takes its listing with it before it would be listed.
            let order: (String) -> Int = { id in
                guard let node = ProviderNode(identifier: id) else { return 9 }
                switch node {
                case .root: return 0
                case .albums, .library: return 1
                case .year: return 2
                default: return 3
                }
            }
            for container in containers.sorted(by: { order($0) < order($1) }) {
                guard await store.containers.contains(container), let node = ProviderNode(identifier: container) else { continue }
                let snapshot = await store.snapshot(container)
                if !force, let snapshot, let signature = context.signature(node), snapshot.signature == signature,
                   now().timeIntervalSince(snapshot.refreshed) < Self.maximumSignatureAge {
                    continue
                }
                try await refresh(container, node, previous: snapshot?.items ?? [], context: context)
            }
            try await store.markRefreshed(now(), full: force)
        }
    }

    private func refresh(_ container: String, _ node: ProviderNode, previous: [ProviderItem], context: Context?) async throws {
        do {
            let (items, signature) = try await listing(node, previous: previous, context: context)
            try await store.apply(container: container, items: items, signature: signature, now: now())
        } catch ProviderFailure.noSuchItem, ImmichError.http(404, _) {
            // An album no longer shared: its folder goes with the Albums listing; drop it here too.
            try await store.remove(container, report: true)
        } catch ImmichError.http(let code, _) where code == 403 || code == 400 {
            // One folder the key may not read must not stop the others.
        }
    }

    // MARK: Items

    func item(_ identifier: String) async throws -> ProviderItem {
        guard let node = ProviderNode(identifier: identifier) else { throw ProviderFailure.noSuchItem }
        let options = options
        if let stored = await store.item(identifier) { return ProviderRendering.rerender(stored, options: options, userID: userID) }
        do {
            switch node {
            case .root, .albums, .library, .favorites, .year, .month:
                let name: String = switch node {
                // FileProvider validates the root like every other item; an empty filename traps the extension.
                case .root: "Immich Gallery"
                case .albums: names.albums
                case .library: names.library
                case .favorites: names.favorites
                case .year(let year): String(format: "%04d", year)
                case .month(_, let month): names.month(month)
                default: ""
                }
                return ProviderRendering.folder(node, name: name, options: options)
            case .album(let id):
                guard let album = try await remote.album(id) else { throw ProviderFailure.noSuchItem }
                return ProviderRendering.folder(node, name: ProviderNaming.sanitize(album.name, fallback: "Untitled"),
                                                options: options, album: album, childCount: album.assetCount)
            case .asset(let container, let id):
                guard let asset = try await remote.asset(id), asset.isListable else { throw ProviderFailure.noSuchItem }
                var album: RemoteAlbum?
                if case .album(let albumID) = container {
                    album = await store.item(container.identifier)?.album
                    if album == nil { album = try await remote.album(albumID) }
                    guard album != nil else { throw ProviderFailure.noSuchItem }
                }
                return ProviderRendering.asset(asset, in: container, options: options, album: album, userID: userID)
            }
        } catch { throw Self.failure(error) }
    }

    /// Downloads an original after checking again that it may be shown (never anything in the Locked Folder).
    func download(_ identifier: String, into directory: URL, progress: Progress) async throws -> (URL, ProviderItem) {
        guard let node = ProviderNode(identifier: identifier), let id = node.assetID else { throw ProviderFailure.noSuchItem }
        do {
            guard let asset = try await remote.asset(id), asset.isListable else { throw ProviderFailure.noSuchItem }
            let url = try await remote.downloadOriginal(id, into: directory, progress: progress)
            let item = try await item(identifier)
            return (url, item)
        } catch { throw Self.failure(error) }
    }

    func thumbnail(_ identifier: String, large: Bool) async throws -> Data? {
        guard let id = ProviderNode(identifier: identifier)?.assetID else { return nil }
        do { return try await remote.thumbnail(id, large: large) }
        catch { throw Self.failure(error) }
    }

    // MARK: Changes from Finder

    struct Creation: Sendable {
        var parent: String
        var name: String
        var isFolder: Bool
        var created: Date?
        var modified: Date?
        var mayAlreadyExist = false
    }

    /// Nil only when the system offered an existing item without contents that matches nothing here.
    func create(_ request: Creation, contents: URL?, progress: Progress) async throws -> ProviderItem? {
        // Hidden and system files (.DS_Store, Icon\r, ._ files) stay on this Mac.
        if request.name.hasPrefix(".") || request.name == "Icon\r" { throw ProviderFailure.excludedFromSync }
        guard let parent = ProviderNode(identifier: request.parent), parent.isFolder else { throw ProviderFailure.noSuchItem }
        let options = options
        do {
            if request.isFolder {
                guard parent == .albums else { throw ProviderFailure.cannotSynchronize(messages.foldersOnlyInAlbums) }
                let name = ProviderNaming.albumName(fromFolderName: request.name)
                if request.mayAlreadyExist,
                   let existing = await store.items(in: parent.identifier).first(where: { ProviderNaming.key($0.name) == ProviderNaming.key(request.name) }) {
                    return ProviderRendering.rerender(existing, options: options, userID: userID)
                }
                guard options.allowChanges else { throw ProviderFailure.cannotSynchronize(messages.changesOff) }
                let album = try await remote.createAlbum(name.isEmpty ? "Untitled" : name)
                let item = ProviderRendering.folder(.album(album.id), name: ProviderNaming.sanitize(album.name, fallback: "Untitled"),
                                                    options: options, album: album, childCount: 0)
                let stored = try await store.insert(item)
                signal()
                return stored
            }
            guard let contents else {
                if request.mayAlreadyExist { return nil }
                throw ProviderFailure.cannotSynchronize(messages.cannotAddHere)
            }
            guard options.allowChanges else { throw ProviderFailure.cannotSynchronize(messages.changesOff) }
            var album: RemoteAlbum?
            switch parent {
            case .album(let id):
                album = await store.item(parent.identifier)?.album
                if album == nil { album = try await remote.album(id) }
                guard let album, album.editable else { throw ProviderFailure.cannotSynchronize(messages.albumReadOnly) }
            case .favorites, .library, .year, .month: break
            default: throw ProviderFailure.cannotSynchronize(messages.cannotAddHere)
            }
            let ext = "." + (request.name as NSString).pathExtension.lowercased()
            guard ext.count > 1, try await remote.uploadExtensions().contains(ext) else {
                throw ProviderFailure.cannotSynchronize(messages.unsupportedType)
            }
            let uploaded = try await remote.upload(contents, name: request.name, created: request.created,
                                                   modified: request.modified, progress: progress)
            guard var asset = try await remote.asset(uploaded.id) else { throw ProviderFailure.cannotSynchronize(messages.unavailable) }
            // A duplicate of something in the Locked Folder (or a hidden live-photo part) is never revealed or moved.
            guard asset.visibility != "locked", asset.visibility != "hidden" else {
                throw ProviderFailure.cannotSynchronize(messages.unavailable)
            }
            if asset.trashed {
                // Adding the same photo again is asking for it back: restore it rather than leave it to be purged.
                try await remote.restore([asset.id])
                guard let restored = try await remote.asset(asset.id), !restored.trashed else {
                    throw ProviderFailure.cannotSynchronize(messages.unavailable)
                }
                asset = restored
            }
            var container = parent
            switch parent {
            case .album(let id):
                try await remote.addToAlbum(id, assets: [asset.id])
            case .favorites:
                guard asset.ownerID == userID else { throw ProviderFailure.cannotSynchronize(messages.notOwner) }
                guard asset.inTimeline else { throw ProviderFailure.cannotSynchronize(messages.archived) }
                if !asset.favorite { try await remote.setFavorite(asset.id, true); asset.favorite = true }
            default:
                guard asset.ownerID == userID else { throw ProviderFailure.cannotSynchronize(messages.notOwner) }
                guard asset.inTimeline else { throw ProviderFailure.cannotSynchronize(messages.archived) }
                // Shown in the month it was taken, when Finder already lists that month.
                if let year = asset.localYear, let month = asset.localMonth,
                   await store.snapshot(ProviderNode.month(year, month).identifier) != nil {
                    container = .month(year, month)
                }
            }
            let item = ProviderRendering.asset(asset, in: container, options: options, album: album, userID: userID)
            let stored = try await store.insert(item)
            signal()
            return stored
        } catch { throw Self.failure(error) }
    }

    enum Field: Hashable, Sendable { case filename, parent, contents, other }

    struct Modification: Sendable {
        var identifier: String
        var fields: Set<Field>
        var name: String
        var parent: String
    }

    enum ModificationResult: Equatable, Sendable {
        /// The item as it now is; fields that differ from the request are put back on disk.
        case item(ProviderItem, pending: Set<Field>)
        /// The item no longer exists where it was (moved between albums, or trashed).
        case deleted
    }

    func modify(_ request: Modification) async throws -> ModificationResult {
        guard let node = ProviderNode(identifier: request.identifier) else { throw ProviderFailure.noSuchItem }
        let options = options
        do {
            var current = try await item(request.identifier)
            // Tags, dates and other local attributes have nowhere to go in Immich; they stay on this Mac.
            let pending: Set<Field> = request.fields.contains(.other) ? [.other] : []
            if request.fields.contains(.contents), !node.isFolder {
                throw ProviderFailure.cannotSynchronize(messages.cannotReplace)
            }
            if request.fields.contains(.parent), request.parent == ProviderNode.trashIdentifier {
                do {
                    try await delete(request.identifier, recursive: true)
                    return .deleted
                } catch ProviderFailure.deletionRejected {
                    return .item(current, pending: pending)
                }
            }
            if request.fields.contains(.parent), request.parent != current.parent,
               case .asset(let source, let assetID) = node, options.allowChanges,
               let target = ProviderNode(identifier: request.parent) {
                let asset = current.asset
                var added = false
                switch target {
                case .album(let albumID):
                    var album = await store.item(target.identifier)?.album
                    if album == nil { album = try await remote.album(albumID) }
                    if album?.editable == true {
                        try await remote.addToAlbum(albumID, assets: [assetID])
                        added = true
                    }
                case .favorites:
                    if asset?.ownerID == userID, asset?.inTimeline == true {
                        if asset?.favorite != true { try await remote.setFavorite(assetID, true) }
                        added = true
                    }
                default: break
                }
                if added {
                    try await store.markStale(target.identifier)
                    if case .album(let sourceAlbum) = source, case .album = target, options.allowRemoving, current.album?.editable == true {
                        try await remote.removeFromAlbum(sourceAlbum, assets: [assetID])
                        try await store.remove(request.identifier)
                        signal()
                        return .deleted
                    }
                    signal()
                }
                // Otherwise the photo stays in its folder too: Finder puts it back there.
            }
            if request.fields.contains(.filename), request.name != current.name, case .album(let id) = node,
               options.allowChanges, current.album?.owner == true {
                let name = ProviderNaming.albumName(fromFolderName: request.name)
                if !name.isEmpty {
                    let album = try await remote.renameAlbum(id, to: name)
                    current = try await store.insert(ProviderRendering.folder(node, name: ProviderNaming.sanitize(album.name, fallback: "Untitled"),
                                                                          options: options, album: album, childCount: album.assetCount))
                    signal()
                }
            }
            return .item(current, pending: pending)
        } catch { throw Self.failure(error) }
    }

    func delete(_ identifier: String, recursive: Bool) async throws {
        guard let node = ProviderNode(identifier: identifier) else { return }
        let current: ProviderItem
        do { current = try await item(identifier) }
        catch ProviderFailure.noSuchItem { try await store.remove(identifier); return }
        do {
            try await delete(node, current: current, recursive: recursive)
        } catch ProviderFailure.deletionRejected(let message, _) {
            // With the item as it still is, so the system puts it back.
            throw ProviderFailure.deletionRejected(message, item: current)
        }
        try await store.remove(identifier)
        signal()
    }

    private func delete(_ node: ProviderNode, current: ProviderItem, recursive: Bool) async throws {
        guard options.allowRemoving else { throw ProviderFailure.deletionRejected(messages.removingOff) }
        do {
            switch node {
            case .asset(.album(let albumID), let id):
                guard current.album?.editable == true else { throw ProviderFailure.deletionRejected(messages.albumReadOnly) }
                try await remote.removeFromAlbum(albumID, assets: [id])
            case .asset(.favorites, let id):
                guard current.asset?.ownerID == userID else { throw ProviderFailure.deletionRejected(messages.notOwner) }
                try await remote.setFavorite(id, false)
            case .asset(.month, let id):
                guard current.asset?.ownerID == userID, current.asset?.external == false else {
                    throw ProviderFailure.deletionRejected(messages.notOwner)
                }
                // Immich's Trash only; with the Trash off the server would delete permanently, so nothing is sent.
                guard try await remote.trashAvailable() else { throw ProviderFailure.deletionRejected(messages.trashOff) }
                try await remote.trash([id])
            case .album(let id):
                guard current.album?.owner == true else { throw ProviderFailure.deletionRejected(messages.notOwner) }
                let children = await store.items(in: node.identifier).count
                if !recursive, children > 0 || (current.album?.assetCount ?? 0) > 0 { throw ProviderFailure.directoryNotEmpty }
                try await remote.deleteAlbum(id) // The photos stay in the library.
            default:
                throw ProviderFailure.deletionRejected(messages.cannotAddHere)
            }
        } catch ImmichError.http(404, _) {
            // Already gone on the server.
        } catch { throw Self.failure(error, deleting: true) }
    }

    // MARK: Errors

    static func failure(_ error: Error, deleting: Bool = false) -> Error {
        switch error {
        case let failure as ProviderFailure: return failure
        case is CancellationError: return ProviderFailure.cancelled
        case let error as URLError:
            return error.code == .cancelled ? ProviderFailure.cancelled
                : error.code == .userAuthenticationRequired ? ProviderFailure.notAuthenticated : ProviderFailure.serverUnreachable
        case ImmichError.unauthorized: return ProviderFailure.notAuthenticated
        case ImmichError.http(let code, let message):
            switch code {
            case 404: return ProviderFailure.noSuchItem
            case 500...599, 408, 429: return ProviderFailure.serverUnreachable
            default:
                let text = message ?? error.localizedDescription
                return deleting ? ProviderFailure.deletionRejected(text) : ProviderFailure.cannotSynchronize(text)
            }
        case ImmichError.serverUnreachable: return ProviderFailure.serverUnreachable
        default:
            if (error as NSError).domain == NSURLErrorDomain { return ProviderFailure.serverUnreachable }
            return deleting ? ProviderFailure.deletionRejected(error.localizedDescription)
                : ProviderFailure.cannotSynchronize(error.localizedDescription)
        }
    }
}

/// One working-set refresh at a time; callers arriving meanwhile wait for it.
private actor RefreshGate {
    private var running: Task<Void, Error>?
    func run(_ body: @escaping @Sendable () async throws -> Void) async throws {
        if let running { return try await running.value }
        let task = Task { try await body() }
        running = task
        defer { running = nil }
        return try await task.value
    }
}
