import Foundation

// Crosslink: which link may still navigate, and the steps of showing what a link names, Foundation only, so
// Tests/CrosslinkNavigationChecks.swift runs them against a fake server, window and account.

/// One link at a time. A new link, and anything that moves away from what a link would show (the user choosing
/// another page or pushing and popping on it, the window closing, signing out, switching accounts), makes the links
/// before it stale: their tasks are cancelled and, after each wait, they stop silently, with no navigation, window
/// or alert. The app has one for links still looking for a window; each library window one for what it shows.
@MainActor
final class CrosslinkNavigation {
    struct Ticket: Equatable, Sendable {
        fileprivate let generation: Int
    }

    private var generation = 0
    private var tasks: [Task<Void, Never>] = []

    /// Starts a link, making every earlier one stale.
    func begin() -> Ticket {
        invalidate()
        return Ticket(generation: generation)
    }

    /// Makes every link so far stale and cancels its tasks.
    func invalidate() {
        generation += 1
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }

    func isCurrent(_ ticket: Ticket) -> Bool { ticket.generation == generation && !Task.isCancelled }

    /// Runs a link's waiting work, which a later link or `invalidate()` cancels.
    func run(_ ticket: Ticket, _ work: @escaping @MainActor () async -> Void) {
        guard isCurrent(ticket) else { return }
        tasks.append(Task { await work() })
    }
}

/// What a link may show of an asset by its visibility: never one in the Locked Folder, which is only ever shown inside
/// the folder's own unlocked session (`LockedFolderMedia`), not in a grid, the shared image cache or a window of its own.
enum CrosslinkVisibility {
    static func canShow(_ visibility: String?) -> Bool { visibility != "locked" }
}

/// What showing an asset a link names needs from a library window.
@MainActor
protocol CrosslinkAssetHost: AnyObject {
    associatedtype Asset
    /// The asset's record (no image).
    func asset(_ id: String) async throws -> Asset
    func visibility(of asset: Asset) -> String?
    /// Loads the grid the link names as far as the asset; true if the asset is in it.
    func loadForReveal(_ asset: Asset) async throws -> Bool
    /// Scrolls to the asset in the grid and opens it.
    func open(_ id: String)
    /// Shows the asset in a window of its own, as a desktop widget photo opens.
    func showAlone(_ id: String)
    func tell(_ message: String)
    /// The asset could not be fetched: the account cannot see it, or the request failed.
    func cannotShow(_ error: Error)
}

extension CrosslinkNavigation {
    /// Shows an asset a link names: in the grid it was seen in, or alone when it is not there. One in the Locked
    /// Folder is refused before anything of it is loaded or shown. A stale link stops after each wait.
    func reveal<Host: CrosslinkAssetHost>(_ id: String, ticket: Ticket, host: Host) async {
        let asset: Host.Asset
        do { asset = try await host.asset(id) } catch {
            if isCurrent(ticket) { host.cannotShow(error) }
            return
        }
        guard isCurrent(ticket) else { return }
        guard CrosslinkVisibility.canShow(host.visibility(of: asset)) else { return host.tell(Self.lockedMessage) }
        let inGrid: Bool
        do { inGrid = try await host.loadForReveal(asset) } catch {
            if isCurrent(ticket), !Self.isCancellation(error) { host.showAlone(id) }
            return
        }
        guard isCurrent(ticket) else { return }
        if inGrid { host.open(id) } else { host.showAlone(id) }
    }

    /// Fetches what a link names (a person) and shows it, unless the link went stale meanwhile.
    func fetchThenShow<Value>(_ ticket: Ticket, fetch: () async throws -> Value, show: (Value) -> Void,
                              failed: (Error) -> Void) async {
        do {
            let value = try await fetch()
            guard isCurrent(ticket) else { return }
            show(value)
        } catch {
            if isCurrent(ticket) { failed(error) }
        }
    }

    /// Hands a link to a library window: the frontmost when there is one, or a new one when none has appeared after
    /// `openAfter` tries. `deliver` is false while the window is still setting up its session; `wait` paces the
    /// tries. Gives up when the link goes stale (a newer link, or the account changed: `live`).
    func deliver(_ ticket: Ticket, tries: Int = 20, openAfter: Int = 4, live: () -> Bool,
                 deliver: () -> Bool, hasWindow: () -> Bool, openWindow: () -> Void, wait: () async -> Void) async {
        for attempt in 0..<tries {
            guard isCurrent(ticket), live() else { return }
            if deliver() { return }
            if attempt == openAfter && !hasWindow() { openWindow() }
            await wait()
        }
    }

    static var lockedMessage: String {
        String(localized: "This item is in the Locked Folder. Open it from the Locked Folder in Immich Gallery.")
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
