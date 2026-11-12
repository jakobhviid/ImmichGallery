import Foundation
import Synchronization

/// The anonymous XPC listener behind `FinderAccessServiceSource`. The system may ask for the endpoint any number of
/// times (each `NSFileProviderManager.getService` call); the listener is resumed exactly once, since resuming a
/// running `NSXPCListener` again traps, and every request gets the same endpoint.
///
/// Every connection must satisfy `requirement` (checked by XPC itself on each message); without one, nothing is
/// accepted. Kept free of the FileProvider framework so `Tests/FileProviderFrameworkChecks.swift` exercises it over
/// real XPC.
final class FinderAccessListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener = NSXPCListener.anonymous()
    private let resumed = Mutex(false)
    private let requirement: String?
    /// Weak: the exported service owns this listener.
    private weak var exported: (any FinderAccessService & NSObject)?

    init(exporting service: any FinderAccessService & NSObject, requirement: String?) {
        self.exported = service
        self.requirement = requirement
        super.init()
        listener.delegate = self
    }

    var endpoint: NSXPCListenerEndpoint {
        let resume = resumed.withLock { done in defer { done = true }; return !done }
        if resume { listener.resume() }
        return listener.endpoint
    }

    func invalidate() { listener.invalidate() }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Unsigned or ad-hoc builds have no team, hence no requirement: nothing is accepted.
        guard let requirement, let exported else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: FinderAccessService.self)
        connection.exportedObject = exported
        connection.resume()
        return true
    }
}
