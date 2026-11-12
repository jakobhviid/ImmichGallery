import SwiftUI

// Crosslink: what a link from another app shows in a library window, on the window's `PageNavigation`, which owns
// the link's tasks: the user choosing a page, pushing or going back makes the link stale, the link's own pages do not.
// Apart from `PageNavigation` it needs no view, so Tests/CrosslinkPageNavigationChecks.swift runs it with a fake window.

/// What a window gives a link besides its pages.
@MainActor struct CrosslinkWindow<Person: Hashable> {
    /// Makes the window show a sidebar item (its selection), after the link set the item's start.
    var select: (SidebarItem) -> Void
    /// Fetches a person a link names.
    var person: (String) async throws -> Person
    /// Shows an asset in the grid it was seen in, or alone (`CrosslinkNavigation.reveal`), while the link is current.
    var reveal: (_ id: String, _ source: GridSource, _ ticket: CrosslinkNavigation.Ticket) -> Void
    /// The person could not be fetched.
    var cannotShow: (Error) -> Void
}

extension PageNavigation {
    /// Shows what a link names, in the page Immich's web app would show it on, making every earlier link stale.
    /// Returns the link's ticket.
    @discardableResult
    func showCrosslink<Person: Hashable>(_ item: Crosslink.Item, in window: CrosslinkWindow<Person>) -> CrosslinkNavigation.Ticket {
        let ticket = links.begin()
        let show = { (page: SidebarItem) in
            self.linkShow(page)
            window.select(page)
        }
        switch item {
        case .page(let page):
            let target: SidebarItem = switch page {
            case .photos: .library
            case .albums: .albums
            case .people: .people
            case .places: .explore(.places)
            case .favorites: .favorites
            case .archive: .archive
            }
            show(target)
        case .album(let id): show(.album(id))
        case .person(let id): openPerson(id, ticket: ticket, in: window, show: show)
        case .place(let place):
            show(.explore(.places))
            linkOpen(CrosslinkDestination.place(place).route, ticket: ticket)
        case .asset(let id, let context):
            switch context {
            case .album(let album)?:
                show(.album(album))
                window.reveal(id, .album(album), ticket)
            case .person(let person)?:
                openPerson(person, ticket: ticket, in: window, show: show) { window.reveal(id, .person(person), ticket) }
            case .favorites?:
                show(.favorites)
                window.reveal(id, .favorites, ticket)
            case .archive?:
                show(.archive)
                window.reveal(id, .archive, ticket)
            case .search(let place)?:
                let destination = CrosslinkDestination.place(place)
                show(.explore(.places))
                linkOpen(destination.route, ticket: ticket)
                window.reveal(id, destination.source, ticket)
            case nil:
                show(.library)
                window.reveal(id, .library, ticket)
            }
        }
        return ticket
    }

    /// Opens a person on People once fetched, if the link is still current then: no fixed wait, the page and the
    /// person are set in one go, so the page's new stack starts with the person.
    private func openPerson<Person: Hashable>(_ id: String, ticket: CrosslinkNavigation.Ticket, in window: CrosslinkWindow<Person>,
                                              show: @escaping (SidebarItem) -> Void, then: @escaping () -> Void = {}) {
        let links = links
        links.run(ticket) {
            await links.fetchThenShow(ticket, fetch: { try await window.person(id) }, show: { person in
                show(.people)
                self.linkOpen(person, ticket: ticket)
                then()
            }, failed: window.cannotShow)
        }
    }
}

/// What a library window pushes for a crosslink besides a person (People's own destination): a place's search, as
/// a grid a page opens.
enum CrosslinkDestination: Hashable {
    case place(Crosslink.Place)

    var source: GridSource {
        switch self {
        case .place(let place):
            var query = SearchQuery()
            query.city = place.city ?? ""
            query.country = place.country ?? ""
            return .filteredSearch(query)
        }
    }

    var title: String {
        switch self {
        case .place(let place): place.city ?? place.country ?? ""
        }
    }

    var route: GridRoute { GridRoute(source: source, title: title) }
}
