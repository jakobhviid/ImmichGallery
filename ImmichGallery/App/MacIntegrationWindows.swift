import SwiftUI

struct MacWindowRoute: Codable, Hashable {
    static let tabbingIdentifier = "ImmichGallery.library"
    var instance = UUID()
    var albumID: String?
    var query: String?
    var asTab: Bool?
    var photoID: String? // Widget: open this photo in All Photos.
}

struct MacWindowRoot: View {
    let app: AppModel
    let route: MacWindowRoute?
    var photoOpened: () -> Void = {} // Widget
    var body: some View {
        Group {
            if let services = app.services {
                MacSignedInWindow(services: services, route: route, photoOpened: photoOpened)
                    .id(ObjectIdentifier(services))
            } else { RootView() }
        }
        .modifier(AccountChrome())
        .background(MacWindowConfiguration(asTab: route?.asTab ?? false))
    }
}

struct MacSignedInWindow: View {
    let services: AccountServices
    let route: MacWindowRoute?
    var photoOpened: () -> Void = {} // Widget
    @State private var session: LibrarySession?
    var body: some View {
        Group {
            if let session {
                MainView(initialAlbumID: route?.albumID, initialSearch: route?.query).environment(session)
                    .modifier(WidgetPhotoOpener(session: session, photoID: route?.photoID, opened: photoOpened)) // Widget
            } else { ProgressView() }
        }
        .task { if session == nil { session = LibrarySession(services: services) } }
    }
}

/// Configure only the scene's actual window; never search NSApp.windows for a new panel.
private struct MacWindowConfiguration: NSViewRepresentable {
    let asTab: Bool
    func makeNSView(context: Context) -> NSView { WindowView(asTab: asTab) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowView: NSView {
        let asTab: Bool
        init(asTab: Bool) { self.asTab = asTab; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.tabbingIdentifier = MacWindowRoute.tabbingIdentifier
            window?.tabbingMode = asTab ? .preferred : .automatic
        }
    }
}

struct MacAlbumWindowMenu: View {
    @Environment(\.openWindow) private var openWindow
    let albumID: String

    var body: some View {
        Button("Open Album in New Window") { openWindow(id: "main", value: MacWindowRoute(albumID: albumID)) }
        Button("Open in New Tab") { openWindow(id: "main", value: MacWindowRoute(albumID: albumID, asTab: true)) }
    }
}

struct MacIntegrationCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "main", value: MacWindowRoute()) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Tab") { openWindow(id: "main", value: MacWindowRoute(asTab: true)) }
                .keyboardShortcut("t", modifiers: .command)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Show Tab Bar") { NSApp.keyWindow?.toggleTabBar(nil) }
        }
    }
}

final class MacIntegrationLifecycle: NSObject, NSApplicationDelegate {
    private var cleanupTimer: Timer?

    /// Clicks on the desktop widget arrive as `immichgallery://` URLs. Handling the Apple event
    /// directly stops SwiftUI from opening an extra library window for every click.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        // Crosslink: links from other Immich apps, read and checked when the app shows them.
        if text.lowercased().hasPrefix(Crosslink.scheme + ":") {
            MainActor.assumeIsolated { MacIntegrationRouter.shared.crosslinks.append(text) }
            return
        }
        guard let url = URL(string: text), let link = WidgetFeed.Link(url) else { return }
        MainActor.assumeIsolated { MacIntegrationRouter.shared.widgetLinks.append(link) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MacSelectAll.install()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in MacTransferCache.prune() }
        // A widget click can launch the app without a library window, whose view would restore the account.
        Task { await MacIntegrationRouter.shared.app?.restore() } // Widget
        AppUpdater.shared.checkAtLaunch() // Updates
    }
    func applicationWillTerminate(_ notification: Notification) {
        MacQuickLook.shared.dismiss()
        MacTransferCache.prune()
        LockedFolderMedia.sweep()
    }
}
