import SwiftUI

/// Opens the photo clicked on the desktop widget (photos from a memory open the memory instead).
struct WidgetPhotoScene: Scene {
    let app: AppModel
    var body: some Scene {
        WindowGroup("Photo", id: "widget-photo", for: String.self) { $id in
            if let services = app.services, let id {
                WidgetPhotoWindow(services: services, id: id).id(ObjectIdentifier(services))
            } else {
                ContentUnavailableView("Sign In to View This Photo", systemImage: "photo",
                                       description: Text("Sign in from the main library window to continue."))
            }
        }
        .defaultSize(width: 1100, height: 760)
    }
}

private struct WidgetPhotoWindow: View {
    let services: AccountServices
    let id: String
    @State private var image: CGImage?
    @State private var asset: AssetResponse?
    @State private var failed = false
    @State private var locked = false

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else if locked {
                ContentUnavailableView("Photo in the Locked Folder", systemImage: "lock.fill",
                                       description: Text("Open it from the Locked Folder in Immich Gallery."))
            } else if failed {
                ContentUnavailableView("Photo Unavailable", systemImage: "photo",
                                       description: Text("It may have been deleted, or it belongs to another account."))
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .navigationTitle(asset.flatMap { ImmichDate.parse($0.localDateTime) }.map { Text(ImmichDate.day($0)) } ?? Text("Photo"))
        .navigationSubtitle(asset?.originalFileName ?? "")
        .task(id: id) {
            let fetched: AssetResponse
            do {
                fetched = try await services.client.asset(id)
            } catch {
                services.handle(error)
                failed = true
                return
            }
            // Locked Folder items are only shown inside the folder's own unlocked session, never through the shared
            // image cache or in a window of their own, whatever opened this one (a widget click, a crosslink).
            guard CrosslinkVisibility.canShow(fetched.visibility) else { locked = true; return }
            asset = fetched
            if let preview = await services.pipeline.thumbnail(id, size: .preview) { image = preview }
            if let full = await services.pipeline.thumbnail(id, size: .fullsize) { image = full }
            if image == nil { failed = true }
        }
    }
}

/// Adds photos to, or removes them from, the widget source "Chosen Photos".
struct WidgetChosenMenuItem: View {
    let ids: [String]
    var body: some View {
        let updater = WidgetFeedUpdater.shared
        if updater.isChosen(ids) {
            Button("Remove from Widget") { updater.setChosen(ids, false) }
        } else {
            Button("Show in Widget") { updater.setChosen(ids, true) }
                .disabled(ids.isEmpty)
        }
    }
}

// MARK: Opening a widget photo in All Photos

extension LibrarySession {
    /// Shows All Photos scrolled to the photo, with the photo open as if double-clicked. Photos that
    /// aren't in All Photos (archived, a partner's, from someone else's album) go to `fallback`.
    func openFromWidget(_ id: String, fallback: @escaping () -> Void) {
        NotificationCenter.default.post(name: .viewerShowLibrary, object: self)
        Task {
            do {
                let asset = try await client.asset(id)
                let library = gridModel(for: .library)
                await library.loadIfNeeded()
                try await library.loadForReveal(asset)
                guard library.item(id) != nil else { fallback(); return }
                closeViewer() // A full-screen viewer or slideshow from this window.
                library.viewerScrollTarget = id
                library.open(id)
            } catch {
                services.handle(error)
                fallback()
            }
        }
    }
}

/// Remembers the library window of a session, and opens the photo a new window was made for.
/// `opened` clears the photo from the window's route, so a restored window or an account switch
/// doesn't open it again.
struct WidgetPhotoOpener: ViewModifier {
    let session: LibrarySession
    let photoID: String?
    let opened: () -> Void
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .background(WindowReader { [weak session] in session?.macWindow = $0 })
            .task {
                guard let photoID else { return }
                opened()
                session.openFromWidget(photoID) { openWindow(id: "widget-photo", value: photoID) }
            }
    }
}

private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onWindow: (NSWindow?) -> Void
        init(onWindow: @escaping (NSWindow?) -> Void) { self.onWindow = onWindow; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}
