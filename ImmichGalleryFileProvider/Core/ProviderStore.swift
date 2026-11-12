import Foundation
import CryptoKit

/// What the system was last told about each folder it has listed, kept in the App Group (`FinderAccess.storeDirectory`),
/// so changes on the server can be reported as differences and names stay the same between listings.
///
/// One JSON file per folder plus `meta.json`. Every change happens inside the actor without suspending, so a listing
/// and the difference it produces are applied as one step.
///
/// **Changes not reported yet.** Every difference a refresh applies to the replica is also queued in `meta.json`
/// (`pending`) and stays there until the system has received it (`issueAnchor(acknowledging:)`). A refresh that
/// fails halfway, or a report that never reaches the system, therefore can't lose the folders already applied: the
/// next report still contains them.
///
/// **Write failures** are thrown, never ignored. The replica in memory is then ahead of the disk, so every sync anchor
/// expires (a new epoch) and the system lists everything again instead of trusting a report built on it.
actor ProviderStore {
    struct Snapshot: Codable {
        var items: [ProviderItem]
        var signature: String?
        var refreshed: Date
    }

    /// Which differences a change queues for the working set.
    enum Report: Sendable {
        /// Updates and deletions: refreshes whose results reach the system only through the working set.
        case all
        /// Deletions only: a folder listing hands its own items to the system, but can't report removals.
        case deletions
    }

    /// Queued changes as of now, and what to acknowledge once the system has them.
    struct Pending: Sendable {
        var changes: ProviderChanges
        /// Identifier → generation queued. Only that generation is acknowledged, so a change queued again meanwhile
        /// is still reported next time.
        var generations: [String: Int]
    }

    private struct Queued: Codable {
        var deleted: Bool
        var generation: Int
    }

    private struct Meta: Codable {
        var epoch: String
        var anchor = 0
        var containers: [String] = []
        var lastRefresh: Date?
        var lastFullRefresh: Date?
        var pending: [String: Queued]?
        var generation: Int?
        /// Folders to list at the next check even within the minimum interval (e.g. an album a photo was just added to).
        var stale: [String]?
    }

    let directory: URL
    private var meta: Meta
    private var loaded: [String: Snapshot] = [:]

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: url), let meta = try? JSONDecoder().decode(Meta.self, from: data) {
            self.meta = meta
        } else {
            // Unreadable or new: start over with a new epoch, so every earlier sync anchor expires.
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: file)
            }
            meta = Meta(epoch: UUID().uuidString)
            try Self.write(meta, to: url)
        }
    }

    // MARK: Sync anchors

    /// The working set's anchor: the epoch and how many change batches were issued.
    var anchor: Data { Data("\(meta.epoch):\(meta.anchor)".utf8) }

    func isCurrent(_ anchor: Data) -> Bool { anchor == self.anchor }

    /// A new anchor, once the system has received `pending`: those changes leave the queue.
    func issueAnchor(acknowledging pending: Pending? = nil) throws -> Data {
        if let pending, var queue = meta.pending {
            for (identifier, generation) in pending.generations where queue[identifier]?.generation == generation {
                queue[identifier] = nil
            }
            meta.pending = queue
        }
        meta.anchor += 1
        try saveMeta()
        return anchor
    }

    var lastRefresh: Date? { meta.lastRefresh }
    var lastFullRefresh: Date? { meta.lastFullRefresh }

    func markRefreshed(_ date: Date, full: Bool) throws {
        meta.lastRefresh = date
        if full { meta.lastFullRefresh = date }
        try saveMeta()
    }

    // MARK: Reading

    var containers: [String] { meta.containers }
    var staleContainers: [String] { (meta.stale ?? []).filter { meta.containers.contains($0) } }

    func snapshot(_ container: String) -> Snapshot? {
        if let snapshot = loaded[container] { return snapshot }
        guard meta.containers.contains(container),
              let data = try? Data(contentsOf: file(container)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        loaded[container] = snapshot
        return snapshot
    }

    func items(in container: String) -> [ProviderItem] { snapshot(container)?.items ?? [] }

    func item(_ identifier: String) -> ProviderItem? {
        guard let parent = ProviderNode(identifier: identifier)?.parent?.identifier else { return nil }
        return snapshot(parent)?.items.first { $0.identifier == identifier }
    }

    func allItems() -> [ProviderItem] { meta.containers.flatMap { items(in: $0) } }

    /// Everything queued and not acknowledged yet, with updated items as the replica now has them.
    func pending() -> Pending {
        var changes = ProviderChanges()
        var generations: [String: Int] = [:]
        for (identifier, queued) in (meta.pending ?? [:]).sorted(by: { $0.value.generation < $1.value.generation }) {
            generations[identifier] = queued.generation
            if !queued.deleted, let item = item(identifier) {
                changes.updated.append(item)
            } else {
                // Gone from the replica since it was queued as an update: the system must forget it too.
                changes.deleted.append(identifier)
            }
        }
        return Pending(changes: changes, generations: generations)
    }

    // MARK: Changing

    /// Replaces a folder's listing with `items` (names assigned here, against the current listing) and returns what
    /// changed. Removed folders take their own listings with them. The changes are queued as `report` says.
    @discardableResult
    func apply(container: String, items incoming: [ProviderItem], signature: String?, now: Date,
               report: Report = .all) throws -> ProviderChanges {
        let previousItems = snapshot(container)?.items ?? []
        let previous = Dictionary(previousItems.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let unique = incoming.filter { seen.insert($0.identifier).inserted }
        let items = ProviderNaming.assign(unique, previous: previous)
        var changes = ProviderChanges()
        changes.updated = items.filter { item in previous[item.identifier].map { !$0.sameVersion(as: item) } ?? true }
        let kept = Set(items.map(\.identifier))
        for old in previousItems where !kept.contains(old.identifier) {
            changes.deleted += removeTree(old.identifier)
        }
        meta.stale?.removeAll { $0 == container }
        try store(Snapshot(items: items, signature: signature, refreshed: now), for: container)
        queue(report == .all ? changes : ProviderChanges(deleted: changes.deleted))
        try saveMeta()
        return changes
    }

    /// Re-applies a folder's stored listing, e.g. with new capabilities, keeping its signature and refresh time. The
    /// changes are queued.
    @discardableResult
    func rerender(container: String, _ transform: (ProviderItem) -> ProviderItem) throws -> ProviderChanges {
        guard let snapshot = snapshot(container) else { return ProviderChanges() }
        let items = snapshot.items.map(transform)
        var changes = ProviderChanges()
        for (old, new) in zip(snapshot.items, items) where !old.sameVersion(as: new) { changes.updated.append(new) }
        guard !changes.updated.isEmpty else { return changes }
        try store(Snapshot(items: items, signature: snapshot.signature, refreshed: snapshot.refreshed), for: container)
        queue(changes)
        try saveMeta()
        return changes
    }

    /// Adds or replaces one item in its folder after a change made from Finder, with a name unique in that folder.
    /// Not queued: the item goes back to the system with the call that made it.
    @discardableResult
    func insert(_ item: ProviderItem) throws -> ProviderItem {
        let container = item.parent
        var snapshot = snapshot(container) ?? Snapshot(items: [], signature: nil, refreshed: .distantPast)
        let others = snapshot.items.filter { $0.identifier != item.identifier }
        let previous = Dictionary((snapshot.items).map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let used = Set(others.map { ProviderNaming.key($0.name) })
        var named = item
        if let old = previous[item.identifier], old.baseName == item.baseName { named.name = old.name }
        if used.contains(ProviderNaming.key(named.name)) {
            named = ProviderNaming.assign(others + [item], previous: previous).last!
        }
        snapshot.items = others + [named]
        let added = !meta.containers.contains(container)
        try store(snapshot, for: container)
        if added { try saveMeta() }
        return named
    }

    /// Removes an item (and, for a folder, everything listed below it). Returns the identifiers removed; with
    /// `report`, they are queued as deletions.
    @discardableResult
    func remove(_ identifier: String, report: Bool = false) throws -> [String] {
        if let parent = ProviderNode(identifier: identifier)?.parent?.identifier, var snapshot = snapshot(parent),
           snapshot.items.contains(where: { $0.identifier == identifier }) {
            snapshot.items.removeAll { $0.identifier == identifier }
            try store(snapshot, for: parent)
        }
        let removed = removeTree(identifier)
        if report { queue(ProviderChanges(deleted: removed)) }
        try saveMeta()
        return removed
    }

    /// The next check lists this folder again, even within the minimum interval and if its signature didn't change.
    func markStale(_ container: String) throws {
        guard var snapshot = snapshot(container) else { return }
        snapshot.refreshed = .distantPast
        snapshot.signature = nil
        try store(snapshot, for: container)
        if !(meta.stale ?? []).contains(container) { meta.stale = (meta.stale ?? []) + [container] }
        try saveMeta()
    }

    // MARK: Queue

    private func queue(_ changes: ProviderChanges) {
        guard !changes.isEmpty else { return }
        var queue = meta.pending ?? [:]
        var generation = meta.generation ?? 0
        for item in changes.updated {
            generation += 1
            queue[item.identifier] = Queued(deleted: false, generation: generation)
        }
        for identifier in changes.deleted {
            generation += 1
            queue[identifier] = Queued(deleted: true, generation: generation)
        }
        meta.pending = queue
        meta.generation = generation
    }

    // MARK: Files

    /// Forgets a folder's listing and those below it, in memory and on disk. The caller saves `meta`.
    private func removeTree(_ identifier: String) -> [String] {
        var removed = [identifier]
        if let snapshot = snapshot(identifier) {
            for child in snapshot.items { removed += removeTree(child.identifier) }
        }
        if meta.containers.contains(identifier) || loaded[identifier] != nil {
            loaded[identifier] = nil
            meta.containers.removeAll { $0 == identifier }
            meta.stale?.removeAll { $0 == identifier }
            // A leftover file is never read: listings are read only for folders in `meta.containers`.
            try? FileManager.default.removeItem(at: file(identifier))
        }
        return removed
    }

    private func store(_ snapshot: Snapshot, for container: String) throws {
        loaded[container] = snapshot
        if !meta.containers.contains(container) { meta.containers.append(container) }
        try persist(snapshot, to: file(container))
    }

    private func file(_ container: String) -> URL {
        let name = SHA256.hash(data: Data(container.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    private var metaURL: URL { directory.appendingPathComponent("meta.json") }

    private func saveMeta() throws { try persist(meta, to: metaURL) }

    private func persist<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            try Self.write(value, to: url)
        } catch {
            // The disk no longer matches what this replica would report: every anchor expires, and the system lists
            // everything again (from memory now, from the disk after a restart, whose epoch differs from this one).
            meta.epoch = UUID().uuidString
            try? Self.write(meta, to: metaURL)
            throw error
        }
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: [.atomic])
    }
}
