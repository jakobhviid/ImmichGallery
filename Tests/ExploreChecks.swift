import Foundation
import CoreGraphics
import ImageIO
import MapKit

@main struct ExploreChecks {
    static func main() async throws {
        let decoder = JSONDecoder()
        let prefs = try decoder.decode(ExplorePreferences.self, from: Data(#"{"memories":{"enabled":false},"tags":{"enabled":true}}"#.utf8))
        precondition(prefs.memories?.enabled == false && prefs.tags?.enabled == true && prefs.folders == nil)
        let status = try decoder.decode(ExploreAuthStatus.self, from: Data(#"{"pinCode":true,"password":true,"isElevated":false}"#.utf8))
        precondition(!status.isElevated && status.pinExpiresAt == nil)
        let elevated = try decoder.decode(ExploreAuthStatus.self, from: Data(#"{"pinCode":true,"password":true,"isElevated":true,"pinExpiresAt":"2026-11-04T14:00:00Z"}"#.utf8))
        precondition(elevated.pinExpiresAt == "2026-11-04T14:00:00Z")
        for removing in [true, false] {
            precondition(ExploreBulkResult(id: "a", success: false, error: removing ? "not_found" : "duplicate").isAccepted(removing: removing))
            precondition(!ExploreBulkResult(id: "a", success: false, error: "no_permission").isAccepted(removing: removing))
            precondition(!ExploreBulkResult(id: "a", success: false, error: "unknown").isAccepted(removing: removing))
        }
        let tags = [ExploreTag(id: "parent", name: "parent", value: "parent"), ExploreTag(id: "child", name: "child", value: "parent/child", parentId: "parent")]
        precondition(ExploreTagNode.tree(tags).first?.children?.first?.id == "child")
        let mapQuery = ExploreMapQuery(bbox: "1,2,3,4", favorites: true, archived: true, partners: true, after: Date(timeIntervalSince1970: 10), before: Date(timeIntervalSince1970: 20))
        precondition(mapQuery.timeline.parameters["bbox"]! == "1,2,3,4")
        precondition(mapQuery.timeline.visibility == nil && mapQuery.timeline.isFavorite == true)
        precondition(mapQuery.includes(Date(timeIntervalSince1970: 10)))
        precondition(!mapQuery.includes(Date(timeIntervalSince1970: 20)))
        precondition(!mapQuery.includes(nil))
        precondition(mapQuery.includesMonth(start: Date(timeIntervalSince1970: 0)))
        precondition(!mapQuery.includesMonth(start: Date(timeIntervalSince1970: 31 * 86400)))
        try await checkRequestsAndCache()
        let tree = ExploreFolderNode.tree(["/data/photos/2024", "/data/photos/2025", "/data/photos/2024", "/data/videos"])
        precondition(tree.count == 1 && tree[0].id == "/data")
        precondition(tree[0].children?.count == 2)
        precondition(tree[0].children?.first?.children?.map(\.name) == ["2024", "2025"])
        // Folder navigation carries the subtree even when a parent contains no photos of its own.
        let folderRoute = tree[0]
        precondition(Set([folderRoute, ExploreFolderNode(id: folderRoute.id, children: nil)]).count == 1)
        precondition(folderRoute != ExploreFolderNode(id: "/other", children: folderRoute.children))
        let photos = folderRoute.children!.first { $0.name == "photos" }!
        precondition(photos.id == "/data/photos" && photos.children!.map(\.id) == ["/data/photos/2024", "/data/photos/2025"])
        precondition(photos.children!.allSatisfy { $0.children == nil })
        let markers = (0..<50_000).map { i in
            ExploreMarker(id: String(i), lat: Double(i % 180) - 89.5, lon: Double(i % 360) - 179.5)
        }
        let clusters = ExploreMapCluster.make(markers, latitude: 0, longitude: 0, latSpan: 180, lonSpan: 360)
        precondition(clusters.count <= 400)
        for cluster in clusters {
            let bounds = cluster.bbox.split(separator: ",").compactMap { Double($0) }
            precondition(bounds.count == 4 && bounds[0] <= bounds[2] && bounds[1] <= bounds[3])
        }
        precondition(clusters.flatMap(\.assets).count == markers.count)
        let near = ExploreMapCluster.make(markers, latitude: 0, longitude: 0, latSpan: 10, lonSpan: 10)
        precondition(near.count < clusters.count)
        let dateline = [ExploreMarker(id: "east", lat: 0, lon: 179.9), ExploreMarker(id: "west", lat: 0, lon: -179.9)]
        precondition(ExploreMapCluster.make(dateline, latitude: 0, longitude: 180, latSpan: 10, lonSpan: 10).flatMap(\.assets).count == 2)
        for longitude in [-1260.0, -540, -180, 180, 540, 1260] {
            precondition(ExploreMapCluster.make(dateline, latitude: 0, longitude: longitude, latSpan: 10, lonSpan: 10).flatMap(\.assets).count == 2)
        }
        for span in [0.0, -10, 720, Double.greatestFiniteMagnitude] {
            let extreme = ExploreMapCluster.make(markers, latitude: 0, longitude: 0, latSpan: span, lonSpan: span)
            precondition(extreme.allSatisfy { $0.lat.isFinite && $0.lon.isFinite })
            if abs(span) >= 360 { precondition(extreme.flatMap(\.assets).count == markers.count) }
        }
        for invalid in [Double.nan, .infinity, -.infinity] {
            precondition(ExploreMapCluster.make(markers, latitude: invalid, longitude: 0, latSpan: 10, lonSpan: 10).isEmpty)
            precondition(ExploreMapCluster.make(markers, latitude: 0, longitude: invalid, latSpan: 10, lonSpan: 10).isEmpty)
            precondition(ExploreMapCluster.make(markers, latitude: 0, longitude: 0, latSpan: invalid, lonSpan: 10).isEmpty)
            precondition(ExploreMapCluster.make(markers, latitude: 0, longitude: 0, latSpan: 10, lonSpan: invalid).isEmpty)
        }
        let invalidMarkers = [ExploreMarker(id: "nan", lat: .nan, lon: 0), ExploreMarker(id: "infinity", lat: 0, lon: .infinity), ExploreMarker(id: "invalid", lat: 91, lon: 181)]
        precondition(ExploreMapCluster.make(invalidMarkers, latitude: 0, longitude: 0, latSpan: 180, lonSpan: 360).isEmpty)
        let closeMarkers = [ExploreMarker(id: "b", lat: 45.01, lon: 9.01), ExploreMarker(id: "a", lat: 45.02, lon: 9.02),
                            ExploreMarker(id: "c", lat: 46, lon: 10)]
        let stable = ExploreMapCluster.make(closeMarkers, latitude: 45, longitude: 9, latSpan: 10, lonSpan: 10)
        let rounded = ExploreMapCluster.make(closeMarkers.reversed(), latitude: 45, longitude: 9, latSpan: 10.001, lonSpan: 10.001)
        precondition(stable == rounded, "Small camera changes and server ordering must not replace annotations")
        let zoomed = ExploreMapCluster.make(closeMarkers, latitude: 45, longitude: 9, latSpan: 1, lonSpan: 1)
        precondition(stable.first { $0.assets == ["a", "b"] }?.id == "a")
        precondition(zoomed.first { $0.assets == ["a", "b"] }?.id == "a")
        precondition(Set(zoomed.map(\.id)).count == zoomed.count)
        let boundaryMarkers = [ExploreMarker(id: "left", lat: 44.165, lon: 9), ExploreMarker(id: "right", lat: 44.168, lon: 9)]
        let boundary = ExploreMapCluster.make(boundaryMarkers, latitude: 44, longitude: 9, latSpan: 10, lonSpan: 10)
        precondition(boundary.count == 1 && boundary[0].assets.count == 2)
        precondition(boundary == ExploreMapCluster.make(boundaryMarkers, latitude: 44, longitude: 9, latSpan: 10.001, lonSpan: 10.001),
                     "Camera rounding must not split markers across the old continuously moving grid boundary")
        precondition(ExploreMapCluster.initialBounds([]) == nil)
        precondition(ExploreMapCluster.initialBounds(invalidMarkers) == nil)
        for input in [closeMarkers, [closeMarkers[0]], dateline] {
            let bounds = ExploreMapCluster.initialBounds(input)!
            precondition(!bounds.isNull && !bounds.isEmpty && bounds.width.isFinite && bounds.height.isFinite)
            for marker in input {
                let point = MKMapPoint(CLLocationCoordinate2D(latitude: marker.lat, longitude: marker.lon))
                precondition(bounds.contains(point), "Initial fit must include source markers, not viewport clusters")
            }
        }
        for latitude in [-90.0, -89, 89, 90] {
            let bounds = ExploreMapCluster.initialBounds([ExploreMarker(id: "pole", lat: latitude, lon: 180)])!
            precondition(!bounds.isNull && !bounds.isEmpty && bounds.origin.x.isFinite && bounds.origin.y.isFinite
                         && bounds.width.isFinite && bounds.height.isFinite)
        }
        print("Explore checks passed: preferences, auth, folder deduplication, 50,000-marker clustering, stable identities/grid, initial bounds, poles and dateline")
    }
}

private final class ExploreMockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (URLRequest) -> Data = { _ in Data() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func checkRequestsAndCache() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ExploreMockProtocol.self]
    config.urlCache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "https://example.invalid/api")!
    let client = ImmichClient(serverURL: url, apiURL: url, credential: .accessToken("test"), session: session)
    ExploreMockProtocol.handler = { request in
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        if request.url!.path.hasSuffix("memories") {
            let date = query.first { $0.name == "for" }?.value
            precondition(date?.count == 10)
        } else {
            precondition(query.first { $0.name == "isArchived" }?.value == "true")
        }
        return Data("[]".utf8)
    }
    _ = try await client.exploreMemories(page: 1)
    _ = try await client.exploreMarkers(favorites: false, archived: true, partners: true, after: nil, before: nil)
    let privateClient = client.explorePrivateClient()
    precondition(privateClient.session.configuration.urlCache == nil)
    precondition(privateClient.session.configuration.httpMaximumConnectionsPerHost == 8)
    precondition(privateClient.session.configuration.timeoutIntervalForRequest == 30)
    precondition(privateClient.session.configuration.httpAdditionalHeaders?["User-Agent"] as? String == ImmichClient.userAgent)
    privateClient.session.invalidateAndCancel()
    let apiKeyClient = ImmichClient(serverURL: url, apiURL: url, credential: .apiKey("test"), session: session)
    precondition(!apiKeyClient.exploreSupportsLockedFolder)
    do { try await apiKeyClient.exploreUnlock("123456", setup: true); preconditionFailure("API key must not set a PIN") }
    catch ImmichError.http(400, _) {} // No request must be sent.
    let requests = [client.thumbnailRequest("a", size: .thumbnail), client.thumbnailRequest("a", size: .preview), client.thumbnailRequest("a", size: .fullsize), client.originalRequest("a"), client.thumbnailRequest("b", size: .thumbnail)]
    for request in requests {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        config.urlCache!.storeCachedResponse(CachedURLResponse(response: response, data: Data("cached".utf8)), for: request)
    }
    let pipeline = ImagePipeline(client: client)
    precondition(pipeline.client === client)
    precondition(config.urlCache!.cachedResponse(for: requests[0]) != nil)
    pipeline.evict(ids: ["a"])
    precondition(requests.prefix(4).allSatisfy { config.urlCache!.cachedResponse(for: $0) == nil })
    precondition(config.urlCache!.cachedResponse(for: requests[4]) != nil)
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let png = NSMutableData()
    let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    ExploreMockProtocol.handler = { _ in png as Data }
    let ordinary = await pipeline.thumbnail("b", size: .thumbnail)
    precondition(ordinary != nil)
    ExploreMockProtocol.handler = { _ in
        pipeline.evict(ids: ["a"])
        return png as Data
    }
    let stale = await pipeline.thumbnail("a", size: .thumbnail)
    precondition(stale == nil && pipeline.cachedThumbnail("a", size: .thumbnail) == nil)
    precondition(pipeline.cachedThumbnail("b", size: .thumbnail) != nil)
    print("Review checks passed: date query, archive query, tag idempotence/tree, bounds/date filters, private session, API-key PIN guard, selective cache eviction and stale-response rejection")
}
