#!/usr/bin/env python3
"""Run the real Locked Folder unlock against a fake server, without an app, keychain or real server.

Covers discarded attempts: a successful answer arriving after the view's task was cancelled, an unlock request
cancelled in flight after it reached the server, the ordering of a new unlock after such a relock, and that a
current attempt's error is still reported without a relock.
"""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
source = (repo / "ImmichGallery/Views/Explore/ExploreLockedView.swift").read_text().replace("    private ", "    ")


def member(signature):
    start = source.index(signature)
    start = source.rindex("\n", 0, start) + 1
    brace = source.index("{", start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def line(text):
    start = source.index(text)
    return source[source.rindex("\n", 0, start) + 1:source.index("\n", start)]


members = "\n".join([
    member("func unlock(_ code: String, viaTouchID: Bool) async"),
    member("func isCurrent(_ attempt: UUID, _ services: AccountServices) -> Bool"),
    member("static func uncached<T>("),
    line("static var discardedRelocks"),
    member("static func relockDiscarded(_ account: ImmichClient)"),
    # The view is a struct; the harness is a class, whose escaping closures name self explicitly.
]).replace("{ Task { await verify() } }", "{ Task { await self.verify() } }")

harness = r'''import Foundation
import Synchronization

/// The fake server. `auth/session/unlock` can be held open until the client cancels it; `auth/session/lock` can be
/// held until released. Every request's path is logged in arrival order.
final class FakeServer: URLProtocol, @unchecked Sendable {
    struct State {
        var log: [String] = []
        var cancelled: [String] = []
        var holdUnlock = false
        var holdLock = false
        var unlockStatus = 200
        var heldLocks: [FakeServer] = []
        var heldUnlocks: [FakeServer] = []
    }
    static let state = Mutex(State())
    static func snapshot() -> State { state.withLock { $0 } }
    static func update(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
    private let finished = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {
        let open = finished.withLock { done in defer { done = true }; return !done }
        if open { Self.update { $0.cancelled.append(self.request.url!.path) } }
    }
    override func startLoading() {
        let path = request.url!.path
        let hold = Self.state.withLock { state -> Bool in
            state.log.append(path)
            if path.hasSuffix("/auth/session/unlock"), state.holdUnlock { state.heldUnlocks.append(self); return true }
            if path.hasSuffix("/auth/session/lock"), state.holdLock { state.heldLocks.append(self); return true }
            return false
        }
        if hold { return }
        if path.hasSuffix("/auth/session/unlock") { respond(Self.snapshot().unlockStatus, "{}") }
        else if path.hasSuffix("/auth/status") { respond(200, #"{"pinCode":true,"isElevated":true,"password":true}"#) }
        else { respond(200, "{}") }
    }
    func respond(_ code: Int, _ body: String) {
        guard finished.withLock({ done in defer { done = true }; return !done }) else { return }
        client!.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: Data(body.utf8))
        client!.urlProtocolDidFinishLoading(self)
    }
    static func releaseLocks() {
        let held = state.withLock { state in defer { state.heldLocks = []; state.holdLock = false }; return state.heldLocks }
        held.forEach { $0.respond(200, "{}") }
    }
    static func releaseUnlocks() {
        let held = state.withLock { state in defer { state.heldUnlocks = []; state.holdUnlock = false }; return state.heldUnlocks }
        held.forEach { $0.respond(200, "{}") }
    }
    static func count(_ suffix: String) -> Int { snapshot().log.filter { $0.hasSuffix(suffix) }.count }
}

enum ImmichError: Error { case http(Int, String?) }
struct ExploreAuthStatus: Decodable, Sendable {
    let pinCode: Bool
    let isElevated: Bool
    let password: Bool
    var pinExpiresAt: String?
}

/// The request plumbing of `ImmichClient`, over a URL session that reaches only the fake server.
final class ImmichClient: Sendable {
    let serverURL = URL(string: "https://fixture.invalid")!
    let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeServer.self]
        session = URLSession(configuration: configuration)
    }
    func explorePrivateClient() -> ImmichClient { ImmichClient() }
    func send(_ method: String, _ path: String) async throws -> Data {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/" + path))
        request.httpMethod = method
        let (data, response) = try await session.data(for: request)
        let code = (response as! HTTPURLResponse).statusCode
        guard (200..<300).contains(code) else { throw ImmichError.http(code, nil) }
        return data
    }
    func exploreUnlock(_ pin: String, setup: Bool) async throws { _ = try await send("POST", "auth/session/unlock") }
    func exploreAuth() async throws -> ExploreAuthStatus { try JSONDecoder().decode(ExploreAuthStatus.self, from: try await send("GET", "auth/status")) }
    func exploreLock() async throws { _ = try await send("POST", "auth/session/lock") }
}

final class AccountServices {}
final class LockedFolderMedia {
    var onRequestFailed: () -> Void = {}
    init(account: ImmichClient) {}
}
final class LibrarySession {
    init(services: AccountServices, lockedFolder: LockedFolderMedia) {}
}
struct Session { var client = ImmichClient(); var services = AccountServices() }
@MainActor enum LockedFolderTouchID {
    static var epoch = 0
    nonisolated static func rejectsPIN(_ error: any Error) -> Bool { if case ImmichError.http(400, _) = error { true } else { false } }
    static func forget(_ key: String) throws {}
    static func save(_ pin: String, for key: String, since epoch: Int) throws {}
}
enum NSApp { static let isActive = true }

@MainActor final class LockedView {
    var session = Session()
    var status: ExploreAuthStatus? = ExploreAuthStatus(pinCode: true, isElevated: false, password: true)
    var unlocked: LibrarySession?
    var pin = "123456"
    var confirmation = ""
    var error: String?
    var busy = false
    var generation = UUID()
    var touchIDEnabled = false
    var touchIDKey: String? = nil
    func scheduleCheck(_ expiry: String?) {}
    func startInactivityTimer() {}
    func verify() async {}
    /// What `lock()` does to an attempt that hasn't unlocked yet.
    func lock() { generation = UUID() }
__MEMBERS__
}

@MainActor func eventually(_ what: String, _ condition: () -> Bool) async throws {
    for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    precondition(condition(), what)
}

@main struct Check {
    @MainActor static func main() async throws {
        // 1. The server's answer arrives after Lock cancelled the view's task: exactly one relock, no late unlock.
        let view = LockedView()
        FakeServer.update { $0.holdUnlock = true }
        let late = Task { await view.unlock("123456", viaTouchID: true) }
        try await eventually("The unlock must reach the server") { FakeServer.count("/unlock") == 1 }
        view.lock()
        late.cancel()
        await late.value
        try await eventually("A cancelled in-flight unlock must be relocked") { FakeServer.count("/lock") == 1 }
        let first = FakeServer.snapshot()
        precondition(first.cancelled.contains { $0.hasSuffix("/unlock") }, "The unlock's response must have been cancelled in flight")
        precondition(first.log.firstIndex { $0.hasSuffix("/lock") }! > first.log.firstIndex { $0.hasSuffix("/unlock") }!)
        precondition(view.unlocked == nil && view.error == nil && !view.busy, "A discarded attempt neither unlocks nor reports its cancellation")
        try await Task.sleep(for: .milliseconds(100))
        precondition(FakeServer.count("/lock") == 1 && FakeServer.count("/status") == 0 && view.unlocked == nil, "No second relock and no late unlock")
        print("PASS unlock cancelled in flight relocks once, with no late unlock")

        // 2. A new unlock started while that kind of relock is still being sent waits for it, so the relock can't
        //    lock the new session.
        FakeServer.update { $0 = FakeServer.State(); $0.holdUnlock = true; $0.holdLock = true }
        let discarded = Task { await view.unlock("123456", viaTouchID: true) }
        try await eventually("The second unlock must reach the server") { FakeServer.count("/unlock") == 1 }
        view.lock()
        discarded.cancel()
        await discarded.value
        try await eventually("The relock must reach the server") { FakeServer.count("/lock") == 1 }
        FakeServer.update { $0.holdUnlock = false }
        let fresh = Task { await view.unlock("123456", viaTouchID: false) }
        try await Task.sleep(for: .milliseconds(100))
        precondition(FakeServer.count("/unlock") == 1, "A new unlock must not reach the server before the pending relock finishes")
        FakeServer.releaseLocks()
        await fresh.value
        let ordered = FakeServer.snapshot().log.map { String($0.split(separator: "/").suffix(2).joined(separator: "/")) }
        precondition(ordered == ["session/unlock", "session/lock", "session/unlock", "auth/status"], "Order: \(ordered)")
        precondition(view.unlocked != nil && view.error == nil, "The new unlock must complete")
        try await Task.sleep(for: .milliseconds(100))
        precondition(FakeServer.count("/lock") == 1, "Nothing relocks the new unlock")
        print("PASS a new unlock waits for the discarded attempt's relock and stays unlocked")

        // 3. The server unlocks, but the attempt was discarded meanwhile: the relock still reaches the server, and
        //    a relock started from an already-cancelled task is still sent.
        let discardedSuccess = LockedView()
        FakeServer.update { $0 = FakeServer.State(); $0.holdUnlock = true }
        let answered = Task { await discardedSuccess.unlock("123456", viaTouchID: true) }
        try await eventually("The unlock must reach the server") { FakeServer.count("/unlock") == 1 }
        discardedSuccess.lock()
        FakeServer.releaseUnlocks()
        await answered.value
        try await eventually("A discarded successful unlock must be relocked") { FakeServer.count("/lock") == 1 }
        precondition(discardedSuccess.unlocked == nil && discardedSuccess.error == nil, "No late unlock after a discarded success")
        let account = ImmichClient()
        let cancelledParent = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            precondition(Task.isCancelled)
            LockedView.relockDiscarded(account)
        }
        await cancelledParent.value
        try await eventually("A relock from a cancelled task must reach the server") { FakeServer.count("/lock") == 2 }
        print("PASS discarded successful unlock relocks, also from a cancelled task")

        // 4. A current attempt the server turns down reports its error and sends no relock.
        let current = LockedView()
        FakeServer.update { $0 = FakeServer.State(); $0.unlockStatus = 400 }
        await current.unlock("000000", viaTouchID: false)
        try await Task.sleep(for: .milliseconds(100))
        precondition(current.error != nil && current.unlocked == nil && FakeServer.count("/lock") == 0, "Wrong PIN: error, no relock")
        print("PASS a current wrong-PIN attempt reports its error without a relock")
    }
}
'''.replace("__MEMBERS__", members)

(repo / "build").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="locked-folder-discard-", dir=repo / "build") as directory:
    swift = Path(directory) / "main.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=60)
