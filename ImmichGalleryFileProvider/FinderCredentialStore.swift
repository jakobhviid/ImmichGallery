import Foundation
import Security

/// The extension's own keychain items, one per domain. Without a provisioning profile the app and the extension can't
/// share a keychain item, so the app hands the credential over through `FinderAccessService` and only the extension,
/// which created the item, can read it.
enum FinderCredentialStore {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "ImmichGalleryFileProvider") + ".credentials" }

    private static func query(_ domain: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: domain]
    }

    static func load(_ domain: String) -> Data? {
        var query = query(domain)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ data: Data, domain: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                                         kSecAttrLabel as String: "Immich Gallery Finder access"]
        var status = SecItemUpdate(query(domain) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(domain).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func delete(_ domain: String) {
        SecItemDelete(query(domain) as CFDictionary)
    }

    /// Forgets credentials of domains the app has removed (their configuration is gone). Skipped when the App Group
    /// can't be read, so a missing container never wipes working credentials.
    static func pruneOrphans() {
        guard let root = FinderAccess.rootDirectory, FileManager.default.fileExists(atPath: root.path) else { return }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        query.removeAll()
        for account in items.compactMap({ $0[kSecAttrAccount as String] as? String })
        where FinderAccess.configurationURL(for: account).map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
            delete(account)
        }
    }
}
