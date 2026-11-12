import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI
import Security

/// Touch ID for the Locked Folder. Immich unlocks it only with the PIN, so the PIN is kept in the login keychain, as
/// the account's credential is, and given back only after the app's own Touch ID check succeeds. The keychain item
/// itself has no biometric protection: the guard is the app's check. A PIN is kept only with the fingerprints
/// enrolled at the time, and adding or removing a fingerprint, a PIN the server turns down, signing out or removing
/// the account, and turning the setting off forget it.
@MainActor
enum LockedFolderTouchID {
    /// Settings ▸ Security ▸ Unlock with Touch ID; on unless turned off.
    static let enabledKey = "lockedFolder.touchID"

    /// Replaced by the offline checks, which never reach the user's keychain.
    static var keychain = LockedFolderKeychain(service: (Bundle.main.bundleIdentifier ?? "ImmichGallery") + ".locked-folder")

    /// Bumped whenever kept PINs are forgotten, so an unlock that started before can't keep its PIN afterwards, and a
    /// fingerprint read before can't give back a PIN forgotten while it was read.
    private(set) static var epoch = 0

    /// Touch ID is set up on this Mac.
    static var isAvailable: Bool { LAContext().lockedFolderEnrollment != nil }

    enum Outcome { case pin(String), cancelled, unavailable, failed(String) }

    /// The kept PINs are per server and user; there's no key without a user.
    static func key(server: URL, userID: String?) -> String? {
        guard let userID, !userID.isEmpty else { return nil }
        return server.absoluteString + "|" + userID
    }

    static func hasPIN(for key: String?) -> Bool {
        guard let key else { return false }
        return ((try? keychain.read(key)) ?? nil) != nil
    }

    /// Keeps the PIN that just unlocked the folder, with the fingerprints enrolled now. Nothing is kept without
    /// enrolled fingerprints, or when PINs were forgotten since `epoch`. Throws when the keychain refuses it.
    @discardableResult
    static func save(_ pin: String, for key: String, context: any LockedFolderBiometry = LAContext(), since epoch: Int) throws -> Bool {
        guard epoch == self.epoch, let fingerprints = context.lockedFolderEnrollment else { return false }
        try keychain.write(JSONEncoder().encode(Stored(pin: pin, fingerprints: fingerprints)), for: key)
        return true
    }

    /// Asks for Touch ID, then gives the kept PIN. With the context of a Touch ID view on screen, the fingerprint is
    /// read in that view rather than in a system dialog. The PIN and the fingerprints are checked again after the
    /// finger is read.
    static func pin(for key: String, context: any LockedFolderBiometry) async -> Outcome {
        let epoch = self.epoch
        let stored: String
        do {
            guard let pin = try validPIN(key, context: context) else { return .unavailable }
            stored = pin
        } catch { return .failed(error.localizedDescription) }
        do {
            guard try await context.lockedFolderEvaluate(String(localized: "unlock the Locked Folder")) else { return .cancelled }
        } catch { return .cancelled }
        guard !Task.isCancelled else { return .cancelled }
        guard epoch == self.epoch else { return .unavailable }
        do {
            guard let pin = try validPIN(key, context: context), pin == stored else { return .unavailable }
            return .pin(pin)
        } catch { return .failed(error.localizedDescription) }
    }

    /// The server's answer to a wrong PIN: Immich's unlock replies 400 "Wrong PIN code", or 400 when the account has
    /// no PIN any more. 401 is the login, and timeouts, rate limits, server errors and offline keep the PIN.
    nonisolated static func rejectsPIN(_ error: any Error) -> Bool {
        if case ImmichError.http(400, _) = error { return true }
        return false
    }

    static func forget(_ key: String) throws {
        epoch += 1
        try keychain.delete(key)
    }

    /// Signing out or removing an account forgets its PIN, and only its.
    static func forget(server: URL, userID: String?) throws {
        guard let key = key(server: server, userID: userID) else { return }
        try forget(key)
    }

    /// Turning Touch ID off or on forgets every kept PIN.
    static func forgetAll() throws {
        epoch += 1
        try keychain.delete(nil)
    }

    private struct Stored: Codable {
        let pin: String
        /// Missing in PINs kept by the first version, which are never used.
        let fingerprints: Data?
    }

    /// The kept PIN, if it was kept with the fingerprints enrolled now. One kept without them, with others, or
    /// unreadable is forgotten. Without Touch ID usable now, there's no PIN, but it stays for later.
    private static func validPIN(_ key: String, context: any LockedFolderBiometry) throws -> String? {
        guard let data = try keychain.read(key), let current = context.lockedFolderEnrollment else { return nil }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.fingerprints == current else {
            // A failed deletion must be reported as well as refusing the invalid PIN.
            try forget(key)
            return nil
        }
        return stored.pin
    }
}

/// The few keychain calls the kept PINs need. The offline checks replace the Security functions.
struct LockedFolderKeychain {
    let service: String
    var copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
    var update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate
    var remove: (CFDictionary) -> OSStatus = SecItemDelete

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { String(localized: "The keychain couldn't handle the Locked Folder PIN for Touch ID (\(String(status))).") }
    }

    private func query(_ account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    /// nil when nothing is kept for the account.
    func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return data
    }

    /// Replaces the kept item in place, or adds it; a failure leaves the previous one as it was.
    func write(_ data: Data, for account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                         kSecAttrLabel as String: "Immich Gallery Locked Folder"]
        var status = update(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = add(query(account).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    /// Deletes the account's item, or every item, until none is left: the file-based keychain deletes one match at a
    /// time. Nothing to delete is success.
    func delete(_ account: String?) throws {
        while true {
            let status = remove(query(account) as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw Failure(status: status) }
        }
    }
}

/// Touch ID as the kept PINs use it; an `LAContext`, or a stand-in in the offline checks.
@MainActor
protocol LockedFolderBiometry: AnyObject {
    /// The enrolled fingerprints, nil when Touch ID can't be used now.
    var lockedFolderEnrollment: Data? { get }
    func lockedFolderEvaluate(_ reason: String) async throws -> Bool
}

extension LAContext: LockedFolderBiometry {
    var lockedFolderEnrollment: Data? {
        var error: NSError?
        guard canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return nil }
        return domainState.biometry.stateHash
    }

    func lockedFolderEvaluate(_ reason: String) async throws -> Bool {
        try await evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
    }
}

/// The Touch ID fingerprint in the page, which reads the finger for its context instead of a system dialog.
struct LockedFolderTouchIDView: NSViewRepresentable {
    let context: LAContext

    func makeNSView(context: Context) -> LAAuthenticationView {
        LAAuthenticationView(context: self.context, controlSize: .large)
    }

    func updateNSView(_ view: LAAuthenticationView, context: Context) {}
}
