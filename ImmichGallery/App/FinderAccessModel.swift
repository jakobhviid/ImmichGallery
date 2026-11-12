import AppKit
import FileProvider
import Observation
import Synchronization

/// Finder access (issue #23): turns each saved account's Finder location on and off. Optional and off by default;
/// see docs/FileProvider.md.
///
/// Turning it on creates a server API key used only by Finder (or reuses the account's own API key), so the
/// location keeps working with its own permissions and can never open the Locked Folder: Immich only grants that to
/// a signed-in session. The key reaches the extension over its XPC service and is kept in the extension's keychain.
@MainActor @Observable
final class FinderAccessModel {
    static let shared = FinderAccessModel()

    struct Location: Identifiable, Equatable {
        let id: String
        var displayName: String
        var configuration: FinderAccessConfiguration?
    }

    private(set) var locations: [Location] = []
    private(set) var busy: Set<String> = []
    var error: String?
    var notice: String?

    /// The extension accepts the key only from this app's own team signature, and the App Group is part of it:
    /// unsigned and ad-hoc builds can't use Finder access.
    var available: Bool { FinderAccess.signingTeam != nil && FinderAccess.rootDirectory != nil }

    /// What the Finder key may do, nothing more (Immich v3.3.5 permissions).
    static let permissions = ["asset.read", "asset.view", "asset.download", "asset.upload", "asset.update", "asset.delete",
                              "album.read", "album.create", "album.update", "album.delete", "albumAsset.create", "albumAsset.delete",
                              "user.read"]

    static var keyName: String {
        #if DEBUG
        let base = "Immich Gallery Dev Finder"
        #else
        let base = "Immich Gallery Finder"
        #endif
        return Host.current().localizedName.map { "\(base) (\($0))" } ?? base
    }

    @ObservationIgnored private var signalTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?

    func location(for entry: AccountVault.Entry) -> Location? {
        let id = FinderAccess.domainIdentifier(apiURL: entry.account.apiURL, userID: entry.userID)
        return locations.first { $0.id == id }
    }

    func reload() async {
        do {
            let domains = try await NSFileProviderManager.domains()
            locations = domains.map { domain in
                Location(id: domain.identifier.rawValue, displayName: domain.displayName,
                         configuration: FinderAccess.loadConfiguration(domain.identifier.rawValue))
            }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        } catch {
            locations = []
        }
    }

    // MARK: Turning on and off

    func enable(_ entry: AccountVault.Entry) async {
        let domainID = FinderAccess.domainIdentifier(apiURL: entry.account.apiURL, userID: entry.userID)
        guard !busy.contains(domainID) else { return }
        busy.insert(domainID)
        defer { busy.remove(domainID) }
        error = nil
        // Never replace (or, on failure, clean up) a location that already exists.
        await reload()
        guard !locations.contains(where: { $0.id == domainID }) else { return }
        let account = entry.account
        let client = ImmichClient(serverURL: account.serverURL, apiURL: account.apiURL, credential: account.credential)
        var createdKey: String?
        do {
            guard available else { throw FinderAccessError.unsigned }
            let (credential, keyID) = try await finderCredential(client: client, account: account)
            createdKey = keyID
            // The key must belong to this very account before anything is shown in Finder.
            let user = try await client.with(credential: credential).currentUser()
            guard user.id == entry.userID else { throw FinderAccessError.wrongAccount }
            let configuration = FinderAccessConfiguration(serverURL: account.serverURL, apiURL: account.apiURL, userID: entry.userID,
                                                          userName: entry.name, email: entry.email, allowChanges: true,
                                                          allowRemoving: false, keyID: keyID, refreshRequested: nil)
            try FinderAccess.saveConfiguration(configuration, domain: domainID)
            let domain = Self.domain(domainID, entry: entry)
            try await NSFileProviderManager.add(domain)
            try await hand(credential, to: domain)
            try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
            createdKey = nil
        } catch {
            self.error = error.localizedDescription
            // Leave nothing half made: no domain, no files, no key.
            let domain = Self.domain(domainID, entry: entry)
            _ = try? await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)
            try? FinderAccess.removeFiles(domainID)
            if let createdKey { try? await client.deleteAccountKey(createdKey) }
        }
        await reload()
    }

    /// A new key for Finder with only `permissions`, or the account's own API key, which Finder then shares and never
    /// deletes. A server that refuses those permissions gets no key at all: never one with every permission instead.
    private func finderCredential(client: ImmichClient, account: AccountStore.Account) async throws -> (Credential, String?) {
        if case .apiKey = account.credential { return (account.credential, nil) }
        let secret: AccountAPIKeySecret
        do { secret = try await client.createAccountKey(name: Self.keyName, permissions: Self.permissions) }
        catch ImmichError.http(400, let message) { throw FinderAccessError.permissionsRefused(message) }
        return (.apiKey(secret.secret), secret.apiKey?.id ?? secret.id)
    }

    /// Makes a new key and hands it over, then deletes the old one: for a location whose key was removed on the server.
    func reconnect(_ entry: AccountVault.Entry) async {
        let domainID = FinderAccess.domainIdentifier(apiURL: entry.account.apiURL, userID: entry.userID)
        guard !busy.contains(domainID), var configuration = FinderAccess.loadConfiguration(domainID) else { return }
        busy.insert(domainID)
        defer { busy.remove(domainID) }
        error = nil
        let client = ImmichClient(serverURL: entry.account.serverURL, apiURL: entry.account.apiURL, credential: entry.account.credential)
        var createdKey: String?
        do {
            let (credential, keyID) = try await finderCredential(client: client, account: entry.account)
            createdKey = keyID
            guard try await client.with(credential: credential).currentUser().id == entry.userID else { throw FinderAccessError.wrongAccount }
            // The configuration names the new key only once the extension uses it, so the old one is never orphaned.
            try await hand(credential, to: Self.domain(domainID, entry: entry))
            createdKey = nil
            let old = configuration.keyID
            configuration.keyID = keyID
            try FinderAccess.saveConfiguration(configuration, domain: domainID)
            if let old, old != keyID { try? await client.deleteAccountKey(old) }
        } catch {
            self.error = error.localizedDescription
            if let createdKey { try? await client.deleteAccountKey(createdKey) }
        }
        await reload()
    }

    /// Removes the location, its downloads, replica and credential, and the server key Finder made. Files added in
    /// Finder but not uploaded yet are kept by the system; their folder is returned.
    @discardableResult
    func disable(_ domainID: String, client: ImmichClient?) async -> Bool {
        guard !busy.contains(domainID) else { return false }
        busy.insert(domainID)
        defer { busy.remove(domainID) }
        let configuration = FinderAccess.loadConfiguration(domainID)
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(domainID), displayName: domainID)
        var failed = false
        try? await forget(domain)
        do {
            if let preserved = try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData) {
                notice = String(localized: "Items added in Finder that weren't uploaded yet were kept in \(preserved.path).")
            }
        } catch let error as NSError where error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.Code.noSuchItem.rawValue {
            // Already removed.
        } catch {
            self.error = error.localizedDescription
            failed = true
        }
        do { try FinderAccess.removeFiles(domainID) } catch { self.error = error.localizedDescription; failed = true }
        if let keyID = configuration?.keyID {
            do {
                guard let client else { throw FinderAccessError.keyKept }
                try await client.deleteAccountKey(keyID)
            } catch ImmichError.http(404, _) {
                // Already deleted on the server.
            } catch {
                self.error = String(localized: "The Finder key couldn't be deleted from the server. You can delete “\(Self.keyName)” in Account Settings ▸ API Keys.")
                failed = true
            }
        }
        await reload()
        return !failed
    }

    /// Sign-out and Remove Account: the account's location goes with it.
    func accountRemoved(apiURL: URL, userID: String, credential: Credential?) async {
        let domainID = FinderAccess.domainIdentifier(apiURL: apiURL, userID: userID)
        await reload()
        guard locations.contains(where: { $0.id == domainID }) || FinderAccess.loadConfiguration(domainID) != nil else { return }
        let configuration = FinderAccess.loadConfiguration(domainID)
        let client = credential.map { credential in
            ImmichClient(serverURL: configuration?.serverURL ?? apiURL, apiURL: apiURL, credential: credential)
        }
        await disable(domainID, client: client)
    }

    func setOptions(_ domainID: String, allowChanges: Bool? = nil, allowRemoving: Bool? = nil) {
        guard var configuration = FinderAccess.loadConfiguration(domainID) else { return }
        if let allowChanges { configuration.allowChanges = allowChanges }
        if let allowRemoving { configuration.allowRemoving = allowRemoving }
        do {
            try FinderAccess.saveConfiguration(configuration, domain: domainID)
            if let index = locations.firstIndex(where: { $0.id == domainID }) { locations[index].configuration = configuration }
            signal(domainID)
        } catch { self.error = error.localizedDescription }
    }

    /// The next check lists every folder again.
    func refresh(_ domainID: String) {
        guard var configuration = FinderAccess.loadConfiguration(domainID) else { return }
        configuration.refreshRequested = Date()
        try? FinderAccess.saveConfiguration(configuration, domain: domainID)
        signal(domainID)
    }

    func reveal(_ domainID: String) async {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(domainID), displayName: domainID)
        do {
            guard let manager = NSFileProviderManager(for: domain) else { return }
            let url = try await manager.getUserVisibleURL(for: .rootContainer)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Keeping Finder current

    private func signal(_ domainID: String) {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(domainID), displayName: domainID)
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
    }

    /// After changes made in the app, and while it runs: Finder checks its folders again (at most every 20 seconds).
    func signalSoon() {
        signalTask?.cancel()
        signalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            for location in self.locations where location.configuration != nil { self.signal(location.id) }
        }
    }

    func start() {
        guard timer == nil else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FinderAccessModel.shared.signalSoon() }
        }
        timer = Task { [weak self] in
            await self?.reload()
            while !Task.isCancelled {
                self?.signalSoon()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    // MARK: The extension's service

    private static func domain(_ id: String, entry: AccountVault.Entry) -> NSFileProviderDomain {
        let host = entry.account.serverURL.host() ?? entry.account.serverURL.absoluteString
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(id),
                                          displayName: FinderAccess.displayName(account: entry.name, host: host))
        // Finder's Trash isn't Immich's: deletions come as deletions and follow Settings ▸ Finder ▸ Allow Removing.
        domain.supportsSyncingTrash = false
        return domain
    }

    private func hand(_ credential: Credential, to domain: NSFileProviderDomain) async throws {
        let data = try JSONEncoder().encode(credential)
        var lastError: Error = FinderAccessError.noService
        // The extension may still be starting right after the domain was added.
        for attempt in 0..<6 {
            if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
            do {
                try await call(domain) { service, reply in service.setCredential(data, reply: reply) }
                return
            } catch { lastError = error }
        }
        throw lastError
    }

    private func forget(_ domain: NSFileProviderDomain) async throws {
        try await call(domain) { service, reply in service.forgetCredential(reply: reply) }
    }

    private func call(_ domain: NSFileProviderDomain,
                      _ body: @escaping @Sendable (FinderAccessService, @escaping @Sendable (NSError?) -> Void) -> Void) async throws {
        guard let manager = NSFileProviderManager(for: domain) else { throw FinderAccessError.noService }
        guard let service = try await manager.service(named: NSFileProviderServiceName(FinderAccess.serviceName), for: .rootContainer) else {
            throw FinderAccessError.noService
        }
        let connection = try await service.fileProviderConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: FinderAccessService.self)
        connection.resume()
        defer { connection.invalidate() }
        let once = Mutex(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let finish: @Sendable (Error?) -> Void = { error in
                guard once.withLock({ done in defer { done = true }; return !done }) else { return }
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ finish($0) }) as? FinderAccessService else {
                finish(FinderAccessError.noService)
                return
            }
            body(proxy) { finish($0) }
            Task {
                try? await Task.sleep(for: .seconds(15))
                finish(FinderAccessError.noService)
            }
        }
    }
}

enum FinderAccessError: LocalizedError {
    case unsigned, wrongAccount, noService, keyKept
    /// The server refused a key limited to `FinderAccessModel.permissions` (400), with its message.
    case permissionsRefused(String?)

    var errorDescription: String? {
        switch self {
        case .unsigned: String(localized: "Finder access needs a copy of Immich Gallery signed with its App Group.")
        case .wrongAccount: String(localized: "The server answered for another account. Finder access wasn't turned on.")
        case .noService: String(localized: "Finder didn't respond. Try again in a moment.")
        case .keyKept: String(localized: "The Finder key couldn't be deleted from the server.")
        case .permissionsRefused(let detail):
            [String(localized: "This server didn't accept a key limited to what Finder access needs, so no key was made. Update Immich, or sign in to this account with an API key you created to let Finder use that key."),
             detail].compactMap { $0 }.joined(separator: " ")
        }
    }
}
