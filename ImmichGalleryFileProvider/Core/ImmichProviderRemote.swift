import Foundation
import Synchronization

/// `ProviderRemote` over the app's `ImmichClient` (Immich v2 and later, checked against the v3.3.5 OpenAPI document).
///
/// - Library months: `POST /search/metadata` with a window of a day either side of the month, kept to assets whose
///   local date falls in it (how `timeline/buckets` groups them), the user's own and in the timeline.
/// - Albums: `timeline/bucket?albumId=` lists every member (shared albums included). Names come from one metadata
///   search for the user's own assets and `GET /assets/{id}` for others'; assets already listed are not asked again.
/// - Nothing is requested with `visibility=locked`; locked, hidden and trashed assets are dropped wherever they appear.
final class ImmichProviderRemote: ProviderRemote {
    let client: ImmichClient
    let userID: String
    private let cache = Mutex(Cache())

    private struct Cache {
        var version: ServerVersion?
        var extensions: Set<String>?
        var trash: Bool?
    }

    init(client: ImmichClient, userID: String) {
        self.client = client
        self.userID = userID
    }

    private func legacy() async throws -> Bool {
        if let version = cache.withLock({ $0.version }) { return version.major < 3 }
        let version = try await client.serverVersion()
        cache.withLock { $0.version = version }
        return version.major < 3
    }

    // MARK: Albums

    func albums() async throws -> [RemoteAlbum] {
        try await client.albumCollections(legacy: legacy()).map(album)
    }

    func album(_ id: String) async throws -> RemoteAlbum? {
        let legacy = try await legacy()
        do {
            // v2 returns every asset unless asked not to; v3 has no such parameter.
            let value: Album = try await client.get("albums/\(id)", query: legacy ? ["withoutAssets": "true"] : [:])
            return album(value)
        } catch ImmichError.http(let code, _) where [400, 403, 404].contains(code) { return nil }
    }

    private func album(_ album: Album) -> RemoteAlbum {
        let ownerID = album.albumOwner?.id ?? album.ownerId
        return RemoteAlbum(id: album.id, name: album.albumName, owner: ownerID == userID, editable: album.canEdit(userID),
                           assetCount: album.assetCount, created: Self.date(album.createdAt), modified: Self.date(album.updatedAt),
                           signature: "\(album.assetCount)|\(album.updatedAt ?? "")|\(album.lastModifiedAssetTimestamp ?? "")")
    }

    func albumAssets(_ albumID: String, known: [String: RemoteAsset]) async throws -> [RemoteAsset] {
        let query = TimelineQuery(visibility: nil, albumId: albumID, withStacked: nil)
        let buckets = try await client.timeBuckets(query)
        let columns = try await Self.concurrently(buckets.map(\.timeBucket), limit: 4) { bucket in
            try await self.client.timeBucket(bucket, query)
        }
        var order: [String] = []
        var overlay: [String: RemoteAsset] = [:]
        for column in columns {
            for index in column.id.indices {
                let id = column.id[index]
                guard overlay[id] == nil else { continue }
                var asset = known[id] ?? RemoteAsset(id: id, name: "")
                asset.isVideo = !column.isImage[index]
                asset.favorite = column.isFavorite[index]
                asset.trashed = column.isTrashed[index]
                if let visibility = column.visibility?[index] { asset.visibility = visibility }
                if let owner = column.ownerId?[index] { asset.ownerID = owner }
                order.append(id)
                overlay[id] = asset
            }
        }
        var missing = order.filter { overlay[$0]?.name.isEmpty == true && overlay[$0]?.isListable == true }
        if missing.contains(where: { overlay[$0]?.ownerID == userID }) {
            do {
                for asset in try await search(SearchBody(albumIds: [albumID])) where overlay[asset.id] != nil {
                    overlay[asset.id] = merge(details: asset, into: overlay[asset.id]!)
                }
            } catch ImmichError.http(400, _) {
                // Servers without album filters: the requests below cover them.
            }
            missing = missing.filter { overlay[$0]?.name.isEmpty == true }
        }
        let details = try await Self.concurrently(missing, limit: 6) { id in try await self.asset(id) }
        for case let asset? in details { overlay[asset.id] = merge(details: asset, into: overlay[asset.id]!) }
        return order.compactMap { overlay[$0] }.filter { !$0.name.isEmpty }
    }

    /// Details from a search or `GET /assets/{id}`, keeping the timeline's newer membership facts.
    private func merge(details: RemoteAsset, into column: RemoteAsset) -> RemoteAsset {
        var asset = details
        asset.favorite = column.favorite
        asset.trashed = column.trashed || details.trashed
        if details.visibility == "locked" || details.visibility == "hidden" { return asset }
        asset.visibility = column.visibility ?? details.visibility
        return asset
    }

    // MARK: Timeline

    func timelineMonths() async throws -> [RemoteMonth] {
        try await client.timeBuckets(TimelineQuery(visibility: "timeline", withStacked: nil)).compactMap { bucket in
            let parts = bucket.timeBucket.prefix(7).split(separator: "-")
            guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month), bucket.count > 0 else { return nil }
            return RemoteMonth(year: year, month: month, count: bucket.count)
        }
    }

    func favoritesSignature() async throws -> String {
        try await client.timeBuckets(TimelineQuery(visibility: "timeline", isFavorite: true, withStacked: nil))
            .map { "\($0.timeBucket):\($0.count)" }.joined(separator: ",")
    }

    func monthAssets(year: Int, month: Int) async throws -> [RemoteAsset] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return [] }
        // Local dates differ from UTC by at most 14 hours; a day either side catches every asset of the month.
        let body = SearchBody(visibility: "timeline", takenAfter: start.addingTimeInterval(-86_400).ISO8601Format(),
                              takenBefore: end.addingTimeInterval(86_400).ISO8601Format())
        return try await search(body).filter { $0.localYear == year && $0.localMonth == month }
    }

    func favoriteAssets() async throws -> [RemoteAsset] {
        try await search(SearchBody(visibility: "timeline", isFavorite: true))
    }

    private struct SearchBody: Encodable {
        var albumIds: [String]?
        var visibility: String?
        var isFavorite: Bool?
        var takenAfter: String?
        var takenBefore: String?
        var withExif = true
        var page = 1
        var size = 1000
        var order = "asc"
    }

    private func search(_ body: SearchBody) async throws -> [RemoteAsset] {
        struct Response: Decodable {
            struct Assets: Decodable { let items: [AssetDTO]; var nextPage: String? }
            let assets: Assets
        }
        var body = body
        var result: [RemoteAsset] = []
        for _ in 0..<10_000 {
            try Task.checkCancellation()
            let response: Response = try await client.send("POST", "search/metadata", body: body)
            result += response.assets.items.map(\.asset)
            guard let next = response.assets.nextPage.flatMap(Int.init), next > body.page else { break }
            body.page = next
        }
        return result
    }

    // MARK: Assets

    func asset(_ id: String) async throws -> RemoteAsset? {
        do {
            let dto: AssetDTO = try await client.get("assets/\(id)")
            return dto.asset
        } catch ImmichError.http(let code, _) where [400, 403, 404].contains(code) { return nil }
    }

    func downloadOriginal(_ id: String, into directory: URL, progress: Progress) async throws -> URL {
        let request = client.originalRequest(id)
        let session = client.session
        let state = Mutex<URLSessionDownloadTask?>(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: request) { location, response, error in
                    do {
                        if let error { throw error }
                        guard let http = response as? HTTPURLResponse, let location else { throw URLError(.badServerResponse) }
                        switch http.statusCode {
                        case 200: break
                        case 401: throw ImmichError.unauthorized(nil)
                        default: throw ImmichError.http(http.statusCode, nil)
                        }
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let destination = directory.appendingPathComponent(UUID().uuidString)
                        try FileManager.default.moveItem(at: location, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                state.withLock { $0 = task }
                progress.addChild(task.progress, withPendingUnitCount: max(progress.totalUnitCount, 1))
                progress.cancellationHandler = { task.cancel() }
                task.resume()
            }
        } onCancel: {
            state.withLock { $0?.cancel() }
        }
    }

    func thumbnail(_ id: String, large: Bool) async throws -> Data {
        try await client.data(for: client.thumbnailRequest(id, size: large ? .preview : .thumbnail))
    }

    // MARK: Changes

    func uploadExtensions() async throws -> Set<String> {
        if let known = cache.withLock({ $0.extensions }) { return known }
        let extensions = try await client.uploadMediaTypes().extensions
        cache.withLock { $0.extensions = extensions }
        return extensions
    }

    func upload(_ file: URL, name: String, created: Date?, modified: Date?, progress: Progress) async throws -> (id: String, duplicate: Bool) {
        let hashing = Task.detached { try UploadMultipart.checksum(file) }
        let checksum = try await withTaskCancellationHandler { try await hashing.value } onCancel: { hashing.cancel() }
        do {
            if let result = try await client.checkUpload(checksum: checksum, name: name).results.first,
               result.action == "reject", let id = result.assetId {
                return (id, true)
            }
        } catch ImmichError.http(404, _) {
            // Older servers still deduplicate through the checksum header and the upload's answer.
        }
        let response = try await client.uploadFile(file, checksum: checksum, legacy: legacy(), name: name,
                                                    created: created, modified: modified) { sent, total in
            progress.totalUnitCount = max(total, 1)
            progress.completedUnitCount = sent
        }
        return (response.id, response.status == "duplicate")
    }

    func createAlbum(_ name: String) async throws -> RemoteAlbum {
        album(details: try await client.createAlbum(name: name, assetIDs: []))
    }

    func renameAlbum(_ id: String, to name: String) async throws -> RemoteAlbum {
        album(details: try await client.updateAlbum(id, AlbumUpdate(albumName: name)))
    }

    private func album(details: AlbumDetails) -> RemoteAlbum {
        RemoteAlbum(id: details.id, name: details.albumName, owner: details.isOwner(userID), editable: details.canEdit(userID),
                    assetCount: details.assetCount, created: nil, modified: Date(),
                    signature: "\(details.assetCount)|changed-\(UUID().uuidString)")
    }

    func deleteAlbum(_ id: String) async throws { try await client.deleteAlbum(id) }
    func addToAlbum(_ albumID: String, assets: [String]) async throws { try await client.changeAlbumAssets(albumID, ids: assets) }
    func removeFromAlbum(_ albumID: String, assets: [String]) async throws {
        try await client.changeAlbumAssets(albumID, ids: assets, removing: true)
    }
    func setFavorite(_ id: String, _ favorite: Bool) async throws { try await client.setFavorite([id], favorite) }

    func trashAvailable() async throws -> Bool {
        if let known = cache.withLock({ $0.trash }) { return known }
        let trash = try await client.serverFeatures().trash
        cache.withLock { $0.trash = trash }
        return trash
    }

    func trash(_ ids: [String]) async throws { try await client.delete(ids, force: false) }
    func restore(_ ids: [String]) async throws { try await client.restore(ids) }

    // MARK: Helpers

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle()))
    }

    /// Runs `body` for every input, at most `limit` at a time, keeping the inputs' order.
    static func concurrently<Input: Sendable, Output: Sendable>(_ inputs: [Input], limit: Int,
                                                               _ body: @escaping @Sendable (Input) async throws -> Output) async throws -> [Output] {
        try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var results = [Output?](repeating: nil, count: inputs.count)
            var next = 0
            while next < min(limit, inputs.count) {
                let index = next
                group.addTask { (index, try await body(inputs[index])) }
                next += 1
            }
            while let (index, output) = try await group.next() {
                results[index] = output
                if next < inputs.count {
                    let index = next
                    group.addTask { (index, try await body(inputs[index])) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }
}

/// The fields of Immich's `AssetResponseDto` the File Provider uses.
private struct AssetDTO: Decodable {
    let id: String
    var type: String?
    let originalFileName: String
    var originalMimeType: String?
    var fileCreatedAt: String?
    var fileModifiedAt: String?
    var localDateTime: String?
    var ownerId: String?
    var libraryId: String?
    var visibility: String?
    var isArchived: Bool?
    var isTrashed: Bool?
    var isFavorite: Bool?
    var checksum: String?
    var exifInfo: ExifSize?

    struct ExifSize: Decodable { var fileSizeInByte: Int64? }

    var asset: RemoteAsset {
        let local = localDateTime.map { $0.prefix(7).split(separator: "-") }
        return RemoteAsset(id: id, name: originalFileName, size: exifInfo?.fileSizeInByte,
                           created: ImmichProviderRemote.date(fileCreatedAt), modified: ImmichProviderRemote.date(fileModifiedAt),
                           localYear: local.flatMap { $0.count == 2 ? Int($0[0]) : nil },
                           localMonth: local.flatMap { $0.count == 2 ? Int($0[1]) : nil },
                           isVideo: type == "VIDEO", mimeType: originalMimeType, ownerID: ownerId,
                           external: libraryId != nil, visibility: visibility ?? (isArchived == true ? "archive" : nil),
                           trashed: isTrashed ?? false, favorite: isFavorite ?? false, checksum: checksum)
    }
}
