import Foundation
import Security

/// Run by scripts/check-integration.py. The real LockedFolderTouchID and LockedFolderKeychain code runs against an
/// in-memory stand-in for the Security functions and a stand-in for Touch ID: no keychain, sensor or server is used.
final class FakeKeychain: @unchecked Sendable {
    var items: [String: Data] = [:]
    var failRead: OSStatus?, failAdd: OSStatus?, failUpdate: OSStatus?, failDelete: OSStatus?
    var adds = 0, updates = 0, deletes = 0

    private static func account(_ query: CFDictionary) -> String? {
        let query = query as NSDictionary as! [String: Any]
        precondition(query[kSecAttrService as String] as? String == "test.locked-folder")
        return query[kSecAttrAccount as String] as? String
    }

    var keychain: LockedFolderKeychain {
        var keychain = LockedFolderKeychain(service: "test.locked-folder")
        keychain.copyMatching = { query, result in
            if let status = self.failRead { return status }
            guard let account = Self.account(query), let data = self.items[account] else { return errSecItemNotFound }
            result?.pointee = data as CFData
            return errSecSuccess
        }
        keychain.add = { item, _ in
            self.adds += 1
            if let status = self.failAdd { return status }
            let item = item as NSDictionary as! [String: Any]
            let account = item[kSecAttrAccount as String] as! String
            guard self.items[account] == nil else { return errSecDuplicateItem }
            self.items[account] = (item[kSecValueData as String] as! Data)
            return errSecSuccess
        }
        keychain.update = { query, attributes in
            self.updates += 1
            if let status = self.failUpdate { return status }
            guard let account = Self.account(query), self.items[account] != nil else { return errSecItemNotFound }
            self.items[account] = ((attributes as NSDictionary)[kSecValueData as String] as! Data)
            return errSecSuccess
        }
        // Like the file-based keychain: one match per call.
        keychain.remove = { query in
            self.deletes += 1
            if let status = self.failDelete { return status }
            let account = Self.account(query)
            guard let match = self.items.keys.sorted().first(where: { account == nil || $0 == account }) else { return errSecItemNotFound }
            self.items[match] = nil
            return errSecSuccess
        }
        return keychain
    }
}

@MainActor
final class FakeBiometry: LockedFolderBiometry {
    var enrollment: Data?
    var evaluate: @MainActor () async throws -> Bool = { true }
    var evaluations = 0
    init(_ enrollment: Data?) { self.enrollment = enrollment }
    var lockedFolderEnrollment: Data? { enrollment }
    func lockedFolderEvaluate(_ reason: String) async throws -> Bool { evaluations += 1; return try await evaluate() }
}

final class UnlockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var offline = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.offline { client!.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: Self.body)
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Unlike precondition, takes values already awaited.
func expect(_ condition: Bool, _ message: String = "", line: Int = #line) {
    if !condition { fatalError("Check failed at line \(line) \(message)") }
}

@main
struct LockedFolderTouchIDChecks {
    @MainActor static func main() async throws {
        let fake = FakeKeychain()
        LockedFolderTouchID.keychain = fake.keychain
        let server = URL(string: "https://photos.example.invalid")!
        let key = LockedFolderTouchID.key(server: server, userID: "user-a")!
        let enrolled = Data("fingers-1".utf8), other = Data("fingers-2".utf8)
        func pin(_ biometry: FakeBiometry, _ key: String = key) async -> LockedFolderTouchID.Outcome {
            await LockedFolderTouchID.pin(for: key, context: biometry)
        }
        func isPIN(_ outcome: LockedFolderTouchID.Outcome, _ expected: String) -> Bool {
            if case .pin(let value) = outcome { return value == expected }
            return false
        }
        func isUnavailable(_ outcome: LockedFolderTouchID.Outcome) -> Bool {
            if case .unavailable = outcome { return true }
            return false
        }

        // Identity: no key without a user.
        expect(LockedFolderTouchID.key(server: server, userID: "") == nil)
        expect(LockedFolderTouchID.key(server: server, userID: nil) == nil)
        expect(!LockedFolderTouchID.hasPIN(for: nil))

        // Enrollment is required to keep a PIN.
        expect(try !LockedFolderTouchID.save("111111", for: key, context: FakeBiometry(nil), since: LockedFolderTouchID.epoch))
        expect(fake.items.isEmpty && fake.adds == 0)
        expect(try LockedFolderTouchID.save("111111", for: key, context: FakeBiometry(enrolled), since: LockedFolderTouchID.epoch))
        expect(fake.adds == 1 && LockedFolderTouchID.hasPIN(for: key))
        expect(isPIN(await pin(FakeBiometry(enrolled)), "111111"))

        // Updated in place, never deleted first.
        let deletesBefore = fake.deletes
        expect(try LockedFolderTouchID.save("222222", for: key, context: FakeBiometry(enrolled), since: LockedFolderTouchID.epoch))
        expect(fake.adds == 1 && fake.updates == 2 && fake.deletes == deletesBefore)
        expect(isPIN(await pin(FakeBiometry(enrolled)), "222222"))

        // A failed update keeps the previous PIN and is reported; a failed add is reported.
        fake.failUpdate = errSecInteractionNotAllowed
        do { try LockedFolderTouchID.save("333333", for: key, context: FakeBiometry(enrolled), since: LockedFolderTouchID.epoch); preconditionFailure() }
        catch let error as LockedFolderKeychain.Failure { expect(error.status == errSecInteractionNotAllowed && error.errorDescription != nil) }
        fake.failUpdate = nil
        expect(isPIN(await pin(FakeBiometry(enrolled)), "222222"))
        let otherKey = LockedFolderTouchID.key(server: server, userID: "user-b")!
        fake.failAdd = errSecDiskFull
        do { try LockedFolderTouchID.save("444444", for: otherKey, context: FakeBiometry(enrolled), since: LockedFolderTouchID.epoch); preconditionFailure() }
        catch let error as LockedFolderKeychain.Failure { expect(error.status == errSecDiskFull) }
        fake.failAdd = nil
        expect(!LockedFolderTouchID.hasPIN(for: otherKey))

        // Read errors are not "nothing kept": no PIN is given, and the error is told.
        fake.failRead = errSecAuthFailed
        expect(!LockedFolderTouchID.hasPIN(for: key))
        if case .failed = await pin(FakeBiometry(enrolled)) {} else { preconditionFailure() }
        fake.failRead = nil
        expect(fake.items[key] != nil)
        expect(isUnavailable(await pin(FakeBiometry(enrolled), "https://photos.example.invalid|nobody")))

        // Touch ID unusable now: no PIN, no reading, and the PIN stays for later.
        let unusable = FakeBiometry(nil)
        expect(isUnavailable(await pin(unusable)) && unusable.evaluations == 0 && fake.items[key] != nil)

        // Other fingerprints: forgotten, never given.
        let changed = FakeBiometry(other)
        expect(isUnavailable(await pin(changed)) && changed.evaluations == 0 && fake.items[key] == nil)

        // A PIN kept by the first version, without fingerprints, or unreadable: forgotten, never given.
        fake.items[key] = try JSONSerialization.data(withJSONObject: ["pin": "555555"])
        expect(isUnavailable(await pin(FakeBiometry(enrolled))) && fake.items[key] == nil)
        fake.items[key] = Data("not json".utf8)
        expect(isUnavailable(await pin(FakeBiometry(enrolled))) && fake.items[key] == nil)
        // Invalid secrets remain unusable, but a failed deletion is reported for every invalid record kind.
        fake.failDelete = errSecInteractionNotAllowed
        for data in [try JSONSerialization.data(withJSONObject: ["pin": "555555"]), Data("not json".utf8),
                     try JSONSerialization.data(withJSONObject: ["pin": "555555", "fingerprints": other.base64EncodedString()])] {
            fake.items[key] = data
            let context = FakeBiometry(enrolled)
            if case .failed(let message) = await pin(context) { expect(!message.isEmpty) } else { preconditionFailure() }
            expect(fake.items[key] == data && context.evaluations == 0)
        }
        fake.failDelete = nil
        fake.items[key] = nil

        // Cancelled, failed or refused Touch ID gives nothing.
        _ = try LockedFolderTouchID.save("666666", for: key, context: FakeBiometry(enrolled), since: LockedFolderTouchID.epoch)
        let refused = FakeBiometry(enrolled)
        refused.evaluate = { false }
        if case .cancelled = await pin(refused) {} else { preconditionFailure() }
        refused.evaluate = { throw CancellationError() }
        if case .cancelled = await pin(refused) {} else { preconditionFailure() }

        // Fingerprints changed while the finger was read.
        let racing = FakeBiometry(enrolled)
        racing.evaluate = { racing.enrollment = other; return true }
        expect(isUnavailable(await pin(racing)) && fake.items[key] == nil)

        // Touch ID turned off while the finger was read, with a delay: the PIN is not given.
        _ = try LockedFolderTouchID.save("777777", for: key, context: FakeBiometry(enrolled), since: LockedFolderTouchID.epoch)
        let slow = FakeBiometry(enrolled)
        slow.evaluate = { try await Task.sleep(for: .milliseconds(50)); return true }
        let delayed = Task { await pin(slow) }
        try await Task.sleep(for: .milliseconds(10))
        try LockedFolderTouchID.forgetAll()
        expect(isUnavailable(await delayed.value))

        // Forgotten and the same PIN kept again while the finger was read: still not given, the read predates it.
        _ = try LockedFolderTouchID.save("777777", for: key, context: FakeBiometry(enrolled), since: LockedFolderTouchID.epoch)
        let forgotten = FakeBiometry(enrolled)
        forgotten.evaluate = {
            try LockedFolderTouchID.forget(key)
            _ = try LockedFolderTouchID.save("777777", for: key, context: FakeBiometry(enrolled), since: LockedFolderTouchID.epoch)
            return true
        }
        expect(isUnavailable(await pin(forgotten)))

        // The reading task cancelled: nothing given.
        let cancelled = Task { await pin(slow) }
        cancelled.cancel()
        if case .cancelled = await cancelled.value {} else { preconditionFailure() }

        // An unlock that started before Touch ID was turned off, an account was signed out or a PIN was forgotten
        // doesn't keep its PIN when it finishes, after a delay.
        try LockedFolderTouchID.forgetAll()
        let started = LockedFolderTouchID.epoch
        try await Task.sleep(for: .milliseconds(10))
        try LockedFolderTouchID.forget(server: server, userID: "user-a")
        expect(try !LockedFolderTouchID.save("999999", for: key, context: FakeBiometry(enrolled), since: started))
        expect(fake.items.isEmpty)

        // Signing out or removing an account forgets its PIN only.
        for user in ["user-a", "user-b"] {
            _ = try LockedFolderTouchID.save("121212", for: LockedFolderTouchID.key(server: server, userID: user)!, context: FakeBiometry(enrolled), since: LockedFolderTouchID.epoch)
        }
        let otherServer = LockedFolderTouchID.key(server: URL(string: "https://other.example.invalid")!, userID: "user-a")!
        _ = try LockedFolderTouchID.save("343434", for: otherServer, context: FakeBiometry(enrolled), since: LockedFolderTouchID.epoch)
        try LockedFolderTouchID.forget(server: server, userID: "user-a")
        expect(fake.items[key] == nil && fake.items[otherKey] != nil && fake.items[otherServer] != nil)
        let count = fake.items.count
        try LockedFolderTouchID.forget(server: server, userID: "")
        try LockedFolderTouchID.forget(server: server, userID: nil)
        expect(fake.items.count == count)
        // Nothing to forget is fine; a failure is reported and the PIN stays.
        try LockedFolderTouchID.forget(server: server, userID: "user-a")
        fake.failDelete = errSecInteractionNotAllowed
        do { try LockedFolderTouchID.forget(server: server, userID: "user-b"); preconditionFailure() } catch is LockedFolderKeychain.Failure {}
        do { try LockedFolderTouchID.forgetAll(); preconditionFailure() } catch is LockedFolderKeychain.Failure {}
        fake.failDelete = nil
        expect(fake.items[otherKey] != nil)

        // Turning Touch ID off forgets every PIN, however many.
        for index in 0..<150 { fake.items["https://photos.example.invalid|user-\(index)"] = Data() }
        try LockedFolderTouchID.forgetAll()
        expect(fake.items.isEmpty)

        // Only Immich's wrong-PIN answer forgets the kept PIN. Contract: server/src/services/auth.service.ts,
        // validatePinCode throws BadRequestException('Wrong PIN code') for POST /api/auth/session/unlock.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnlockProtocol.self]
        let client = ImmichClient(serverURL: server, apiURL: server.appending(path: "api"), credential: .accessToken("test"),
                                  session: URLSession(configuration: config))
        func unlockError(_ status: Int, _ message: String, offline: Bool = false) async -> any Error {
            UnlockProtocol.status = status
            UnlockProtocol.offline = offline
            UnlockProtocol.body = try! JSONSerialization.data(withJSONObject: ["message": message, "error": "x", "statusCode": status])
            do { try await client.exploreUnlock("123456", setup: false); preconditionFailure() } catch { return error }
        }
        expect(LockedFolderTouchID.rejectsPIN(await unlockError(400, "Wrong PIN code")))
        expect(LockedFolderTouchID.rejectsPIN(await unlockError(400, "User does not have a PIN code")))
        for status in [401, 403, 404, 408, 429, 500, 502, 503] {
            expect(!LockedFolderTouchID.rejectsPIN(await unlockError(status, "Other")), "\(status)")
        }
        expect(!LockedFolderTouchID.rejectsPIN(await unlockError(400, "", offline: true)))
        expect(!LockedFolderTouchID.rejectsPIN(CancellationError()))
        print("LockedFolderTouchID checks passed")
    }
}
