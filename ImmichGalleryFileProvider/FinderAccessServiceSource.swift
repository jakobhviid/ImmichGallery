import FileProvider
import Foundation
import Security

/// Receives the credential from the app. Restricted, so only reachable through `NSFileProviderManager.getService` by a
/// process that can manage this domain, and every connection must also come from the app's own bundle identifier signed
/// by the extension's own team: another process able to see the domain's files can't replace the credential or point
/// the domain somewhere else.
final class FinderAccessServiceSource: NSObject, NSFileProviderServiceSource, FinderAccessService, @unchecked Sendable {
    private weak var owner: FileProviderExtension?
    private var channel: FinderAccessListener!

    init(owner: FileProviderExtension) {
        self.owner = owner
        super.init()
        channel = FinderAccessListener(exporting: self, requirement: Self.appRequirement)
    }

    deinit { channel.invalidate() }

    var serviceName: NSFileProviderServiceName { NSFileProviderServiceName(FinderAccess.serviceName) }

    /// Only processes that can manage the domain (the app, through `NSFileProviderManager`) may reach the service.
    var isRestricted: Bool { true }

    /// Called again for every `getService`: the same, already running listener answers each time.
    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint { channel.endpoint }

    func setCredential(_ credential: Data, reply: @escaping @Sendable (NSError?) -> Void) {
        // Only API keys: Immich never lets them into the Locked Folder, unlike a session the app may have unlocked.
        guard let owner, FinderAccess.isDomainIdentifier(owner.domainID),
              FinderAccess.loadConfiguration(owner.domainID) != nil,
              case .apiKey? = try? JSONDecoder().decode(Credential.self, from: credential) else {
            reply(NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError))
            return
        }
        do {
            try FinderCredentialStore.save(credential, domain: owner.domainID)
            owner.credentialChanged()
            reply(nil)
        } catch {
            reply(error as NSError)
        }
    }

    func forgetCredential(reply: @escaping @Sendable (NSError?) -> Void) {
        guard let owner else { reply(nil); return }
        FinderCredentialStore.delete(owner.domainID)
        owner.credentialChanged()
        reply(nil)
    }

    /// `anchor apple generic and identifier "<app>" and certificate leaf[subject.OU] = "<team>"`, from this
    /// extension's own signature and Info.plist.
    static let appRequirement: String? = {
        guard let team = FinderAccess.signingTeam,
              let app = Bundle.main.object(forInfoDictionaryKey: "ImmichAppBundleIdentifier") as? String else { return nil }
        let safe = { (value: String) in !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") } }
        guard safe(team), safe(app) else { return nil }
        return "anchor apple generic and identifier \"\(app)\" and certificate leaf[subject.OU] = \"\(team)\""
    }()
}
