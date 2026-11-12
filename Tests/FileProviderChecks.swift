import Foundation
import Synchronization

// Finder access (issue #23): offline checks of the File Provider's model, replica and engine with a fake server,
// and of ImmichProviderRemote's requests with URLProtocol. No network, keychain, File Provider domain or app.

func check(_ condition: Bool, _ message: String, line: UInt = #line) {
    if !condition { print("FAIL \(line): \(message)"); exit(1) }
}

func expectFailure<T>(_ expected: ProviderFailure, _ message: String, line: UInt = #line, _ body: () async throws -> T) async {
    do {
        _ = try await body()
        print("FAIL \(line): \(message): no error"); exit(1)
    } catch let failure as ProviderFailure {
        switch (failure, expected) {
        case (.cannotSynchronize, .cannotSynchronize), (.deletionRejected, .deletionRejected): return
        default: if failure != expected { print("FAIL \(line): \(message): \(failure)"); exit(1) }
        }
    } catch {
        print("FAIL \(line): \(message): \(error)"); exit(1)
    }
}

let me = "11111111-1111-1111-1111-111111111111"
let partner = "22222222-2222-2222-2222-222222222222"
func id(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", n) }

func makeAsset(_ n: Int, _ name: String, owner: String = me, month: (Int, Int) = (2024, 3), visibility: String = "timeline",
           trashed: Bool = false, favorite: Bool = false, external: Bool = false) -> RemoteAsset {
    RemoteAsset(id: id(n), name: name, size: 1000 + Int64(n), created: Date(timeIntervalSince1970: Double(n)), modified: nil,
                localYear: month.0, localMonth: month.1, isVideo: name.hasSuffix(".MOV"), mimeType: nil, ownerID: owner,
                external: external, visibility: visibility, trashed: trashed, favorite: favorite, checksum: "sum\(n)")
}

func makeAlbum(_ n: Int, _ name: String, owner: Bool = true, editable: Bool = true, count: Int = 0, signature: String = "s") -> RemoteAlbum {
    RemoteAlbum(id: id(900 + n), name: name, owner: owner, editable: editable, assetCount: count, created: nil, modified: nil, signature: signature)
}

/// A server in memory that records every call.
final class FakeRemote: ProviderRemote, @unchecked Sendable {
    struct State {
        var albums: [RemoteAlbum] = []
        var albumMembers: [String: [String]] = [:]
        var assets: [String: RemoteAsset] = [:]
        var months: [RemoteMonth] = []
        var favoritesSignature = "f"
        var calls: [String] = []
        var trashEnabled = true
        var uploadResult: (String, Bool)?
        /// Albums whose listing fails like an overloaded server.
        var failing: Set<String> = []
    }
    let state = Mutex(State())
    func record(_ call: String) { state.withLock { $0.calls.append(call) } }
    var calls: [String] { state.withLock { $0.calls } }
    func reset() { state.withLock { $0.calls = [] } }

    func albums() async throws -> [RemoteAlbum] { record("albums"); return state.withLock { $0.albums } }
    func album(_ id: String) async throws -> RemoteAlbum? { record("album \(id)"); return state.withLock { s in s.albums.first { $0.id == id } } }
    func timelineMonths() async throws -> [RemoteMonth] { record("months"); return state.withLock { $0.months } }
    func favoritesSignature() async throws -> String { record("favoritesSignature"); return state.withLock { $0.favoritesSignature } }
    func monthAssets(year: Int, month: Int) async throws -> [RemoteAsset] {
        record("month \(year)-\(month)")
        // Like a padded search window: neighbours and partners come back too and must be filtered.
        return state.withLock { $0.assets.values.sorted { $0.id < $1.id } }
    }
    func albumAssets(_ albumID: String, known: [String: RemoteAsset]) async throws -> [RemoteAsset] {
        record("albumAssets \(albumID)")
        if state.withLock({ $0.failing.contains(albumID) }) { throw ImmichError.http(503, nil) }
        return state.withLock { s in (s.albumMembers[albumID] ?? []).compactMap { s.assets[$0] } }
    }
    func favoriteAssets() async throws -> [RemoteAsset] {
        record("favorites")
        return state.withLock { $0.assets.values.filter(\.favorite).sorted { $0.id < $1.id } }
    }
    func asset(_ id: String) async throws -> RemoteAsset? { record("asset \(id)"); return state.withLock { $0.assets[id] } }
    func downloadOriginal(_ id: String, into directory: URL, progress: Progress) async throws -> URL {
        record("download \(id)")
        let url = directory.appendingPathComponent(UUID().uuidString)
        try Data("original".utf8).write(to: url)
        return url
    }
    func thumbnail(_ id: String, large: Bool) async throws -> Data { record("thumbnail \(id)"); return Data() }
    func uploadExtensions() async throws -> Set<String> { [".jpg", ".heic", ".mov"] }
    func upload(_ file: URL, name: String, created: Date?, modified: Date?, progress: Progress) async throws -> (id: String, duplicate: Bool) {
        record("upload \(name)")
        return state.withLock { s in
            if let result = s.uploadResult { return (id: result.0, duplicate: result.1) }
            let new = id(500 + s.assets.count)
            s.assets[new] = makeAsset(500 + s.assets.count, name)
            return (id: new, duplicate: false)
        }
    }
    func createAlbum(_ name: String) async throws -> RemoteAlbum {
        record("createAlbum \(name)")
        let value = makeAlbum(50, name)
        state.withLock { $0.albums.append(value) }
        return value
    }
    func renameAlbum(_ id: String, to name: String) async throws -> RemoteAlbum {
        record("renameAlbum \(name)")
        return state.withLock { s in
            let index = s.albums.firstIndex { $0.id == id }!
            s.albums[index] = RemoteAlbum(id: id, name: name, owner: true, editable: true, assetCount: s.albums[index].assetCount,
                                          created: nil, modified: nil, signature: "renamed")
            return s.albums[index]
        }
    }
    func deleteAlbum(_ id: String) async throws { record("deleteAlbum \(id)") }
    func addToAlbum(_ albumID: String, assets: [String]) async throws {
        record("add \(albumID) \(assets.joined())")
        state.withLock { $0.albumMembers[albumID, default: []] += assets }
    }
    func removeFromAlbum(_ albumID: String, assets: [String]) async throws {
        record("remove \(albumID) \(assets.joined())")
        state.withLock { $0.albumMembers[albumID]?.removeAll { assets.contains($0) } }
    }
    func setFavorite(_ id: String, _ favorite: Bool) async throws { record("favorite \(id) \(favorite)") }
    func trashAvailable() async throws -> Bool { state.withLock { $0.trashEnabled } }
    func trash(_ ids: [String]) async throws { record("trash \(ids.joined())") }
    func restore(_ ids: [String]) async throws {
        record("restore \(ids.joined())")
        state.withLock { s in for id in ids { s.assets[id]?.trashed = false } }
    }
}

final class Settings: @unchecked Sendable {
    let state = Mutex((ProviderOptions(allowChanges: true, allowRemoving: false), Date?.none))
    var options: ProviderOptions {
        get { state.withLock { $0.0 } }
        set { state.withLock { $0.0 = newValue } }
    }
    func requestRefresh(_ date: Date) { state.withLock { $0.1 = date } }
}

final class TestClock: @unchecked Sendable {
    let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
}

@main struct FileProviderChecks {
    static func main() async throws {
        identifiers()
        naming()
        capabilities()
        try await replica()
        try await engine()
        try await flakyRemote()
        try await bouncedMoves()
        try await writeFailures()
        try await remoteRequests()
        print("File Provider checks passed")
    }

    // MARK: Identifiers

    static func identifiers() {
        let nodes: [ProviderNode] = [.root, .albums, .library, .favorites, .album(id(1)), .year(2024), .month(2024, 3),
                                     .asset(.album(id(1)), id(2)), .asset(.month(2024, 3), id(3)), .asset(.favorites, id(4)),
                                     .asset(.library, id(5)), .asset(.year(2024), id(6))]
        for node in nodes {
            check(ProviderNode(identifier: node.identifier) == node, "round trip \(node.identifier)")
            check(node.parent.map { ProviderNode(identifier: $0.identifier) != nil } ?? (node == .root), "parent of \(node)")
        }
        check(ProviderNode.root.identifier == "NSFileProviderRootContainerItemIdentifier", "root is the system's root")
        for invalid in ["album:", "album:../etc", "album:a/b", "album:a?b=c", "album:\(String(repeating: "a", count: 65))", "album:é",
                        "year:20x4", "year:024", "month:2024-13", "month:2024-3", "month:2024-03-01",
                        "asset|albums|\(id(1))", "asset|root|\(id(1))", "asset|album:\(id(1))|a/b", "asset|album:\(id(1))|\(id(2))|x",
                        "asset|asset|album:\(id(1))|\(id(2))|\(id(3))", "NSFileProviderWorkingSetContainerItemIdentifier", "", "trash"] {
            check(ProviderNode(identifier: invalid) == nil, "rejects \(invalid)")
        }
        check(ProviderNode.asset(.album(id(1)), id(2)).albumID == id(1), "album of an album photo")
        check(FinderAccess.isDomainIdentifier(FinderAccess.domainIdentifier(apiURL: URL(string: "https://a.example/api")!, userID: me)), "domain identifier")
        check(FinderAccess.domainIdentifier(apiURL: URL(string: "https://a.example/api")!, userID: me)
              != FinderAccess.domainIdentifier(apiURL: URL(string: "https://b.example/api")!, userID: me), "one domain per server")
        check(FinderAccess.domainIdentifier(apiURL: URL(string: "https://a.example/api")!, userID: me)
              != FinderAccess.domainIdentifier(apiURL: URL(string: "https://a.example/api")!, userID: partner), "one domain per user")
        for invalid in ["account-../../x", "account-ABCDEF0123456789abcdef0123456789", "../account", "account-"] {
            check(!FinderAccess.isDomainIdentifier(invalid), "rejects domain \(invalid)")
            check(FinderAccess.directory(for: invalid) == nil, "no folder for \(invalid)")
        }
    }

    // MARK: Names

    static func naming() {
        check(ProviderNaming.sanitize("Trip/2024", fallback: "x") == "Trip:2024", "slash shown by Finder as a slash")
        check(ProviderNaming.albumName(fromFolderName: "Trip:2024") == "Trip/2024", "and back")
        check(ProviderNaming.sanitize(".hidden.jpg", fallback: "x") == "_hidden.jpg", "no hidden files")
        check(ProviderNaming.sanitize("a\u{0}b\nc.jpg", fallback: "x") == "abc.jpg", "no control characters")
        check(ProviderNaming.sanitize("  ", fallback: "fallback.jpg") == "fallback.jpg", "empty names")
        let long = ProviderNaming.sanitize(String(repeating: "é", count: 200) + ".jpeg", fallback: "x")
        check(long.utf8.count <= 255 && long.hasSuffix(".jpeg"), "255 bytes, extension kept")

        func item(_ n: Int, _ name: String) -> ProviderItem {
            ProviderRendering.asset(makeAsset(n, name), in: .album(id(1)), options: ProviderOptions(), album: nil, userID: me)
        }
        let first = ProviderNaming.assign([item(1, "IMG_1.JPG"), item(2, "img_1.jpg"), item(3, "Cafe\u{301}.jpg"), item(4, "Café.jpg")], previous: [:])
        let keys = Set(first.map { ProviderNaming.key($0.name) })
        check(keys.count == 4, "unique ignoring case and normalization: \(first.map(\.name))")
        check(first[0].name == "IMG_1.JPG" && first[1].name.hasPrefix("img_1 (") && first[1].name.hasSuffix(").jpg"), "suffix before the extension")
        // A new same-named photo never renames one already listed.
        let previous = Dictionary(uniqueKeysWithValues: first.map { ($0.identifier, $0) })
        let second = ProviderNaming.assign([item(0, "IMG_1.JPG")] + first.map { item(Int($0.asset!.id.suffix(3))!, $0.asset!.name) }, previous: previous)
        for old in first { check(second.first { $0.identifier == old.identifier }?.name == old.name, "stable \(old.name)") }
        check(second[0].name != "IMG_1.JPG", "the newcomer gets the suffix")
        // Same input, same names.
        check(ProviderNaming.assign(first.map { item(Int($0.asset!.id.suffix(3))!, $0.asset!.name) }, previous: [:]).map(\.name) == first.map(\.name), "deterministic")
    }

    // MARK: Capabilities

    static func capabilities() {
        let none = ProviderOptions(allowChanges: false, allowRemoving: false)
        let change = ProviderOptions(allowChanges: true, allowRemoving: false)
        let all = ProviderOptions(allowChanges: true, allowRemoving: true)
        func caps(_ asset: RemoteAsset, _ container: ProviderNode, _ options: ProviderOptions, album: RemoteAlbum? = nil) -> ProviderCapabilities {
            ProviderRendering.asset(asset, in: container, options: options, album: album, userID: me).capabilities
        }
        let mine = makeAsset(1, "a.jpg"), theirs = makeAsset(2, "b.jpg", owner: partner), outside = makeAsset(3, "c.jpg", external: true)
        let editable = makeAlbum(1, "A", owner: false, editable: true), readOnly = makeAlbum(2, "B", owner: false, editable: false)
        check(caps(mine, .month(2024, 3), none) == [.reading], "read-only without changes")
        check(caps(mine, .month(2024, 3), change) == [.reading, .reparenting], "no deleting without removing")
        check(caps(mine, .month(2024, 3), all) == [.reading, .reparenting, .deleting], "own photo to Immich's Trash")
        check(!caps(outside, .month(2024, 3), all).contains(.deleting), "external library photos are never deleted")
        check(!caps(theirs, .favorites, all).contains(.deleting), "only the owner unfavorites")
        check(caps(theirs, .album(editable.id), all, album: editable).contains(.deleting), "editors remove from albums")
        check(!caps(mine, .album(readOnly.id), all, album: readOnly).contains(.deleting), "viewers don't")
        for options in [none, change, all] {
            check(!caps(mine, .month(2024, 3), options).contains(.writing), "photos are never writable")
            check(!caps(mine, .month(2024, 3), options).contains(.renaming), "photos are never renamed")
        }
        let folder = { (album: RemoteAlbum, options: ProviderOptions) in
            ProviderRendering.folder(.album(album.id), name: album.name, options: options, album: album).capabilities
        }
        check(folder(makeAlbum(3, "Own"), all) == [.reading, .writing, .renaming, .deleting], "own album")
        check(folder(makeAlbum(3, "Own"), change) == [.reading, .writing, .renaming], "own album without removing")
        check(folder(editable, all) == [.reading, .writing], "shared editable album")
        check(folder(readOnly, all) == [.reading], "shared read-only album")
        check(ProviderRendering.folder(.root, name: "", options: all).capabilities == [.reading], "root is fixed")
        check(ProviderRendering.folder(.library, name: "", options: none).capabilities == [.reading], "no uploads without changes")
    }

    // MARK: Replica

    static func replica() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileProviderChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProviderStore(directory: directory)
        let options = ProviderOptions(allowChanges: true, allowRemoving: true)
        let a = makeAlbum(1, "A")
        let albumsFolder = [ProviderRendering.folder(.album(a.id), name: "A", options: options, album: a)]
        var changes = try await store.apply(container: "albums", items: albumsFolder, signature: nil, now: Date())
        check(changes.updated.count == 1 && changes.deleted.isEmpty, "new folder reported")
        let photos = [makeAsset(1, "x.jpg"), makeAsset(2, "y.jpg")].map {
            ProviderRendering.asset($0, in: .album(a.id), options: options, album: a, userID: me)
        }
        try await store.apply(container: "album:\(a.id)", items: photos, signature: "1", now: Date())
        _ = try await store.issueAnchor(acknowledging: await store.pending())
        changes = try await store.apply(container: "album:\(a.id)", items: photos, signature: "1", now: Date())
        check(changes.isEmpty, "same listing, no changes")
        check(await store.pending().changes.isEmpty, "nothing queued")
        changes = try await store.apply(container: "album:\(a.id)", items: [photos[0]], signature: "2", now: Date(), report: .deletions)
        check(changes.deleted == [photos[1].identifier], "removed photo reported")
        var pending = await store.pending()
        check(pending.changes.deleted == [photos[1].identifier] && pending.changes.updated.isEmpty, "and queued for the working set")
        check(await store.pending().changes == pending.changes, "until the system has it")
        _ = try await store.issueAnchor(acknowledging: pending)
        check(await store.pending().changes.isEmpty, "only once")
        // A change queued again after a report was built isn't acknowledged by that report.
        try await store.apply(container: "album:\(a.id)", items: photos, signature: "3", now: Date())
        pending = await store.pending()
        try await store.apply(container: "album:\(a.id)", items: [photos[0]], signature: "4", now: Date())
        _ = try await store.issueAnchor(acknowledging: pending)
        check(await store.pending().changes.deleted == [photos[1].identifier], "a newer change stays queued")
        // Queued changes survive a restart.
        check(try await ProviderStore(directory: directory).pending().changes.deleted == [photos[1].identifier], "queue kept on disk")
        _ = try await store.issueAnchor(acknowledging: await store.pending())
        // An album removed on the server takes its listing with it.
        changes = try await store.apply(container: "albums", items: [], signature: nil, now: Date())
        check(Set(changes.deleted) == [albumsFolder[0].identifier, photos[0].identifier], "children go with their folder: \(changes.deleted)")
        check(await store.snapshot("album:\(a.id)") == nil, "and its listing")
        // Anchors survive a restart; an unreadable replica starts a new epoch.
        let anchor = try await store.issueAnchor()
        let reopened = try ProviderStore(directory: directory)
        check(await reopened.isCurrent(anchor), "anchor kept on disk")
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("meta.json"))
        let reset = try ProviderStore(directory: directory)
        check(!(await reset.isCurrent(anchor)), "a new epoch expires old anchors")
        check(await reset.containers.isEmpty, "and forgets old listings")
    }

    // MARK: Engine

    static func engine() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileProviderChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = FakeRemote()
        let settings = Settings()
        let clock = TestClock()
        let signals = Mutex(0)
        let engine = ProviderEngine(remote: remote, store: try ProviderStore(directory: directory), userID: me,
                                    settings: { (settings.options, settings.state.withLock { $0.1 }) },
                                    now: { clock.now }, signal: { signals.withLock { $0 += 1 } })
        let shared = makeAlbum(1, "Shared", owner: false, editable: true, count: 4, signature: "a1")
        let own = makeAlbum(2, "Trips", count: 1, signature: "b1")
        remote.state.withLock { s in
            s.albums = [shared, own]
            s.assets = [id(1): makeAsset(1, "IMG_1.JPG"),
                        id(2): makeAsset(2, "IMG_1.JPG", owner: partner),
                        id(3): makeAsset(3, "secret.jpg", visibility: "locked"),
                        id(4): makeAsset(4, "live.MOV", visibility: "hidden"),
                        id(5): makeAsset(5, "old.jpg", trashed: true),
                        id(6): makeAsset(6, "archived.jpg", visibility: "archive", favorite: true),
                        id(7): makeAsset(7, "april.jpg", month: (2024, 4), favorite: true),
                        id(8): makeAsset(8, "nas.jpg", external: true)]
            s.albumMembers = [shared.id: [id(1), id(2), id(3), id(4), id(5), id(6)], own.id: [id(1)]]
            s.months = [RemoteMonth(year: 2024, month: 3, count: 3), RemoteMonth(year: 2024, month: 4, count: 1)]
        }

        // Listings: nothing locked, hidden or trashed anywhere; the Library holds only the user's own timeline.
        let rootItem = try await engine.item(ProviderNode.rootIdentifier)
        check(rootItem.name == "Immich Gallery" && rootItem.isFolder, "root item has a filename: FileProvider traps on an empty one")
        check(rootItem.identifier == ProviderNode.rootIdentifier && rootItem.parent == ProviderNode.rootIdentifier, "root item identity")
        let root = try await engine.list(ProviderNode.rootIdentifier)
        check(root.map(\.identifier) == ["albums", "library", "favorites"], "root folders")
        let albums = try await engine.list("albums")
        check(Set(albums.map(\.name)) == ["Shared", "Trips"], "albums")
        let sharedItems = try await engine.list("album:\(shared.id)")
        check(Set(sharedItems.compactMap(\.asset?.id)) == [id(1), id(2), id(6)], "album: no locked, hidden or trashed: \(sharedItems.map(\.name))")
        check(Set(sharedItems.map(\.name)).count == 3, "same-named photos in one album get distinct names")
        check(try await engine.list("library").map(\.name) == ["2024"], "years")
        check(try await engine.list("year:2024").map(\.identifier) == ["month:2024-03", "month:2024-04"], "months")
        let march = try await engine.list("month:2024-03")
        check(Set(march.compactMap(\.asset?.id)) == [id(1), id(8)], "own timeline photos of that month only: \(march.map(\.name))")
        _ = try await engine.list("month:2024-04")
        let favorites = try await engine.list("favorites")
        check(favorites.compactMap(\.asset?.id) == [id(7)], "favorites: own, in the timeline")
        await expectFailure(.noSuchItem, "Locked Folder item lookup") { try await engine.item("asset|album:\(shared.id)|\(id(3))") }
        await expectFailure(.noSuchItem, "Locked Folder download") {
            try await engine.download("asset|album:\(shared.id)|\(id(3))", into: directory, progress: Progress())
        }
        check(!remote.calls.contains("download \(id(3))"), "no locked original requested")

        // Working set: unchanged signatures list nothing again; Refresh lists everything.
        _ = try await report(engine)
        clock.advance(60)
        remote.reset()
        var changes = try await report(engine)
        check(changes.isEmpty, "nothing changed")
        check(!remote.calls.contains { $0.hasPrefix("albumAssets") || $0.hasPrefix("month ") || $0 == "favorites" }, "unchanged signatures aren't listed: \(remote.calls)")
        remote.reset()
        _ = try await report(engine)
        check(remote.calls.isEmpty, "checks closer than the minimum interval don't reach the server")
        clock.advance(60)
        settings.requestRefresh(clock.now)
        clock.advance(1)
        remote.reset()
        _ = try await report(engine)
        check(remote.calls.contains("albumAssets \(shared.id)") && remote.calls.contains("month 2024-3"), "Refresh lists every folder")
        // A server change: one photo left the album, the album's signature changed.
        clock.advance(60)
        remote.state.withLock { s in
            s.albumMembers[shared.id] = [id(1), id(6)]
            s.albums[0].signature = "a2"
        }
        changes = try await report(engine)
        check(changes.deleted == ["asset|album:\(shared.id)|\(id(2))"], "removal reported: \(changes.deleted)")
        // Options change capabilities without asking the server.
        clock.advance(1)
        remote.reset()
        settings.options = ProviderOptions(allowChanges: true, allowRemoving: true)
        changes = try await report(engine)
        check(changes.updated.contains { $0.identifier == "asset|month:2024-03|\(id(1))" && $0.capabilities.contains(.deleting) }, "new capabilities reported")
        check(remote.calls.isEmpty, "without listing again")
        settings.options = ProviderOptions(allowChanges: true, allowRemoving: false)

        // Creating.
        let progress = Progress()
        let file = directory.appendingPathComponent("drop.jpg")
        try Data("photo".utf8).write(to: file)
        await expectFailure(.excludedFromSync, "hidden files stay local") {
            try await engine.create(.init(parent: "albums", name: ".DS_Store", isFolder: false), contents: file, progress: progress)
        }
        await expectFailure(.cannotSynchronize(""), "folders only in Albums") {
            try await engine.create(.init(parent: "album:\(own.id)", name: "Sub", isFolder: true), contents: nil, progress: progress)
        }
        await expectFailure(.cannotSynchronize(""), "unsupported kinds") {
            try await engine.create(.init(parent: "album:\(own.id)", name: "notes.txt", isFolder: false), contents: file, progress: progress)
        }
        settings.options = ProviderOptions(allowChanges: false, allowRemoving: false)
        remote.reset()
        await expectFailure(.cannotSynchronize(""), "changes off") {
            try await engine.create(.init(parent: "album:\(own.id)", name: "drop.jpg", isFolder: false), contents: file, progress: progress)
        }
        check(remote.calls.isEmpty, "nothing sent with changes off")
        settings.options = ProviderOptions(allowChanges: true, allowRemoving: false)
        let newAlbum = try await engine.create(.init(parent: "albums", name: "Summer:2025", isFolder: true), contents: nil, progress: progress)
        check(remote.calls.contains("createAlbum Summer/2025") && newAlbum?.name == "Summer:2025", "a folder in Albums makes an album")
        remote.reset()
        let uploaded = try await engine.create(.init(parent: "album:\(own.id)", name: "drop.jpg", isFolder: false), contents: file, progress: progress)
        check(remote.calls.contains("upload drop.jpg") && remote.calls.contains { $0.hasPrefix("add \(own.id)") }, "upload, then add: \(remote.calls)")
        check(uploaded?.parent == "album:\(own.id)", "in the album")
        // A duplicate in the Trash comes back; one in the Locked Folder is never revealed or touched.
        remote.state.withLock { $0.uploadResult = (id(5), true) }
        remote.reset()
        let restored = try await engine.create(.init(parent: "album:\(own.id)", name: "old.jpg", isFolder: false), contents: file, progress: progress)
        check(remote.calls.contains("restore \(id(5))") && restored?.asset?.trashed == false, "trashed duplicate restored")
        remote.state.withLock { $0.uploadResult = (id(3), true) }
        remote.reset()
        await expectFailure(.cannotSynchronize(""), "Locked Folder duplicate") {
            try await engine.create(.init(parent: "album:\(own.id)", name: "secret.jpg", isFolder: false), contents: file, progress: progress)
        }
        check(!remote.calls.contains { $0.hasPrefix("add ") || $0.hasPrefix("restore") || $0.hasPrefix("favorite") }, "locked asset untouched: \(remote.calls)")
        remote.state.withLock { $0.uploadResult = (id(6), true) }
        await expectFailure(.cannotSynchronize(""), "archived duplicate can't show in Library") {
            try await engine.create(.init(parent: "month:2024-03", name: "archived.jpg", isFolder: false), contents: file, progress: progress)
        }
        // Dropped on Library: shown in the month it was taken when Finder lists that month.
        remote.state.withLock { $0.uploadResult = (id(7), true) }
        let placed = try await engine.create(.init(parent: "library", name: "april.jpg", isFolder: false), contents: file, progress: progress)
        check(placed?.parent == "month:2024-04", "placed in its month: \(placed?.parent ?? "nil")")
        remote.state.withLock { $0.uploadResult = nil }

        // Moving and renaming.
        remote.reset()
        var result = try await engine.modify(.init(identifier: "asset|month:2024-03|\(id(1))", fields: [.parent], name: "IMG_1.JPG", parent: "album:\(own.id)"))
        guard case .item(let bounced, _) = result else { check(false, "Library photo stays in Library"); return }
        check(bounced.parent == "month:2024-03" && remote.calls.contains { $0.hasPrefix("add \(own.id)") }, "added to the album, kept in Library")
        result = try await engine.modify(.init(identifier: "asset|album:\(shared.id)|\(id(1))", fields: [.parent], name: "IMG_1.JPG", parent: "album:\(own.id)"))
        guard case .item = result else { check(false, "without removing, a move between albums copies"); return }
        settings.options = ProviderOptions(allowChanges: true, allowRemoving: true)
        remote.reset()
        result = try await engine.modify(.init(identifier: "asset|album:\(shared.id)|\(id(1))", fields: [.parent], name: "IMG_1.JPG", parent: "album:\(own.id)"))
        check(result == .deleted && remote.calls.contains("remove \(shared.id) \(id(1))"), "with removing, it moves")
        remote.reset()
        result = try await engine.modify(.init(identifier: "asset|month:2024-03|\(id(8))", fields: [.filename], name: "renamed.jpg", parent: "month:2024-03"))
        guard case .item(let unrenamed, _) = result else { check(false, "rename result"); return }
        check(unrenamed.name == "nas.jpg" && remote.calls.filter { !$0.hasPrefix("asset ") }.isEmpty, "photos keep their Immich name")
        result = try await engine.modify(.init(identifier: "album:\(own.id)", fields: [.filename], name: "Trips:Old", parent: "albums"))
        guard case .item(let renamed, _) = result else { check(false, "album rename"); return }
        check(renamed.name == "Trips:Old" && remote.calls.contains("renameAlbum Trips/Old"), "own album renamed")
        await expectFailure(.cannotSynchronize(""), "originals are never replaced") {
            try await engine.modify(.init(identifier: "asset|month:2024-03|\(id(8))", fields: [.contents], name: "nas.jpg", parent: "month:2024-03"))
        }
        result = try await engine.modify(.init(identifier: "asset|month:2024-03|\(id(8))", fields: [.other], name: "nas.jpg", parent: "month:2024-03"))
        check(result == .item(unrenamed, pending: [.other]), "tags and dates stay local")

        // Deleting.
        settings.options = ProviderOptions(allowChanges: true, allowRemoving: false)
        remote.reset()
        do {
            try await engine.delete("asset|month:2024-03|\(id(1))", recursive: false)
            check(false, "removing off must be refused")
        } catch ProviderFailure.deletionRejected(_, let item) {
            check(item?.identifier == "asset|month:2024-03|\(id(1))", "a refused deletion carries the item to put back")
        }
        check(remote.calls.filter { !$0.hasPrefix("asset ") && !$0.hasPrefix("album ") }.isEmpty, "nothing sent with removing off")
        settings.options = ProviderOptions(allowChanges: true, allowRemoving: true)
        try await engine.delete("asset|month:2024-03|\(id(1))", recursive: false)
        check(remote.calls.contains("trash \(id(1))"), "Library: Immich's Trash")
        await expectFailure(.deletionRejected(""), "external photos") { try await engine.delete("asset|month:2024-03|\(id(8))", recursive: false) }
        remote.state.withLock { $0.trashEnabled = false }
        remote.state.withLock { $0.assets[id(9)] = makeAsset(9, "z.jpg") }
        remote.reset()
        await expectFailure(.deletionRejected(""), "Trash off: never a permanent deletion") { try await engine.delete("asset|month:2024-03|\(id(9))", recursive: false) }
        check(!remote.calls.contains { $0.hasPrefix("trash") }, "no delete request with the Trash off")
        try await engine.delete("asset|favorites|\(id(7))", recursive: false)
        check(remote.calls.contains("favorite \(id(7)) false"), "Favorites: unfavorite")
        try await engine.delete("asset|album:\(shared.id)|\(id(6))", recursive: false)
        check(remote.calls.contains("remove \(shared.id) \(id(6))"), "album: remove from album")
        await expectFailure(.deletionRejected(""), "only owners delete albums") { try await engine.delete("album:\(shared.id)", recursive: true) }
        _ = try await engine.list("album:\(own.id)")
        await expectFailure(.directoryNotEmpty, "non-recursive") { try await engine.delete("album:\(own.id)", recursive: false) }
        try await engine.delete("album:\(own.id)", recursive: true)
        check(remote.calls.contains("deleteAlbum \(own.id)"), "album deleted, photos kept")
        try await engine.delete("asset|album:\(id(999))|\(id(998))", recursive: false) // unknown: already gone
        check(signals.withLock { $0 } > 0, "changes from Finder signal the working set")
    }

    /// One working-set report as the enumerator makes it: the changes, then a new anchor acknowledging them.
    static func report(_ engine: ProviderEngine) async throws -> ProviderChanges {
        let pending = try await engine.changes()
        _ = try await engine.store.issueAnchor(acknowledging: pending)
        return pending.changes
    }

    static func makeEngine(_ directory: URL, _ remote: FakeRemote, _ settings: Settings, _ clock: TestClock) throws -> ProviderEngine {
        ProviderEngine(remote: remote, store: try ProviderStore(directory: directory), userID: me,
                       settings: { (settings.options, settings.state.withLock { $0.1 }) }, now: { clock.now })
    }

    // MARK: A server failing halfway

    /// A check that fails after some folders were applied to the replica must not lose their changes: they are queued
    /// in the replica and reported by the next check (and again until the system has them).
    static func flakyRemote() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileProviderChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = FakeRemote(), settings = Settings(), clock = TestClock()
        let engine = try makeEngine(directory, remote, settings, clock)
        let a = makeAlbum(1, "A", count: 2, signature: "a1"), b = makeAlbum(2, "B", count: 2, signature: "b1")
        let c = makeAlbum(3, "C", count: 1, signature: "c1")
        remote.state.withLock { s in
            s.albums = [a, b, c]
            for n in 1...5 { s.assets[id(n)] = makeAsset(n, "p\(n).jpg") }
            s.albumMembers = [a.id: [id(1), id(2)], b.id: [id(3), id(4)], c.id: [id(5)]]
            s.months = [RemoteMonth(year: 2024, month: 3, count: 5)]
        }
        for folder in ["albums", "album:\(a.id)", "album:\(b.id)", "album:\(c.id)", "library", "year:2024", "month:2024-03"] {
            _ = try await engine.list(folder)
        }
        _ = try await report(engine)

        // On the server: C is deleted, a photo leaves A, another goes to the Locked Folder. Then B's listing fails with
        // 503, after Albums (and perhaps A) were already applied.
        clock.advance(60)
        remote.state.withLock { s in
            s.albums = [RemoteAlbum(id: a.id, name: "A", owner: true, editable: true, assetCount: 0, created: nil, modified: nil, signature: "a2"),
                        RemoteAlbum(id: b.id, name: "B", owner: true, editable: true, assetCount: 2, created: nil, modified: nil, signature: "b2")]
            s.albumMembers[a.id] = [id(1)]
            s.albumMembers[c.id] = nil
            s.assets[id(1)]?.visibility = "locked"
            s.months = [RemoteMonth(year: 2024, month: 3, count: 4)]
            s.failing = [b.id]
        }
        await expectFailure(.serverUnreachable, "B's listing fails") { try await engine.changes() }
        check(await engine.store.snapshot("album:\(c.id)") == nil, "the replica already applied the Albums listing")

        remote.state.withLock { $0.failing = [] }
        clock.advance(1) // The failed check didn't count: the server is asked again at once.
        let undelivered = try await engine.changes()
        // Not acknowledged (the report never reached the system): everything is reported again.
        clock.advance(60)
        let changes = try await report(engine)
        for expected in ["album:\(c.id)", "asset|album:\(c.id)|\(id(5))", "asset|album:\(a.id)|\(id(2))",
                         "asset|album:\(a.id)|\(id(1))", "asset|month:2024-03|\(id(1))"] {
            check(changes.deleted.contains(expected), "\(expected) deleted after the failure: \(changes.deleted)")
            check(undelivered.changes.deleted.contains(expected), "and in the report that wasn't delivered")
        }
        check(!changes.updated.contains { $0.asset?.id == id(1) }, "the locked photo is never reported as an update")
        clock.advance(60)
        check(try await report(engine).isEmpty, "acknowledged changes aren't reported again")

        // New capabilities are applied to the whole replica before the server is asked: a failure keeps them too.
        settings.options = ProviderOptions(allowChanges: true, allowRemoving: true)
        remote.state.withLock { $0.failing = [b.id]; $0.albums[1].signature = "b3" }
        clock.advance(60)
        await expectFailure(.serverUnreachable, "B's listing fails again") { try await engine.changes() }
        remote.state.withLock { $0.failing = [] }
        let capabilities = try await report(engine)
        check(capabilities.updated.contains { $0.identifier == "asset|album:\(b.id)|\(id(3))" && $0.capabilities.contains(.deleting) },
              "capabilities applied before the failure are reported: \(capabilities.updated.map(\.identifier))")
    }

    // MARK: Bounced moves

    /// A photo dragged from Library onto an album stays in Library (Finder puts it back) and is added to the album;
    /// the album shows it at the next check, even one within the minimum interval.
    static func bouncedMoves() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileProviderChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = FakeRemote(), settings = Settings(), clock = TestClock()
        let engine = try makeEngine(directory, remote, settings, clock)
        let album = makeAlbum(1, "A", count: 0, signature: "a1")
        remote.state.withLock { s in
            s.albums = [album]
            s.assets[id(1)] = makeAsset(1, "p1.jpg")
            s.months = [RemoteMonth(year: 2024, month: 3, count: 1)]
        }
        for folder in ["albums", "album:\(album.id)", "library", "year:2024", "month:2024-03"] { _ = try await engine.list(folder) }
        _ = try await report(engine)
        clock.advance(5) // Within the minimum interval of that check.
        let result = try await engine.modify(.init(identifier: "asset|month:2024-03|\(id(1))", fields: [.parent], name: "p1.jpg",
                                                   parent: "album:\(album.id)"))
        guard case .item(let bounced, _) = result else { check(false, "the Library photo stays"); return }
        check(bounced.parent == "month:2024-03", "put back in Library")
        remote.reset()
        let changes = try await report(engine)
        check(changes.updated.contains { $0.identifier == "asset|album:\(album.id)|\(id(1))" }, "the album shows it now: \(changes.updated.map(\.identifier))")
        check(!remote.calls.contains("albums") && !remote.calls.contains("months"), "other folders still wait for the interval: \(remote.calls)")
        remote.reset()
        _ = try await report(engine)
        check(remote.calls.isEmpty, "listed once: \(remote.calls)")
    }

    // MARK: Replica write failures

    /// A replica that can't be written never reports success: the call fails and every sync anchor expires, so the
    /// system lists everything again rather than trust changes that weren't kept.
    static func writeFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileProviderChecks-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let remote = FakeRemote(), settings = Settings(), clock = TestClock()
        let engine = try makeEngine(directory, remote, settings, clock)
        remote.state.withLock { $0.albums = [makeAlbum(1, "A")] }
        _ = try await engine.list("albums")
        let anchor = await engine.store.anchor
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        remote.state.withLock { $0.albums.append(makeAlbum(2, "B")) }
        clock.advance(60)
        do {
            _ = try await engine.changes()
            check(false, "a check whose replica can't be written must fail")
        } catch {}
        check(!(await engine.store.isCurrent(anchor)), "and expire the anchor")
        do {
            _ = try await engine.list("albums")
            check(false, "a listing whose replica can't be written must fail")
        } catch {}
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        clock.advance(60)
        _ = try await report(engine)
        check(Set(await engine.store.items(in: "albums").map(\.name)) == ["A", "B"], "works again once it can write")
    }

    // MARK: Requests

    static func remoteRequests() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImmichStub.self]
        let client = ImmichClient(serverURL: URL(string: "https://photos.example.com")!, apiURL: URL(string: "https://photos.example.com/api")!,
                                  credential: .apiKey("finder-key"), session: URLSession(configuration: config))
        let remote = ImmichProviderRemote(client: client, userID: me)
        let assets = try await remote.albumAssets(id(900), known: [:])
        check(assets.map(\.id) == [id(1), id(2), id(3)], "every member, in order: \(assets.map(\.id))")
        check(assets[0].name == "mine.jpg" && assets[1].name == "theirs.jpg", "names from the search and from the asset")
        check(assets[2].visibility == "locked", "locked members are marked, for the engine to drop")
        let requests = ImmichStub.requests.withLock { $0 }
        check(requests.allSatisfy { $0.headers["x-api-key"] == "finder-key" && $0.headers["Authorization"] == nil }, "only the Finder key is sent")
        check(!requests.contains { $0.url.contains("visibility=locked") || $0.body.contains("\"locked\"") }, "nothing asks for the Locked Folder")
        check(!requests.contains { $0.url.contains("withStacked") }, "stacked photos are all listed")
        check(requests.contains { $0.method == "GET" && $0.url.hasSuffix("/api/assets/\(id(2))") }, "others' photos looked up one by one")
        check(!requests.contains { $0.url.hasSuffix("/api/assets/\(id(1))") }, "own photos named by the search")
        ImmichStub.requests.withLock { $0 = [] }
        let month = try await remote.monthAssets(year: 2024, month: 3)
        check(month.map(\.id) == [id(1)], "the month's local dates only")
        let search = ImmichStub.requests.withLock { $0 }.first { $0.url.hasSuffix("search/metadata") }
        check(search?.body.contains("\"visibility\":\"timeline\"") == true && search?.body.contains("\"takenAfter\":\"2024-02-29") == true,
              "a day either side, timeline only: \(search?.body ?? "")")
        check(try await remote.album(id(900))?.editable == true, "album details")
        check(!ImmichStub.requests.withLock { $0 }.contains { $0.url.contains("withoutAssets") }, "v3 has no withoutAssets")
        check(try await remote.trashAvailable() == false, "server features say the Trash is off")
        ImmichStub.requests.withLock { $0 = [] }
        do {
            _ = try await remote.downloadOriginal(id(401), into: FileManager.default.temporaryDirectory, progress: Progress(totalUnitCount: 100))
            check(false, "401 must fail")
        } catch ImmichError.unauthorized {} catch { check(false, "401 is unauthorized: \(error)") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileProviderChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try await remote.downloadOriginal(id(1), into: directory, progress: Progress(totalUnitCount: 100))
        check(try Data(contentsOf: original) == Data("ORIGINAL".utf8), "original bytes")
        check(ImmichStub.requests.withLock { $0 }.contains { $0.url.contains("/api/assets/\(id(1))/original?edited=false") }, "unedited original")
        check(ProviderEngine.failure(ImmichError.unauthorized(nil)) as? ProviderFailure == .notAuthenticated, "401 → not authenticated")
        check(ProviderEngine.failure(URLError(.notConnectedToInternet)) as? ProviderFailure == .serverUnreachable, "offline → unreachable")
        check(ProviderEngine.failure(URLError(.cancelled)) as? ProviderFailure == .cancelled, "cancelled")
        check(ProviderEngine.failure(ImmichError.http(503, nil)) as? ProviderFailure == .serverUnreachable, "5xx retried")
        check(ProviderEngine.failure(ImmichError.http(404, nil)) as? ProviderFailure == .noSuchItem, "404 → no such item")
    }
}

/// Answers like an Immich v3 server for one shared album, and records every request.
final class ImmichStub: URLProtocol, @unchecked Sendable {
    struct Request { var method: String; var url: String; var headers: [String: String]; var body: String }
    static let requests = Mutex<[Request]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
        }
        let url = request.url!
        Self.requests.withLock {
            $0.append(Request(method: request.httpMethod ?? "GET", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:],
                              body: String(decoding: data, as: UTF8.self)))
        }
        let path = url.path
        func dto(_ n: Int, _ name: String, owner: String, local: String, visibility: String = "timeline") -> [String: Any] {
            ["id": id(n), "type": "IMAGE", "originalFileName": name, "fileCreatedAt": local, "fileModifiedAt": local, "localDateTime": local,
             "ownerId": owner, "visibility": visibility, "isTrashed": false, "isFavorite": false, "checksum": "c\(n)",
             "exifInfo": ["fileSizeInByte": 10 * n]]
        }
        var status = 200
        var body: Any = [:]
        var raw: Data?
        switch path {
        case "/api/server/version": body = ["major": 3, "minor": 3, "patch": 5]
        case "/api/server/features": body = ["trash": false]
        case "/api/timeline/buckets": body = [["timeBucket": "2024-03-01T00:00:00.000Z", "count": 3]]
        case "/api/timeline/bucket":
            body = ["id": [id(1), id(2), id(3)], "isImage": [true, true, true], "isFavorite": [false, false, false],
                    "isTrashed": [false, false, false], "thumbhash": [NSNull(), NSNull(), NSNull()], "ratio": [1, 1, 1],
                    "duration": [NSNull(), NSNull(), NSNull()], "fileCreatedAt": ["2024-03-01", "2024-03-01", "2024-03-01"],
                    "livePhotoVideoId": [NSNull(), NSNull(), NSNull()], "visibility": ["timeline", "timeline", "locked"],
                    "ownerId": [me, partner, me]]
        case "/api/search/metadata":
            if String(decoding: data, as: UTF8.self).contains("albumIds") {
                body = ["assets": ["items": [dto(1, "mine.jpg", owner: me, local: "2024-03-02T10:00:00.000Z"),
                                             dto(3, "secret.jpg", owner: me, local: "2024-03-02T10:00:00.000Z", visibility: "locked")],
                                   "nextPage": NSNull()]]
            } else {
                body = ["assets": ["items": [dto(1, "march.jpg", owner: me, local: "2024-03-31T23:30:00.000Z"),
                                             dto(5, "april.jpg", owner: me, local: "2024-04-01T00:30:00.000Z")], "nextPage": NSNull()]]
            }
        case "/api/assets/\(id(2))": body = dto(2, "theirs.jpg", owner: partner, local: "2024-03-03T10:00:00.000Z")
        case "/api/assets/\(id(1))/original": raw = Data("ORIGINAL".utf8)
        case "/api/assets/\(id(401))/original": status = 401; body = ["message": "Invalid API key"]
        case "/api/albums/\(id(900))":
            body = ["id": id(900), "albumName": "Shared", "assetCount": 3, "shared": true, "albumThumbnailAssetId": NSNull(),
                    "albumUsers": [["role": "owner", "user": ["id": partner, "email": "p@example.com", "name": "P"]],
                                   ["role": "editor", "user": ["id": me, "email": "m@example.com", "name": "M"]]]]
        default: status = 404; body = ["message": "Not found: \(path)"]
        }
        client!.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: raw ?? (try! JSONSerialization.data(withJSONObject: body)))
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
