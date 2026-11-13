import SwiftUI

/// What the detail column has opened from its page: an album, a person, a country, a grid of photos. Opening and
/// going back switch the page in place, as in Finder and Photos, rather than sliding it in from the side.
@MainActor @Observable final class PageNavigation {
    /// One path for each sidebar item, so switching items starts at the item's page.
    private var paths: [SidebarItem: NavigationPath] = [:]
    var item: SidebarItem = .library
    /// Crosslink: counts the links that showed a page from its start, so the detail column builds a new stack for each
    /// (`PageStackID`). Replacing a stack's pages in one go, SwiftUI sometimes went on showing the stack's start.
    private(set) var linkPages = 0
    /// Crosslink: what a link is still doing in this window (fetching a person, loading a grid as far as a photo).
    /// The user moving (choosing a page, pushing, going back) makes it stale; the link's own pages do not.
    @ObservationIgnored let links = CrosslinkNavigation()

    func path(for item: SidebarItem) -> NavigationPath { paths[item] ?? NavigationPath() }

    /// The stack's own changes: the user pushing or going back on the page shown.
    func setPath(_ path: NavigationPath, for item: SidebarItem) {
        if item == self.item, path != self.path(for: item) { links.invalidate() }
        paths[item] = path
    }

    /// Another page chosen: every page starts again from its start.
    func reset() {
        links.invalidate()
        paths = [:]
    }

    func open<Value: Hashable>(_ value: Value) {
        links.invalidate()
        push(value)
    }

    /// The window's selection changed. Another page starts from its start, every page with it, and makes a link
    /// stale, unless the link chose the page itself (`linkShow`): then its pages pushed meanwhile stay.
    func selectionChanged(to selection: SidebarItem?) {
        guard selection == nil || selection != item else { return }
        item = selection ?? .library
        reset()
    }

    /// Crosslink: a link shows a page from its start, staying current.
    func linkShow(_ item: SidebarItem) {
        self.item = item
        paths = [:]
        linkPages += 1
    }

    /// Crosslink: a link pushes onto the page it shows, at once, if it is still current.
    func linkOpen<Value: Hashable>(_ value: Value, ticket: CrosslinkNavigation.Ticket) {
        guard links.isCurrent(ticket) else { return }
        push(value)
    }

    private func push<Value: Hashable>(_ value: Value) {
        var path = path(for: item)
        path.append(value)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { paths[item] = path }
    }
}

/// What the detail column's stack is built for: a new one for each sidebar item chosen, and for each page a link shows
/// from its start.
struct PageStackID: Hashable {
    let item: SidebarItem?
    let link: Int
}

/// A grid opened from a page: a city, a tag, a folder, a partner, a spot on the map.
struct GridRoute: Hashable {
    let source: GridSource
    let title: String
}

extension View {
    /// The detail column's navigation, without the slide.
    func pageNavigation(_ navigation: PageNavigation, item: SidebarItem) -> some View {
        let path = Binding(get: { navigation.path(for: item) }, set: { navigation.setPath($0, for: item) })
        return NavigationStack(path: path) {
            self.navigationDestination(for: GridRoute.self) { route in
                AssetGridContainer(source: route.source, title: Text(verbatim: route.title))
            }
        }
        .transaction(value: navigation.path(for: item).count) { transaction in
            transaction.disablesAnimations = true
            transaction.animation = nil
        }
        .environment(navigation)
    }
}
