import FileProvider
import Foundation

/// `ProviderFailure` as the FileProvider framework expects it. Errors the SDK has constructors for are built with them,
/// so they carry the user info the system relies on (the item to restore after a rejected deletion, the identifier
/// that doesn't exist). Checked by `Tests/FileProviderFrameworkChecks.swift`.
enum FileProviderErrors {
    /// The domain doesn't sync Finder's Trash (`supportsSyncingTrash = false`), so its trash container has no
    /// enumerator. Cocoa's "feature unsupported" is what the system expects for that.
    static var trashUnsupported: NSError { NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError) }

    /// - Parameter identifier: the item the failing call was about, named by a "no such item" error.
    static func nsError(_ underlying: Error, identifier: NSFileProviderItemIdentifier? = nil) -> NSError {
        let failure = (underlying as? ProviderFailure) ?? (ProviderEngine.failure(underlying) as? ProviderFailure) ?? .serverUnreachable
        func error(_ code: NSFileProviderError.Code, _ message: String? = nil) -> NSError {
            NSError(domain: NSFileProviderErrorDomain, code: code.rawValue,
                    userInfo: message.map { [NSLocalizedDescriptionKey: $0] } ?? [:])
        }
        switch failure {
        case .notAuthenticated:
            return error(.notAuthenticated, String(localized: "Open Immich Gallery and turn on Finder access again in Settings ▸ Finder."))
        case .serverUnreachable: return error(.serverUnreachable)
        case .noSuchItem:
            guard let identifier else { return error(.noSuchItem) }
            return NSError.fileProviderErrorForNonExistentItem(withIdentifier: identifier)
        case .cancelled: return CocoaError(.userCancelled) as NSError
        case .deletionRejected(let message, let item):
            // The system restores the item from the error's item; without one it has only its own metadata.
            guard let item else { return error(.deletionRejected, message) }
            return described(NSError.fileProviderErrorForRejectedDeletion(of: FileProviderItem(item)), message)
        case .directoryNotEmpty: return error(.directoryNotEmpty)
        case .cannotSynchronize(let message): return error(.cannotSynchronize, message)
        case .excludedFromSync: return error(.excludedFromSync)
        case .syncAnchorExpired: return error(.syncAnchorExpired)
        case .pageExpired: return error(.pageExpired)
        }
    }

    /// The SDK's error with the message shown to the user added, keeping the SDK's own user info.
    private static func described(_ error: NSError, _ message: String) -> NSError {
        var info = error.userInfo
        info[NSLocalizedDescriptionKey] = message
        return NSError(domain: error.domain, code: error.code, userInfo: info)
    }
}
