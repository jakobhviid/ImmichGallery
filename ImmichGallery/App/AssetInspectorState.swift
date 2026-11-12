import Foundation

/// What the inspector shows for the photo it was asked about. Answers are accepted only for the photo currently
/// requested, so a late or cancelled load of the previous photo can't replace the next one's details or error.
/// While the next photo loads, the previous one's details may stay on screen, read-only: edits are possible only once
/// the shown details are the requested photo's.
struct AssetInspectorState {
    enum Phase: Equatable {
        case none
        case loading
        /// The previous photo's details, shown read-only while the requested photo loads.
        case stale
        case failed
        case current
    }

    private(set) var requestedID: String?
    private(set) var asset: AssetResponse?
    private(set) var failed = false
    private var albumsAssetID: String?
    private var loadedAlbums: [Album] = []

    /// What to show for `id`, the photo the inspector is asked about now. It is checked against `id` rather than the
    /// last request, because the view draws the new photo before its load starts.
    func phase(for id: String?) -> Phase {
        guard let id else { return .none }
        if failed, requestedID == id { return .failed }
        guard let asset else { return .loading }
        return asset.id == id ? .current : .stale
    }

    /// Writes are offered only for `id`'s own details.
    func canEdit(_ id: String?) -> Bool { phase(for: id) == .current }

    /// The albums of the photo on screen, never another photo's.
    var albums: [Album] { asset != nil && albumsAssetID == asset?.id ? loadedAlbums : [] }

    /// A new request for `id`: a new photo, a reload after an edit, or Retry.
    mutating func request(_ id: String?) {
        requestedID = id
        failed = false
        if id == nil { asset = nil }
    }

    mutating func loaded(_ loaded: AssetResponse, for id: String) {
        guard id == requestedID, loaded.id == id else { return }
        asset = loaded
        failed = false
    }

    mutating func loadedAlbums(_ albums: [Album], for id: String) {
        guard id == requestedID, asset?.id == id else { return }
        albumsAssetID = id
        loadedAlbums = albums
    }

    mutating func failedLoading(_ id: String) {
        guard id == requestedID else { return }
        failed = true
    }

    /// The inspector's load of `id`: the photo, then its albums. A cancelled load (the selection moved on) changes
    /// nothing after its request; answers for another photo are ignored by the state itself.
    @MainActor static func load(_ id: String?,
                                asset: (String) async throws -> AssetResponse,
                                albums: (String) async -> [Album],
                                update: ((inout AssetInspectorState) -> Void) -> Void) async {
        update { $0.request(id) }
        guard let id else { return }
        do {
            let loaded = try await asset(id)
            try Task.checkCancellation()
            update { $0.loaded(loaded, for: id) }
            let loadedAlbums = await albums(id)
            try Task.checkCancellation()
            update { $0.loadedAlbums(loadedAlbums, for: id) }
        } catch {
            if !Task.isCancelled { update { $0.failedLoading(id) } }
        }
    }
}

/// A description being typed for one photo. The draft keeps the photo it was started for, so finishing it after the
/// selection moved on (focus leaving, the inspector closing) saves it to that photo and never to the next one.
struct DescriptionDraft: Equatable {
    let assetID: String
    var text: String
    private(set) var submitted: String

    init(assetID: String, saved: String) {
        self.assetID = assetID
        text = saved
        submitted = saved
    }

    /// The write to make, once: nil when nothing changed since the last save.
    mutating func takeChange() -> (assetID: String, description: String)? {
        guard text != submitted else { return nil }
        submitted = text
        return (assetID, text)
    }

    /// Saving `value` failed and the server still has `saved`, so the draft can be saved again, unless a newer save
    /// has started since.
    mutating func saveFailed(_ value: String, saved: String) {
        if submitted == value { submitted = saved }
    }
}
