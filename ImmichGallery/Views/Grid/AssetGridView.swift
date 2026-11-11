import SwiftUI

enum GridMetrics {
    static let defaultSize = 150.0
    /// Square photos (false) or the Aspect Ratio grid (true), as Photos' toggle.
    static let aspectRatioKey = "gridAspectRatio"
    static let steps: [Double] = [56, 72, 96, 120, 150, 190, 240, 320, 420]

    static func zoomIn(_ size: Double) -> Double { steps.first { $0 > size + 1 } ?? steps.last! }
    static func zoomOut(_ size: Double) -> Double { steps.last { $0 < size - 1 } ?? steps.first! }
    static func nearest(_ size: Double) -> Double { steps.min { abs($0 - size) < abs($1 - size) }! }
}

/// Resolves the grid model for a source and hosts the grid, the viewer, toolbar and inspector.
struct AssetGridContainer<Header: View>: View {
    @Environment(LibrarySession.self) private var session
    let source: GridSource
    let title: Text
    let header: Header
    /// The header scrolls away with the photos, as an album's or a person's title does, instead of staying above them.
    var headerScrolls = false

    init(source: GridSource, title: Text, headerScrolls: Bool = false, @ViewBuilder header: () -> Header) {
        self.source = source
        self.title = title
        self.headerScrolls = headerScrolls
        self.header = header()
    }

    var body: some View {
        AssetGridHost(model: session.gridModel(for: source), title: title, header: header, headerScrolls: headerScrolls)
            .id(source)
    }
}

extension AssetGridContainer where Header == EmptyView {
    init(source: GridSource, title: Text) {
        self.init(source: source, title: title) { EmptyView() }
    }
}

struct AssetGridHost<Header: View>: View {
    @Environment(LibrarySession.self) private var session
    @Bindable var model: AssetGridModel
    let title: Text
    let header: Header
    var headerScrolls = false

    @AppStorage("showInspector") private var showInspector = false
    /// Follows `showInspector`, which menu commands also change, so the panel slides in and out as Photos' Info does.
    @State private var inspectorShown = UserDefaults.standard.bool(forKey: "showInspector")
    @AppStorage("gridThumbnailSize") private var thumbnailSize = GridMetrics.defaultSize
    @AppStorage(GridMetrics.aspectRatioKey) private var aspectRatio = false
    @State private var pendingDelete: [String]?
    @State private var tagRequest: ExploreTagRequest?
    @State private var playLive = false
    @State private var utilities = AssetsUtilities()
    @AppStorage("library.mode") private var libraryMode = LibraryMode.all
    /// The month Months opens at, after a year card.
    @State private var overviewStart: String?

    /// Library's Years or Months instead of the grid.
    private var overview: LibraryMode? {
        model.source == .library && libraryMode != .all ? libraryMode : nil
    }

    private var viewerItem: AssetItem? {
        model.viewerID.flatMap { id in model.item(id) ?? (session.metadata.viewerSnapshot?.id == id ? session.metadata.viewerSnapshot : nil) }
    }

    private var inspectedID: String? {
        model.viewerID ?? (model.selection.count == 1 ? model.selection.first : nil)
    }

    var body: some View {
        ZStack {
            Group {
                if let overview {
                    LibraryOverviewView(model: model, mode: overview, startMonth: overviewStart, openYear: { year in
                        overviewStart = year.months.first
                        withAnimation(.smooth(duration: 0.35)) { libraryMode = .months }
                    }, openPhoto: { id in
                        model.selection = [id]
                        model.viewerScrollTarget = id
                        withAnimation(.smooth(duration: 0.35)) { libraryMode = .all }
                    })
                } else {
                    AssetGridView(model: model, onDelete: requestDelete, onTags: { ids, removing in
                        guard model.canMutate(ids) else { return }
                        tagRequest = ExploreTagRequest(ids: ids, removing: removing)
                    }, scrollHeader: headerScrolls ? AnyView(header) : nil)
                }
            }
            // Switching between Years, Months and All Photos replaces the view with a transition, as in Photos.
            .id(overview ?? .all)
            .transition(.blurReplace)
            .opacity(model.viewerID == nil ? 1 : 0)
            .allowsHitTesting(model.viewerID == nil)
            if let item = viewerItem {
                AssetViewer(model: model, item: item, playLive: $playLive, onDelete: requestDelete, onTags: { ids, removing in
                    guard model.canMutate(ids) else { return }
                    tagRequest = ExploreTagRequest(ids: ids, removing: removing)
                })
                    .id("\(item.id)-\(session.metadata.imageRevision)") // Metadata
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.viewerID)
        .modifier(MetadataHost(model: model)) // Metadata
        .navigationTitle(viewerItem?.date.map { Text(ImmichDate.day($0)) } ?? (headerNamesPage ? Text(verbatim: "") : title))
        .navigationSubtitle(headerNamesPage && viewerItem == nil ? "" : subtitle)
        // An open photo has its own Back, to the photos; the page's Back returns with them.
        .navigationBarBackButtonHidden(model.viewerID != nil)
        .toolbar(id: "assetGrid") { toolbar }
        .sheet(item: $tagRequest) { request in
            ExploreTagPicker(tags: session.exploreTags, removing: request.removing) { tag in
                do {
                    try await session.client.exploreTagAssets(request.ids, tag: tag.id, remove: request.removing)
                } catch {
                    session.handle(error)
                    session.invalidateGrids()
                    await model.reload()
                    throw error
                }
                session.invalidateGrids()
                await model.reload()
            }
        }
        .sharingPresentation() // Sharing
        .modifier(AssetsGridUtilities(model: model, utilities: utilities))
        .gridHeader(header, shown: !headerScrolls)
        .inspector(isPresented: Binding(get: { inspectorShown }, set: { showInspector = $0 })) {
            AssetInspector(assetID: inspectedID)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .task(id: session.macGridRevision) { await model.loadIfNeeded() }
        .gridViewOptionsReloader(model)
        .onChange(of: session.upload.revision) { Task { await model.reload() } } // Upload
        .focusedSceneValue(\.gridModel, model)
        .selectAllTarget(model, enabled: overview == nil)
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button(model.source == .trash || model.source == .locked ? "Delete Permanently" : "Delete", role: .destructive) {
                let ids = pendingDelete ?? []
                Task { await model.delete(ids, permanently: deletesPermanently) }
            }
        } message: {
            Text(deletesPermanently
                 ? "This can't be undone."
                 : "Items are moved to Recently Deleted.")
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.lastError ?? "")
        }
        .onChange(of: model.viewerID) { _, id in
            playLive = false
            if id == nil { showInspector = false }
        }
        .onDisappear { showInspector = false }
        .onChange(of: showInspector) { _, shown in
            guard inspectorShown != shown else { return }
            withAnimation(.smooth(duration: 0.3)) { inspectorShown = shown }
        }
        .modifier(ViewerIntegration(model: model))
    }

    /// The page's header shows its name while it is in view, so the toolbar leaves it out until it scrolls away.
    private var headerNamesPage: Bool { headerScrolls && model.headerInView && model.viewerID == nil && overview == nil }

    private var subtitle: String {
        if let item = viewerItem { return item.date.map(ImmichDate.time) ?? "" }
        let count = model.totalCount
        guard model.state == .loaded, count > 0 else { return "" }
        if model.checkingLocations, model.selection.isEmpty { return String(localized: "Looking for items without a location…") }
        if !model.selection.isEmpty { return String(localized: "\(model.selection.count) of \(count) selected") }
        return model.visibleMonths ?? String(localized: "\(count) items")
    }

    /// Locked items skip Recently Deleted, as in Immich.
    private var deletesPermanently: Bool {
        model.source == .trash || model.source == .locked || !session.features.trash
    }

    private var deleteTitle: String {
        let n = pendingDelete?.count ?? 0
        return model.source == .trash || model.source == .locked
            ? String(localized: "Permanently delete \(n) items?")
            : String(localized: "Delete \(n) items?")
    }

    private func requestDelete(_ ids: [String]) {
        guard model.canDelete(ids) else { return }
        pendingDelete = ids
    }

    /// Photos' toggle between square photos and whole photos in their own shape.
    private var aspectRatioButton: some View {
        Button { aspectRatio.toggle() } label: {
            Label(aspectRatio ? "Show Square Photos" : "Show Aspect Ratio", systemImage: "rectangle.arrowtriangle.2.inward")
        }
        .help(aspectRatio ? "Show Square Photos" : "Show Aspect Ratio")
    }

    private var zoomOutButton: some View {
        Button { thumbnailSize = GridMetrics.zoomOut(thumbnailSize) } label: { Label("Zoom Out", systemImage: "minus") }
    }

    private var zoomInButton: some View {
        Button { thumbnailSize = GridMetrics.zoomIn(thumbnailSize) } label: { Label("Zoom In", systemImage: "plus") }
    }

    /// Grouped as Photos groups its toolbar: the grid's size, then its shape and what it shows, then what to do with
    /// the selection. Customize Toolbar… rearranges it; Delete is there to add, and otherwise ⌘⌫ and the context menu.
    /// Every toolbar in the window must be customizable, or none of it is.
    @ToolbarContentBuilder
    private var toolbar: some CustomizableToolbarContent {
        let ids = model.viewerID.map { [$0] } ?? Array(model.selection)
        let items = ids.compactMap(model.item)
        // Years and Months show the library, not photos to act on. Their items stay, disabled, rather than come and
        // go: the toolbar keeps its layout, and the Years, Months and All Photos control stays under the pointer.
        let grid = overview == nil

        if model.viewerID != nil {
            ToolbarItem(id: "back", placement: .navigation) {
                Button { model.viewerID = nil } label: { Label("Back", systemImage: "chevron.backward") }
                    .help("Back to grid")
            }
            if viewerItem?.livePhotoVideoID != nil {
                ToolbarItem(id: "live") {
                    Toggle(isOn: $playLive) { Label("Live", systemImage: "livephoto") }
                        .help("Play Live Photo")
                }
            }
        } else {
            // Two buttons rather than a ControlGroup, which share a capsule all the same: a ControlGroup came up empty
            // on some pages, and on macOS 15 it was part of an endless toolbar layout loop on pushed pages (see
            // GlobalToolbar in MainView.swift).
            if model.source == .library {
                // In the middle with Years, Months and All Photos, in Photos' order.
                ToolbarItem(id: "libraryZoomOut", placement: .principal) { zoomOutButton.disabled(!grid) }
                ToolbarItem(id: "libraryZoomIn", placement: .principal) { zoomInButton.disabled(!grid) }
                ToolbarItem(id: "libraryMode", placement: .principal) {
                    ToolbarModePicker(selection: $libraryMode.animation(.smooth(duration: 0.35)), options: LibraryMode.allCases) { $0.title }
                }
            } else {
                if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
                ToolbarItem(id: "zoomOut") { zoomOutButton }
                ToolbarItem(id: "zoomIn") { zoomInButton }
            }
            if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
            ToolbarItem(id: "aspectRatio") { aspectRatioButton.disabled(!grid) }
            if let page = model.source.gridPage {
                ToolbarItem(id: "viewOptions") {
                    GridViewOptions(page: page, dateAddedAvailable: GridArrangement.supportsDateAdded(session.version))
                        .menuIndicator(.hidden)
                        .disabled(!grid)
                }
            }
            if AssetsUtilitiesMenu.hasItems(for: model.source) {
                ToolbarItem(id: "utilities") { AssetsUtilitiesMenu(model: model, utilities: utilities).disabled(!grid) }
            }
        }
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }

        ToolbarItem(id: "info") {
            Button { showInspector.toggle() } label: { Label("Info", systemImage: "info.circle") }
                .help("Show Info (⌘I)")
        }
        if model.source != .locked {
            // The selection's: dimmed with nothing selected, as in Photos. Sharing an album is in its Album menu.
            ToolbarItem(id: "share") { // Sharing
                SharingMenu(assetIDs: ids, allowPublicLinks: model.canMutate(ids))
                    .menuIndicator(.hidden)
                    .disabled(!grid)
            }
        }
        if model.source == .trash {
            ToolbarItem(id: "restore") {
                Button { Task { await model.restore(ids) } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    .disabled(!model.canDelete(ids))
                    .help("Restore")
            }
        } else if !model.source.isPartner {
            ToolbarItem(id: "favorite") {
                let allFavorite = !items.isEmpty && items.allSatisfy(\.isFavorite)
                Button { Task { await model.toggleFavorite(ids) } } label: {
                    Label("Favorite", systemImage: allFavorite ? "heart.fill" : "heart")
                }
                .disabled(!grid || !model.canMutate(ids))
                .help(allFavorite ? "Unfavorite" : "Favorite")
            }
            ToolbarItem(id: "rotate") { rotateButton(ids).disabled(!grid) }
        }
        if model.source == .geolocation {
            // The page is for this, so the button is always there.
            ToolbarItem(id: "assignLocationPage") { assignLocationButton(ids).disabled(!grid) }
                .customizationBehavior(.disabled)
        } else if AssetsUtilitiesMenu.supportsLocation(model.source) {
            ToolbarItem(id: "assignLocation", showsByDefault: false) { assignLocationButton(ids).disabled(!grid) }
        }
        ToolbarItem(id: "download") {
            Button {
                Exporter.exportOriginals(ids, session: session)
            } label: {
                Label("Download", systemImage: "arrow.down.to.line")
            }
            .disabled(!grid || ids.isEmpty)
            .help("Export Unmodified Original…")
        }
        if !model.source.isPartner {
            // Recently Deleted keeps its button: there it deletes for good.
            ToolbarItem(id: model.source == .trash ? "deletePermanently" : "delete", showsByDefault: model.source == .trash) {
                Button { requestDelete(ids) } label: { Label("Delete", systemImage: "trash") }
                    .disabled(!grid || !model.canDelete(ids))
                    .help("Delete")
            }
        }
        SearchToolbarItem()
    }

    /// Assign Location… for the selection, as in the Image menu and the More menu.
    private func assignLocationButton(_ ids: [String]) -> some View {
        Button { session.metadata.present(.location, ids: ids.sorted()) } label: {
            Label("Assign Location…", systemImage: "mappin.and.ellipse")
        }
        .disabled(ids.isEmpty || !model.canMutate(ids))
        .help("Assign Location…")
    }

    /// Photos' Rotate: to the left, or to the right with Option.
    private func rotateButton(_ ids: [String]) -> some View {
        let id = ids.count == 1 ? ids.first : nil
        let canRotate = id.map { session.metadata.imageEligibility[$0] == true } == true
            && !session.metadata.unavailableEdits && session.version?.supportsMetadataEdits == true && model.canMutate(ids)
        return Button {
            guard let id else { return }
            let clockwise = NSEvent.modifierFlags.contains(.option)
            Task { await session.metadata.rotate(id, clockwise: clockwise, session: session) }
        } label: {
            Label("Rotate", systemImage: "rotate.left")
        }
        .disabled(!canRotate)
        .help("Rotate left, or right with Option")
    }
}

struct AssetGridView: View {
    @Environment(LibrarySession.self) private var session
    @Bindable var model: AssetGridModel
    let onDelete: ([String]) -> Void
    let onTags: ([String], Bool) -> Void
    /// Above the photos, scrolling with them.
    var scrollHeader: AnyView?

    @AppStorage("gridThumbnailSize") private var thumbnailSize = GridMetrics.defaultSize
    @State private var zoomBase: Double?
    @State private var gridWidth: CGFloat = 0
    /// Whole photos in their own shape, rather than cropped to squares, as Photos' Aspect Ratio grid.
    @AppStorage(GridMetrics.aspectRatioKey) private var aspectRatio = false
    /// The size and shape the grid shows, which follow the saved ones with Photos' transition.
    @State private var shownSize = UserDefaults.standard.object(forKey: "gridThumbnailSize") as? Double ?? GridMetrics.defaultSize
    @State private var shownFit = UserDefaults.standard.bool(forKey: GridMetrics.aspectRatioKey)
    @State private var visibleCells = VisibleCells()

    var body: some View {
        Group {
            // Months a filter emptied still count as empty (Assign Location).
            if model.sections.allSatisfy({ model.shownCount($0) == 0 }) {
                VStack(spacing: 0) {
                if let scrollHeader { scrollHeader }
                switch model.state {
                case .idle, .loading:
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        if model.searchResultsLoaded > 0 {
                            Text("Loaded \(model.searchResultsLoaded) search results")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Load Photos", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await model.reload() } }
                    }
                case .loaded where model.checkingLocations:
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("Looking for items without a location…").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded:
                    if let page = model.source.gridPage, model.arrangement?.hidesLocated == true {
                        ContentUnavailableView {
                            Label("All Items Have a Location", systemImage: "mappin.circle")
                        } description: {
                            Text("Every photo and video you own has GPS coordinates, so it shows on the map.")
                        } actions: {
                            Button("Show All Items") { page.showAllItems() }
                        }
                    } else if let page = model.source.gridPage, model.arrangement?.isFiltered == true {
                        ContentUnavailableView {
                            Label("No Matching Photos", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("No photos match the selected view options.")
                        } actions: {
                            Button("Show All Items") { page.showAllItems() }
                        }
                    } else {
                        emptyState
                    }
                }
                }
            } else {
                grid
            }
        }
    }

    private var emptyState: some View {
        let (title, symbol): (LocalizedStringKey, String) = switch model.source {
        case .favorites: ("No Favorites", "heart")
        case .videos: ("No Videos", "video")
        case .archive: ("Archive Is Empty", "archivebox")
        case .trash: ("No Recently Deleted Items", "trash")
        case .locked: ("Locked Folder Is Empty", "lock")
        case .search, .filteredSearch: ("No Results", "magnifyingglass")
        case .partner: ("No Partner Photos", "person.2")
        case .largeFiles: ("No Large Files", "externaldrive")
        case .geolocation: ("No Photos to Locate", "mappin.and.ellipse")
        case .explore: ("No Photos to Explore", "globe")
        default: ("No Photos", "photo.on.rectangle")
        }
        return ContentUnavailableView(title, systemImage: symbol)
    }

    private var thumbnailRequestSize: ImmichClient.ThumbnailSize {
        thumbnailSize * 2 > 320 ? .preview : .thumbnail
    }

    private var grid: some View {
        ScrollViewReader { proxy in
        ScrollView {
            if let scrollHeader {
                scrollHeader.onScrollVisibilityChange(threshold: 0.25) { model.headerInView = $0 }
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: shownSize, maximum: shownSize * 1.8), spacing: 2)],
                spacing: 2,
                pinnedViews: model.showsSectionHeaders ? [.sectionHeaders] : []
            ) {
                ForEach(Array(model.sections.enumerated()), id: \.element.id) { s, section in
                    Section {
                        // IDs must be unique across sections: they all live in one lazy container.
                        ForEach((0..<model.shownCount(section)).map { CellKey(section: section.id, index: $0, asset: model.asset(s, $0)?.id) }, id: \.self) { key in
                            cell(s, key.index)
                        }
                    } header: {
                        if model.showsSectionHeaders, model.shownCount(section) > 0, let title = section.title {
                            SectionHeader(title: title)
                        }
                    }
                }
            }
            .padding(.bottom, 20)
            .scrollTargetLayout()
            .animation(.smooth(duration: 0.3), value: model.removals)
        }
        .onScrollTargetVisibilityChange(idType: CellKey.self, threshold: 0.3) { keys in
            visibleCells.keys = keys
            model.showing(sections: keys.map(\.section))
        }
        // Zooming keeps the first photo in view where it was, and animates the photos to their new places, as
        // Photos does; a pinch follows the fingers, then settles on the nearest zoom level.
        .onChange(of: thumbnailSize) { _, size in
            let anchor = visibleCells.first(in: model.sections)
            withAnimation(zoomBase == nil ? .smooth(duration: 0.35) : .interactiveSpring(duration: 0.25)) {
                shownSize = size
                if let anchor { proxy.scrollTo(anchor, anchor: .topLeading) }
            }
        }
        .onChange(of: aspectRatio) { _, fit in
            withAnimation(.smooth(duration: 0.35)) { shownFit = fit }
        }
        // The grid's columns, for moving up and down a row: an adaptive grid fits as many minimum-width items
        // as the width holds.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        .onChange(of: GridColumns(width: gridWidth, size: shownSize), initial: true) { _, columns in
            model.columns = columns.count
        }
        .onAppear { scrollToViewerTarget(proxy) }
        .onChange(of: model.viewerScrollTarget) { scrollToViewerTarget(proxy) }
        .onChange(of: model.keyboardScrollTarget) { _, id in
            // Only as far as needed to show it, as Finder and Photos scroll with the arrow keys.
            guard let id, let position = model.position(of: id) else { return }
            proxy.scrollTo(CellKey(section: position.section, index: position.item, asset: id))
            model.keyboardScrollTarget = nil
        }
        .onChange(of: model.selection) {
            MacQuickLook.shared.follow(model.macOrderedSelection, ahead: model.quickLookAhead)
        }
        }
        .macOriginalDragContainer(model: model, client: session.client)
        .fastWheelScrolling()
        .background {
            // Clicking empty space clears the selection, like Photos.
            Color.clear.contentShape(Rectangle()).onTapGesture { model.selection = [] }
        }
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = zoomBase ?? thumbnailSize
                    zoomBase = base
                    thumbnailSize = min(GridMetrics.steps.last!, max(GridMetrics.steps.first!, base * value.magnification))
                }
                .onEnded { _ in
                    // As Photos does, the pinch settles on the nearest zoom level.
                    zoomBase = nil
                    thumbnailSize = GridMetrics.nearest(thumbnailSize)
                }
        )
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(action: handleKey)
    }

    private func scrollToViewerTarget(_ proxy: ScrollViewProxy) {
        guard let id = model.viewerScrollTarget else { return }
        for section in model.sections {
            if let index = section.assets?.firstIndex(where: { $0.id == id }) {
                proxy.scrollTo(CellKey(section: section.id, index: index, asset: id), anchor: .center)
                model.viewerScrollTarget = nil
                return
            }
        }
    }

    private func cell(_ s: Int, _ i: Int) -> some View {
        let asset = model.asset(s, i)
        let thumbnail = ThumbnailCell(
            asset: asset,
            isSelected: asset.map { model.selection.contains($0.id) } ?? false,
            size: thumbnailRequestSize,
            fit: shownFit
        )
        return Group {
            if let asset {
                // Locked items can't be dropped on albums; they can still be dragged out as files.
                let albumIDs = model.source == .locked ? nil : AlbumAssetTransfer(ids: model.selection.contains(asset.id) ? Array(model.selection) : [asset.id])
                if #available(macOS 26, *) {
                    if let albumIDs { thumbnail.draggable(albumIDs) } else { thumbnail }
                } else {
                    thumbnail.legacyAssetDrag(albumIDs: albumIDs, original: OriginalTransfer(id: asset.id, isVideo: asset.isVideo, client: session.client))
                }
            } else {
                thumbnail
            }
        }
        .overlay(alignment: .topLeading) {
            AssetsLargeFileBadge(asset: asset, source: model.source)
            AssetsLocationBadge(asset: asset, source: model.source, arrangement: model.arrangement)
        }
        .macOriginalContainerItem(asset.map { OriginalTransfer(id: $0.id, isVideo: $0.isVideo, client: session.client) })
        .onAppear { model.cellAppeared(section: s, item: i) }
        .onTapGesture(count: 2) { if let asset { model.open(asset.id) } }
        .simultaneousGesture(TapGesture().onEnded { if let asset { model.click(asset.id) } })
        .deferredContextMenu {
            if let asset { contextMenu(for: asset) }
        }
    }

    @ViewBuilder
    private func contextMenu(for asset: AssetItem) -> some View {
        let ids = model.selection.contains(asset.id) ? Array(model.selection) : [asset.id]
        Button("Open") { model.open(asset.id) }
        AssetActionsMenu(model: model, asset: asset, ids: ids, onDelete: onDelete, onTags: onTags)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let ids = Array(model.selection)
        switch press.key {
        case .space:
            guard !ids.isEmpty else { return .ignored }
            MacQuickLook.shared.toggle(model.macOrderedSelection, ahead: model.quickLookAhead, session: session,
                                       onError: { model.lastError = $0 }, onArrow: quickLookArrow)
        case .return:
            guard let first = model.selectedItems.first else { return .ignored }
            model.open(first.id)
        case .delete, .deleteForward:
            guard press.modifiers.contains(.command), !ids.isEmpty else { return .ignored }
            onDelete(ids)
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            // Command with an arrow is left to the menus and the system.
            guard !press.modifiers.contains(.command) else { return .ignored }
            let direction: AssetGridModel.Move = switch press.key {
            case .leftArrow: .left
            case .rightArrow: .right
            case .upArrow: .up
            default: .down
            }
            let extending = press.modifiers.contains(.shift)
            Task { await model.move(direction, extending: extending) }
        case .escape:
            model.selection = []
        default:
            if press.characters == "." && !ids.isEmpty {
                Task { await model.toggleFavorite(ids) }
            } else {
                return .ignored
            }
        }
        return .handled
    }
}

extension AssetGridView {
    /// Quick Look: an arrow key pressed in the panel moves the grid, which the panel then follows.
    private func quickLookArrow(_ event: NSEvent) -> Bool {
        let direction: AssetGridModel.Move
        switch event.keyCode {
        case 123: direction = .left
        case 124: direction = .right
        case 125: direction = .down
        case 126: direction = .up
        default: return false
        }
        let extending = event.modifierFlags.contains(.shift)
        Task { await model.move(direction, extending: extending) }
        return true
    }
}

/// An adaptive grid's column count: as many minimum-width items, with their spacing, as the width holds.
struct GridColumns: Equatable {
    let count: Int
    init(width: CGFloat, size: Double, spacing: CGFloat = 2) {
        count = max(1, Int((width + spacing) / (CGFloat(size) + spacing)))
    }
}

/// A cell: its photo once its month has loaded, so removing photos moves the others to their new places, as Photos
/// does; until then its place.
private struct CellKey: Hashable {
    let section: String
    let index: Int
    let asset: String?

    static func == (a: Self, b: Self) -> Bool {
        if let asset = a.asset { return asset == b.asset }
        return b.asset == nil && a.section == b.section && a.index == b.index
    }

    func hash(into hasher: inout Hasher) {
        if let asset { hasher.combine(asset) } else { hasher.combine(section); hasher.combine(index) }
    }
}

/// The cells in view, kept without redrawing the grid as it scrolls.
private final class VisibleCells {
    var keys: [CellKey] = []

    /// The first cell in the grid's order.
    func first(in sections: [GridSection]) -> CellKey? {
        let shown = Set(keys.map(\.section))
        guard let section = sections.first(where: { shown.contains($0.id) }) else { return nil }
        return keys.filter { $0.section == section.id }.min { $0.index < $1.index }
    }
}

struct SectionHeader: View {
    /// Albums: a chevron for groups that collapse.
    enum Disclosure { case expanded, collapsed }

    let title: String
    var disclosure: Disclosure?
    /// Albums and Places: how many items the group holds.
    var count: Int?

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                if let disclosure {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(disclosure == .expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                if let count { Text(count, format: .number).foregroundStyle(.secondary).monospacedDigit() }
            }
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .adaptiveGlass(in: .capsule)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

struct ThumbnailCell: View {
    @Environment(LibrarySession.self) private var session
    let asset: AssetItem?
    let isSelected: Bool
    let size: ImmichClient.ThumbnailSize
    /// The whole photo in its own shape, inside its square, instead of the square filled.
    var fit = false

    @State private var image: CGImage?
    @State private var placeholder: CGImage?
    @State private var imageID: String?
    @State private var failed = false
    @State private var isVisible = false

    /// One structure for both shapes, so switching between them animates: the photo's frame and crop change shape.
    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                // As Photos' Aspect Ratio grid: the photo fitted inside its square, with room around it.
                picture(corner: fit ? 6 : 0)
                    .aspectRatio(fit ? max(0.2, min(5, asset?.ratio ?? 1)) : 1, contentMode: .fit)
                    .padding(fit ? 5 : 0)
            }
            .contentShape(Rectangle())
            .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
            .task(id: TaskKey(id: asset?.id, size: size, revision: session.metadata.imageRevision, visible: isVisible)) { await load() }
    }

    /// The photo with its badges and selection, cropped to the shape it is given.
    private func picture(corner: CGFloat) -> some View {
        Rectangle()
            .fill(.quaternary.opacity(0.5))
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else if let placeholder {
                    Image(decorative: placeholder, scale: 1).resizable().scaledToFill()
                } else if failed {
                    Image(systemName: asset?.isVideo == true ? "video.slash" : "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay(alignment: .bottom) { badges }
            .clipShape(.rect(cornerRadius: corner))
            .overlay {
                if isSelected {
                    // Fitted photos get Photos' ring just outside them; squares a frame and a tint.
                    RoundedRectangle(cornerRadius: fit ? corner + 3 : 0)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(fit ? -4 : 0)
                    Color.accentColor.opacity(fit ? 0 : 0.12)
                }
            }
    }

    private struct TaskKey: Equatable { let id: String?; let size: ImmichClient.ThumbnailSize; let revision: Int; let visible: Bool }

    private func load() async {
        failed = false
        if imageID != asset?.id {
            image = nil
            placeholder = nil
            imageID = asset?.id
        }
        guard isVisible, !Task.isCancelled, let id = asset?.id else { return }
        let pipeline = session.pipeline
        if let cached = pipeline.cachedThumbnail(id, size: size) { image = cached; return }
        image = pipeline.cachedThumbnail(id, size: .thumbnail) ?? pipeline.cachedThumbnail(id, size: .preview) ?? image
        if image == nil, let hash = asset?.thumbhash {
            placeholder = ThumbHash.cachedImage(base64: hash)
            if placeholder == nil {
                let decoded = await ThumbHash.placeholder(base64: hash)
                guard !Task.isCancelled else { return }
                placeholder = decoded
            }
        }
        let loaded = await pipeline.gridThumbnail(id, size: size)
        guard !Task.isCancelled else { return }
        // Fades in over its placeholder when it arrives; from the cache it is just there.
        if let loaded { withAnimation(.easeOut(duration: 0.2)) { image = loaded; placeholder = nil } }
        else if !Task.isCancelled && image == nil { failed = true }
    }

    @ViewBuilder
    private var badges: some View {
        if let asset, asset.isFavorite || asset.isVideo || asset.livePhotoVideoID != nil || asset.stackCount != nil {
            HStack(spacing: 4) {
                if asset.isFavorite { Image(systemName: "heart.fill") }
                Spacer(minLength: 0)
                if let count = asset.stackCount {
                    Label("\(count)", systemImage: "square.stack.3d.up.fill").labelStyle(.titleAndIcon)
                }
                if asset.livePhotoVideoID != nil { Image(systemName: "livephoto") }
                if asset.isVideo {
                    Text(asset.durationMS.map(Duration.formatMilliseconds) ?? "")
                        .monospacedDigit()
                    Image(systemName: "video.fill")
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 2)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

/// Shared by the grid and the opened photo; callers choose the target IDs.
struct AssetActionsMenu: View {
    @Environment(LibrarySession.self) private var session
    @AppStorage("showInspector") private var showInspector = false
    let model: AssetGridModel
    let asset: AssetItem
    let ids: [String]
    let onDelete: ([String]) -> Void
    let onTags: ([String], Bool) -> Void

    var body: some View {
        Button("Info") {
            model.selection = [asset.id]
            showInspector = true
        }
        if model.source != .locked {
            ViewerContextMenu(model: model, asset: asset)
            if model.source != .trash { WidgetChosenMenuItem(ids: ids) } // Widget
            if model.source != .trash, ids.count <= 1 { CrosslinkMenuItems(item: .asset(asset.id, model.source.crosslinkContext)) } // Crosslink
        }
        Divider()
        if model.source == .locked {
            // Like Immich: no albums, sharing, tags or archive for locked items.
            Button(asset.isFavorite ? "Unfavorite" : "Favorite") { Task { await model.setFavorite(ids, !asset.isFavorite) } }
            AssetsContextMenu(model: model, ids: [asset.id] + ids.filter { $0 != asset.id })
            MetadataMenuItems(ids: ids, canEditImage: !asset.isVideo && asset.livePhotoVideoID == nil).disabled(session.metadata.busy) // Metadata
            AssetsExportMenu(ids: ids)
            Divider()
            Button("Remove from Locked Folder") { Task { await model.removeFromLockedFolder(ids) } }
            Button("Delete Permanently…", role: .destructive) { onDelete(ids) }
        } else if !model.canMutate(ids), model.source != .trash {
            SharingMenuItems(assetIDs: ids, allowPublicLinks: false)
            AssetsExportMenu(ids: ids)
        } else if model.source == .trash {
            Button("Restore") { Task { await model.restore(ids) } }.disabled(!model.canDelete(ids))
            Button("Delete Permanently…", role: .destructive) { onDelete(ids) }.disabled(!model.canDelete(ids))
        } else {
            AlbumSelectionMenu(session: session, model: model, ids: ids) // Albums
            Button(asset.isFavorite ? "Unfavorite" : "Favorite") { Task { await model.setFavorite(ids, !asset.isFavorite) } }
            SharingMenu(assetIDs: ids) // Sharing
            AssetsContextMenu(model: model, ids: [asset.id] + ids.filter { $0 != asset.id })
            MetadataMenuItems(ids: ids, canEditImage: !asset.isVideo && asset.livePhotoVideoID == nil).disabled(session.metadata.busy) // Metadata
            ExploreAssetActions(ids: ids, model: model, onTags: { onTags(ids, $0) }) // Explore
            AssetsExportMenu(ids: ids)
            Divider()
            if model.source == .archive {
                Button("Unarchive") { Task { await model.setArchived(ids, false) } }
            } else {
                Button(String(localized: "Archive Selected Photos")) { Task { await model.setArchived(ids, true) } }
            }
            Button("Delete…", role: .destructive) { onDelete(ids) }
        }
    }
}
