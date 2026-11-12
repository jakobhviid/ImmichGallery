import Foundation
import CryptoKit
import Security

/// Finder access (issue #23): what the app and its File Provider extension share. Compiled into both targets.
///
/// Each account shown in Finder is its own File Provider domain. The domain's identifier is derived from the account's
/// API address and user ID, so accounts never share a domain, a replica or a credential. Nothing secret is written
/// here: the extension keeps its credential in its own keychain item, handed over through `FinderAccessService`.
enum FinderAccess {
    /// The XPC service the extension offers on its root item, through which the app hands over the credential.
    static let serviceName = "dev.igol.ImmichGallery.finder-access.v1"

    static func domainIdentifier(apiURL: URL, userID: String) -> String {
        let digest = SHA256.hash(data: Data("\(apiURL.absoluteString)|\(userID)".utf8))
        return "account-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The location's name in Finder, which is also a folder name: no "/" or ":" (an IPv6 host has colons), no
    /// control characters, and not empty.
    static func displayName(account: String, host: String) -> String {
        let raw = "\(account.trimmingCharacters(in: .whitespacesAndNewlines)) (\(host))"
        let scalars = raw.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if CharacterSet.controlCharacters.contains(scalar) { return nil }
            return scalar == "/" || scalar == ":" ? "-" : scalar
        }
        var name = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 120 { name = String(name.prefix(120)) }
        return name.isEmpty ? "Immich" : name
    }

    /// Only identifiers this app makes, so a stray or hostile value can never name another folder.
    static func isDomainIdentifier(_ value: String) -> Bool {
        value.count == 40 && value.hasPrefix("account-") && value.dropFirst(8).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The team of this process's code signature; nil for unsigned and ad-hoc builds.
    static let signingTeam: String? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return team
    }()

    static let appGroup: String? = {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "ImmichAppGroup") as? String, !group.isEmpty else { return nil }
        return group
    }()

    /// `<App Group>/FileProvider`. Nil when the App Group is missing from the signature (unsigned builds).
    static var rootDirectory: URL? {
        guard let group = appGroup,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return container.appendingPathComponent("FileProvider", isDirectory: true)
    }

    static func directory(for domain: String) -> URL? {
        guard isDomainIdentifier(domain) else { return nil }
        return rootDirectory?.appendingPathComponent(domain, isDirectory: true)
    }

    static func configurationURL(for domain: String) -> URL? {
        directory(for: domain)?.appendingPathComponent("configuration.json")
    }

    static func storeDirectory(for domain: String) -> URL? {
        directory(for: domain)?.appendingPathComponent("Replica", isDirectory: true)
    }

    static func loadConfiguration(_ domain: String) -> FinderAccessConfiguration? {
        guard let url = configurationURL(for: domain), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FinderAccessConfiguration.self, from: data)
    }

    static func saveConfiguration(_ configuration: FinderAccessConfiguration, domain: String) throws {
        guard let directory = directory(for: domain), let url = configurationURL(for: domain) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(configuration).write(to: url, options: [.atomic])
    }

    /// Removes the domain's configuration and replica. The extension forgets its credential when it sees none.
    static func removeFiles(_ domain: String) throws {
        guard let directory = directory(for: domain) else { return }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}

/// Non-secret settings of one account's Finder location, written by the app and read by the extension.
struct FinderAccessConfiguration: Codable, Sendable, Equatable {
    var serverURL: URL
    var apiURL: URL
    var userID: String
    var userName: String
    var email: String
    /// Uploads, new albums, renaming albums, adding to albums and Favorites.
    var allowChanges: Bool
    /// Removing from albums and Favorites, moving Library photos to Immich's Trash and deleting album folders.
    var allowRemoving: Bool
    /// The server API key created for Finder, deleted when Finder access is turned off. Nil when the account itself
    /// signs in with an API key, which Finder then reuses and never deletes.
    var keyID: String?
    /// Set by Refresh in Settings: the next check lists every folder again even if nothing seems to have changed.
    var refreshRequested: Date?

    var accountID: String { apiURL.absoluteString + "|" + userID }
}

/// The extension's XPC service, reachable only through `NSFileProviderManager` for the app's own domain and accepted
/// only from the app's own code signature.
@objc(ImmichFinderAccessService) protocol FinderAccessService {
    /// A JSON-encoded `Credential` for this domain's account, kept in the extension's own keychain item.
    func setCredential(_ credential: Data, reply: @escaping @Sendable (NSError?) -> Void)
    /// Deletes the extension's keychain item for this domain.
    func forgetCredential(reply: @escaping @Sendable (NSError?) -> Void)
}
