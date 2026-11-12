import FileProvider
import Foundation
import Synchronization

// Finder access (issue #23): the extension's framework-facing parts, outside Finder. The XPC listener over real XPC
// (an anonymous listener in this process), errors built with the FileProvider SDK, and capabilities as the SDK's bits.
// No domain is registered and fileproviderd is never involved: Finder's own behavior still needs the manual pass in
// docs/FileProvider.md.

func check(_ condition: Bool, _ message: String, line: UInt = #line) {
    if !condition { print("FAIL \(line): \(message)"); exit(1) }
}

final class RecordingService: NSObject, FinderAccessService, @unchecked Sendable {
    let received = Mutex<[Data]>([])
    func setCredential(_ credential: Data, reply: @escaping @Sendable (NSError?) -> Void) {
        received.withLock { $0.append(credential) }
        reply(nil)
    }
    func forgetCredential(reply: @escaping @Sendable (NSError?) -> Void) { reply(nil) }
}

struct Timeout: Error {}

/// One call over a new connection to `endpoint`, as the app makes it after `getService`.
func send(_ data: Data, to endpoint: NSXPCListenerEndpoint) async -> Error? {
    let connection = NSXPCConnection(listenerEndpoint: endpoint)
    connection.remoteObjectInterface = NSXPCInterface(with: FinderAccessService.self)
    connection.resume()
    defer { connection.invalidate() }
    let once = Mutex(false)
    return await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
        let finish: @Sendable (Error?) -> Void = { error in
            guard once.withLock({ done in defer { done = true }; return !done }) else { return }
            continuation.resume(returning: error)
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ finish($0) }) as? FinderAccessService else {
            finish(Timeout())
            return
        }
        proxy.setCredential(data) { finish($0) }
        Task {
            try? await Task.sleep(for: .seconds(5))
            finish(Timeout())
        }
    }
}

@main struct FileProviderFrameworkChecks {
    static func main() async throws {
        await listener()
        errors()
        capabilities()
        names()
        print("File Provider framework checks passed")
    }

    // MARK: XPC

    static func listener() async {
        // The system asks for the endpoint again for every getService: resuming the listener twice used to trap.
        let service = RecordingService()
        let accepting = FinderAccessListener(exporting: service, requirement: "always")
        defer { accepting.invalidate() }
        let endpoints = (0..<3).map { _ in accepting.endpoint }
        for (index, endpoint) in endpoints.enumerated() {
            let error = await send(Data("key \(index)".utf8), to: endpoint)
            check(error == nil, "call \(index) over a repeated endpoint: \(String(describing: error))")
        }
        check(service.received.withLock { $0 } == (0..<3).map { Data("key \($0)".utf8) }, "every credential arrived once, in order")

        // A peer that doesn't satisfy the code-signing requirement never reaches the service.
        let refused = RecordingService()
        let refusing = FinderAccessListener(exporting: refused, requirement: "never")
        defer { refusing.invalidate() }
        let error = await send(Data("intruder".utf8), to: refusing.endpoint)
        check(error != nil && !(error is Timeout), "the requirement refuses the call: \(String(describing: error))")
        check(refused.received.withLock { $0 }.isEmpty, "nothing reached the service")

        // Without a requirement (unsigned and ad-hoc builds), no connection is accepted at all.
        let unsigned = RecordingService()
        let closed = FinderAccessListener(exporting: unsigned, requirement: nil)
        defer { closed.invalidate() }
        check(await send(Data("x".utf8), to: closed.endpoint) != nil, "unsigned: refused")
        check(unsigned.received.withLock { $0 }.isEmpty, "unsigned: nothing reached the service")
    }

    // MARK: Errors

    static func errors() {
        let item = ProviderItem(identifier: "asset|favorites|00000000-0000-0000-0000-000000000001", parent: "favorites",
                                name: "a.jpg", baseName: "a.jpg", isFolder: false)
        let rejected = FileProviderErrors.nsError(ProviderFailure.deletionRejected("Removing is off.", item: item))
        check(rejected.domain == NSFileProviderErrorDomain && rejected.code == NSFileProviderError.Code.deletionRejected.rawValue,
              "deletion rejected: \(rejected)")
        let restored = rejected.userInfo[NSFileProviderErrorItemKey] as? NSFileProviderItem
        check(restored?.itemIdentifier.rawValue == item.identifier && restored?.parentItemIdentifier.rawValue == "favorites",
              "carries the item to restore, as the SDK builds it: \(rejected.userInfo)")
        check(rejected.localizedDescription == "Removing is off.", "with the message: \(rejected.localizedDescription)")

        let identifier = NSFileProviderItemIdentifier("album:00000000-0000-0000-0000-000000000901")
        let missing = FileProviderErrors.nsError(ProviderFailure.noSuchItem, identifier: identifier)
        check(missing.domain == NSFileProviderErrorDomain && missing.code == NSFileProviderError.Code.noSuchItem.rawValue, "no such item")
        check(missing.userInfo[NSFileProviderErrorNonExistentItemIdentifierKey] as? String == identifier.rawValue,
              "names the missing item, as the SDK builds it: \(missing.userInfo)")
        check(FileProviderErrors.nsError(ImmichError.http(404, nil), identifier: identifier).userInfo[NSFileProviderErrorNonExistentItemIdentifierKey] != nil,
              "a server 404 too")

        let trash = FileProviderErrors.trashUnsupported
        check(trash.domain == NSCocoaErrorDomain && trash.code == NSFeatureUnsupportedError, "the trash container is unsupported")

        let mapped: [(Error, NSFileProviderError.Code)] = [
            (ImmichError.unauthorized(nil), .notAuthenticated), (URLError(.timedOut), .serverUnreachable),
            (ImmichError.http(429, nil), .serverUnreachable), (ImmichError.http(503, nil), .serverUnreachable),
            (ProviderFailure.syncAnchorExpired, .syncAnchorExpired), (ProviderFailure.directoryNotEmpty, .directoryNotEmpty),
            (ProviderFailure.excludedFromSync, .excludedFromSync), (ImmichError.http(400, "Bad"), .cannotSynchronize)]
        for (error, code) in mapped {
            let result = FileProviderErrors.nsError(error)
            check(result.domain == NSFileProviderErrorDomain && result.code == code.rawValue, "\(error) → \(code.rawValue): \(result)")
        }
        let cancelled = FileProviderErrors.nsError(CancellationError())
        check(cancelled.domain == NSCocoaErrorDomain && cancelled.code == NSUserCancelledError, "cancelled")
    }

    // MARK: Capabilities

    static func capabilities() {
        check(ProviderCapabilities.reading.rawValue == NSFileProviderItemCapabilities.allowsReading.rawValue, "reading")
        check(ProviderCapabilities.writing.rawValue == NSFileProviderItemCapabilities.allowsWriting.rawValue, "writing")
        check(ProviderCapabilities.reparenting.rawValue == NSFileProviderItemCapabilities.allowsReparenting.rawValue, "reparenting")
        check(ProviderCapabilities.renaming.rawValue == NSFileProviderItemCapabilities.allowsRenaming.rawValue, "renaming")
        check(ProviderCapabilities.deleting.rawValue == NSFileProviderItemCapabilities.allowsDeleting.rawValue, "deleting")
        // Never Finder's Trash: removals are deletions, with Immich's own meaning (see docs/FileProvider.md).
        let me = "11111111-1111-1111-1111-111111111111"
        let asset = RemoteAsset(id: "00000000-0000-0000-0000-000000000001", name: "a.jpg", ownerID: me, visibility: "timeline")
        let album = RemoteAlbum(id: "00000000-0000-0000-0000-000000000901", name: "A", owner: true, editable: true, assetCount: 1, signature: "s")
        let all = ProviderOptions(allowChanges: true, allowRemoving: true)
        let items = [ProviderRendering.asset(asset, in: .month(2024, 3), options: all, album: nil, userID: me),
                     ProviderRendering.asset(asset, in: .favorites, options: all, album: nil, userID: me),
                     ProviderRendering.asset(asset, in: .album(album.id), options: all, album: album, userID: me),
                     ProviderRendering.folder(.album(album.id), name: "A", options: all, album: album)]
        for item in items {
            let capabilities = FileProviderItem(item).capabilities
            check(capabilities.contains(.allowsDeleting), "\(item.identifier) can be removed with Allow Removing")
            check(!capabilities.contains(.allowsTrashing), "\(item.identifier) is never offered to Finder's Trash")
        }
    }

    // MARK: Names

    static func names() {
        let name = FinderAccess.displayName(account: " Ann/Bob ", host: "fe80::1")
        check(!name.contains("/") && !name.contains(":"), "no / or : in the location's name: \(name)")
        check(name == "Ann-Bob (fe80--1)", name)
        check(FinderAccess.displayName(account: ".\u{0}", host: "") == "()" || !FinderAccess.displayName(account: ".\u{0}", host: "").hasPrefix("."),
              "never hidden")
        check(FinderAccess.displayName(account: String(repeating: "a", count: 500), host: "h").count <= 120, "bounded length")
    }
}
