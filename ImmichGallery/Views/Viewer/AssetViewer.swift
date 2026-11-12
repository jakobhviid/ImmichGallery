import AVKit
import SwiftUI

/// Single-asset viewer shown in place of the grid (like double-clicking in Photos). Below the photo, a two-finger scroll
/// down, are its people, its place and its details, as Photos has them; the Info panel (⌘I) shows them beside it too.
struct AssetViewer: View {
    @Environment(LibrarySession.self) private var session
    @Bindable var model: AssetGridModel
    let item: AssetItem
    @Binding var playLive: Bool
    let onDelete: ([String]) -> Void
    var onTags: ([String], Bool) -> Void = { _, _ in }
    /// ⌫ in an album: takes the photo out of it.
    var onRemove: ([String]) -> Void = { _ in }
    /// The toolbar's zoom buttons, ⌘+ and ⌘−.
    var zoomRequest: PhotoZoomRequest?
    /// Z, which the page turns into a zoom request.
    var onZoom: (PhotoZoomRequest.Zoom) -> Void = { _ in }
    /// The face boxes to draw, while the page shows face names.
    var faces: [PeopleFace] = []
    /// Pinching the photo smaller than it fits closes it, as in Photos; the page flies it back into the grid from the
    /// scale the pinch left it at.
    var onPinchClose: ((Double) -> Void)?
    /// While a pinch shrinks the photo, the page shows the grid behind it, through the fading backdrop.
    var onPinchChange: (Bool) -> Void = { _ in }
    /// The photo's zoom, for the toolbar's slider.
    var onScaleChange: (Double) -> Void = { _ in }
    /// Double-clicking the map below the photo opens it out over the photo.
    var onExpandMap: (PhotoPlace) -> Void = { _ in }
    /// Esc and Back close what the page shows over the photo, such as the opened-out map, before the photo.
    var closeOverlay: () -> Bool = { false }
    /// A trackpad swipe that the photos follow, then the step it ends in (nil to spring back). Without them a swipe
    /// steps when it ends.
    var onSwipeDrag: ((CGFloat) -> Void)?
    var onSwipeEnd: ((Int?) -> Void)?
    /// The pointer is over the photo: the side arrows show, as in Photos. Kept by the page, because each photo gets a
    /// new viewer.
    var showsSideArrows = false

    @Environment(\.viewerContext) private var viewer
    var isPresentation = false
    @FocusState private var isFocused: Bool
    @State private var isZoomed = false
    /// The backdrop behind the photo, fading as a pinch shrinks it.
    @State private var backdrop = 1.0
    @State private var pinching = false

    var body: some View {
        Group {
            if isPresentation {
                media
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            media.frame(height: geometry.size.height)
                            AssetInspector(assetID: item.id, layout: .belowPhoto, onExpandMap: onExpandMap)
                                .frame(maxWidth: 900)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                    // A zoomed photo pans with two fingers instead.
                    .scrollDisabled(isZoomed)
                }
            }
        }
        .safeAreaInset(edge: .top) { if !isPresentation { AssetsStackButton(item: item, model: model).id(item.id) } }
        .deferredContextMenu {
            if let viewer {
                if !item.isVideo {
                    Button("Copy Image") { viewer.copy() }
                    Button("Copy Original Image") { viewer.copy(original: true) }
                }
                Button("Copy as File") { viewer.copy(asFile: true) }
                Divider()
            }
            if isPresentation {
                if model.source != .locked { Button("Show in All Photos") { viewer?.showInLibrary() } }
                AssetsExportMenu(ids: [item.id])
                if model.canMutate([item.id]), model.source != .locked {
                    Button("Move to Locked Folder") { Task { await model.moveToLockedFolder([item.id]) } }
                }
            } else {
                AssetActionsMenu(model: model, asset: item, ids: [item.id], onDelete: onDelete, onTags: onTags)
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .onKeyPress(action: handleKey)
        // ⌫ is the key of the Edit menu's Delete, which takes it before the viewer sees it.
        .onDeleteCommand { delete(command: false) }
        .onExitCommand {
            if isPresentation { viewer?.close() } else if !closeOverlay() { model.viewerID = nil }
        }
        .task(id: item.id) { await prefetchNeighbours() }
    }

    /// As in Photos: ⌘⌫ deletes; ⌫ takes the photo out of an album, and deletes it elsewhere.
    private func delete(command: Bool) {
        if command || model.source.albumID == nil { onDelete([item.id]) } else { onRemove([item.id]) }
    }

    private var media: some View {
        ZStack {
            if !isPresentation { Color(nsColor: .windowBackgroundColor).opacity(backdrop).ignoresSafeArea() }

            if viewer?.window != nil && !isPresentation {
                Color(nsColor: .windowBackgroundColor)
            } else if item.isVideo {
                VideoPlayerView(url: session.client.videoURL(item.id), headers: session.client.credential?.headers ?? [:],
                                playing: viewer?.slideshow != true || viewer?.paused != true,
                                onFinished: videoFinished,
                                onProgress: { viewer?.videoStalledElapsed = 0 },
                                onFailed: { if viewer?.slideshow == true && viewer?.paused != true { viewer?.step(1) } })
                    .id("\(item.id)-\(viewer?.playbackGeneration ?? 0)")
                    .modifier(ViewerVideoOptionsPlacement(visible: !isPresentation || viewer?.controlsVisible != false))
                    .draggable(OriginalTransfer(id: item.id, isVideo: true, client: session.client))
            } else {
                ZoomableImage(item: item, rotation: viewer?.rotation ?? 0, faces: faces, isZoomed: $isZoomed,
                              zoomRequest: zoomRequest, onPinchClose: isPresentation ? nil : onPinchClose,
                              onDoubleClick: isPresentation ? nil : { model.viewerID = nil },
                              onPinch: isPresentation ? nil : { scale in
                                  backdrop = scale.map(ViewerMotionLayout.backdrop(forPinch:)) ?? 1
                                  if pinching != (scale != nil) {
                                      pinching = scale != nil
                                      onPinchChange(pinching)
                                  }
                              },
                              onScaleChange: onScaleChange)
                    .id(item.id)
                if playLive, let videoID = item.livePhotoVideoID {
                    VideoPlayerView(
                        url: session.client.videoURL(videoID),
                        headers: session.client.credential?.headers ?? [:],
                        showsControls: false,
                        onFinished: { playLive = false })
                        .id(videoID)
                        .allowsHitTesting(false)
                }
            }

            if !isPresentation {
                HStack {
                    navButton("chevron.left", delta: -1)
                    Spacer()
                    navButton("chevron.right", delta: 1)
                }
                .padding(.horizontal, 16)
                .opacity(showsSideArrows ? 1 : 0)
                .allowsHitTesting(showsSideArrows)
                .animation(.easeInOut(duration: 0.2), value: showsSideArrows)
            }
        }
        .background(ViewerSwipeNavigation(
            isEnabled: !item.isVideo && !isZoomed && (isPresentation || viewer?.window == nil),
            isCurrent: { [model, id = item.id] in model.viewerID == id },
            onNavigate: { delta in
                if isPresentation { viewer?.stepWithoutWrapping(delta) } else { step(delta) }
            },
            onDrag: isPresentation ? nil : onSwipeDrag,
            onDragEnd: isPresentation ? nil : onSwipeEnd))
    }

    private var videoFinished: (@MainActor @Sendable () -> Void)? {
        guard let viewer, viewer.slideshow else { return nil }
        return { viewer.step(1) }
    }

    private func navButton(_ symbol: String, delta: Int) -> some View {
        Button { step(delta) } label: {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .adaptiveGlass(in: .circle, interactive: true)
        .opacity(0.9)
    }

    private func step(_ delta: Int) {
        if isPresentation { viewer?.step(delta); return }
        Task {
            if let next = await model.neighbor(of: item.id, delta: delta) {
                model.viewerID = next.id
                model.selection = [next.id]
            }
        }
    }

    private func prefetchNeighbours() async {
        for delta in [1, -1] {
            if let next = await (isPresentation ? viewer?.neighbor(of: item.id, delta: delta) : model.neighbor(of: item.id, delta: delta)), !next.isVideo {
                _ = await session.pipeline.thumbnail(next.id, size: .preview)
            }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !(NSApp.keyWindow?.firstResponder is NSText) else { return .ignored }
        // Photos' ⌥Space plays a Live Photo; it doesn't close the photo as Space does.
        if press.key == .space, press.modifiers.contains(.option) {
            if item.livePhotoVideoID != nil { playLive.toggle() }
            return .handled
        }
        if isPresentation {
            if press.key == .escape { viewer?.close(); return .handled }
            if press.key == .return { return .handled }
            if press.key == .space {
                if viewer?.slideshow == true { viewer?.paused.toggle() }
                return .handled
            }
        }
        switch press.key {
        case .leftArrow: step(-1)
        case .rightArrow: step(1)
        case .escape where closeOverlay(): break
        case .space where !item.isVideo, .escape, .return: model.viewerID = nil
        case .delete, .deleteForward:
            guard press.modifiers.isDisjoint(with: [.shift, .option, .control]) else { return .ignored }
            delete(command: press.modifiers.contains(.command))
        default:
            if press.characters == "z", press.modifiers.isEmpty, !item.isVideo {
                onZoom(.toggle) // Photos' Z
            } else if press.characters == "." {
                Task { await model.toggleFavorite([item.id]) }
            } else {
                return .ignored
            }
        }
        return .handled
    }
}

/// Zooming the open photo, from the toolbar's buttons, ⌘+ and ⌘−, or Z; each press is a new request.
struct PhotoZoomRequest: Equatable {
    enum Zoom: Equatable {
        case zoomIn, zoomOut, toggle
        /// The toolbar's slider: this scale, 1 being fitted.
        case to(Double)
    }
    let zoom: Zoom
    let generation: Int
}

/// The page's zoom for its open photo, for the View menu's Zoom In and Zoom Out.
struct PhotoZoomAction {
    let zoom: (PhotoZoomRequest.Zoom) -> Void
}

/// Shows the cached thumbnail instantly, then the preview, and fetches the original once the
/// user zooms in past 1×. Pinch or double-click to zoom, drag or scroll to pan. On an HDR display, HDR
/// originals are drawn in extended dynamic range over the SDR preview.
private struct ZoomableImage: View {
    @Environment(LibrarySession.self) private var session
    let item: AssetItem
    let rotation: Int
    var faces: [PeopleFace] = []
    @Binding var isZoomed: Bool
    var zoomRequest: PhotoZoomRequest?
    var onPinchClose: ((Double) -> Void)?
    /// Double-clicking the photo closes it, as in Photos; the full-screen viewer zooms instead.
    var onDoubleClick: (() -> Void)?
    /// A pinch below fitted size, and nil when it ends.
    var onPinch: ((Double?) -> Void)?
    var onScaleChange: ((Double) -> Void)?
    @AppStorage(HDRPhotos.enabledKey) private var showHDR = true

    @State private var image: CGImage?
    @State private var hdrImage: CGImage?
    @State private var hdrCandidate: Bool?
    @State private var hasOriginal = false
    @State private var scale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?

    var body: some View {
        GeometryReader { geo in
            let swapsAxes = abs(rotation % 180) == 90
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .overlay {
                            if let hdrImage { HDRImageLayer(image: hdrImage).allowsHitTesting(false) }
                        }
                        // On the photo itself, so the boxes zoom and pan with it.
                        .overlay {
                            Group {
                                if rotation % 360 == 0, !faces.isEmpty { PhotoFaceBoxes(faces: faces, zoom: scale * gestureScale) }
                            }
                            .animation(.easeInOut(duration: 0.2), value: faces.isEmpty)
                        }
                        .macOriginalDraggable(OriginalTransfer(id: item.id, client: session.client),
                                              isEnabled: scale * gestureScale <= 1)
                } else if let hash = item.thumbhash, let placeholder = ThumbHash.image(base64: hash) {
                    Image(decorative: placeholder, scale: 1)
                        .resizable()
                        .aspectRatio(item.ratio, contentMode: .fit)
                    ProgressView().controlSize(.large)
                }
            }
            // The photo fades in over its blurred placeholder, and the HDR version over the photo.
            .animation(.easeOut(duration: 0.2), value: image == nil)
            .animation(.easeOut(duration: 0.3), value: hdrImage != nil)
            .frame(width: swapsAxes ? geo.size.height : geo.size.width, height: swapsAxes ? geo.size.width : geo.size.height)
            .rotationEffect(.degrees(Double(rotation)))
            .frame(width: geo.size.width, height: geo.size.height)
            .scaleEffect(scale * gestureScale)
            .offset(offset)
            .contentShape(Rectangle())
            .gesture(magnify)
            .simultaneousGesture(pan(in: geo.size), isEnabled: scale * gestureScale > 1)
            .onTapGesture(count: 2) { if let onDoubleClick { onDoubleClick() } else { toggleZoom() } }
        }
        .clipped()
        .background(ViewerSmartZoom(onSmartZoom: toggleZoom))
        .background(ViewerScrollPan(isEnabled: scale * gestureScale > 1) { delta in
            offset.width += delta.width
            offset.height += delta.height
        })
        .task { await load() }
        .task(id: [showHDR, hasOriginal]) { await loadDetail() }
        .onChange(of: scale * gestureScale) { _, value in isZoomed = value > 1 }
        .onChange(of: scale) { _, newValue in
            if newValue > 1.1 { hasOriginal = true }
        }
        .onChange(of: zoomRequest) { _, request in
            if let request { zoom(request.zoom) }
        }
        .onChange(of: scale, initial: true) { _, value in onScaleChange?(value) }
    }

    /// A two-finger double-tap and Z, and double-clicking in the full-screen viewer: in, or back to fit.
    private func toggleZoom() {
        withAnimation(.snappy) {
            if scale > 1 { scale = 1; offset = .zero } else { scale = 2.5 }
        }
    }

    /// Keeps the point in the middle of the view where it is, as pinching does. Toggling zooms as double-clicking does.
    private func zoom(_ zoom: PhotoZoomRequest.Zoom) {
        let target: CGFloat = switch zoom {
        case .zoomIn: min(8, scale * 1.5)
        case .zoomOut: max(1, scale / 1.5)
        case .toggle: scale > 1 ? 1 : 2.5
        case .to(let value): min(8, max(1, value))
        }
        if case .to = zoom {
            // The toolbar's slider: follows it as it moves, without an animation trailing behind.
            offset = target <= 1 ? .zero : CGSize(width: offset.width * target / scale, height: offset.height * target / scale)
            scale = target
            return
        }
        withAnimation(.snappy) {
            offset = target <= 1 ? .zero : CGSize(width: offset.width * target / scale, height: offset.height * target / scale)
            scale = target
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                gestureScale = value.magnification
                if scale <= 1 { onPinch?(min(1, value.magnification)) }
            }
            .onEnded { value in
                if scale <= 1, value.magnification < ViewerMotionLayout.pinchCloseScale, let onPinchClose {
                    onPinchClose(value.magnification)
                    return
                }
                // A pinch that didn't close springs back to fitted size, and the backdrop with it.
                let shrunk = scale * value.magnification < 1
                withAnimation(shrunk ? .snappy : nil) {
                    scale = min(8, max(1, scale * value.magnification))
                    gestureScale = 1
                    onPinch?(nil)
                }
                if scale == 1 { withAnimation(.snappy) { offset = .zero } }
            }
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard scale > 1 else { return }
                let start = dragStart ?? offset
                dragStart = start
                offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func load() async {
        let pipeline = session.pipeline
        image = pipeline.cachedThumbnail(item.id, size: .preview) ?? pipeline.cachedThumbnail(item.id, size: .thumbnail)
        if let preview = await pipeline.thumbnail(item.id, size: .preview) { image = preview }
    }

    /// Caps a zoomed HDR bitmap (8 bytes per pixel) at about 230 MB.
    private static let zoomedHDRPixelSize = 6144

    /// HDR original when the setting, display and photo allow it (re-decoded larger once zoomed),
    /// otherwise the SDR original once zoomed. One task, restarted when either input changes,
    /// so a zoom during the HDR load doesn't download the original twice.
    private func loadDetail() async {
        var hdr: CGImage?
        if showHDR, HDRPhotos.displaySupportsHDR, await isHDRCandidate() {
            let size = hasOriginal ? Self.zoomedHDRPixelSize : HDRPhotos.screenPixelSize
            hdr = await session.pipeline.hdrOriginal(item.id, maxPixelSize: size)
        }
        guard !Task.isCancelled else { return }
        hdrImage = hdr
        if hdr == nil, hasOriginal, let original = await session.pipeline.original(item.id, edited: true), !Task.isCancelled {
            image = original
        }
    }

    /// Immich doesn't flag HDR photos; skip formats that can't be HDR before downloading.
    private func isHDRCandidate() async -> Bool {
        if let hdrCandidate { return hdrCandidate }
        guard let asset = try? await session.client.asset(item.id), !Task.isCancelled else { return false }
        hdrCandidate = HDRPhotos.mayContainHDR(mimeType: asset.originalMimeType)
        return hdrCandidate ?? false
    }
}

/// Authenticated range playback. Sound settings persist across assets and app launches.
struct VideoPlayerView: NSViewRepresentable {
    let url: URL
    let headers: [String: String]
    var showsControls = true
    var playing = true
    var onFinished: (@MainActor @Sendable () -> Void)?
    var onProgress: (@MainActor @Sendable () -> Void)?
    var onFailed: (@MainActor @Sendable () -> Void)?
    @AppStorage("viewer.videoLoop") private var loop = false
    @AppStorage("viewer.videoSpeed") private var speed = 1.0

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = showsControls ? .floating : .none
        view.allowsPictureInPicturePlayback = showsControls
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers]))
        let player = AVPlayer(playerItem: item)
        player.isMuted = UserDefaults.standard.bool(forKey: "viewer.videoMuted")
        player.volume = UserDefaults.standard.object(forKey: "viewer.videoVolume") as? Float ?? 1
        view.player = player
        context.coordinator.onFailed = onFailed
        context.coordinator.observe(player, item: item)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onFinished = onFinished
        coordinator.onProgress = onProgress
        coordinator.onFailed = onFailed
        coordinator.loop = loop && showsControls
        if coordinator.playing != playing || coordinator.speed != speed {
            coordinator.playing = playing
            coordinator.speed = speed
            if playing { view.player?.playImmediately(atRate: Float(speed)) } else { view.player?.pause() }
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        coordinator.stop()
        view.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var onFinished: (@MainActor @Sendable () -> Void)?
        var onProgress: (@MainActor @Sendable () -> Void)?
        var onFailed: (@MainActor @Sendable () -> Void)?
        private weak var player: AVPlayer?
        private var progressToken: Any?
        private var lastTime = CMTime.zero
        var loop = false
        var playing: Bool?
        var speed = 0.0
        private var token: NSObjectProtocol?
        private var observations: [NSKeyValueObservation] = []

        func observe(_ player: AVPlayer, item: AVPlayerItem) {
            self.player = player
            progressToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, time != self.lastTime else { return }
                    self.lastTime = time
                    self.onProgress?()
                }
            }
            observations = [
                item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    if item.status == .failed {
                        Task { @MainActor [weak self] in self?.onFailed?() }
                    }
                },
                player.observe(\.volume, options: [.new]) { player, _ in UserDefaults.standard.set(player.volume, forKey: "viewer.videoVolume") },
                player.observe(\.isMuted, options: [.new]) { player, _ in UserDefaults.standard.set(player.isMuted, forKey: "viewer.videoMuted") }
            ]
            token = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self, weak player] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let onFinished = self.onFinished { onFinished() }
                    else if self.loop {
                        player?.seek(to: .zero)
                        player?.playImmediately(atRate: Float(self.speed))
                    }
                }
            }
        }

        func stop() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            observations = []
            if let progressToken { player?.removeTimeObserver(progressToken) }
            progressToken = nil
            player = nil
        }
    }
}

/// macOS 26 floats the video options over the player. On macOS 15 the AVPlayerView draws
/// above SwiftUI overlays, hiding them, so the options sit in a strip above the video there.
private struct ViewerVideoOptionsPlacement: ViewModifier {
    let visible: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.overlay(alignment: .topTrailing) { options.padding() }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) {
                HStack { Spacer(); options }.padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
    }

    private var options: some View {
        ViewerVideoOptions()
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
    }
}
