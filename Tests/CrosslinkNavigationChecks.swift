import Foundation

/// Crosslink: what a received link may still do, against a fake server and window. Locked Folder assets are refused
/// before anything of them is loaded or shown; a stale link (a newer link, the user moving on, the window closing,
/// another account) stops silently after each wait: no navigation, window or alert.
@main struct CrosslinkNavigationChecks {
    @MainActor static func main() async {
        await lockedAssetIsRefused()
        await assetShowsInGridOrAlone()
        await slowLinkLosesToFastLink()
        await userNavigationAndLogoutDropLink()
        await personFetchGoesStale()
        await windowDelivery()
        if failures > 0 { print("\(failures) crosslink navigation checks failed"); exit(1) }
        print("Crosslink navigation checks passed")
    }

    nonisolated(unsafe) static var failures = 0
    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAILED: \(message)") }
    }

    /// Lets started tasks run until they wait.
    @MainActor static func settle() async { for _ in 0..<50 { await Task.yield() } }

    @MainActor static func lockedAssetIsRefused() async {
        let navigation = CrosslinkNavigation()
        let host = FakeWindow(visibility: "locked")
        let ticket = navigation.begin()
        await navigation.reveal("a", ticket: ticket, host: host)
        check(host.messages == [CrosslinkNavigation.lockedMessage], "locked: refused with a message \(host.messages)")
        check(host.gridLoads == 0, "locked: no grid or image loaded")
        check(host.events.isEmpty, "locked: not opened, no window of its own: \(host.events)")
        check(!CrosslinkVisibility.canShow("locked") && CrosslinkVisibility.canShow("timeline")
              && CrosslinkVisibility.canShow("archive") && CrosslinkVisibility.canShow(nil), "visibility rule")
    }

    @MainActor static func assetShowsInGridOrAlone() async {
        let navigation = CrosslinkNavigation()
        let inGrid = FakeWindow(visibility: "timeline", inGrid: true)
        await navigation.reveal("a", ticket: navigation.begin(), host: inGrid)
        check(inGrid.events == ["open a"], "in grid: opened \(inGrid.events)")
        let elsewhere = FakeWindow(visibility: "archive", inGrid: false)
        await navigation.reveal("b", ticket: navigation.begin(), host: elsewhere)
        check(elsewhere.events == ["alone b"], "not in grid: alone \(elsewhere.events)")
        let failing = FakeWindow(visibility: "timeline", loadError: URLError(.timedOut))
        await navigation.reveal("c", ticket: navigation.begin(), host: failing)
        check(failing.events == ["alone c"], "grid failed: alone \(failing.events)")
        let cancelled = FakeWindow(visibility: "timeline", loadError: URLError(.cancelled))
        await navigation.reveal("d", ticket: navigation.begin(), host: cancelled)
        check(cancelled.events.isEmpty, "grid cancelled: nothing \(cancelled.events)")
        let missing = FakeWindow(visibility: "timeline", assetError: URLError(.fileDoesNotExist))
        await navigation.reveal("e", ticket: navigation.begin(), host: missing)
        check(missing.errors == 1 && missing.events.isEmpty && missing.gridLoads == 0, "asset failed: says so, nothing shown")
    }

    /// Link A's server answers late, after link B was shown: A does nothing, not even an alert.
    @MainActor static func slowLinkLosesToFastLink() async {
        let navigation = CrosslinkNavigation()
        let slowA = FakeWindow(visibility: "timeline", inGrid: true, gate: Gate())
        let ticketA = navigation.begin()
        navigation.run(ticketA) { await navigation.reveal("a", ticket: ticketA, host: slowA) }
        await settle()
        let fastB = FakeWindow(visibility: "timeline", inGrid: true)
        let ticketB = navigation.begin()
        navigation.run(ticketB) { await navigation.reveal("b", ticket: ticketB, host: fastB) }
        await settle()
        check(fastB.events == ["open b"], "B shown \(fastB.events)")
        slowA.gate?.release()
        await settle()
        check(slowA.events.isEmpty && slowA.gridLoads == 0, "slow A after B: nothing \(slowA.events)")

        // A slow failure after B: no alert.
        let failingA = FakeWindow(visibility: "timeline", assetError: URLError(.badServerResponse), gate: Gate())
        let ticketA2 = navigation.begin()
        navigation.run(ticketA2) { await navigation.reveal("a", ticket: ticketA2, host: failingA) }
        await settle()
        _ = navigation.begin()
        failingA.gate?.release()
        await settle()
        check(failingA.errors == 0 && failingA.messages.isEmpty, "slow A failing after B: no alert")

        // A locked asset answered late: no alert either.
        let lockedA = FakeWindow(visibility: "locked", gate: Gate())
        let ticketA3 = navigation.begin()
        navigation.run(ticketA3) { await navigation.reveal("a", ticket: ticketA3, host: lockedA) }
        await settle()
        _ = navigation.begin()
        lockedA.gate?.release()
        await settle()
        check(lockedA.messages.isEmpty && lockedA.events.isEmpty, "slow locked A after B: no alert")

        // The grid loads late, after B: A is not opened, nor shown alone.
        let slowGrid = FakeWindow(visibility: "timeline", inGrid: false, gridGate: Gate())
        let ticketA4 = navigation.begin()
        navigation.run(ticketA4) { await navigation.reveal("a", ticket: ticketA4, host: slowGrid) }
        await settle()
        check(slowGrid.gridLoads == 1, "grid loading")
        _ = navigation.begin()
        slowGrid.gridGate?.release()
        await settle()
        check(slowGrid.events.isEmpty, "grid late after B: no window of its own \(slowGrid.events)")
    }

    /// The user choosing another page, the window closing, signing out: all `invalidate()`.
    @MainActor static func userNavigationAndLogoutDropLink() async {
        let navigation = CrosslinkNavigation()
        let window = FakeWindow(visibility: "timeline", inGrid: true, gate: Gate())
        let ticket = navigation.begin()
        navigation.run(ticket) { await navigation.reveal("a", ticket: ticket, host: window) }
        await settle()
        navigation.invalidate()
        check(!navigation.isCurrent(ticket), "ticket stale after invalidate")
        window.gate?.release()
        await settle()
        check(window.events.isEmpty && window.messages.isEmpty, "after user navigation: nothing \(window.events)")
        // A stale ticket starts nothing.
        var ran = false
        navigation.run(ticket) { ran = true }
        await settle()
        check(!ran, "stale ticket runs nothing")
    }

    @MainActor static func personFetchGoesStale() async {
        let navigation = CrosslinkNavigation()
        let gate = Gate()
        var shown: [String] = [], failed = 0
        let ticket = navigation.begin()
        navigation.run(ticket) {
            await navigation.fetchThenShow(ticket, fetch: { await gate.wait(); return "person" },
                                           show: { shown.append($0) }, failed: { _ in failed += 1 })
        }
        await settle()
        _ = navigation.begin() // B
        gate.release()
        await settle()
        check(shown.isEmpty && failed == 0, "person answered after B: not pushed")

        let current = navigation.begin()
        await navigation.fetchThenShow(current, fetch: { "person" }, show: { shown.append($0) }, failed: { _ in failed += 1 })
        check(shown == ["person"], "person current: pushed")
        await navigation.fetchThenShow(navigation.begin(), fetch: { throw URLError(.timedOut) }, show: { shown.append($0) },
                                       failed: { _ in failed += 1 })
        check(failed == 1, "person failed: says so")
    }

    @MainActor static func windowDelivery() async {
        let navigation = CrosslinkNavigation()
        // A window that finishes setting up on the third try gets the link; none is opened.
        var tries = 0, opened = 0
        await navigation.deliver(navigation.begin(), live: { true }, deliver: { tries += 1; return tries == 3 },
                                 hasWindow: { true }, openWindow: { opened += 1 }, wait: {})
        check(tries == 3 && opened == 0, "delivered when ready: \(tries) tries, \(opened) opened")

        // No window: one is opened, once.
        tries = 0; opened = 0
        await navigation.deliver(navigation.begin(), tries: 10, openAfter: 4, live: { true }, deliver: { tries += 1; return false },
                                 hasWindow: { false }, openWindow: { opened += 1 }, wait: {})
        check(opened == 1 && tries == 10, "no window: one opened \(opened)")

        // Signed out (or switched) meanwhile: stops, no window opened.
        tries = 0; opened = 0
        var live = true
        await navigation.deliver(navigation.begin(), live: { live }, deliver: { tries += 1; live = false; return false },
                                 hasWindow: { false }, openWindow: { opened += 1 }, wait: {})
        check(tries == 1 && opened == 0, "account changed: stops")

        // A newer link while waiting: the older stops, no window opened for it.
        tries = 0; opened = 0
        let older = navigation.begin()
        await navigation.deliver(older, live: { true }, deliver: { tries += 1; return false },
                                 hasWindow: { false }, openWindow: { opened += 1 }, wait: { _ = navigation.begin() })
        check(tries == 1 && opened == 0, "newer link: older stops")
    }
}

@MainActor final class Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        isOpen = true
        for continuation in continuations { continuation.resume() }
        continuations.removeAll()
    }
}

/// A library window over a fake server: records what it was asked to do.
@MainActor final class FakeWindow: CrosslinkAssetHost {
    struct Asset { let id: String; let visibility: String? }
    let visibility: String?
    let inGrid: Bool
    let assetError: Error?
    let loadError: Error?
    let gate: Gate?
    let gridGate: Gate?
    var events: [String] = []
    var messages: [String] = []
    var errors = 0
    var gridLoads = 0

    init(visibility: String?, inGrid: Bool = true, assetError: Error? = nil, loadError: Error? = nil,
         gate: Gate? = nil, gridGate: Gate? = nil) {
        self.visibility = visibility
        self.inGrid = inGrid
        self.assetError = assetError
        self.loadError = loadError
        self.gate = gate
        self.gridGate = gridGate
    }

    func asset(_ id: String) async throws -> Asset {
        await gate?.wait()
        if let assetError { throw assetError }
        return Asset(id: id, visibility: visibility)
    }
    func visibility(of asset: Asset) -> String? { asset.visibility }
    func loadForReveal(_ asset: Asset) async throws -> Bool {
        gridLoads += 1
        await gridGate?.wait()
        if let loadError { throw loadError }
        return inGrid
    }
    func open(_ id: String) { events.append("open \(id)") }
    func showAlone(_ id: String) { events.append("alone \(id)") }
    func tell(_ message: String) { messages.append(message) }
    func cannotShow(_ error: Error) { errors += 1 }
}
