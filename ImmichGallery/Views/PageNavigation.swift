import SwiftUI

/// What the detail column has opened from its page: an album, a person, a country, a grid of photos. Opening and
/// going back switch the page in place, as in Finder and Photos, rather than sliding it in from the side.
@MainActor @Observable final class PageNavigation {
    /// One path for each sidebar item, so switching items starts at the item's page.
    private var paths: [SidebarItem: NavigationPath] = [:]
    var item: SidebarItem = .library

    func path(for item: SidebarItem) -> NavigationPath { paths[item] ?? NavigationPath() }
    func setPath(_ path: NavigationPath, for item: SidebarItem) { paths[item] = path }
    func reset() { paths = [:] }

    func open<Value: Hashable>(_ value: Value) {
        var path = path(for: item)
        path.append(value)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { paths[item] = path }
    }
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
