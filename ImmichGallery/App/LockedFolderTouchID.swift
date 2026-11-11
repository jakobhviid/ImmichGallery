import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI
import Security

/// Touch ID for the Locked Folder. Immich unlocks it only with the PIN, so the PIN is kept in the login keychain, as
/// the account's credential is, and used only after Touch ID succeeds. Adding or removing a fingerprint asks for the
/// PIN again, as Apple's "current fingerprints" keychain items do, and a PIN the server no longer takes is forgotten.
@MainActor
enum LockedFolderTouchID {
    /// Settings ▸ Security ▸ Unlock with Touch ID; on unless turned off.
    static let enabledKey = "lockedFolder.touchID"

    /// Touch ID is set up on this Mac.
    static var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    enum Outcome { case pin(String), cancelled, unavailable }

    /// The kept PINs are per server and user.
    static func key(server: URL, userID: String) -> String { server.absoluteString + "|" + userID }

    static func hasPIN(for key: String) -> Bool { read(key) != nil }

    /// Keeps the PIN that just unlocked the folder, with the fingerprints enrolled now.
    static func save(_ pin: String, for key: String) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
              let data = try? JSONEncoder().encode(Stored(pin: pin, fingerprints: context.domainState.biometry.stateHash)) else { return }
        forget(key)
        var item = query(key)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrLabel as String] = "Immich Gallery Locked Folder"
        SecItemAdd(item as CFDictionary, nil)
    }

    /// Asks for Touch ID, then gives the kept PIN. With the context of a Touch ID view on screen, the fingerprint is
    /// read in that view rather than in a system dialog.
    static func pin(for key: String, context: LAContext) async -> Outcome {
        guard let stored = read(key) else { return .unavailable }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return .unavailable }
        if let fingerprints = stored.fingerprints, context.domainState.biometry.stateHash != fingerprints {
            forget(key)
            return .unavailable
        }
        do {
            let reason = String(localized: "unlock the Locked Folder")
            return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) ? .pin(stored.pin) : .cancelled
        } catch {
            return .cancelled
        }
    }

    static func forget(_ key: String) { delete(query(key)) }

    /// Turning Touch ID off forgets every kept PIN.
    static func forgetAll() { delete(query(nil)) }

    private struct Stored: Codable {
        let pin: String
        let fingerprints: Data?
    }

    private static let service = (Bundle.main.bundleIdentifier ?? "ImmichGallery") + ".locked-folder"

    private static func query(_ key: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let key { query[kSecAttrAccount as String] = key }
        return query
    }

    private static func read(_ key: String) -> Stored? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    /// The file-based keychain deletes one match at a time.
    private static func delete(_ query: [String: Any]) {
        var deleted = 0
        while deleted < 64, SecItemDelete(query as CFDictionary) == errSecSuccess { deleted += 1 }
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
