import CoreGraphics
import Foundation
import ImageIO

/// Loads and decodes Immich media off the main thread with a memory cache in front of the
/// cached URLSession. Cancelling the calling task cancels the network request, which keeps
/// fast scrolling responsive.
final class ImagePipeline: Sendable {
    let client: ImmichClient
    private let thumbnailSlots = ThumbnailLoadSlots(limit: 6)
    // NSCache is thread-safe.
    nonisolated(unsafe) private let cache: NSCache<NSString, CGImage>

    private let evictionLock = NSLock()
    nonisolated(unsafe) private var revisions: [String: Int] = [:]
    nonisolated(unsafe) private var revision = 0
    /// Originals already found to be SDR, so the viewer doesn't download them again.
    nonisolated(unsafe) private var sdrOriginals: Set<String> = []
    /// The last few HDR photos decoded at screen size, the most recently used last: the open photo and its neighbours,
    /// so they slide as bright as they show and show at once when stepped to.
    nonisolated(unsafe) private var hdrPhotos: [(id: String, image: CGImage)] = []
    private static let hdrPhotoLimit = (count: 4, bytes: 640 << 20)

    init(client: ImmichClient) {
        self.client = client
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 512 << 20
        self.cache = cache
    }

    func cachedHDR(_ id: String) -> CGImage? {
        evictionLock.withLock {
            guard let index = hdrPhotos.firstIndex(where: { $0.id == id }) else { return nil }
            let photo = hdrPhotos.remove(at: index)
            hdrPhotos.append(photo)
            return photo.image
        }
    }

    /// Under `evictionLock`.
    private func keepHDR(_ image: CGImage, for id: String) {
        hdrPhotos.removeAll { $0.id == id }
        hdrPhotos.append((id, image))
        var bytes = hdrPhotos.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }
        while hdrPhotos.count > 1, hdrPhotos.count > Self.hdrPhotoLimit.count || bytes > Self.hdrPhotoLimit.bytes {
            let oldest = hdrPhotos.removeFirst().image
            bytes -= oldest.bytesPerRow * oldest.height
        }
    }

    func cachedThumbnail(_ id: String, size: ImmichClient.ThumbnailSize, edited: Bool = true) -> CGImage? {
        cache.object(forKey: "\(id)-\(size.rawValue)-\(edited)" as NSString)
    }

    func thumbnail(_ id: String, size: ImmichClient.ThumbnailSize, edited: Bool = true) async -> CGImage? {
        await load(client.thumbnailRequest(id, size: size, edited: edited), key: "\(id)-\(size.rawValue)-\(edited)", maxPixelSize: nil)
    }

    /// Grid work must not queue viewer or editor requests behind hundreds of cells.
    func gridThumbnail(_ id: String, size: ImmichClient.ThumbnailSize) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = cachedThumbnail(id, size: size) { return cached }
        guard await thumbnailSlots.acquire() else { return nil }
        let image = await thumbnail(id, size: size)
        await thumbnailSlots.release()
        return image
    }

    func personThumbnail(_ id: String) async -> CGImage? {
        await load(client.personThumbnailRequest(id), key: "person-\(id)", maxPixelSize: nil)
    }

    func invalidatePerson(_ id: String) {
        evictionLock.withLock {
            evict(key: "person-\(id)", request: client.personThumbnailRequest(id))
        }
    }

    /// Featured thumbnails are generated asynchronously by the server.
    func refreshPersonThumbnail(_ id: String, replacing previous: Data?) async {
        invalidatePerson(id)
        for delay in [1, 3, 6] {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            invalidatePerson(id)
            var request = client.personThumbnailRequest(id)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let data = try? await client.data(for: request), !Task.isCancelled else { continue }
            guard data != previous, let image = Self.decode(data, maxPixelSize: nil) else { continue }
            cache.setObject(image, forKey: "person-\(id)" as NSString, cost: image.bytesPerRow * image.height)
            return
        }
        // Don't leave an old cached response behind after retries expire.
        invalidatePerson(id)
    }

    /// Full-resolution original (HEIC, RAW, JPEG…), downsampled to `maxPixelSize`.
    func original(_ id: String, maxPixelSize: Int = 8192, edited: Bool = false) async -> CGImage? {
        await load(client.originalRequest(id, edited: edited), key: "\(id)-original-\(edited)", maxPixelSize: maxPixelSize)
    }

    /// The original decoded to HDR, or nil when it has no gain map or HDR transfer function.
    /// An HDR bitmap uses 8 bytes per pixel, so only the last few at screen size (`keeps`) stay in memory
    /// (`cachedHDR`). The compressed original stays in the URL cache, so returning to the photo later only decodes it.
    func hdrOriginal(_ id: String, maxPixelSize: Int, keeps: Bool = false) async -> CGImage? {
        let key = "\(id)-hdr"
        let started = evictionLock.withLock { sdrOriginals.contains(id) ? nil : (revision, revisions[key, default: 0]) }
        let request = client.originalRequest(id, edited: true)
        guard let started, let data = try? await client.data(for: request) else { return nil }
        let image = Task.isCancelled ? nil : Self.decode(data, maxPixelSize: maxPixelSize, hdr: true)
        return evictionLock.withLock {
            // As in `load`: a download that outlived an eviction mustn't leave the old original cached.
            guard started == (revision, revisions[key, default: 0]) else {
                client.session.configuration.urlCache?.removeCachedResponse(for: request)
                return nil
            }
            guard !Task.isCancelled else { return nil }
            guard let image, image.contentHeadroom > 1 else { sdrOriginals.insert(id); return nil }
            if keeps { keepHDR(image, for: id) }
            return image
        }
    }

    func removeAll() {
        evictionLock.withLock {
            revision += 1
            sdrOriginals.removeAll()
            hdrPhotos.removeAll()
            cache.removeAllObjects()
            client.session.configuration.urlCache?.removeAllCachedResponses()
        }
    }

    func evict(ids: [String]) {
        evictionLock.withLock {
            // Metadata adds edited/unedited variants, so evict both.
            for id in ids {
                sdrOriginals.remove(id)
                revisions["\(id)-hdr", default: 0] += 1
                hdrPhotos.removeAll { $0.id == id }
                for edited in [true, false] {
                    for size in [ImmichClient.ThumbnailSize.thumbnail, .preview, .fullsize] {
                        evict(key: "\(id)-\(size.rawValue)-\(edited)", request: client.thumbnailRequest(id, size: size, edited: edited))
                    }
                    evict(key: "\(id)-original-\(edited)", request: client.originalRequest(id, edited: edited))
                }
            }
        }
    }

    private func evict(key: String, request: URLRequest) {
        revisions[key, default: 0] += 1
        cache.removeObject(forKey: key as NSString)
        client.session.configuration.urlCache?.removeCachedResponse(for: request)
    }

    @concurrent private func load(_ request: URLRequest, key: String, maxPixelSize: Int?) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let started = evictionLock.withLock { (revision, revisions[key, default: 0]) }
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let data = try? await client.data(for: request)
        guard !Task.isCancelled else { return nil }
        let image = data.flatMap { Self.decode($0, maxPixelSize: maxPixelSize) }
        return evictionLock.withLock {
            // A request started before eviction may finish after the delayed purge.
            guard started == (revision, revisions[key, default: 0]) else {
                client.session.configuration.urlCache?.removeCachedResponse(for: request)
                return nil
            }
            guard !Task.isCancelled, let image else { return nil }
            cache.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
            return image
        }
    }

    /// `hdr` applies gain maps and keeps HLG/PQ highlights (extended range, 16 bits per channel).
    static func decode(_ data: Data, maxPixelSize: Int?, hdr: Bool = false) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if hdr { options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR }
        if let maxPixelSize { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize }
        else if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            options[kCGImageSourceThumbnailMaxPixelSize] = max(w, h)
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Bound downloads and decoding even over HTTP/2, where the connection limit isn't a request limit.
actor ThumbnailLoadSlots {
    private var available: Int
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) { precondition(limit > 0); available = limit }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if available > 0 {
                    available -= 1
                    continuation.resume(returning: true)
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        if waiters.isEmpty { available += 1 }
        else { waiters.removeFirst().1.resume(returning: true) }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(returning: false)
    }
}
