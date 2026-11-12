import AppKit
import Observation

@MainActor @Observable
final class AppModel {
    enum Phase {
        case launching
        case signedOut
        case signedIn(AccountServices)
    }
    private(set) var phase: Phase = .launching {
        didSet { // Widget
            switch phase {
            case .signedIn(let services): WidgetFeedUpdater.shared.start(services)
            case .signedOut: WidgetFeedUpdater.shared.clear()
            case .launching: break
            }
        }
    }
    private(set) var entries: [AccountVault.Entry] = []
    private(set) var switching = false
    private(set) var currentAccountID: String?
    var accountError: String?

    var services: AccountServices? {
        if case .signedIn(let services) = phase { services } else { nil }
    }

    @ObservationIgnored private var restoreTask: Task<Void, Never>?

    init() { MacIntegrationRouter.shared.app = self }

    private func refreshEntries() throws { entries = try AccountVault.loadEntries() }

    func restore() async {
        if let restoreTask { await restoreTask.value; return }
        guard case .launching = phase else { return }
        let task = Task { await restoreAccount() }
        restoreTask = task
        await task.value
    }

    private func restoreAccount() async {
        do {
            try refreshEntries()
            let selected = try AccountVault.selectedEntry()
            guard let account = selected?.account ?? AccountVault.legacyAccountForMigration else {
                phase = .signedOut
                return
            }
            currentAccountID = selected?.id
            let client = ImmichClient(serverURL: account.serverURL, apiURL: account.apiURL, credential: account.credential)
            let user: User?
            do { user = try await client.currentUser() }
            catch ImmichError.unauthorized {
                if let selected {
                    try LockedFolderTouchID.forget(server: selected.account.serverURL, userID: selected.userID)
                    try AccountVault.remove(selected.id)
                    try removeSavedCache(selected)
                    // Finder access: the account's location goes too. Its key can't be deleted with a refused login.
                    await FinderAccessModel.shared.accountRemoved(apiURL: selected.account.apiURL, userID: selected.userID, credential: nil)
                }
                try refreshEntries()
                UserDefaults.standard.set(true, forKey: "accountVaultMigrated")
                phase = .signedOut
                return
            } catch { user = nil }
            if let user {
                try AccountVault.save(account: account, user: user)
                try refreshEntries()
                currentAccountID = account.apiURL.absoluteString + "|" + user.id
            }
            // Credential identity is stable even before a legacy user's ID is available.
            let fallback = try JSONEncoder().encode(account.credential).base64EncodedString()
            start(client: client, user: user, cacheUserID: user?.id ?? selected?.userID ?? "offline-" + fallback)
        } catch {
            accountError = error.localizedDescription
            phase = .signedOut
        }
    }

    func signIn(client: ImmichClient, credential: Credential) async throws {
        guard !switching else { return }
        switching = true
        defer { switching = false }
        let authed = client.with(credential: credential)
        let user = try await authed.currentUser()
        try AccountVault.save(account: .init(serverURL: authed.serverURL, apiURL: authed.apiURL, credential: credential), user: user)
        try refreshEntries()
        currentAccountID = authed.apiURL.absoluteString + "|" + user.id
        start(client: authed, user: user, cacheUserID: user.id)
    }

    func signOut() async {
        guard !switching, let services else { return }
        switching = true
        defer { switching = false }
        var userIDForFinder: String?
        do {
            // Persist removal first: a vault failure must leave the live login intact. The kept Locked Folder PIN
            // goes before the vault entry, so it can't outlive the account.
            let userID = services.user?.id ?? entries.first { $0.id == currentAccountID }?.userID
            userIDForFinder = userID
            try LockedFolderTouchID.forget(server: services.client.serverURL, userID: userID)
            if let currentAccountID { try AccountVault.remove(currentAccountID) }
            else { _ = try AccountVault.loadEntries() }
            UserDefaults.standard.set(true, forKey: "accountVaultMigrated")
            try refreshEntries()
        } catch { accountError = error.localizedDescription; return }
        guard self.services === services else { return }
        endSession(services)
        phase = .signedOut
        currentAccountID = nil
        // Finder access: remove the account's location and its server key while the login still works.
        if let userID = services.user?.id ?? userIDForFinder {
            await FinderAccessModel.shared.accountRemoved(apiURL: services.client.apiURL, userID: userID, credential: services.client.credential)
            if let error = FinderAccessModel.shared.error { accountError = error }
        }
        if case .accessToken = services.client.credential { try? await services.client.logout() }
        do { try clearCache(services) } catch { accountError = error.localizedDescription }
    }

    func switchAccount(_ entry: AccountVault.Entry) async throws {
        guard !switching, currentAccountID != entry.id else { return }
        switching = true
        defer { switching = false }
        let previous = services
        let account = entry.account
        let client = ImmichClient(serverURL: account.serverURL, apiURL: account.apiURL, credential: account.credential)
        let user = try await client.currentUser()
        guard services === previous else { return }
        try AccountVault.select(entry.id)
        try refreshEntries()
        currentAccountID = entry.id
        start(client: client, user: user, cacheUserID: user.id)
    }

    func removeAccount(_ entry: AccountVault.Entry) throws {
        guard !switching else { return }
        try LockedFolderTouchID.forget(server: entry.account.serverURL, userID: entry.userID)
        try AccountVault.remove(entry.id)
        try refreshEntries()
        // Finder access: the account's location and its server key go too.
        Task { await FinderAccessModel.shared.accountRemoved(apiURL: entry.account.apiURL, userID: entry.userID, credential: entry.account.credential) }
        if currentAccountID == entry.id {
            let old = services
            if let old { endSession(old) }
            phase = .signedOut
            currentAccountID = nil
            if let old { try clearCache(old) }
        }
        try removeSavedCache(entry)
    }

    private func endSession(_ services: AccountServices) {
        services.bootstrapTask?.cancel()
        services.notificationTask?.cancel()
        services.upload.cancelAll()
        for window in services.windows.allObjects { window.endSession() }
        services.pipeline.removeAll()
        MacIntegrationRouter.shared.pending.removeAll()
        MacIntegrationRouter.shared.widgetLinks.removeAll() // Widget
        MacQuickLook.shared.dismiss()
    }

    private func removeSavedCache(_ entry: AccountVault.Entry) throws {
        try ImmichClient.removeAccountCache(apiURL: entry.account.apiURL, userID: entry.userID)
        let fallback = try JSONEncoder().encode(entry.account.credential).base64EncodedString()
        try ImmichClient.removeAccountCache(apiURL: entry.account.apiURL, userID: "offline-" + fallback)
    }

    private func clearCache(_ services: AccountServices) throws {
        if let credential = services.client.credential {
            let fallback = try JSONEncoder().encode(credential).base64EncodedString()
            try ImmichClient.removeAccountCache(apiURL: services.client.apiURL, userID: "offline-" + fallback)
        }
        try ImmichClient.removeAccountCache(apiURL: services.client.apiURL, userID: services.cacheUserID)
        if let id = services.user?.id, id != services.cacheUserID {
            try ImmichClient.removeAccountCache(apiURL: services.client.apiURL, userID: id)
        }
    }

    private func start(client: ImmichClient, user: User?, cacheUserID: String) {
        let isolated = client.accountIsolated(userID: cacheUserID)
        let services = AccountServices(client: isolated, user: user, cacheUserID: cacheUserID)
        let legacyCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImageCache", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: legacyCache.path) { try FileManager.default.removeItem(at: legacyCache) }
        } catch { accountError = error.localizedDescription }
        services.onUnauthorized = { [weak self, weak services] in
            Task {
                guard let self, self.services === services else { return }
                await self.signOut()
            }
        }
        services.onUserLoaded = { [weak self, weak services] user in
            guard let self, self.services === services, !self.switching, let credential = client.credential else { return }
            do {
                try AccountVault.save(account: .init(serverURL: client.serverURL, apiURL: client.apiURL, credential: credential), user: user)
                try self.refreshEntries()
                self.currentAccountID = client.apiURL.absoluteString + "|" + user.id
            } catch { self.accountError = error.localizedDescription }
        }
        if let previous = self.services { endSession(previous) }
        MacIntegrationRouter.shared.pending.removeAll()
        MacQuickLook.shared.dismiss()
        phase = .signedIn(services)
        services.bootstrapTask = Task { await services.bootstrap() }
        FinderAccessModel.shared.start() // Finder access: keeps enabled locations current while the app runs.
    }
}

/// Everything that belongs to one signed-in server/user.
@MainActor @Observable
final class AccountServices {
    let client: ImmichClient
    let sharing: SharingModel // Sharing
    let upload: UploadQueue // Upload
    let metadata = MetadataSharedState()
    let pipeline: ImagePipeline
    private(set) var user: User?
    private(set) var features = ServerFeatures()
    private(set) var version: ServerVersion?
    private(set) var albums: [Album] = []
    private(set) var preferences: AccountPreferences? // Account: loaded preferences for feature consumers.
    var explorePreferences: ExplorePreferences?
    var exploreTags: [ExploreTag] = []
    var exploreTagsEnabled = false
    @ObservationIgnored private var exploreTagsLoaded = false
    @ObservationIgnored private var exploreTagsTask: Task<Void, Never>?

    func loadExploreTags(refresh: Bool = false) async {
        if let task = exploreTagsTask { await task.value; if !refresh { return } }
        guard refresh || !exploreTagsLoaded else { return }
        let task = Task {
            do {
                explorePreferences = try await client.explorePreferences()
                exploreTagsEnabled = explorePreferences?.tags?.enabled == true
                exploreTags = exploreTagsEnabled ? try await client.exploreTags().sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending } : []
                exploreTagsLoaded = true
            } catch { handle(error) }
        }
        exploreTagsTask = task
        await task.value
        exploreTagsTask = nil
    }

    let cacheUserID: String
    @ObservationIgnored var onUserLoaded: (User) -> Void = { _ in }
    @ObservationIgnored var onUnauthorized: () -> Void = {}
    @ObservationIgnored let windows = NSHashTable<LibrarySession>.weakObjects()

    init(client: ImmichClient, user: User?, cacheUserID: String) {
        self.cacheUserID = cacheUserID
        self.client = client
        self.sharing = SharingModel(client: client)
        self.pipeline = ImagePipeline(client: client)
        self.upload = UploadQueue(client: client)
        self.upload.onFinished = { [weak self] in // Upload
            self?.invalidateGrids()
            Task { await self?.reloadAlbums() }
        }
        self.upload.onError = { [weak self] in self?.handle($0) } // Upload
        self.user = user
    }

    @ObservationIgnored var bootstrapTask: Task<Void, Never>?
    var notifications: [AccountNotification] = []
    var notificationsAvailable = true
    var notificationError: String?
    @ObservationIgnored var notificationTask: Task<Void, Never>?
    func reloadNotifications() async throws {
        notifications = try await client.accountNotifications().sorted { $0.createdAt > $1.createdAt }
    }
    func startNotifications() {
        notificationTask = Task { [weak self] in
            var delay = 60
            while !Task.isCancelled {
                guard self != nil else { return }
                do {
                    try await self?.reloadNotifications()
                    self?.notificationError = nil
                    delay = 60
                } catch is CancellationError { return }
                catch ImmichError.http(404, _), ImmichError.http(403, _) { self?.notificationsAvailable = false; return }
                catch {
                    self?.notificationError = error.localizedDescription
                    self?.handle(error)
                    delay = min(delay * 2, 900)
                }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    func bootstrap() async {
        startNotifications()
        async let features = try? client.serverFeatures()
        async let version = try? client.serverVersion()
        async let user = try? client.currentUser()
        self.features = await features ?? ServerFeatures()
        guard !Task.isCancelled else { return }
        self.version = await version
        if let user = await user, !Task.isCancelled { self.user = user; onUserLoaded(user) }
        guard !Task.isCancelled else { return }
        Task { [weak self] in await self?.loadProfilePicture() }
        preferences = try? await client.accountPreferences()
        await reloadAlbums()
        await sharing.reload() // Sharing
        await loadExploreTags()
    }

    /// Preference reads and saves run one after another, so the server ends with the last change and reopening
    /// Settings never reads it before an earlier save has landed.
    @ObservationIgnored private var preferencesQueue: Task<Void, Never>?
    /// Why the last preferences save failed, kept until Settings shows it (a save made as Settings closed).
    var preferencesSaveError: String?

    func queuePreferences<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = preferencesQueue
        let task = Task { await previous?.value; return try await work() }
        preferencesQueue = Task { _ = await task.result }
        return try await task.value
    }

    var preferencesRevision = 0
    func setPreferences(_ value: AccountPreferences) {
        preferences = value
        preferencesRevision += 1
        Task { await loadExploreTags(refresh: true); await sharing.reload() }
    }

    func refreshAccountUser() async throws {
        user = try await client.currentUser()
        await loadProfilePicture()
    }

    /// Account: the signed-in user's picture, shown in the sidebar and in Settings.
    private(set) var profilePicture: NSImage?
    func loadProfilePicture() async {
        guard let user, let path = user.profileImagePath, !path.isEmpty else { profilePicture = nil; return }
        let picture: NSImage?
        do {
            var request = try client.request("users/\(user.id)/profile-image")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            picture = NSImage(data: try await client.data(for: request))
        } catch { picture = nil }
        // An older load finishing late must not bring back a replaced or removed picture.
        if self.user?.profileImagePath == path { profilePicture = picture }
    }

    var requiresPasswordChange: Bool {
        guard case .accessToken = client.credential else { return false }
        return user?.requiresPasswordChange(passwordLoginEnabled: features.passwordLogin) == true
    }

    func reloadAlbums() async {
        do {
            albums = try await client.albumCollections(legacy: (version?.major ?? 3) < 3).sorted { // Albums
                ($0.lastModifiedAssetTimestamp ?? "") > ($1.lastModifiedAssetTimestamp ?? "")
            }
        } catch { handle(error) }
    }

    func invalidateGrids() {
        for window in windows.allObjects { window.invalidateMacWindowGrids() }
        FinderAccessModel.shared.signalSoon() // Finder access
    }

    var hiddenAssetIDs: Set<String> = []

    func removeFromGrids(_ ids: Set<String>) {
        hiddenAssetIDs.formUnion(ids)
        for window in windows.allObjects { window.removeFromGrids(ids) }
        MacQuickLook.shared.dismiss()
        FinderAccessModel.shared.signalSoon() // Finder access
    }

    func handle(_ error: Error) {
        if case ImmichError.unauthorized = error { onUnauthorized() }
    }
}

/// Navigation, selection and presentations belong to one window.
@MainActor @Observable
final class LibrarySession {
    let services: AccountServices
    /// Set for the session that shows an unlocked Locked Folder inside a window.
    let lockedFolder: LockedFolderMedia?
    @ObservationIgnored var lockFolder: () -> Void = {}
    @ObservationIgnored var closeViewer: () -> Void = {}
    /// The library window showing this session (Widget: clicks open photos in the frontmost one).
    @ObservationIgnored weak var macWindow: NSWindow?
    func endSession() { lockFolder(); closeViewer(); lockFolder = {}; closeViewer = {} }
    let albumActions = AlbumsActions()
    let metadata: MetadataState
    let sharing: SharingModel
    @ObservationIgnored private var gridModels: [GridSource: AssetGridModel] = [:]
    var client: ImmichClient { lockedFolder?.client ?? services.client }
    var pipeline: ImagePipeline { lockedFolder?.pipeline ?? services.pipeline }
    var upload: UploadQueue { services.upload }
    var user: User? { services.user }
    var features: ServerFeatures { services.features }
    var version: ServerVersion? { services.version }
    var albums: [Album] { services.albums }
    var preferences: AccountPreferences? { services.preferences }
    var preferencesRevision: Int { services.preferencesRevision }
    var exploreTags: [ExploreTag] { services.exploreTags }
    var exploreTagsEnabled: Bool { services.exploreTagsEnabled }
    var cacheUserID: String { services.cacheUserID }
    init(services: AccountServices, lockedFolder: LockedFolderMedia? = nil) {
        self.services = services
        self.lockedFolder = lockedFolder
        metadata = MetadataState(shared: services.metadata)
        sharing = SharingModel(client: services.client, data: services.sharing.data)
        services.windows.add(self)
    }
    func reloadAlbums() async { await services.reloadAlbums() }
    func loadExploreTags(refresh: Bool = false) async { await services.loadExploreTags(refresh: refresh) }
    /// Grid models are cached per source so switching sidebar items keeps loaded data.
    func gridModel(for source: GridSource) -> AssetGridModel {
        if let model = gridModels[source] { return model }
        let previousSearch = gridModels.first { key, _ in
            if case .filteredSearch = key { return true }; return false
        }?.value
        // Only retain the current search, including its loaded pages.
        switch source {
        case .search, .filteredSearch:
            gridModels = gridModels.filter { key, model in
                switch key {
                case .search, .filteredSearch: model.cancelLoading(); return false
                default: return true
                }
            }
        default: break
        }
        let model = AssetGridModel(source: source, session: self, reusing: previousSearch)
        gridModels[source] = model
        return model
    }

    func invalidateAlbumGrid(_ id: String) {
        FinderAccessModel.shared.signalSoon() // Finder access
        for window in services.windows.allObjects {
            window.gridModels[.album(id)]?.markStale()
            window.albumActions.revisions[id, default: 0] += 1
        }
    }

    func discardAlbumGrid(_ id: String) {
        gridModels.removeValue(forKey: .album(id))
        albumActions.details.removeValue(forKey: id)
    }

    var macGridRevision = 0

    func invalidateMacWindowGrids() {
        for model in gridModels.values { model.markStale() }
        macGridRevision += 1
    }

    /// Mutations affect cached grids in every window for this account.
    func invalidateGrids(except keep: AssetGridModel? = nil) {
        for model in gridModels.values where model !== keep { model.markStale() }
        macGridRevision += 1
        for window in services.windows.allObjects where window !== self { window.invalidateMacWindowGrids() }
        FinderAccessModel.shared.signalSoon() // Finder access
    }

    func setLocationInGrids(_ ids: [String], latitude: Double, longitude: Double) {
        for window in services.windows.allObjects {
            for model in window.gridModels.values { model.setLocation(ids, latitude: latitude, longitude: longitude) }
        }
    }

    // Explore
    func exploreRemoveFromGrids(_ ids: Set<String>) {
        services.removeFromGrids(ids)
    }

    func removeFromGrids(_ ids: Set<String>) {
        if let snapshot = metadata.viewerSnapshot, ids.contains(snapshot.id) { metadata.viewerSnapshot = nil }
        for model in gridModels.values {
            // Items moved into the Locked Folder from elsewhere belong in this grid.
            if model.source == .locked { model.markStale(); continue }
            if let id = model.viewerID, ids.contains(id) { closeViewer() }
            model.exploreRemove(ids)
        }
    }

    func handle(_ error: Error) {
        // An expired unlock fails Locked Folder requests; that locks the folder, it doesn't sign out.
        if let lockedFolder { if !error.isCancellation { lockedFolder.requestFailed() }; return }
        services.handle(error)
    }
}
