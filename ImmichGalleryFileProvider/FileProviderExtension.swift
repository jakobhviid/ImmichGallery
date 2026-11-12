import FileProvider
import Foundation
import Security
import Synchronization
import UniformTypeIdentifiers

/// Finder access (issue #23): one account's Immich library as a Finder location. See docs/FileProvider.md.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing,
                                   NSFileProviderServicing, @unchecked Sendable {
    let domain: NSFileProviderDomain
    private let state = Mutex(State())

    private struct State {
        var store: ProviderStore?
        var engine: ProviderEngine?
        var engineKey: String?
        /// The engine's own session, invalidated with it so a replaced engine leaves nothing running.
        var session: URLSession?
        var tasks: [UUID: Task<Void, Never>] = [:]
        /// Kept for the extension's lifetime: the XPC listener lives in it.
        var service: FinderAccessServiceSource?
    }

    var domainID: String { domain.identifier.rawValue }

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        UploadMultipart.sweepStale()
        FinderCredentialStore.pruneOrphans()
        Self.pruneCaches()
    }

    func invalidate() {
        let (tasks, session) = state.withLock { state in
            defer { state.tasks.removeAll(); state.engine = nil; state.engineKey = nil; state.session = nil }
            return (Array(state.tasks.values), state.session)
        }
        tasks.forEach { $0.cancel() }
        session?.invalidateAndCancel()
    }

    // MARK: Engine

    /// The replica, which exists before a credential does (its sync anchors are needed either way).
    func store() throws -> ProviderStore {
        if let store = state.withLock({ $0.store }) { return store }
        guard let directory = FinderAccess.storeDirectory(for: domainID) else {
            throw ProviderFailure.cannotSynchronize(String(localized: "Finder access can't reach Immich Gallery's shared folder. Reinstall Immich Gallery."))
        }
        let store = try ProviderStore(directory: directory)
        return state.withLock { state in
            if let existing = state.store { return existing }
            state.store = store
            return store
        }
    }

    /// Rebuilt when the configuration or the credential changes, so nothing of an earlier key is kept.
    func engine() throws -> ProviderEngine {
        guard FinderAccess.isDomainIdentifier(domainID), let configuration = FinderAccess.loadConfiguration(domainID),
              let data = FinderCredentialStore.load(domainID),
              let credential = try? JSONDecoder().decode(Credential.self, from: data), case .apiKey = credential else {
            throw ProviderFailure.notAuthenticated
        }
        let key = configuration.accountID + "|" + data.base64EncodedString()
        if let engine = state.withLock({ $0.engineKey == key ? $0.engine : nil }) { return engine }
        let store = try store()
        let session = Self.session(for: domainID)
        let client = ImmichClient(serverURL: configuration.serverURL, apiURL: configuration.apiURL, credential: credential,
                                  session: session)
        let domainID = domainID
        let manager = Unchecked(NSFileProviderManager(for: domain))
        let engine = ProviderEngine(
            remote: ImmichProviderRemote(client: client, userID: configuration.userID),
            store: store, userID: configuration.userID, names: Self.folderNames, messages: Self.messages,
            settings: {
                let current = FinderAccess.loadConfiguration(domainID)
                // Removing is offered only together with changes, as in Settings.
                let changes = current?.allowChanges ?? false
                return (ProviderOptions(allowChanges: changes, allowRemoving: changes && current?.allowRemoving == true),
                        current?.refreshRequested)
            },
            signal: { manager.value?.signalEnumerator(for: .workingSet) { _ in } })
        let (current, replaced) = state.withLock { state -> (ProviderEngine, URLSession?) in
            // Another call may have built the same engine meanwhile: keep that one.
            if state.engineKey == key, let existing = state.engine { return (existing, session) }
            defer { state.engine = engine; state.engineKey = key; state.session = session }
            return (engine, state.session)
        }
        // Requests already running for the old key finish; nothing new starts on its session.
        replaced?.finishTasksAndInvalidate()
        return current
    }

    func credentialChanged() {
        let session = state.withLock { state in
            defer { state.engine = nil; state.engineKey = nil; state.session = nil }
            return state.session
        }
        session?.finishTasksAndInvalidate()
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.signalErrorResolved(NSFileProviderError(.notAuthenticated)) { _ in }
        manager.signalEnumerator(for: .workingSet) { _ in }
    }

    /// Each domain has its own cache, so one account's thumbnails are never served to another.
    private static func session(for domain: String) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": ImmichClient.userAgent]
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 3600
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            configuration.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20,
                                              directory: caches.appendingPathComponent("FinderAccess/\(domain)", isDirectory: true))
        }
        return URLSession(configuration: configuration)
    }

    /// Removes caches of domains the app has removed.
    private static func pruneCaches() {
        guard let root = FinderAccess.rootDirectory, FileManager.default.fileExists(atPath: root.path),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("FinderAccess", isDirectory: true) else { return }
        for folder in (try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? []
        where FinderAccess.configurationURL(for: folder.lastPathComponent).map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    static let folderNames: ProviderFolderNames = {
        let formatter = DateFormatter()
        let months = formatter.standaloneMonthSymbols ?? []
        return ProviderFolderNames(
            albums: String(localized: "Albums"), library: String(localized: "Library"), favorites: String(localized: "Favorites"),
            month: { month in
                let name = months.indices.contains(month - 1) ? months[month - 1] : ""
                return String(format: "%02d %@", month, name).trimmingCharacters(in: .whitespaces)
            })
    }()

    static let messages = ProviderMessages(
        changesOff: String(localized: "Changes from Finder are turned off for this account in Immich Gallery Settings."),
        removingOff: String(localized: "Removing from Finder is turned off for this account in Immich Gallery Settings."),
        foldersOnlyInAlbums: String(localized: "New folders can only be made in Albums, where each folder is an album."),
        cannotAddHere: String(localized: "Items can't be added to this folder."),
        albumReadOnly: String(localized: "You can't add to or remove from this album."),
        unsupportedType: String(localized: "Immich doesn't accept this kind of file."),
        cannotReplace: String(localized: "Photos in Immich can't be replaced. Add the edited file as a new item instead."),
        unavailable: String(localized: "This item is already in Immich but can't be shown here."),
        archived: String(localized: "This photo is already in Immich's Archive, so it isn't shown in Library or Favorites."),
        notOwner: String(localized: "Only the photo's owner can do this."),
        trashOff: String(localized: "This server's Trash is turned off, so photos can't be removed from Finder: Immich would delete them for good."))

    // MARK: Running work

    /// Runs `body` as a task the returned progress (and `invalidate`) can cancel.
    private func run(_ progress: Progress, _ body: @escaping @Sendable () async -> Void) -> Progress {
        let id = UUID()
        // Registered under the lock it removes itself under, so a task that ends at once is never left behind.
        let task = state.withLock { state in
            let task = Task { [weak self] in
                await body()
                _ = self?.state.withLock { $0.tasks.removeValue(forKey: id) }
            }
            state.tasks[id] = task
            return task
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let completion = Unchecked(completionHandler)
        return run(Progress(totalUnitCount: 1)) { [self] in
            do { completion.value(FileProviderItem(try await engine().item(identifier.rawValue)), nil) }
            catch { completion.value(nil, FileProviderErrors.nsError(error, identifier: identifier)) }
        }
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let completion = Unchecked(completionHandler)
        let progress = Progress(totalUnitCount: 100)
        let shared = Unchecked(progress)
        return run(progress) { [self] in
            do {
                guard let directory = try NSFileProviderManager(for: domain)?.temporaryDirectoryURL() else {
                    throw ProviderFailure.serverUnreachable
                }
                let (url, item) = try await engine().download(itemIdentifier.rawValue, into: directory, progress: shared.value)
                completion.value(url, FileProviderItem(item), nil)
            } catch { completion.value(nil, nil, FileProviderErrors.nsError(error, identifier: itemIdentifier)) }
        }
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let completion = Unchecked(completionHandler)
        let isFolder = itemTemplate.contentType?.conforms(to: .folder) == true
        let parent = itemTemplate.parentItemIdentifier
        let creation = ProviderEngine.Creation(parent: itemTemplate.parentItemIdentifier.rawValue, name: itemTemplate.filename,
                                               isFolder: isFolder, created: itemTemplate.creationDate ?? nil,
                                               modified: itemTemplate.contentModificationDate ?? nil,
                                               mayAlreadyExist: options.contains(.mayAlreadyExist))
        let progress = Progress(totalUnitCount: 100)
        let shared = Unchecked(progress)
        let contents = Unchecked(url)
        return run(progress) { [self] in
            do {
                let item = try await engine().create(creation, contents: contents.value, progress: shared.value)
                completion.value(item.map(FileProviderItem.init), [], false, nil)
            } catch { completion.value(nil, [], false, FileProviderErrors.nsError(error, identifier: parent)) }
        }
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let completion = Unchecked(completionHandler)
        var fields: Set<ProviderEngine.Field> = []
        if changedFields.contains(.filename) { fields.insert(.filename) }
        if changedFields.contains(.parentItemIdentifier) { fields.insert(.parent) }
        if changedFields.contains(.contents) { fields.insert(.contents) }
        let local: NSFileProviderItemFields = changedFields.subtracting([.filename, .parentItemIdentifier, .contents])
        if !local.isEmpty { fields.insert(.other) }
        let identifier = item.itemIdentifier
        let modification = ProviderEngine.Modification(identifier: identifier.rawValue, fields: fields,
                                                       name: item.filename, parent: item.parentItemIdentifier.rawValue)
        return run(Progress(totalUnitCount: 1)) { [self] in
            do {
                switch try await engine().modify(modification) {
                case .deleted:
                    completion.value(nil, [], false, nil)
                case .item(let result, let pending):
                    // Fields Immich can't hold stay on this Mac: reported as still pending, the system stops sending them.
                    completion.value(FileProviderItem(result), pending.contains(.other) ? local : [], false, nil)
                }
            } catch { completion.value(nil, [], false, FileProviderErrors.nsError(error, identifier: identifier)) }
        }
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let completion = Unchecked(completionHandler)
        let recursive = options.contains(.recursive)
        return run(Progress(totalUnitCount: 1)) { [self] in
            do {
                try await engine().delete(identifier.rawValue, recursive: recursive)
                completion.value(nil)
            } catch { completion.value(FileProviderErrors.nsError(error, identifier: identifier)) }
        }
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        let identifier = containerItemIdentifier.rawValue
        // Finder's Trash isn't synced (supportsSyncingTrash = false): there is nothing to list in it.
        if containerItemIdentifier == .trashContainer { throw FileProviderErrors.trashUnsupported }
        guard identifier == ProviderNode.workingSetIdentifier || ProviderNode(identifier: identifier)?.isFolder == true else {
            throw NSError.fileProviderErrorForNonExistentItem(withIdentifier: containerItemIdentifier)
        }
        return FileProviderEnumerator(container: identifier, owner: self)
    }

    // MARK: Thumbnails

    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize,
                         perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
                         completionHandler: @escaping (Error?) -> Void) -> Progress {
        let each = Unchecked(perThumbnailCompletionHandler)
        let completion = Unchecked(completionHandler)
        let large = max(size.width, size.height) > 250
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let shared = Unchecked(progress)
        return run(progress) { [self] in
            let engine: ProviderEngine
            do { engine = try self.engine() } catch { completion.value(FileProviderErrors.nsError(error)); return }
            _ = try? await ImmichProviderRemote.concurrently(itemIdentifiers, limit: 4) { identifier in
                guard !Task.isCancelled else { return }
                do { each.value(identifier, try await engine.thumbnail(identifier.rawValue, large: large), nil) }
                catch { each.value(identifier, nil, FileProviderErrors.nsError(error, identifier: identifier)) }
                shared.value.completedUnitCount += 1
            }
            completion.value(Task.isCancelled ? CocoaError(.userCancelled) : nil)
        }
    }

    // MARK: Service

    func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier,
                                 completionHandler: @escaping ([NSFileProviderServiceSource]?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard itemIdentifier == .rootContainer else { completionHandler([], nil); return progress }
        let source = state.withLock { state in
            if let service = state.service { return service }
            let service = FinderAccessServiceSource(owner: self)
            state.service = service
            return service
        }
        completionHandler([source], nil)
        return progress
    }
}

/// Lets completion handlers and progress objects cross into the tasks that finish them. Each is called once.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
