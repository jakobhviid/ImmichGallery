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
    @AppStorage(TimelineRail.shownKey) private var showsDateScroller = true
    @State private var pendingDelete: [String]?
    @State private var pendingRemoval: [String]?
    @State private var photoZoom: PhotoZoomRequest?
    @State private var showingFaceList = false
    @State private var photoFaces = PhotoFaces()
    @AppStorage(PhotoFaces.shownKey) private var faceNamesShown = false
    @State private var tagRequest: ExploreTagRequest?
    @State private var playLive = false
    @State private var utilities = AssetsUtilities()
    @AppStorage("library.mode") private var libraryMode = LibraryMode.all
    /// The month Months opens at, after a year card.
    @State private var overviewStart: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cellFrames = ViewerCellFrames()
    /// The open photo's zoom out of its square, back in, or slide to the next one.
    @State private var motion: ViewerMotion?
    /// The photo the viewer last moved to, or nil for the grid: one update behind `model.viewerID` when it changes.
    @State private var settledID: String?
    @State private var hostSize: CGSize = .zero
    /// The scale a pinch left the photo at as it closed.
    @State private var pinchedScale: Double?
    /// A pinch is shrinking the photo: the grid shows through behind it.
    @State private var revealsGrid = false
    /// The open photo's zoom, for the toolbar's slider.
    @State private var photoScale = 1.0
    /// The photo's place, opened out over it from the map below it.
    @State private var expandedMap: PhotoPlace?
    @State private var slider = ViewerSlider()
    /// The open photo's neighbours, for a swipe to uncover.
    @State private var neighbors: (previous: String?, next: String?) = (nil, nil)
    /// The pointer is over the page, for the open photo's side arrows.
    @State private var pointerOverViewer = false

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
                    }, onRemove: requestRemoval, scrollHeader: headerScrolls ? AnyView(header) : nil, cellFrames: cellFrames)
                }
            }
            // Switching between Years, Months and All Photos replaces the view with a transition, as in Photos.
            .id(overview ?? .all)
            .transition(.blurReplace)
            // Behind a photo flying out of it or back in, or pinched smaller, the grid shows, dimmed.
            .opacity(model.viewerID == nil || shownMotion?.isFlight == true || revealsGrid ? 1 : 0)
            .allowsHitTesting(model.viewerID == nil)
            if let motion = shownMotion, case .flight(_, _, let opening, let dim) = motion.kind {
                Color(nsColor: .windowBackgroundColor)
                    .opacity(opening ? (motion.done ? 1 : 0) : (motion.done ? 0 : dim))
                    .allowsHitTesting(false)
            }
            if let item = viewerItem {
                photoViewer(item)
                    .id("\(item.id)-\(session.metadata.imageRevision)") // Metadata
                    // While a motion runs, pictures of the photos stand in for it.
                    .opacity(shownMotion == nil ? 1 : 0)
                    .transition(shownMotion == nil ? AnyTransition.opacity : .identity)
            }
            if let motion = shownMotion { motionLayer(motion) }
            if viewerItem != nil { ViewerSlideLayer(slider: slider).allowsHitTesting(false) }
            if let place = expandedMap {
                ExpandedPhotoMap(place: place).transition(.opacity)
            }
        }
        .coordinateSpace(.named(ViewerCellFrames.space))
        .background(ViewerPointerTracking { pointerOverViewer = $0 })
        .onGeometryChange(for: CGSize.self) { $0.size } action: { hostSize = $0 }
        // Without a motion (Reduce Motion, or a square off screen), the photo cross-fades. Stepping swaps it under the
        // slide without animating: nothing in SwiftUI animates while the slide's layers move.
        .animation(shownMotion == nil && !(isStepping && !reduceMotion) ? .easeOut(duration: 0.18) : nil, value: model.viewerID)
        .task(id: model.viewerID) {
            guard let id = model.viewerID else { neighbors = (nil, nil); return }
            let previous = await model.neighbor(of: id, delta: -1)?.id
            let next = await model.neighbor(of: id, delta: 1)?.id
            if model.viewerID == id { neighbors = (previous, next) }
        }
        .onChange(of: model.viewerID) { old, new in
            revealsGrid = false
            if let old, let new { slide(from: old, to: new) }
            expandedMap = nil
            startMotion(from: old, to: new)
        }
        .onAppear { settledID = model.viewerID }
        .modifier(MetadataHost(model: model)) // Metadata
        .navigationTitle(viewerItem?.date.map { Text(ImmichDate.day($0)) } ?? (headerNamesPage ? Text(verbatim: "") : title))
        .navigationSubtitle(headerNamesPage && viewerItem == nil ? "" : subtitle)
        // An open photo's title is in the middle of the toolbar, as in Photos (`photoTitle`).
        .toolbar(removing: viewerItem == nil ? nil : .title)
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
        .focusedSceneValue(\.faceNamesAvailable, canShowFaces ? true : nil)
        .focusedSceneValue(\.photoZoom, viewerItem?.isVideo == false ? PhotoZoomAction(zoom: zoomPhoto) : nil)
        // The open photo's faces, while its face names are shown.
        .task(id: canShowFaces && faceNamesShown ? viewerItem?.id : nil) {
            if canShowFaces && faceNamesShown, let id = viewerItem?.id { await photoFaces.load(id, session: session) }
        }
        .modifier(PhotoFacesSheets(faces: photoFaces, assetID: canShowFaces ? viewerItem?.id : nil, showingList: $showingFaceList))
        .focusedSceneValue(\.libraryMode, model.source == .library ? $libraryMode.animation(.smooth(duration: 0.35)) : nil)
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
        // Photos undoes a removal with ⌘Z; without undo, ⌫ asks first. An alert, not a destructive confirmation, so
        // Return accepts, as in Photos, and ⌫ then Return works without the pointer.
        .alert(removalTitle, isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("Remove from Album") {
                let ids = pendingRemoval ?? []
                guard let id = model.source.albumID else { return }
                session.albumActions.perform(session: session, albumID: id) { try await model.removeFromAlbum(ids) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photos remain in your library.")
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

    /// From one photo to another, in the update before `startMotion` has run.
    private var isStepping: Bool {
        settledID != nil && model.viewerID != nil && settledID != model.viewerID
    }

    /// The motion running, or the one about to start: for the update in which `model.viewerID` changes, before
    /// `startMotion` runs, so the first frame already shows its start.
    private var shownMotion: ViewerMotion? {
        motion ?? (model.viewerID != settledID ? makeMotion(from: settledID, to: model.viewerID, generation: 0) : nil)
    }

    private func makeMotion(from old: String?, to new: String?, generation: Int) -> ViewerMotion? {
        guard !reduceMotion, old != new else { return nil }
        let bounds = CGRect(origin: .zero, size: hostSize)
        switch (old, new) {
        case (nil, let id?):
            guard let flight = flight(of: id, in: bounds) else { return nil }
            return ViewerMotion(id: id, kind: .flight(from: flight.square, to: flight.fit, opening: true, dim: 0),
                                generation: generation)
        case (let id?, nil):
            guard let flight = flight(of: id, in: bounds) else { return nil }
            let from = pinchedScale.map { ViewerMotionLayout.scaled(flight.fit, by: $0) } ?? flight.fit
            let dim = pinchedScale.map(ViewerMotionLayout.backdrop(forPinch:)) ?? 1
            return ViewerMotion(id: id, kind: .flight(from: from, to: flight.square, opening: false, dim: dim), generation: generation)
        default:
            return nil
        }
    }

    /// A photo's grid square, as the grid shows it (cropped, or whole in Aspect Ratio), and its place in the viewer.
    private func flight(of id: String, in bounds: CGRect) -> (square: CGRect, fit: CGRect)? {
        guard let cell = cellFrames.frames[id], ViewerMotionLayout.isShown(cell, in: bounds),
              let item = model.item(id), cachedImage(id) != nil else { return nil }
        let square = aspectRatio ? ViewerMotionLayout.fitted(item.ratio, in: cell) : cell
        return (square, ViewerMotionLayout.fitted(item.ratio, in: bounds))
    }

    private func startMotion(from old: String?, to new: String?) {
        let generation = (motion?.generation ?? 0) + 1
        let next = makeMotion(from: old, to: new, generation: generation)
        // A photo closing into a square off screen fades instead; the grid scrolls to it as it shows again. The grid
        // doesn't follow while hidden behind a photo: scrolling it then made AppKit's layout loop and throw.
        if let old, new == nil, next == nil { model.viewerScrollTarget = old }
        settledID = new
        pinchedScale = nil
        motion = next
        guard let next else { return }
        // After the start has been drawn, so there's something to move from.
        Task { @MainActor in
            guard motion?.generation == generation else { return }
            withAnimation(.smooth(duration: next.isFlight ? 0.35 : 0.3)) {
                motion?.done = true
            } completion: {
                if motion?.generation == generation { motion = nil }
            }
        }
    }

    private func cachedImage(_ id: String) -> CGImage? {
        session.pipeline.cachedThumbnail(id, size: .preview) ?? session.pipeline.cachedThumbnail(id, size: .thumbnail)
    }

    private func photoViewer(_ item: AssetItem) -> AssetViewer {
        var viewer = AssetViewer(model: model, item: item, playLive: $playLive, onDelete: requestDelete,
                                 onTags: requestTags, onRemove: requestRemoval, zoomRequest: photoZoom, onZoom: zoomPhoto,
                                 faces: faceNamesShown ? photoFaces.boxes(for: item.id) : [])
        viewer.onPinchClose = pinchClose
        viewer.onPinchChange = { revealsGrid = $0 }
        viewer.onScaleChange = { photoScale = $0 }
        viewer.onExpandMap = expandMap
        viewer.closeOverlay = closeExpandedMap
        viewer.showsSideArrows = pointerOverViewer
        if !reduceMotion {
            viewer.onSwipeDrag = swipeDrag
            viewer.onSwipeEnd = swipeEnd
        }
        return viewer
    }

    private func requestTags(_ ids: [String], removing: Bool) {
        guard model.canMutate(ids) else { return }
        tagRequest = ExploreTagRequest(ids: ids, removing: removing)
    }

    private func pinchClose(_ scale: Double) {
        pinchedScale = scale
        model.viewerID = nil
    }

    private func expandMap(_ place: PhotoPlace) {
        withAnimation(.easeOut(duration: 0.2)) { expandedMap = place }
    }

    /// Esc and Back close the opened-out map before the photo.
    private func closeExpandedMap() -> Bool {
        guard expandedMap != nil else { return false }
        withAnimation(.easeOut(duration: 0.2)) { expandedMap = nil }
        return true
    }

    /// The flying copy of the photo.
    @ViewBuilder private func motionLayer(_ motion: ViewerMotion) -> some View {
        switch motion.kind {
        case .flight(let from, let to, _, _):
            if let image = cachedImage(motion.id) {
                let rect = motion.done ? to : from
                // Filling the rect, so a square crop opens out to the whole photo.
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: rect.width, height: rect.height)
                    .clipped()
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Stepping slides pictures of the two photos in Core Animation (`ViewerSlider`), while the photo underneath is
    /// swapped without animating.
    private func slide(from old: String, to new: String) {
        guard !reduceMotion, expandedMap == nil, let a = model.order(of: old), let b = model.order(of: new),
              let outgoing = cachedImage(old), let incoming = cachedImage(new) else { return }
        slider.slide(from: outgoing, to: incoming, direction: ViewerMotionLayout.direction(from: a, to: b), toID: new)
    }

    /// The photos follow a trackpad swipe: the open one, and the neighbour it uncovers.
    private func swipeDrag(_ width: CGFloat) {
        guard let id = model.viewerID, let current = cachedImage(id) else { return }
        slider.drag(width, current: current, previous: neighbors.previous.flatMap(cachedImage),
                    next: neighbors.next.flatMap(cachedImage))
    }

    /// The swipe ended: far enough, it finishes the step on the layers and moves to that photo; otherwise back.
    private func swipeEnd(_ direction: Int?) {
        let target = direction == 1 ? neighbors.next : direction == -1 ? neighbors.previous : nil
        guard let target, cachedImage(target) != nil else {
            slider.endDrag(direction: nil, toID: nil)
            return
        }
        slider.endDrag(direction: direction, toID: target)
        model.viewerID = target
        model.selection = [target]
    }

    /// Face names and Manage Faces, for an open photo, as Photos has them.
    private var canShowFaces: Bool {
        viewerItem?.isVideo == false && session.features.facialRecognition && photoFaces.supported
    }

    private var removalTitle: String {
        String(localized: "Remove \(pendingRemoval?.count ?? 0) items from the album?")
    }

    private func requestRemoval(_ ids: [String]) {
        guard let id = model.source.albumID, session.albumActions.details[id]?.canEdit(session.user?.id) == true else { return }
        pendingRemoval = ids
    }

    /// Photos' toggle between square photos and whole photos in their own shape.
    private var aspectRatioButton: some View {
        Button { aspectRatio.toggle() } label: {
            Label(aspectRatio ? "Show Square Photos" : "Show Aspect Ratio", systemImage: "rectangle.arrowtriangle.2.inward")
        }
        .help(aspectRatio ? "Show Square Photos" : "Show Aspect Ratio")
    }

    private func photoTitle(_ item: AssetItem) -> some CustomizableToolbarContent {
        ToolbarItem(id: "photoTitle", placement: .principal) {
            VStack(spacing: 1) {
                Text(item.date.map(ImmichDate.day) ?? "").font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            // A steady width, so the toolbar doesn't lay itself out again for every date.
            .frame(width: 280)
        }
        .customizationBehavior(.disabled)
    }

    private var photoZoomSlider: some CustomizableToolbarContent {
        ToolbarItem(id: "photoZoom", placement: .navigation) {
            PhotoZoomSlider(scale: photoScale) { zoomPhoto(.to($0)) }
                .disabled(viewerItem?.isVideo != false)
        }
    }

    private func zoomPhoto(_ zoom: PhotoZoomRequest.Zoom) {
        photoZoom = PhotoZoomRequest(zoom: zoom, generation: (photoZoom?.generation ?? 0) + 1)
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
            if let item = viewerItem {
                // Plain text in the middle, as Photos' title is, not in a capsule.
                if #available(macOS 26, *) {
                    photoTitle(item).sharedBackgroundVisibility(.hidden)
                } else {
                    photoTitle(item)
                }
            }
            ToolbarItem(id: "back", placement: .navigation) {
                Button { if !closeExpandedMap() { model.viewerID = nil } } label: { Label("Back", systemImage: "chevron.backward") }
                    .help(expandedMap == nil ? "Back to grid" : "Back to photo")
            }
            // Over the opened-out map, the photo's zoom and faces would act on the photo hidden under it.
            // The photo's items stay from one photo to the next, dimmed where they don't apply (a video has no zoom
            // or faces, most photos aren't Live), so stepping doesn't change the toolbar's layout. Over the opened-out
            // map they go: they would act on the photo hidden under it.
            if expandedMap == nil {
                // Photos' zoom slider, beside Back; it draws its own capsule, apart from Back's.
                if #available(macOS 26, *) {
                    photoZoomSlider.sharedBackgroundVisibility(.hidden)
                } else {
                    photoZoomSlider
                }
                if session.features.facialRecognition && photoFaces.supported {
                    if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
                    PeopleFaceToolbarItems(showingList: $showingFaceList, isEnabled: canShowFaces)
                }
                ToolbarItem(id: "live") {
                    Toggle(isOn: $playLive) { Label("Live", systemImage: "livephoto") }
                        .help("Play Live Photo")
                        .disabled(viewerItem?.livePhotoVideoID == nil)
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
            if model.showsSectionHeaders {
                // The date scroller beside the grid: a calendar with a timeline at its trailing edge.
                ToolbarItem(id: "dateScroller") {
                    Toggle(isOn: $showsDateScroller) { Label("Date Scroller", systemImage: "calendar.day.timeline.trailing") }
                        .help(showsDateScroller ? "Hide Date Scroller" : "Show Date Scroller")
                        .disabled(!grid)
                }
            }
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
    /// ⌫ in an album: takes the photos out of it.
    var onRemove: ([String]) -> Void = { _ in }
    /// Above the photos, scrolling with them.
    var scrollHeader: AnyView?
    /// A quieter message for a page whose header already holds what there is, such as a folder of subfolders.
    @Environment(\.gridEmptyNote) private var emptyNote
    /// Where the squares are, for an open photo to fly out of and back into.
    var cellFrames: ViewerCellFrames?

    @AppStorage("gridThumbnailSize") private var thumbnailSize = GridMetrics.defaultSize
    @State private var zoomBase: Double?
    @State private var gridWidth: CGFloat = 0
    /// Whole photos in their own shape, rather than cropped to squares, as Photos' Aspect Ratio grid.
    @AppStorage(GridMetrics.aspectRatioKey) private var aspectRatio = false
    /// The size and shape the grid shows, which follow the saved ones with Photos' transition.
    @State private var shownSize = UserDefaults.standard.object(forKey: "gridThumbnailSize") as? Double ?? GridMetrics.defaultSize
    @State private var shownFit = UserDefaults.standard.bool(forKey: GridMetrics.aspectRatioKey)
    @State private var visibleCells = VisibleCells()
    @State private var emptyHeaderHeight: CGFloat = 0
    @AppStorage(TimelineRail.shownKey) private var showsDateScroller = true
    /// Follows `showsDateScroller`, keeping the first photo in view where it was as the columns change.
    @State private var shownRail = UserDefaults.standard.object(forKey: TimelineRail.shownKey) as? Bool ?? true
    @State private var railPosition = TimelineRailPosition()

    var body: some View {
        Group {
            // Months a filter emptied still count as empty (Assign Location).
            if model.sections.allSatisfy({ model.shownCount($0) == 0 }) {
                if let scrollHeader {
                    // The header stays at the top and scrolls when it is taller than the window (a folder with many
                    // subfolders); the message fills the space left below it.
                    ScrollView {
                        VStack(spacing: 0) {
                            scrollHeader
                                .onScrollVisibilityChange(threshold: 0.25) { model.headerInView = $0 }
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { emptyHeaderHeight = $0 }
                            emptyContent.containerRelativeFrame(.vertical) { height, _ in max(160, height - emptyHeaderHeight) }
                        }
                    }
                } else {
                    emptyContent
                }
            } else {
                grid
            }
        }
    }

    /// Loading, a failure or why there are no photos, filling the space it is given.
    private var emptyContent: some View {
        Group {
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
                case .loaded where model.uncheckedLocationMonths > 0:
                    // Months that failed weren't checked, so this can't say every item has a location.
                    ContentUnavailableView {
                        Label("Couldn't Check Every Month", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("\(model.uncheckedLocationMonths) months couldn't be loaded, so items without a location may be missing.")
                    } actions: {
                        Button("Try Again") { model.retryLocationCheck() }
                    }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyState: some View {
        if let note = emptyNote {
            Text(note).foregroundStyle(.secondary).padding()
        } else {
            defaultEmptyState
        }
    }

    private var defaultEmptyState: some View {
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
        case .explore(.folder): ("No Photos", "folder")
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
                        ForEach((0..<model.shownCount(section)).map { CellKey(section: section.id, index: $0, asset: section.assets?[$0].id) }, id: \.self) { key in
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
            if let first = visibleCells.first(in: model.sections),
               let section = model.sections.first(where: { $0.id == first.section }) {
                railPosition.month = first.section
                railPosition.progress = Double(first.index) / Double(max(1, section.count))
            }
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
        // The scroller's space changes the columns: the photo in the middle of the view stays in the middle. The grid
        // lays out its new columns first, and a lazy grid's first scroll deep in a large library lands on its estimate
        // of the rows above, so it scrolls a second time once they're measured.
        .onChange(of: showsDateScroller) { _, shown in
            let anchor = visibleCells.middle(in: model.sections)
            shownRail = shown
            guard let anchor else { return }
            Task { @MainActor in
                await Task.yield()
                proxy.scrollTo(anchor, anchor: .center)
                try? await Task.sleep(for: .milliseconds(30))
                proxy.scrollTo(anchor, anchor: .center)
            }
        }
        .onChange(of: aspectRatio) { _, fit in
            withAnimation(.smooth(duration: 0.35)) { shownFit = fit }
        }
        // The grid's columns, for moving up and down a row: an adaptive grid fits as many minimum-width items
        // as the width holds.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        .onChange(of: GridColumns(width: photosWidth, size: shownSize), initial: true) { _, columns in
            model.columns = columns.count
        }
        .safeAreaInset(edge: .trailing, spacing: 0) {
            if let months = railMonths {
                let columns = GridColumns(width: photosWidth, size: shownSize).count
                TimelineRail(sections: months, columns: columns,
                             rowHeight: (photosWidth - 2 * CGFloat(columns - 1)) / CGFloat(columns) + 2,
                             position: railPosition) { section in
                    proxy.scrollTo(CellKey(section: section.id, index: 0, asset: section.assets?.first?.id), anchor: .top)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Assign Location: the list leaves out months whose check failed.
            if model.uncheckedLocationMonths > 0 {
                HStack {
                    Label("\(model.uncheckedLocationMonths) months couldn't be loaded, so items without a location may be missing.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Try Again") { model.retryLocationCheck() }
                }
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.bar)
            }
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
        // ⌫ is the key of the Edit menu's Delete, which takes it before the grid sees it.
        .onDeleteCommand { delete(Array(model.selection), command: false) }
    }

    /// The months the date scroller shows: a timeline's, as months with headers, and enough of them to scroll through.
    private var railMonths: [GridSection]? {
        guard shownRail, model.showsSectionHeaders else { return nil }
        let months = model.sections.filter { model.shownCount($0) > 0 }
        guard months.count >= 3, months.allSatisfy({ TimelineRailLayout.isMonth($0.id) }) else { return nil }
        return months
    }

    /// The photos' width, beside the date scroller.
    private var photosWidth: CGFloat {
        max(0, gridWidth - (railMonths == nil ? 0 : TimelineRail.inset))
    }

    /// As in Photos: ⌘⌫ deletes; ⌫ takes the photos out of an album, and deletes them elsewhere.
    private func delete(_ ids: [String], command: Bool) {
        guard !ids.isEmpty else { return }
        if command || model.source.albumID == nil { onDelete(ids) } else { onRemove(ids) }
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
        return gridCell {
            Group {
                if let asset {
                    if #available(macOS 26, *) {
                        // One drag source (`macOriginalContainerItem`) carries the original and album IDs.
                        thumbnail
                    } else {
                        // Locked items can't be dropped on albums; they can still be dragged out as files.
                        let albumIDs = model.source == .locked ? nil : AlbumAssetTransfer(ids: model.selection.contains(asset.id) ? Array(model.selection) : [asset.id])
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
            .macOriginalContainerItem(asset.map { model.macOriginalTransfer($0.id, isVideo: $0.isVideo, client: session.client) })
        }
        .onAppear { model.cellAppeared(section: s, item: i) }
        .onGeometryChange(for: ViewerCellFrame.self) { geometry in
            ViewerCellFrame(id: asset?.id, frame: geometry.frame(in: .named(ViewerCellFrames.space)))
        } action: { cell in
            if let id = cell.id { cellFrames?.frames[id] = cell.frame }
        }
        .onDisappear { if let id = asset?.id { cellFrames?.frames[id] = nil } }
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
            guard !ids.isEmpty, press.modifiers.isDisjoint(with: [.shift, .option, .control]) else { return .ignored }
            delete(ids, command: press.modifiers.contains(.command))
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

    /// The cell in the middle of those in view, in the grid's order.
    func middle(in sections: [GridSection]) -> CellKey? {
        let order = Dictionary(sections.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = keys.sorted { (order[$0.section] ?? 0, $0.index) < (order[$1.section] ?? 0, $1.index) }
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
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
                if asset.isFavorite {
                    // On a dark plate, so it shows on snow and sky too.
                    Image(systemName: "heart.fill")
                        .padding(3)
                        .background(.black.opacity(0.45), in: .rect(cornerRadius: 4))
                }
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
