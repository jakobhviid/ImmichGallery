import FileProvider
import Foundation
import Synchronization

/// Lists a folder, or the working set: everything the system has seen, whose changes are found by listing those
/// folders again and comparing with the replica (`ProviderStore`).
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    let container: String
    weak var owner: FileProviderExtension?
    private let tasks = Mutex<[UUID: Task<Void, Never>]>([:])

    /// Items handed to the system per call.
    static let batch = 200

    init(container: String, owner: FileProviderExtension) {
        self.container = container
        self.owner = owner
    }

    private var isWorkingSet: Bool { container == ProviderNode.workingSetIdentifier }

    func invalidate() {
        tasks.withLock { tasks in
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
        }
    }

    /// Each task removes itself when done; registered under the same lock, so one that ends at once isn't kept.
    private func start(_ body: @escaping @Sendable () async -> Void) {
        let id = UUID()
        tasks.withLock { tasks in
            tasks[id] = Task { [weak self] in
                await body()
                _ = self?.tasks.withLock { $0.removeValue(forKey: id) }
            }
        }
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let observer = Unchecked(observer)
        start { [self] in
            do {
                guard let owner else { throw ProviderFailure.cancelled }
                let engine = try owner.engine()
                let items = isWorkingSet ? await engine.knownItems() : try await engine.list(container)
                for offset in stride(from: 0, to: items.count, by: Self.batch) {
                    try Task.checkCancellation()
                    observer.value.didEnumerate(items[offset..<min(offset + Self.batch, items.count)].map(FileProviderItem.init))
                }
                observer.value.finishEnumerating(upTo: nil)
                if !isWorkingSet { await signalIfStale(engine) }
            } catch {
                observer.value.finishEnumeratingWithError(FileProviderErrors.nsError(error, identifier: NSFileProviderItemIdentifier(container)))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let observer = Unchecked(observer)
        let anchor = anchor.rawValue
        start { [self] in
            do {
                guard let owner else { throw ProviderFailure.cancelled }
                let store = try owner.store()
                let engine = try owner.engine()
                let current = await store.anchor
                let changes: ProviderChanges
                var pending: ProviderStore.Pending?
                if isWorkingSet {
                    // An anchor the replica didn't issue last (an older one, or another epoch) means the system may have
                    // missed changes: it lists everything again instead.
                    guard anchor == current else { throw ProviderFailure.syncAnchorExpired }
                    pending = try await engine.changes()
                    changes = pending!.changes
                } else {
                    guard Self.epoch(of: anchor) == Self.epoch(of: current) else { throw ProviderFailure.syncAnchorExpired }
                    changes = try await engine.changes(in: container)
                }
                for offset in stride(from: 0, to: changes.updated.count, by: Self.batch) {
                    try Task.checkCancellation()
                    let items: [NSFileProviderItem] = changes.updated[offset..<min(offset + Self.batch, changes.updated.count)]
                        .map { FileProviderItem($0) }
                    observer.value.didUpdate(items)
                }
                for offset in stride(from: 0, to: changes.deleted.count, by: Self.batch) {
                    try Task.checkCancellation()
                    let identifiers: [NSFileProviderItemIdentifier] = changes.deleted[offset..<min(offset + Self.batch, changes.deleted.count)]
                        .map { NSFileProviderItemIdentifier(rawValue: $0) }
                    observer.value.didDeleteItems(withIdentifiers: identifiers)
                }
                // Only now do the reported changes leave the replica's queue: an interrupted report is sent again.
                let next = isWorkingSet ? try await store.issueAnchor(acknowledging: pending) : await Self.folderAnchor(store)
                observer.value.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(rawValue: next), moreComing: false)
            } catch {
                observer.value.finishEnumeratingWithError(FileProviderErrors.nsError(error, identifier: NSFileProviderItemIdentifier(container)))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let completion = Unchecked(completionHandler)
        start { [self] in
            guard let store = try? owner?.store() else { completion.value(nil); return }
            let anchor = isWorkingSet ? await store.anchor : await Self.folderAnchor(store)
            completion.value(NSFileProviderSyncAnchor(anchor))
        }
    }

    /// Folder enumerators share the replica's epoch but never advance the working set's anchor.
    private static func folderAnchor(_ store: ProviderStore) async -> Data {
        Data("\(epoch(of: await store.anchor)):folder:\(Date().timeIntervalSince1970)".utf8)
    }

    private static func epoch(of anchor: Data) -> String {
        String(decoding: anchor, as: UTF8.self).split(separator: ":").first.map(String.init) ?? ""
    }

    /// Changes made elsewhere reach Finder when the app signals them, or here: browsing a folder asks for a check
    /// when the last one is more than ten minutes old.
    private func signalIfStale(_ engine: ProviderEngine) async {
        let last = await engine.store.lastRefresh
        guard last.map({ Date().timeIntervalSince($0) > 600 }) ?? true else { return }
        engine.signal()
    }
}
