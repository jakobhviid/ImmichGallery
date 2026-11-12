import SwiftUI

@main
struct ImmichGalleryApp: App {
    @NSApplicationDelegateAdaptor(MacIntegrationLifecycle.self) private var lifecycle
    @State private var app = AppModel()
    @Environment(\.openWindow) private var openWindow

    init() {
        MacTransferCache.prune() // MacIntegration
        SharingTemporaryFiles.sweep() // Sharing
        Task.detached { UploadMultipart.sweepStale() } // Upload
        ViewerState.pruneClipboard() // Viewer
        LockedFolderMedia.sweep() // Explore
    }

    var body: some Scene {
        WindowGroup("Immich Gallery", id: "main", for: MacWindowRoute.self) { route in
            MacWindowRoot(app: app, route: route.wrappedValue, photoOpened: { route.wrappedValue?.photoID = nil })
                .environment(app)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .onChange(of: MacIntegrationRouter.shared.pending, initial: true) { openPendingIntents() }
        .onChange(of: MacIntegrationRouter.shared.widgetLinks, initial: true) { openWidgetLinks() } // Widget
        .onChange(of: MacIntegrationRouter.shared.crosslinks, initial: true) { openCrosslinks() } // Crosslink
        .onChange(of: app.services.map(ObjectIdentifier.init)) {
            CrosslinkReceiver.accountChanged() // Crosslink: links of the account before are dropped
            openPendingIntents(); openWidgetLinks(); openCrosslinks()
        }
        .commands { AppCommands(app: app); AdminCommands(app: app); UploadCommands(app: app); ViewerCommands(); MacIntegrationCommands(); UpdateCommands(updater: .shared) }

        AdminScene(app: app) // Admin

        ExploreMemoryScene(app: app) // Explore

        WidgetPhotoScene(app: app) // Widget

        Settings {
            AccountSettingsTabs() // Account
                .environment(app)
        }
    }

    private func openPendingIntents() {
        guard app.services != nil else { return }
        let routes = MacIntegrationRouter.shared.pending
        MacIntegrationRouter.shared.pending.removeAll()
        for route in routes { openWindow(id: "main", value: route) }
    }

    // Crosslink: links wait until the app knows whether it is signed in.
    private func openCrosslinks() {
        let router = MacIntegrationRouter.shared
        guard !router.crosslinks.isEmpty else { return }
        if case .launching = app.phase {
            Task { try? await Task.sleep(for: .milliseconds(300)); openCrosslinks() }
            return
        }
        let links = router.crosslinks
        router.crosslinks.removeAll()
        for link in links {
            CrosslinkReceiver.open(link, app: app) { openWindow(id: "main", value: MacWindowRoute()) }
        }
    }

    // Widget
    private func openWidgetLinks() {
        let router = MacIntegrationRouter.shared
        if router.widgetLinks.contains(.open) {
            router.widgetLinks.removeAll { $0 == .open }
            // Let a window SwiftUI opens at launch appear first, so we don't add a second one.
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                let hasLibrary = NSApp.windows.contains { $0.isVisible && $0.tabbingIdentifier == MacWindowRoute.tabbingIdentifier }
                if !hasLibrary { openWindow(id: "main", value: MacWindowRoute()) }
            }
        }
        guard app.services != nil, !router.widgetLinks.isEmpty else { return }
        let links = router.widgetLinks
        router.widgetLinks.removeAll()
        for link in links {
            switch link {
            case .memory(let id): openWindow(id: "explore-memory", value: id)
            case .photo(let id): openWidgetPhoto(id)
            case .open: break
            }
        }
    }

    /// Opens the photo in All Photos, in the frontmost library window or a new one.
    private func openWidgetPhoto(_ id: String) {
        Task {
            // At launch, the first library window may still be setting up its session.
            for attempt in 0..<10 {
                let window = NSApp.orderedWindows.first {
                    ($0.isVisible || $0.isMiniaturized) && $0.tabbingIdentifier == MacWindowRoute.tabbingIdentifier
                }
                if let window, let session = app.services?.windows.allObjects.first(where: { $0.macWindow === window }) {
                    if window.isMiniaturized { window.deminiaturize(nil) }
                    window.makeKeyAndOrderFront(nil)
                    session.openFromWidget(id) { openWindow(id: "widget-photo", value: id) }
                    return
                }
                if window == nil && attempt >= 4 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            openWindow(id: "main", value: MacWindowRoute(photoID: id))
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Group {
            switch app.phase {
            case .launching: ProgressView().controlSize(.large)
            case .signedOut: LoginView()
            case .signedIn: ProgressView()
            }
        }
        .task { await app.restore() }
    }
}

/// Kept inside the split view's detail column so native sidebar safe areas stay intact.
struct AccountPasswordBanner: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var changingPassword = false

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if app.services?.requiresPasswordChange == true {
                HStack {
                    Text("Your server asks you to change your password.")
                    Button("Change Password…") { changingPassword = true }
                }.padding(8).frame(maxWidth: .infinity).background(.bar)
            }
        }
        .onChange(of: app.services.map(ObjectIdentifier.init)) { changingPassword = false }
        .sheet(isPresented: $changingPassword, onDismiss: { changingPassword = false }) {
            if let services = app.services {
                VStack {
                    AccountSecurityView(session: services)
                    Button("Done") { changingPassword = false }.padding()
                }.frame(width: 640, height: 650)
            }
        }
    }
}

struct AccountChrome: ViewModifier {
    @Environment(AppModel.self) private var app
    func body(content: Content) -> some View {
        content
            .alert("Account Error", isPresented: Binding(get: { app.accountError != nil }, set: { if !$0 { app.accountError = nil } })) {
                Button("OK") { app.accountError = nil }
            } message: { Text(app.accountError ?? "") }
    }
}

// MARK: - Menu commands

struct SearchActions {
    var find: () -> Void
    var filters: () -> Void
}

struct SidebarActions {
    var editing: Binding<Bool>
}

extension FocusedValues {
    @Entry var searchActions: SearchActions?
    @Entry var sidebarActions: SidebarActions?
    @Entry var librarySession: LibrarySession?
    @Entry var gridModel: AssetGridModel?
    /// Library's Years, Months and All Photos, while Library is shown.
    @Entry var libraryMode: Binding<LibraryMode>?
    /// While a photo is open, on a server that finds faces.
    @Entry var faceNamesAvailable: Bool?
    /// While a photo is open: ⌘+ and ⌘− zoom it rather than the grid behind it.
    @Entry var photoZoom: PhotoZoomAction?
}

struct AppCommands: Commands {
    let app: AppModel
    @FocusedValue(\.searchActions) private var searchActions
    @FocusedValue(\.sidebarActions) private var sidebarActions
    @FocusedValue(\.gridModel) private var grid
    @FocusedValue(\.libraryMode) private var libraryMode
    @FocusedValue(\.faceNamesAvailable) private var faceNamesAvailable
    @FocusedValue(\.photoZoom) private var photoZoom
    @AppStorage(PhotoFaces.shownKey) private var faceNamesShown = false
    @FocusedValue(\.librarySession) private var session
    @AppStorage("gridThumbnailSize") private var thumbnailSize = GridMetrics.defaultSize
    @AppStorage(GridMetrics.aspectRatioKey) private var aspectRatio = false
    @AppStorage("showInspector") private var showInspector = false

    private var overviewShown: Bool { libraryMode.map { $0.wrappedValue != .all } ?? false }

    /// Library's Years, Months or All Photos, with Photos' ⌘1, ⌘2 and ⌘3.
    private func libraryModeItem(_ mode: LibraryMode, key: KeyEquivalent) -> some View {
        Toggle(isOn: Binding(get: { libraryMode?.wrappedValue == mode }, set: { _ in libraryMode?.wrappedValue = mode })) {
            Text(mode.title)
        }
        .keyboardShortcut(key, modifiers: .command)
        .disabled(libraryMode == nil || grid?.viewerID != nil)
    }

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            if session != nil {
                if app.entries.count > 1 { // Account: reachable while the sidebar is hidden.
                    Menu("Switch Account") {
                        ForEach(app.entries) { entry in
                            Button("\(entry.email) · \(entry.account.serverURL.host() ?? "")") {
                                Task {
                                    do { try await app.switchAccount(entry) }
                                    catch { app.accountError = error.localizedDescription }
                                }
                            }.disabled(app.currentAccountID == entry.id || app.switching)
                        }
                    }
                }
                Button("Sign Out…") { Task { await app.signOut() } }
            }
        }

        CommandGroup(after: .newItem) {
            Button("New Album…") { session?.albumActions.newAlbum() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(session == nil)
        } // Albums

        CommandGroup(after: .importExport) {
            Button("Export Unmodified Original…") {
                if let grid { Exporter.exportOriginals(grid.selectedItems.map(\.id), session: grid.session ?? session) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(grid?.selection.isEmpty ?? true)
        }

        CommandGroup(after: .textEditing) {
            Button("Find") { searchActions?.find() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(searchActions == nil)
            Button("Search Filters…") { searchActions?.filters() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(searchActions == nil)
        }

        CommandGroup(after: .pasteboard) {
            Button("Select All Photos") { grid?.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(grid == nil || grid?.viewerID != nil || overviewShown)
            Button("Deselect All") { grid?.selection = [] }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(overviewShown || (grid.map { $0.selection.isEmpty || $0.viewerID != nil } ?? true))
        }

        CommandGroup(after: .sidebar) {
            Toggle("Edit Sidebar", isOn: sidebarActions?.editing ?? .constant(false))
                .disabled(sidebarActions == nil)
        }

        CommandGroup(before: .sidebar) {
            libraryModeItem(.years, key: "1")
            libraryModeItem(.months, key: "2")
            libraryModeItem(.all, key: "3")
            Divider()
            // The grid's size, so not while a photo hides the grid; the photo has its own buttons.
            // With a photo open, the photo zooms, as in Photos; the grid behind it doesn't. Not with a video open.
            Button("Zoom In") {
                if let photoZoom { photoZoom.zoom(.zoomIn) } else { thumbnailSize = GridMetrics.zoomIn(thumbnailSize) }
            }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(grid?.viewerID != nil && photoZoom == nil)
            Button("Zoom Out") {
                if let photoZoom { photoZoom.zoom(.zoomOut) } else { thumbnailSize = GridMetrics.zoomOut(thumbnailSize) }
            }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(grid?.viewerID != nil && photoZoom == nil)
            Button(aspectRatio ? "Show Square Photos" : "Show Aspect Ratio") { aspectRatio.toggle() }
            Divider()
            Button("Refresh") {
                if let session = session {
                    session.metadata.revision += 1
                    session.invalidateGrids()
                }
                if let grid { Task { await grid.reload() } }
            }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(grid == nil)
            Divider()
            Button(faceNamesShown ? "Hide Face Names" : "Show Face Names") { faceNamesShown.toggle() } // Photos' View menu
                .disabled(faceNamesAvailable != true)
            Button(showInspector ? "Hide Info" : "Show Info") { showInspector.toggle() }
                .keyboardShortcut("i", modifiers: .command)
            Divider()
        }

        CommandMenu("Image") {
            // A Locked Folder grid has its own session, with its own client.
            if let session = grid?.session ?? session {
                let metadataIDs = grid?.viewerID.map { [$0] } ?? Array(grid?.selection ?? [])
                MetadataMenuItems(ids: metadataIDs, canEditImage: true, menuBarShortcuts: true)
                    .environment(session)
                    .disabled(grid?.canMutate(metadataIDs) != true || session.metadata.busy)
                Divider()
            }
            let ids = grid?.viewerID.map { [$0] } ?? grid?.selectedItems.map(\.id) ?? []
            if grid?.source == .locked {
                Button("Remove from Locked Folder") { if let grid { Task { await grid.removeFromLockedFolder(ids) } } }
                    .disabled(grid?.canMutate(ids) != true) // Explore
            } else {
                if let session = session { AlbumSelectionMenu(session: session, model: grid, ids: ids, menuBarShortcuts: true) } // Albums
                if session != nil, grid?.source != .trash { WidgetChosenMenuItem(ids: ids) } // Widget
                Button("Move to Locked Folder") { if let grid { Task { await grid.moveToLockedFolder(ids) } } }
                    .disabled(ids.isEmpty || grid?.canMutate(ids) != true) // Explore
            }
            // "." and ⌘⌫ are handled by the grid/viewer so they don't steal keys from text fields.
            Button("Favorite (.)") { if let grid { Task { await grid.toggleFavorite(ids) } } }
                .disabled(grid?.canMutate(ids) != true)
            if grid?.source == .archive {
                Button("Unarchive") { if let grid { Task { await grid.setArchived(ids, false) } } }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(grid?.canMutate(ids) != true)
            } else if grid?.source != .locked {
                Button(String(localized: "Archive Selected Photos")) { if let grid { Task { await grid.setArchived(ids, true) } } }
                    .keyboardShortcut("l", modifiers: .command) // Photos' Hide
                    .disabled(ids.isEmpty || grid?.canMutate(ids) != true)
            }
        }
    }
}
