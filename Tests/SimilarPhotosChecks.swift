// Offline checks for Find Similar Photos (#41). Run through scripts/check-integration.py ("similar-photos").
// The server is a URLProtocol fixture; Vision runs on generated geometric images. No app, Keychain or network.
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import Vision

@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() { print("FAIL line \(line): \(message)"); exit(1) }
}

// MARK: Fixture server

final class Fixture: @unchecked Sendable {
    static let shared = Fixture()
    let lock = NSLock()
    var assets: [String: [String: Any]] = [:]
    /// Search pages in order; each holds asset IDs.
    var pages: [[String]] = []
    var repeatPage = false
    var requests: [(method: String, path: String, body: [String: Any])] = []
    var stackFailures: Set<String> = [] // first ID of a POST that fails
    var ignorePrimary = false // server returns another primary
    var previews: [String: Data] = [:]
    /// When set, a POST /stacks waits here after it's recorded, until the test signals it.
    var holdStack: DispatchSemaphore?
    var stackArrived = false
    var holdStackRead: DispatchSemaphore?
    var stackReadArrived = false
    var trashEnabled: Bool? = true

    func reset() {
        lock.withLock {
            assets = [:]; pages = []; requests = []; stackFailures = []; ignorePrimary = false; repeatPage = false; previews = [:]; holdStack = nil; stackArrived = false; holdStackRead = nil; stackReadArrived = false; trashEnabled = true
        }
    }
    var posts: [String] { lock.withLock { requests.filter { $0.method == "POST" && $0.path.hasSuffix("/stacks") }.map(\.path) } }
    var writes: [(String, String)] {
        lock.withLock { requests.filter { $0.method != "GET" && !$0.path.hasSuffix("search/metadata") }.map { ($0.method, $0.path) } }
    }
}

func assetJSON(_ id: String, owner: String = "me", type: String = "IMAGE", seconds: Double, visibility: String = "timeline",
               trashed: Bool = false, favorite: Bool = false, stack: Bool = false) -> [String: Any] {
    let date = Date(timeIntervalSince1970: 1_780_000_000 + seconds).formatted(.iso8601)
    var json: [String: Any] = ["id": id, "ownerId": owner, "type": type, "originalFileName": "\(id).jpg", "fileCreatedAt": date,
                               "localDateTime": date, "isFavorite": favorite, "isTrashed": trashed, "visibility": visibility,
                               "width": 4000, "height": 3000]
    if stack { json["stack"] = ["id": "old-\(id)", "primaryAssetId": id, "assetCount": 2] }
    return json
}

final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func reply(_ status: Int, _ object: Any) {
        let data = (object as? Data) ?? (try! JSONSerialization.data(withJSONObject: object))
        client!.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: data)
        client!.urlProtocolDidFinishLoading(self)
    }

    override func startLoading() {
        let fixture = Fixture.shared
        let method = request.httpMethod ?? "GET"
        let path = request.url!.path
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            stream.close(); bodyData = data
        }
        let body = bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        fixture.lock.withLock { fixture.requests.append((method, path, body)) }

        if method == "POST", path.hasSuffix("search/metadata") {
            let page = body["page"] as? Int ?? 1
            let (ids, total, assets, repeatPage) = fixture.lock.withLock { (fixture.pages.indices.contains(page - 1) ? fixture.pages[page - 1] : [], fixture.pages.count, fixture.assets, fixture.repeatPage) }
            let next: Any = page < total ? String(repeatPage ? page : page + 1) : NSNull()
            return reply(200, ["assets": ["items": ids.compactMap { assets[$0] }, "nextPage": next]])
        }
        if method == "GET", path.contains("/assets/"), path.hasSuffix("/thumbnail") {
            let id = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
            if let data = fixture.lock.withLock({ fixture.previews[id] }) { return reply(200, data) }
            return reply(404, ["message": "No preview"])
        }
        if method == "GET", path.contains("/assets/") {
            let id = String(path.split(separator: "/").last!)
            if let json = fixture.lock.withLock({ fixture.assets[id] }) { return reply(200, json) }
            return reply(404, ["message": "Not found"])
        }
        if method == "POST", path.hasSuffix("/stacks") {
            let ids = body["assetIds"] as? [String] ?? []
            if fixture.lock.withLock({ fixture.stackFailures.contains(ids.first ?? "") }) { return reply(500, ["message": "Simulated stack failure"]) }
            let primary = fixture.lock.withLock { fixture.ignorePrimary } ? ids.last! : ids.first!
            fixture.lock.withLock { for id in ids { fixture.assets[id]?["stack"] = ["id": "stack-\(ids[0])", "primaryAssetId": primary, "assetCount": ids.count] } }
            if let hold = fixture.lock.withLock({ fixture.stackArrived = true; return fixture.holdStack }) {
                hold.wait()
                fixture.lock.withLock { fixture.holdStack = nil }
            }
            return reply(201, ["id": "stack-\(ids[0])", "primaryAssetId": primary, "assets": []])
        }
        if method == "GET", path.hasSuffix("server/features") {
            let enabled = fixture.lock.withLock { fixture.trashEnabled }
            return reply(200, enabled.map { ["trash": $0] } ?? [:])
        }
        if method == "GET", path.contains("/stacks/") {
            let assets = fixture.lock.withLock { Array(fixture.assets.values) }
            if let hold = fixture.lock.withLock({ fixture.stackReadArrived = true; return fixture.holdStackRead }) { hold.wait() }
            return reply(200, ["id": "read-stack", "primaryAssetId": "cover", "assets": assets])
        }
        if method == "DELETE", path.hasSuffix("/assets") { return reply(200, [:]) }
        if method == "PUT", path.contains("/stacks/") {
            return reply(200, ["id": String(path.split(separator: "/").last!), "primaryAssetId": body["primaryAssetId"] as? String ?? "", "assets": []])
        }
        reply(500, ["message": "Unexpected \(method) \(path)"])
    }
}

func makeClient() -> ImmichClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureProtocol.self]
    configuration.urlCache = nil
    let url = URL(string: "https://fixture.invalid")!
    return ImmichClient(serverURL: url, apiURL: url.appendingPathComponent("api"), credential: .apiKey("fixture"), session: URLSession(configuration: configuration))
}

/// Feature prints chosen per photo: equal vectors are similar, orthogonal ones are not.
struct TableAnalyzer: SimilarPhotosAnalyzing {
    let vectors: [String: [Float]]
    var scores: [String: SimilarPhotos.Score] = [:]
    var gate: Gate?
    func analyze(_ id: String) async throws -> SimilarPhotoFeatures {
        if let gate { await gate.wait() }
        guard let vector = vectors[id] else { throw SimilarPhotosAnalysisError.unreadableImage }
        return SimilarPhotoFeatures(featurePrint: vector, score: scores[id] ?? .init())
    }
}

actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0
    func wait() async {
        arrivals += 1
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

func unit(_ axis: Int) -> [Float] { var v = [Float](repeating: 0, count: 8); v[axis] = 1; return v }

@MainActor func waitFor(_ condition: () -> Bool, _ message: String, line: Int = #line) async {
    for _ in 0..<500 { if condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
    check(false, "Timed out: \(message)", line: line)
}

// MARK: Synthetic images for Vision

func scene(_ kind: Int, shift: Int = 0, brightness: CGFloat = 1, size: (Int, Int) = (960, 720)) -> CGImage {
    let (w, h) = size
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: min(r * brightness, 1), green: min(g * brightness, 1), blue: min(b * brightness, 1), alpha: 1) }
    let dx = CGFloat(shift)
    switch kind {
    case 0: // sky, sea and a red sun
        ctx.setFillColor(color(0.35, 0.6, 0.9)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(color(0.05, 0.25, 0.45)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 3))
        ctx.setFillColor(color(0.95, 0.35, 0.1)); ctx.fillEllipse(in: CGRect(x: 520 + dx, y: 380, width: 180, height: 180))
    case 1: // black and white checkerboard
        for y in stride(from: 0, to: h, by: 60) { for x in stride(from: 0, to: w, by: 60) {
            ctx.setFillColor(((x + y) / 60) % 2 == 0 ? color(0.95, 0.95, 0.95) : color(0.08, 0.08, 0.08))
            ctx.fill(CGRect(x: CGFloat(x) + dx, y: CGFloat(y), width: 60, height: 60))
        } }
    case 2: // green field with yellow triangle
        ctx.setFillColor(color(0.2, 0.65, 0.25)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(color(0.98, 0.85, 0.15))
        ctx.move(to: CGPoint(x: 200 + dx, y: 100)); ctx.addLine(to: CGPoint(x: 760 + dx, y: 120)); ctx.addLine(to: CGPoint(x: 480 + dx, y: 620)); ctx.fillPath()
    default: // purple stripes
        for i in 0..<16 {
            ctx.setFillColor(i % 2 == 0 ? color(0.5, 0.2, 0.7) : color(0.9, 0.8, 0.95))
            ctx.fill(CGRect(x: CGFloat(i * w / 16) + dx, y: 0, width: CGFloat(w / 16), height: CGFloat(h)))
        }
    }
    return ctx.makeImage()!
}

func jpeg(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
    CGImageDestinationFinalize(destination)
    return data as Data
}

func blurred(_ image: CGImage) -> CGImage {
    // Downscale hard and back up: loses edges, as a shaken shot would.
    let small = CGContext(data: nil, width: image.width / 16, height: image.height / 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    small.interpolationQuality = .high
    small.draw(image, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
    let big = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    big.interpolationQuality = .high
    big.draw(small.makeImage()!, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return big.makeImage()!
}

@main struct SimilarPhotosChecks {
    @MainActor static func main() async throws {
        pureChecks()
        try visionChecks()
        await serverChecks()
        try await mutationAndClusteringChecks()
        print("PASS similar photos")
    }

    @MainActor static func mutationAndClusteringChecks() async throws {
        let fixture = Fixture.shared
        let client = makeClient()
        for mode in ["switch", "logout", "close", "cancel"] {
            fixture.reset()
            fixture.assets["cover"] = assetJSON("cover", seconds: 0)
            fixture.assets["other"] = assetJSON("other", seconds: 1)
            let json: [String: Any] = ["id": "read-stack", "primaryAssetId": "cover", "assets": Array(fixture.assets.values)]
            let shown = try JSONDecoder().decode(AssetsStack.self, from: JSONSerialization.data(withJSONObject: json))
            let hold = DispatchSemaphore(value: 0)
            fixture.lock.withLock { fixture.holdStackRead = hold }
            var current = true
            let task = Task { try await AssetsStackMutation.trashOthers(client: client, stackID: shown.id, shown: shown, userID: "me", isCurrent: { current }) }
            await waitFor({ fixture.lock.withLock { fixture.stackReadArrived } }, "stack read pending")
            if mode == "cancel" { task.cancel() } else { current = false }
            hold.signal()
            do { try await task.value; check(false, "obsolete action must cancel: \(mode)") } catch {}
            check(fixture.writes.isEmpty, "zero DELETE after \(mode)")
        }
        fixture.reset()
        for (id, owner, visibility, trashed) in [("cover", "me", "timeline", false), ("other", "me", "timeline", false),
                                                ("partner", "someone", "timeline", false), ("locked", "me", "locked", false), ("trash", "me", "timeline", true)] {
            fixture.assets[id] = assetJSON(id, owner: owner, seconds: 0, visibility: visibility, trashed: trashed)
        }
        let json: [String: Any] = ["id": "read-stack", "primaryAssetId": "cover", "assets": Array(fixture.assets.values)]
        let shown = try JSONDecoder().decode(AssetsStack.self, from: JSONSerialization.data(withJSONObject: json))
        try await AssetsStackMutation.trashOthers(client: client, stackID: shown.id, shown: shown, userID: "me", isCurrent: { true })
        let request = fixture.lock.withLock { fixture.requests.last! }
        check(request.method == "DELETE" && request.body["ids"] as? [String] == ["other"] && request.body["force"] as? Bool == false,
              "only owned non-cover, nonlocked and untrashed members, recoverable delete")

        for enabled: Bool? in [false, nil] {
            fixture.lock.withLock { fixture.requests = []; fixture.trashEnabled = enabled }
            do {
                try await AssetsStackMutation.trashOthers(client: client, stackID: shown.id, shown: shown, userID: "me", isCurrent: { true })
                check(false, "disabled or unknown trash must fail closed")
            } catch {}
            check(fixture.writes.isEmpty, "no delete when recoverable trash is disabled or unknown")
        }

        let dense = (0..<2000).map { SimilarPhotos.Candidate(id: String($0), date: Date(timeIntervalSince1970: Double($0) / 1000), isFavorite: false, pixels: 1) }
        let features = Dictionary(uniqueKeysWithValues: dense.map { ($0.id, SimilarPhotoFeatures(featurePrint: [Float](repeating: 0, count: 32), score: .init())) })
        let start = ContinuousClock.now
        let task = Task { try await SimilarPhotosModel.cluster([dense], features: features, options: .init()) }
        try await Task.sleep(for: .milliseconds(25))
        check(start.duration(to: .now) < .seconds(1), "main actor remains responsive while clustering 2000 candidates")
        task.cancel()
        do { _ = try await task.value; check(false, "dense clustering must cancel") } catch is CancellationError {}
        check(start.duration(to: .now) < .seconds(2), "dense clustering cooperatively stops")
        print("PASS browser account/close/cancel guards and off-main cancellable clustering")
    }

    // MARK: Pure logic

    @MainActor static func pureChecks() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        func c(_ id: String, _ seconds: Double, favorite: Bool = false, pixels: Int = 12_000_000) -> SimilarPhotos.Candidate {
            .init(id: id, date: base.addingTimeInterval(seconds), isFavorite: favorite, pixels: pixels)
        }
        // A pause of exactly the gap keeps photos together; a millisecond more splits them; singletons drop.
        let runs = SimilarPhotos.timeRuns([c("b", 10), c("a", 0), c("c", 20.001), c("d", 25), c("e", 100)], maxGap: 10)
        check(runs.map { $0.map(\.id) } == [["a", "b"], ["c", "d"]], "time runs at the gap boundary: \(runs.map { $0.map(\.id) })")
        // Same timestamp: ID order, independent of input order.
        check(SimilarPhotos.timeRuns([c("z", 0), c("y", 0)], maxGap: 10)[0].map(\.id) == ["y", "z"], "stable order at equal dates")

        // Duration: a run 1 s apart over 70 s never yields a group longer than 60 s.
        let long = (0...70).map { c(String(format: "p%03d", $0), Double($0)) }
        let longGroups = SimilarPhotos.groups(long, threshold: 0.35) { _, _ in 0 }
        check(longGroups.allSatisfy { long[$0.last!].date.timeIntervalSince(long[$0.first!].date) <= 60 }, "max duration 60 s")
        check(longGroups.allSatisfy { $0.count <= 20 } && longGroups.flatMap { $0 }.count == long.count, "max 20 members, every photo grouped")
        let exact = [c("a", 0), c("b", 30), c("c", 60)]
        check(SimilarPhotos.groups(exact, threshold: 0.35) { _, _ in 0 } == [[0, 1, 2]], "exactly 60 s is allowed")
        check(SimilarPhotos.groups([c("a", 0), c("b", 30), c("c", 60.5)], threshold: 0.35) { _, _ in 0 } == [[0, 1]], "over 60 s splits")
        // 25 identical photos: 20 + 5.
        let burst = (0..<25).map { c(String(format: "b%02d", $0), Double($0) * 0.5) }
        let burstGroups = SimilarPhotos.groups(burst, threshold: 0.35) { _, _ in 0.1 }
        check(burstGroups.map(\.count).sorted() == [5, 20], "20-member cap: \(burstGroups.map(\.count))")

        // Complete link: A≈B and B≈C but A far from C never makes one group of three.
        let chain = [c("a", 0), c("b", 1), c("c", 2)]
        let distances: [[Float]] = [[0, 0.2, 0.6], [0.2, 0, 0.2], [0.6, 0.2, 0]]
        check(SimilarPhotos.groups(chain, threshold: 0.35) { distances[$0][$1] } == [[0, 1]], "chain broken, tie to earliest pair")
        // Strict/Normal/Loose change only the threshold.
        let pair = [c("a", 0), c("b", 1)]
        check(SimilarPhotos.groups(pair, threshold: SimilarPhotos.Sensitivity.strict.threshold) { _, _ in 0.3 }.isEmpty, "strict rejects 0.30")
        check(SimilarPhotos.groups(pair, threshold: SimilarPhotos.Sensitivity.normal.threshold) { _, _ in 0.3 } == [[0, 1]], "normal accepts 0.30")
        check(SimilarPhotos.groups(pair, threshold: SimilarPhotos.Sensitivity.loose.threshold) { _, _ in 0.45 } == [[0, 1]], "loose accepts its threshold")
        // A photo that couldn't be analyzed joins nothing.
        check(SimilarPhotos.groups(chain, threshold: 0.35) { i, j in i == 1 || j == 1 ? nil : 0.1 } == [[0, 2]], "unknown distance excluded")

        // Eligibility.
        func response(_ json: [String: Any]) -> AssetResponse { try! JSONDecoder().decode(AssetResponse.self, from: JSONSerialization.data(withJSONObject: json)) }
        check(SimilarPhotos.exclusion(response(assetJSON("ok", seconds: 0)), userID: "me") == nil, "own timeline photo")
        check(SimilarPhotos.exclusion(response(assetJSON("ar", seconds: 0, visibility: "archive")), userID: "me") == nil, "archived selection allowed")
        check(SimilarPhotos.exclusion(response(assetJSON("v", type: "VIDEO", seconds: 0)), userID: "me") == .notPhoto, "video")
        check(SimilarPhotos.exclusion(response(assetJSON("p", owner: "partner", seconds: 0)), userID: "me") == .notOwned, "partner")
        check(SimilarPhotos.exclusion(response(assetJSON("e", owner: "", seconds: 0)), userID: "") == .notOwned, "empty account ID never matches")
        check(SimilarPhotos.exclusion(response(assetJSON("t", seconds: 0, trashed: true)), userID: "me") == .trashed, "trash")
        check(SimilarPhotos.exclusion(response(assetJSON("l", seconds: 0, visibility: "locked")), userID: "me") == .hiddenOrLocked, "locked")
        check(SimilarPhotos.exclusion(response(assetJSON("h", seconds: 0, visibility: "hidden")), userID: "me") == .hiddenOrLocked, "Live Photo video part")
        check(SimilarPhotos.exclusion(response(assetJSON("s", seconds: 0, stack: true)), userID: "me") == .stacked, "already stacked")
        var undated = assetJSON("u", seconds: 0); undated["fileCreatedAt"] = "not a date"
        check(SimilarPhotos.exclusion(response(undated), userID: "me") == .noDate, "no date")

        // Top pick: favorite, then aesthetics, sharpness, resolution, earliest, ID; input order never matters.
        let members = [c("m1", 0), c("m2", 1), c("m3", 2, favorite: true), c("m4", 3)]
        let scores: [String: SimilarPhotos.Score] = ["m1": .init(aesthetics: 0.2, sharpness: 50), "m2": .init(aesthetics: 0.6, sharpness: 10),
                                                     "m3": .init(aesthetics: 0.1, sharpness: 5), "m4": .init(aesthetics: 0.6, sharpness: 40)]
        check(SimilarPhotos.topPick(members, scores: scores) == "m3", "favorite first")
        let plain = members.filter { $0.id != "m3" }
        for _ in 0..<10 { check(SimilarPhotos.topPick(plain.shuffled(), scores: scores) == "m4", "aesthetics then sharpness, deterministic") }
        check(SimilarPhotos.topPick([c("x2", 5), c("x1", 5)], scores: [:]) == "x1", "full tie: earliest, then ID")
        check(SimilarPhotos.topPick([c("r1", 0, pixels: 1), c("r2", 1, pixels: 2)], scores: [:]) == "r2", "resolution before date")

        // Ranges cover whole days in the user's calendar, inclusive.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 15))!
        let range = SimilarPhotosRange.lastDays(30, now: now, calendar: calendar)
        let (after, before) = range.bounds(calendar: calendar)
        check(after == calendar.date(from: DateComponents(year: 2026, month: 10, day: 13)), "30 days back to the start of day")
        check(before > now && before < calendar.date(from: DateComponents(year: 2026, month: 11, day: 12))!, "through the end of today")
        print("PASS pure grouping, eligibility, top pick, ranges")
    }

    // MARK: Real Vision

    static func visionChecks() throws {
        var intra: [Float] = [], inter: [Float] = []
        var prints: [[[Float]]] = []
        for kind in 0..<4 {
            var list: [[Float]] = []
            for (shift, brightness) in [(0, 1.0), (8, 1.0), (-6, 0.9), (4, 1.08)] {
                let image = ImagePipeline.decode(jpeg(scene(kind, shift: shift, brightness: brightness)), maxPixelSize: SimilarPhotosVisionAnalyzer.edge)!
                precondition(max(image.width, image.height) == SimilarPhotosVisionAnalyzer.edge, "analyzed at 720 px")
                list.append(try SimilarPhotosVisionAnalyzer.features(of: image).featurePrint)
            }
            prints.append(list)
        }
        for list in prints { for i in list.indices { for j in (i + 1)..<list.count { intra.append(SimilarPhotosVisionAnalyzer.distance(list[i], list[j])!) } } }
        for a in prints.indices { for b in (a + 1)..<prints.count { for x in prints[a] { for y in prints[b] { inter.append(SimilarPhotosVisionAnalyzer.distance(x, y)!) } } } }
        print(String(format: "Vision revision 2 on synthetic scenes: within-scene max %.3f, between-scene min %.3f", intra.max()!, inter.min()!))
        precondition(intra.max()! < SimilarPhotos.Sensitivity.normal.threshold, "variants of one scene group at Normal")
        precondition(inter.min()! > SimilarPhotos.Sensitivity.loose.threshold, "different scenes stay apart even at Loose")

        // Our Euclidean distance is Vision's own.
        let request = VNGenerateImageFeaturePrintRequest(); request.revision = VNGenerateImageFeaturePrintRequestRevision2
        let other = VNGenerateImageFeaturePrintRequest(); other.revision = VNGenerateImageFeaturePrintRequestRevision2
        try VNImageRequestHandler(cgImage: scene(0)).perform([request])
        try VNImageRequestHandler(cgImage: scene(0, shift: 12)).perform([other])
        var visionDistance: Float = 0
        try request.results!.first!.computeDistance(&visionDistance, to: other.results!.first!)
        let ours = SimilarPhotosVisionAnalyzer.distance(try SimilarPhotosVisionAnalyzer.features(of: scene(0)).featurePrint,
                                                        try SimilarPhotosVisionAnalyzer.features(of: scene(0, shift: 12)).featurePrint)!
        precondition(abs(ours - visionDistance) < 1e-4, "distance matches computeDistance (\(ours) vs \(visionDistance))")

        // Sharpness prefers the crisp shot over a blurred copy.
        let crisp = SimilarPhotosVisionAnalyzer.sharpness(of: scene(1))!, soft = SimilarPhotosVisionAnalyzer.sharpness(of: blurred(scene(1)))!
        precondition(crisp > soft, "sharpness ranks blur lower")
        print("PASS real Vision feature prints, distance and sharpness")
    }

    // MARK: Server flows

    @MainActor static func serverChecks() async {
        let fixture = Fixture.shared
        let client = makeClient()
        var current = true
        var changes = 0
        func model(_ analyzer: any SimilarPhotosAnalyzing, user: String? = "me") -> SimilarPhotosModel {
            SimilarPhotosModel(client: client, userID: user, analyzer: analyzer, isCurrent: { current }, didChangeLibrary: { changes += 1 })
        }
        let range = SimilarPhotosRange(start: Date(timeIntervalSince1970: 1_779_900_000), end: Date(timeIntervalSince1970: 1_780_100_000))

        // Every page is read; ineligible photos are counted; nothing is written before apply().
        fixture.reset()
        var all: [[String: Any]] = [
            assetJSON("g1a", seconds: 0), assetJSON("g1b", seconds: 2, favorite: true), assetJSON("g1c", seconds: 4),
            assetJSON("g2a", seconds: 600), assetJSON("g2b", seconds: 603),
            assetJSON("g3a", seconds: 1200), assetJSON("g3b", seconds: 1201),
            assetJSON("g4a", seconds: 1800), assetJSON("g4b", seconds: 1801),
            assetJSON("g5a", seconds: 2400), assetJSON("g5b", seconds: 2402),
            assetJSON("far", seconds: 5000),
            assetJSON("partner", owner: "other", seconds: 1), assetJSON("video", type: "VIDEO", seconds: 3),
            assetJSON("stacked", seconds: 601, stack: true), assetJSON("trashed", seconds: 602, trashed: true),
        ]
        all.shuffle()
        for json in all { fixture.assets[json["id"] as! String] = json }
        let ids = all.map { $0["id"] as! String }
        fixture.pages = stride(from: 0, to: ids.count, by: 5).map { Array(ids[$0..<min($0 + 5, ids.count)]) }
        let vectors: [String: [Float]] = ["g1a": unit(0), "g1b": unit(0), "g1c": unit(0), "g2a": unit(1), "g2b": unit(1),
                                          "g3a": unit(2), "g3b": unit(2), "g4a": unit(3), "g4b": unit(3), "g5a": unit(4), "g5b": unit(4)]
        let scanner = model(TableAnalyzer(vectors: vectors, scores: ["g1a": .init(aesthetics: 0.9, sharpness: 1)]))
        scanner.scan(.range(range), options: .init())
        await waitFor({ scanner.phase == .ready }, "scan finishes")
        let searches = fixture.lock.withLock { fixture.requests.filter { $0.path.hasSuffix("search/metadata") } }
        check(searches.count == fixture.pages.count, "all \(fixture.pages.count) pages read, got \(searches.count)")
        check(searches.allSatisfy { $0.body["type"] as? String == "IMAGE" && $0.body["takenAfter"] != nil && $0.body["takenBefore"] != nil
                                    && $0.body["visibility"] as? String == "timeline" }, "range search filters")
        check(scanner.coverage.eligible == 12 && scanner.coverage.excluded.values.reduce(0, +) == 4, "coverage: \(scanner.coverage)")
        check(scanner.coverage.analyzed == 11, "only photos with a neighbor analyzed: \(scanner.coverage.analyzed)")
        check(scanner.groups.map { $0.members.map(\.id) } == [["g1a", "g1b", "g1c"], ["g2a", "g2b"], ["g3a", "g3b"], ["g4a", "g4b"], ["g5a", "g5b"]],
              "groups: \(scanner.groups.map { $0.members.map(\.id) })")
        check(scanner.groups[0].suggestedCover == "g1b", "favorite suggested over higher aesthetics")
        check(fixture.writes.isEmpty, "zero writes before confirmation: \(fixture.writes)")

        // Review edits: override cover, remove a member, exclude a group.
        scanner.setCover("g1c", in: "g1a")
        scanner.remove("g1a", from: "g1a")
        check(scanner.groups[0].stackIDs == ["g1c", "g1b"], "override cover goes first: \(scanner.groups[0].stackIDs)")
        scanner.setIncluded(false, groupID: "g5a")
        check(scanner.stackableGroups.count == 4, "excluded group not stacked")
        check(fixture.writes.isEmpty, "edits don't write")

        // Before applying, the server changes: g2b now a partner's, g3b locked, g4a already stacked elsewhere.
        fixture.lock.withLock {
            fixture.assets["g2b"]?["ownerId"] = "other"
            fixture.assets["g3b"]?["visibility"] = "locked"
            fixture.assets["g4a"]?["stack"] = ["id": "x", "primaryAssetId": "g4a", "assetCount": 2]
        }
        await scanner.apply()
        let statuses = scanner.groups.map(\.status)
        check(statuses[0] == .stacked(stackID: "stack-g1c"), "group 1 stacked with the chosen cover: \(statuses[0])")
        check(statuses[1] == .changed && statuses[2] == .changed && statuses[3] == .changed, "changed groups skipped: \(statuses)")
        check(statuses[4] == .pending, "excluded group untouched")
        check(fixture.posts.count == 1, "only one POST: \(fixture.posts)")
        let post = fixture.lock.withLock { fixture.requests.first { $0.method == "POST" && $0.path.hasSuffix("/stacks") }!.body }
        check(post["assetIds"] as? [String] == ["g1c", "g1b"], "cover first in POST, removed member left out")
        check(changes == 1, "grids invalidated once")
        check(!fixture.writes.contains { $0.0 == "DELETE" }, "never deletes")

        // A server keeping another primary gets an explicit PUT; a failed POST is reported and never retried.
        fixture.reset()
        for (i, id) in ["a1", "a2", "b1", "b2"].enumerated() { fixture.assets[id] = assetJSON(id, seconds: Double(i < 2 ? i : 100 + i)) }
        fixture.pages = [["a1", "a2", "b1", "b2"]]
        fixture.ignorePrimary = true
        fixture.stackFailures = ["b1"]
        let second = model(TableAnalyzer(vectors: ["a1": unit(0), "a2": unit(0), "b1": unit(1), "b2": unit(1)]))
        second.scan(.range(range), options: .init())
        await waitFor({ second.phase == .ready }, "second scan")
        await second.apply()
        check(second.groups[0].status == .stacked(stackID: "stack-a1"), "primary corrected: \(second.groups[0].status)")
        check(fixture.lock.withLock { fixture.requests.contains { $0.method == "PUT" && $0.path.hasSuffix("stacks/stack-a1") && $0.body["primaryAssetId"] as? String == "a1" } }, "PUT primary sent")
        if case .failed(let message) = second.groups[1].status { check(message.contains("Simulated"), "server message shown") } else { check(false, "partial failure visible: \(second.groups[1].status)") }
        await second.apply()
        check(fixture.posts.count == 2, "failed group not retried: \(fixture.posts)")

        // Selection: items are read back; one missing item is reported, not silently dropped.
        fixture.reset()
        for (i, id) in ["s1", "s2", "s3"].enumerated() { fixture.assets[id] = assetJSON(id, seconds: Double(i)) }
        let selected = model(TableAnalyzer(vectors: ["s1": unit(0), "s2": unit(0), "s3": unit(0)]))
        selected.scan(.selection(["s1", "s2", "s3", "gone"]), options: .init())
        await waitFor({ selected.phase == .ready }, "selection scan")
        check(selected.coverage.unreadable == 1 && selected.coverage.eligible == 3 && selected.groups.count == 1, "selection coverage: \(selected.coverage)")
        check(fixture.lock.withLock { !fixture.requests.contains { $0.path.hasSuffix("search/metadata") } }, "selection doesn't search the range")

        // Analysis failures are counted; those photos join no group.
        fixture.reset()
        for (i, id) in ["f1", "f2", "f3"].enumerated() { fixture.assets[id] = assetJSON(id, seconds: Double(i)) }
        fixture.pages = [["f1", "f2", "f3"]]
        let failing = model(TableAnalyzer(vectors: ["f1": unit(0), "f3": unit(0)]))
        failing.scan(.range(range), options: .init())
        await waitFor({ failing.phase == .ready }, "failing scan")
        check(failing.coverage.analysisFailures == 1 && failing.groups.map { $0.members.map(\.id) } == [["f1", "f3"]], "analysis failure reported")

        // Over the limit: the scan stops with a message instead of analyzing only the first pages.
        fixture.reset()
        let many = (0...SimilarPhotos.candidateLimit).map { "m\($0)" }
        for (i, id) in many.enumerated() { fixture.assets[id] = assetJSON(id, seconds: Double(i * 100)) }
        fixture.pages = stride(from: 0, to: many.count, by: 250).map { Array(many[$0..<min($0 + 250, many.count)]) } + [["m0"]]
        let big = model(TableAnalyzer(vectors: [:]))
        big.scan(.range(range), options: .init())
        await waitFor({ big.phase == .tooMany }, "limit reached")
        check(big.groups.isEmpty && big.coverage.analyzed == 0, "nothing analyzed over the limit")

        // A server repeating a page fails explicitly.
        fixture.reset()
        fixture.assets["r1"] = assetJSON("r1", seconds: 0); fixture.pages = [["r1"], ["r1"]]; fixture.repeatPage = true
        let looping = model(TableAnalyzer(vectors: [:]))
        looping.scan(.range(range), options: .init())
        await waitFor({ if case .failed = looping.phase { true } else { false } }, "repeated page fails")

        // Cancel during analysis: late results are ignored and nothing is grouped.
        fixture.reset()
        for (i, id) in ["c1", "c2"].enumerated() { fixture.assets[id] = assetJSON(id, seconds: Double(i)) }
        fixture.pages = [["c1", "c2"]]
        let gate = Gate()
        let cancelled = model(TableAnalyzer(vectors: ["c1": unit(0), "c2": unit(0)], gate: gate))
        cancelled.scan(.range(range), options: .init())
        await waitFor({ if case .analyzing = cancelled.phase { true } else { false } }, "analysis started")
        cancelled.cancel()
        await gate.release()
        try? await Task.sleep(for: .milliseconds(100))
        check(cancelled.phase == .idle && cancelled.groups.isEmpty, "cancelled scan stays empty: \(cancelled.phase)")

        // Account switch during analysis: the scan never finishes into groups.
        let gate2 = Gate()
        let switching = model(TableAnalyzer(vectors: ["c1": unit(0), "c2": unit(0)], gate: gate2))
        switching.scan(.range(range), options: .init())
        await waitFor({ if case .analyzing = switching.phase { true } else { false } }, "second analysis started")
        current = false
        await gate2.release()
        try? await Task.sleep(for: .milliseconds(100))
        check(switching.groups.isEmpty && switching.phase != .ready, "switched account gets no groups")
        current = true

        // Account switch during apply: the stack already sent is recorded, no later group is sent.
        fixture.reset()
        let applyIDs = ["w1", "w2", "x1", "x2", "y1", "y2"]
        for (i, id) in applyIDs.enumerated() { fixture.assets[id] = assetJSON(id, seconds: Double((i / 2) * 100 + i % 2)) }
        fixture.pages = [applyIDs]
        let late = model(TableAnalyzer(vectors: ["w1": unit(0), "w2": unit(0), "x1": unit(1), "x2": unit(1), "y1": unit(2), "y2": unit(2)]))
        late.scan(.range(range), options: .init())
        await waitFor({ late.phase == .ready }, "apply scan")
        let hold = DispatchSemaphore(value: 0)
        fixture.lock.withLock { fixture.holdStack = hold }
        let applying = Task { await late.apply() }
        await waitFor({ fixture.lock.withLock { fixture.stackArrived } }, "first stack sent")
        current = false
        hold.signal()
        await applying.value
        check(fixture.posts.count == 1, "no POST after the account changed: \(fixture.posts)")
        check(late.groups[0].status == .stacked(stackID: "stack-w1") && late.groups[1].status == .pending && late.groups[2].status == .pending,
              "sent group recorded, others untouched: \(late.groups.map(\.status))")
        await late.apply()
        check(fixture.posts.count == 1, "apply refuses while the account isn't current")
        late.invalidateStack("stack-w1")
        check(late.needsRescan && late.groups.count == 2 && late.groups.allSatisfy { $0.status == .pending }, "browser mutation removes obsolete applied result and preserves pending choices")
        current = true

        // Cancel during apply (closing the sheet) stops before the next group.
        fixture.reset()
        for (i, id) in applyIDs.enumerated() { fixture.assets[id] = assetJSON(id, seconds: Double((i / 2) * 100 + i % 2)) }
        fixture.pages = [applyIDs]
        let stopped = model(TableAnalyzer(vectors: ["w1": unit(0), "w2": unit(0), "x1": unit(1), "x2": unit(1), "y1": unit(2), "y2": unit(2)]))
        stopped.scan(.range(range), options: .init())
        await waitFor({ stopped.phase == .ready }, "cancel-apply scan")
        let hold2 = DispatchSemaphore(value: 0)
        fixture.lock.withLock { fixture.holdStack = hold2 }
        let stopping = Task { await stopped.apply() }
        await waitFor({ fixture.lock.withLock { fixture.stackArrived } }, "first stack sent before cancel")
        stopped.cancel()
        hold2.signal()
        await stopping.value
        check(stopped.groups[0].status != .pending, "the group already sent is never sent again: \(stopped.groups[0].status)")
        check(fixture.posts.count == 1, "cancel stops later groups: \(fixture.posts)")

        // No account ID: nothing is scanned.
        let anonymous = model(TableAnalyzer(vectors: [:]), user: nil)
        anonymous.scan(.range(range), options: .init())
        if case .failed = anonymous.phase {} else { check(false, "missing account ID refused") }

        // Real Vision through the fixture's previews: two variants group, a different scene stays out.
        fixture.reset()
        let real: [(String, CGImage)] = [("v1", scene(0)), ("v2", scene(0, shift: 8, brightness: 0.95)), ("v3", scene(1))]
        for (i, (id, image)) in real.enumerated() {
            fixture.assets[id] = assetJSON(id, seconds: Double(i)); fixture.previews[id] = jpeg(image)
        }
        fixture.pages = [real.map(\.0)]
        let vision = model(SimilarPhotosVisionAnalyzer(client: client))
        vision.scan(.range(range), options: .init())
        await waitFor({ vision.phase == .ready }, "vision scan")
        check(vision.groups.map { $0.members.map(\.id) } == [["v1", "v2"]], "Vision groups variants only: \(vision.groups.map { $0.members.map(\.id) })")
        check(fixture.lock.withLock { fixture.requests.filter { $0.path.hasSuffix("/thumbnail") }.count } == 3, "previews downloaded once each")
        check(fixture.writes.isEmpty, "Vision scan writes nothing")
        print("PASS paging, revalidation, primary, partial errors, cancel and account switch")
    }
}
