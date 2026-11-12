import SwiftUI

/// Grid pages: the View Options menu (GridArrangement), with the options the page offers. Takes only
/// stable inputs: on macOS 15 a toolbar item whose inputs change is rebuilt, which closes its menu.
struct GridViewOptions: View {
    let page: GridPage
    let dateAddedAvailable: Bool
    @AppStorage private var show: GridShow
    @AppStorage private var mediaType: GridMediaType
    @AppStorage private var sortBy: GridSortBy
    @AppStorage private var order: GridOrder
    @AppStorage private var location: GridLocation
    @AppStorage(TimelineRail.shownKey) private var showsDateScroller = true

    init(page: GridPage, dateAddedAvailable: Bool) {
        self.page = page
        self.dateAddedAvailable = dateAddedAvailable
        _show = AppStorage(wrappedValue: .all, page.key("show"))
        _mediaType = AppStorage(wrappedValue: .all, page.key("mediaType"))
        _sortBy = AppStorage(wrappedValue: .dateTaken, page.key("sortBy"))
        _order = AppStorage(wrappedValue: .newestFirst, page.key("order"))
        _location = AppStorage(wrappedValue: page.defaultLocation, page.key("location"))
    }

    var body: some View {
        Menu {
            if page.offersLocationFilter {
                Picker("Show", selection: $location) {
                    ForEach(GridLocation.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
            if page.offersFavoritesFilter {
                Picker("Show", selection: $show) {
                    ForEach(GridShow.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
            if page.offersMediaTypeFilter {
                Picker("Media Type", selection: $mediaType) {
                    ForEach(GridMediaType.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
            if page.offersSortBy {
                // Photos or videos only come from search, which can't order by upload date.
                let dateAdded = dateAddedAvailable && mediaType == .all
                Picker("Sort By", selection: Binding(get: { dateAdded ? sortBy : .dateTaken }, set: { sortBy = $0 })) {
                    ForEach(GridSortBy.allCases) { option in
                        Text(option.title).tag(option).disabled(option == .dateAdded && !dateAdded)
                    }
                }
                .pickerStyle(.inline)
            }
            if page.offersOrder {
                Picker("Order", selection: $order) {
                    ForEach(GridOrder.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
            Divider()
            Toggle("Date Scroller", isOn: $showsDateScroller) // Also View > Show Date Scroller
        } label: {
            let filtered = (page.offersFavoritesFilter && show != .all) || (page.offersMediaTypeFilter && mediaType != .all)
                || (page.offersLocationFilter && location != .all)
            Label("View Options", systemImage: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .help(page.offersSortBy && !dateAddedAvailable ? "View Options. Sorting by Date Added needs Immich v3.0 or later." : "View Options")
    }
}

/// Reloads a grid when its page's view options change, in this window or another.
struct GridViewOptionsReloader: ViewModifier {
    let model: AssetGridModel
    @AppStorage private var show: GridShow
    @AppStorage private var mediaType: GridMediaType
    @AppStorage private var sortBy: GridSortBy
    @AppStorage private var order: GridOrder
    @AppStorage private var location: GridLocation

    init(page: GridPage, model: AssetGridModel) {
        self.model = model
        _show = AppStorage(wrappedValue: .all, page.key("show"))
        _mediaType = AppStorage(wrappedValue: .all, page.key("mediaType"))
        _sortBy = AppStorage(wrappedValue: .dateTaken, page.key("sortBy"))
        _order = AppStorage(wrappedValue: .newestFirst, page.key("order"))
        _location = AppStorage(wrappedValue: page.defaultLocation, page.key("location"))
    }

    func body(content: Content) -> some View {
        content.onChange(of: GridArrangement(show: show, mediaType: mediaType, sortBy: sortBy, order: order, location: location)) {
            Task { await model.reload() }
        }
    }
}

extension View {
    @ViewBuilder
    func gridViewOptionsReloader(_ model: AssetGridModel) -> some View {
        if let page = model.source.gridPage {
            modifier(GridViewOptionsReloader(page: page, model: model))
        } else {
            self
        }
    }
}

extension GridPage {
    /// Back to all items, from an empty filtered page.
    func showAllItems(defaults: UserDefaults = .standard) {
        defaults.set(GridShow.all.rawValue, forKey: key("show"))
        defaults.set(GridMediaType.all.rawValue, forKey: key("mediaType"))
        defaults.set(GridLocation.all.rawValue, forKey: key("location"))
    }
}
