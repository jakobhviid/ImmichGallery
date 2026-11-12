import SwiftUI

/// Crosslink on the detail column's `PageNavigation`, the real one and its real link dispatch, with a fake window
/// (selection, person fetch, reveal, alerts). The user choosing a page, pushing or going back, and the window
/// closing, make a link stale: its late answers do nothing, not even an alert. The link's own page and pushes keep it
/// current, without any wait. Stand-ins for the app types the navigation names are at the end.
@main struct CrosslinkPageNavigationChecks {
    @MainActor static func main() async {
        ownPagesKeepLinkCurrent()
        userMovesMakeLinkStale()
        await personOpensInOneGo()
        await personLinkGoesStale()
        await slowLinkLosesToNewerLink()
        await assetRevealsWhileCurrent()
        if failures > 0 { print("\(failures) crosslink page navigation checks failed"); exit(1) }
        print("Crosslink page navigation checks passed")
    }

    nonisolated(unsafe) static var failures = 0
    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAILED: \(message)") }
    }

    @MainActor static func settle() async { for _ in 0..<50 { await Task.yield() } }

    /// A place link chooses Places and pushes the place's grid at once; the stacks echoing their paths back keep it.
    @MainActor static func ownPagesKeepLinkCurrent() {
        let window = FakeWindow()
        window.navigation.open(GridRoute(source: .library, title: "earlier")) // the user's page before the link
        window.show(.place(.init(city: "Rome", country: "Italy")))
        let ticket: CrosslinkNavigation.Ticket = window.lastTicket
        check(window.selection == .explore(.places), "place: Places chosen \(String(describing: window.selection))")
        check(window.navigation.path(for: .explore(.places)).count == 1, "place: grid pushed at once, no wait")
        check(window.navigation.path(for: .library).isEmpty, "place: other pages start from their start")
        check(window.navigation.links.isCurrent(ticket), "place: own page and push keep the link current")
        // The new stack writes back the path it was given; the old page's stack its own, emptied, path.
        window.navigation.setPath(window.navigation.path(for: .explore(.places)), for: .explore(.places))
        window.navigation.setPath(NavigationPath(), for: .library)
        check(window.navigation.links.isCurrent(ticket), "place: stacks echoing paths keep the link current")

        // The same page shown again: back to its start, then the push.
        window.show(.place(.init(city: "Paris", country: "France")))
        check(window.navigation.path(for: .explore(.places)).count == 1, "same page: one grid, the new one")
        check(window.navigation.links.isCurrent(window.lastTicket), "same page: link current")
        check(!window.navigation.links.isCurrent(ticket), "same page: the earlier link stale")

        window.show(.page(.albums))
        check(window.selection == .albums && window.navigation.links.isCurrent(window.lastTicket), "page link")

        // A stale link never pushes.
        let stale: CrosslinkNavigation.Ticket = window.lastTicket
        window.userSelects(.people)
        window.navigation.linkOpen(GridRoute(source: .library, title: "late"), ticket: stale)
        check(window.navigation.path(for: .people).isEmpty, "stale link: no push")
    }

    @MainActor static func userMovesMakeLinkStale() {
        let window = FakeWindow()
        window.show(.place(.init(city: "Rome", country: nil)))
        var path = window.navigation.path(for: .explore(.places))
        path.append(GridRoute(source: .favorites, title: "pushed"))
        window.navigation.setPath(path, for: .explore(.places))
        check(!window.navigation.links.isCurrent(window.lastTicket), "user push: link stale")

        window.show(.place(.init(city: "Rome", country: nil)))
        window.navigation.setPath(NavigationPath(), for: .explore(.places))
        check(!window.navigation.links.isCurrent(window.lastTicket), "user back: link stale")

        window.show(.page(.people))
        window.userSelects(.albums)
        check(!window.navigation.links.isCurrent(window.lastTicket), "user chooses a page: link stale")
        check(window.navigation.path(for: .people).isEmpty, "user chooses a page: pages start again")

        window.show(.page(.albums))
        window.navigation.open(GridRoute(source: .library, title: "album"))
        check(!window.navigation.links.isCurrent(window.lastTicket), "user opens from a page: link stale")

        window.show(.page(.albums))
        window.userSelects(nil)
        check(!window.navigation.links.isCurrent(window.lastTicket), "selection cleared: link stale")
    }

    /// The person's page and the person are set together once fetched, and the link stays current for the asset.
    @MainActor static func personOpensInOneGo() async {
        let window = FakeWindow()
        let gate = Gate()
        window.personGate = gate
        window.userSelects(.favorites)
        window.show(.asset("a", .person("p")))
        await settle()
        check(window.selection == .favorites, "person: nothing changes before the person comes")
        gate.release()
        await settle()
        check(window.selection == .people, "person: People chosen \(String(describing: window.selection))")
        check(window.navigation.path(for: .people).count == 1, "person: pushed with the page, no wait")
        check(window.reveals == ["a in person p, current"], "person: asset revealed while current \(window.reveals)")
        check(window.navigation.links.isCurrent(window.lastTicket), "person: still current after its own push")
    }

    @MainActor static func personLinkGoesStale() async {
        typealias Move = (FakeWindow) -> Void
        let moves: [(String, Move)] = [
            ("user chooses a page", { $0.userSelects(.albums) }),
            ("user pushes", { window in
                var path = window.navigation.path(for: window.navigation.item)
                path.append(GridRoute(source: .library, title: "x"))
                window.navigation.setPath(path, for: window.navigation.item)
            }),
            ("user opens from a page", { $0.navigation.open(GridRoute(source: .library, title: "x")) }),
            ("window closes or account changes", { $0.navigation.links.invalidate() }), // MainView's onDisappear
            ("another link arrives, even an invalid one", { $0.navigation.links.invalidate() }), // .crosslinkArrived
        ]
        for (name, move) in moves {
            for failing in [false, true] {
                let window = FakeWindow()
                let gate = Gate()
                window.personGate = gate
                window.personFails = failing
                window.userSelects(.library)
                window.show(.asset("a", .person("p")))
                await settle()
                move(window)
                let selection = window.selection
                gate.release()
                await settle()
                let label = "\(name)\(failing ? ", fetch failed" : "")"
                check(window.selection == selection, "\(label): selection kept \(String(describing: window.selection))")
                check(window.navigation.path(for: .people).isEmpty, "\(label): no person pushed")
                check(window.reveals.isEmpty && window.alerts.isEmpty, "\(label): no reveal or alert \(window.reveals) \(window.alerts)")
            }
        }
        // While current, a failed fetch says so.
        let window = FakeWindow()
        window.personFails = true
        window.show(.person("p"))
        await settle()
        check(window.alerts.count == 1 && window.selection == .library, "current person failed: one alert, no move")
    }

    /// Link A's person comes after link B was shown: B stays.
    @MainActor static func slowLinkLosesToNewerLink() async {
        let window = FakeWindow()
        let gate = Gate()
        window.personGate = gate
        window.show(.person("slow"))
        await settle()
        window.personGate = nil
        window.show(.album("b"))
        gate.release()
        await settle()
        check(window.selection == .album("b"), "newer link stays \(String(describing: window.selection))")
        check(window.navigation.path(for: .people).isEmpty && window.alerts.isEmpty, "older link: no push, no alert")
        check(window.navigation.links.isCurrent(window.lastTicket), "newer link current")
    }

    @MainActor static func assetRevealsWhileCurrent() async {
        let window = FakeWindow()
        window.show(.asset("a", .album("b")))
        window.show(.asset("c", .search(.init(city: "Rome", country: nil))))
        window.show(.asset("d", nil))
        check(window.reveals == ["a in album b, current", "c in search, current", "d in library, current"],
              "assets: revealed with a current ticket \(window.reveals)")
        check(window.selection == .library, "asset without context: Library")
    }
}

@MainActor final class Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var open = false
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        open = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

struct FakePerson: Hashable { let id: String }

/// A library window as MainView wires it: its selection drives `selectionChanged`.
@MainActor final class FakeWindow {
    let navigation = PageNavigation()
    private(set) var selection: SidebarItem? = .library
    var personGate: Gate?
    var personFails = false
    var reveals: [String] = []
    var alerts: [String] = []
    private(set) var lastTicket: CrosslinkNavigation.Ticket!

    func userSelects(_ item: SidebarItem?) {
        selection = item
        navigation.selectionChanged(to: item)
    }

    func show(_ item: Crosslink.Item) {
        lastTicket = navigation.showCrosslink(item, in: CrosslinkWindow<FakePerson>(
            select: { [unowned self] item in
                // MainView: the selection changes, then its onChange tells the navigation.
                selection = item
                navigation.selectionChanged(to: item)
            },
            person: { [unowned self] id in
                await personGate?.wait()
                if personFails { throw URLError(.badServerResponse) }
                return FakePerson(id: id)
            },
            reveal: { [unowned self] id, source, ticket in
                reveals.append("\(id) in \(source.label), \(navigation.links.isCurrent(ticket) ? "current" : "stale")")
            },
            cannotShow: { [unowned self] error in alerts.append("\(error)") }))
    }
}

// Stand-ins for the app's types that the navigation names.

enum ExplorePage: Hashable { case places }

enum SidebarItem: Hashable {
    case library, favorites, people, albums, archive
    case album(String)
    case explore(ExplorePage)
}

struct SearchQuery: Hashable {
    var city = ""
    var country = ""
}

enum GridSource: Hashable {
    case library, favorites, archive
    case album(String), person(String)
    case filteredSearch(SearchQuery)

    var label: String {
        switch self {
        case .library: "library"
        case .favorites: "favorites"
        case .archive: "archive"
        case .album(let id): "album \(id)"
        case .person(let id): "person \(id)"
        case .filteredSearch: "search"
        }
    }
}

struct AssetGridContainer: View {
    let source: GridSource
    let title: Text
    var body: some View { title }
}
