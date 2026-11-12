import AppKit
import UniformTypeIdentifiers
import Observation
import SwiftUI

// Crosslink: Show in <app> for the other apps that take immich-crosslink links, Copy Immich Link, opening the links
// they send, and the Immich crosslink switch in Settings. The links themselves are in App/Crosslink.swift.

enum CrosslinkSettings {
    static let enabledKey = "crosslink.enabled"
    /// Open in Immich and Copy Immich Link: the items' addresses in Immich's web app.
    static let webLinksKey = "crosslink.webLinks"
    /// Apps left out of the menus, by bundle id, one per line.
    static let hiddenKey = "crosslink.hidden"
    /// The apps seen, by bundle id, with their names and when they were last seen: Settings lists them while they
    /// are away, so they can be switched off or forgotten.
    static let seenKey = "crosslink.seen"
    /// An app not seen for this long is forgotten, its switch with it.
    static let forgetAfter: TimeInterval = 30 * 24 * 60 * 60
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static func hidden(_ stored: String) -> Set<String> { Set(stored.split(separator: "\n").map(String.init)) }
}

/// Another app that announces this draft and takes crosslinks, by the name and icon macOS gives it.
struct CrosslinkParticipant: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL
    let kinds: Set<Crosslink.Kind>
    /// Made once, at menu size: menus are built often.
    let icon: NSImage
    var id: String { bundleID }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.name == rhs.name && lhs.url == rhs.url && lhs.kinds == rhs.kinds
    }
    func hash(into hasher: inout Hasher) { hasher.combine(bundleID) }

    /// Sends the link to this app alone, never to the scheme's default handler, which could be any of them. An app
    /// need not be running: macOS starts it. One removed since the list was read, or that cannot start, says so.
    @MainActor func send(_ link: String) {
        guard let url = URL(string: link) else { return }
        let name = name
        guard FileManager.default.fileExists(atPath: self.url.path) else {
            CrosslinkDirectory.shared.refresh()
            return CrosslinkReceiver.tell(String(localized: "\(name) is no longer installed."))
        }
        NSWorkspace.shared.open([url], withApplicationAt: self.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            let reason = error.localizedDescription
            Task { @MainActor in
                CrosslinkReceiver.tell(String(localized: "Immich Gallery could not open \(name): \(reason)"))
            }
        }
    }
}

/// An app seen before, remembered while it is away.
struct CrosslinkSeenApp: Codable, Hashable, Identifiable {
    var id: String // bundle id
    var name: String
    var lastSeen: Date
}

/// The apps found, read again whenever this app becomes active or another app launches: macOS gives no signal when
/// apps are installed or removed, and menus are built too often to ask Launch Services each time.
@MainActor @Observable
final class CrosslinkDirectory {
    static let shared = CrosslinkDirectory()
    private(set) var participants: [CrosslinkParticipant] = []
    /// Apps seen before that are not installed now, for Settings.
    private(set) var absent: [CrosslinkSeenApp] = []
    @ObservationIgnored private var seen: [CrosslinkSeenApp] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        seen = (UserDefaults.standard.data(forKey: CrosslinkSettings.seenKey))
            .flatMap { try? JSONDecoder().decode([CrosslinkSeenApp].self, from: $0) } ?? []
        refresh()
        let refresh: @Sendable (Notification) -> Void = { _ in Task { @MainActor in CrosslinkDirectory.shared.refresh() } }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main, using: refresh))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                                           object: nil, queue: .main, using: refresh))
    }

    func refresh() {
        guard let probe = URL(string: "\(Crosslink.scheme):///photos") else { return }
        var seen = Set<String>()
        let found = NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { url -> CrosslinkParticipant? in
            // This app and its other build are not listed; an app without an announcement does not take part.
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.hasPrefix("dev.igol.ImmichGallery"),
                  // An app that cannot start (its program missing) is left out.
                  let program = bundle.executableURL, FileManager.default.isExecutableFile(atPath: program.path),
                  seen.insert(id).inserted, let kinds = Crosslink.announcedKinds(bundle.infoDictionary) else { return nil }
            // Named by the bundle's display name, as the system shows the app, or its file name without one.
            var name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String) ?? ""
            if name.isEmpty {
                name = FileManager.default.displayName(atPath: url.path)
                if name.hasSuffix(".app") { name.removeLast(4) }
            }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            return CrosslinkParticipant(bundleID: id, name: name, url: url, kinds: kinds, icon: icon)
        }
        let sorted = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if sorted != participants { participants = sorted }
        remember(sorted)
    }

    /// Notes when each app was seen, and forgets one away for longer than `forgetAfter`, its switch with it.
    private func remember(_ found: [CrosslinkParticipant]) {
        let now = Date()
        var byID = Dictionary(seen.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for app in found { byID[app.bundleID] = CrosslinkSeenApp(id: app.bundleID, name: app.name, lastSeen: now) }
        let installed = Set(found.map(\.bundleID))
        let expired = byID.values.filter { !installed.contains($0.id) && now.timeIntervalSince($0.lastSeen) > CrosslinkSettings.forgetAfter }
        for app in expired { byID[app.id] = nil }
        store(Array(byID.values), unhiding: Set(expired.map(\.id)), installed: installed)
    }

    /// Forgets an app that is not found: what is remembered of it, and its switch. A found app has no Forget: it
    /// announces itself, so it would be found again at once; its switch is the control for it.
    func forget(_ id: String) {
        let installed = Set(participants.map(\.bundleID))
        guard !installed.contains(id) else { return }
        store(seen.filter { $0.id != id }, unhiding: [id], installed: installed)
    }

    private func store(_ apps: [CrosslinkSeenApp], unhiding forgotten: Set<String>, installed: Set<String>) {
        seen = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        UserDefaults.standard.set(try? JSONEncoder().encode(seen), forKey: CrosslinkSettings.seenKey)
        let away = seen.filter { !installed.contains($0.id) }
        if away != absent { absent = away }
        if !forgotten.isEmpty {
            let stored = UserDefaults.standard.string(forKey: CrosslinkSettings.hiddenKey) ?? ""
            let hidden = CrosslinkSettings.hidden(stored).subtracting(forgotten)
            UserDefaults.standard.set(hidden.sorted().joined(separator: "\n"), forKey: CrosslinkSettings.hiddenKey)
        }
    }

    func offered(for kind: Crosslink.Kind, hidden stored: String) -> [CrosslinkParticipant] {
        let hidden = CrosslinkSettings.hidden(stored)
        return participants.filter { $0.kinds.contains(kind) && !hidden.contains($0.bundleID) }
    }
}

/// Open in Immich and Copy Immich Link, and Show in <app> for each app found that shows this kind of item.
struct CrosslinkMenuItems: View {
    @Environment(LibrarySession.self) private var session
    @AppStorage(CrosslinkSettings.enabledKey) private var enabled = true
    @AppStorage(CrosslinkSettings.webLinksKey) private var webLinks = true
    @AppStorage(CrosslinkSettings.hiddenKey) private var hidden = ""
    let item: Crosslink.Item

    var body: some View {
        let server = session.client.serverURL.absoluteString
        if webLinks {
            Button("Open in Immich") {
                if let url = URL(string: Crosslink.webAddress(item, server: server)) { NSWorkspace.shared.open(url) }
            }
            Button("Copy Immich Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Crosslink.webAddress(item, server: server), forType: .string)
            }
        }
        if enabled {
            ForEach(CrosslinkDirectory.shared.offered(for: item.kind, hidden: hidden)) { app in
                Button {
                    app.send(Crosslink.link(item, server: server, user: session.user?.id))
                } label: {
                    Label { Text("Show in \(app.name)") } icon: { Image(nsImage: app.icon) }
                }
            }
        }
    }
}

extension GridSource {
    /// Where an asset is seen, as a crosslink says it.
    var crosslinkContext: Crosslink.Context? {
        switch self {
        case .album(let id): .album(id)
        case .person(let id): .person(id)
        case .favorites: .favorites
        case .archive: .archive
        default: nil
        }
    }
}

// MARK: Receiving

extension Notification.Name {
    /// Crosslink: a library window shows the item in the notification's `item` (a `Crosslink.Item`).
    static let crosslinkShow = Notification.Name("crosslinkShow")
    /// Crosslink: another link came, so what every window was still doing for an earlier one is stale.
    static let crosslinkArrived = Notification.Name("crosslinkArrived")
}

@MainActor
enum CrosslinkReceiver {
    /// Links still looking for a library window. Each window has its own for what it shows (`MainView`).
    static let navigation = CrosslinkNavigation()
    /// Alerts on screen, so a link sent again and again asks once.
    private static var telling: Set<String> = []

    /// Shows what a link names, for the signed-in account only. Any web page can open a crosslink, so this only ever
    /// navigates: it never changes anything, never switches accounts and never asks to sign in. A new link makes
    /// every earlier one stale, here and in every window.
    static func open(_ text: String, app: AppModel, openLibraryWindow: @escaping () -> Void) {
        let ticket = navigation.begin()
        NotificationCenter.default.post(name: .crosslinkArrived, object: nil)
        guard CrosslinkSettings.enabled else { return turnedOff() }
        switch Crosslink.read(text) {
        case .invalid:
            tell(String(localized: "This link from another app is not valid."))
        case .cannotShow:
            tell(String(localized: "Immich Gallery cannot show what this link from another app names."))
        case .show(let link):
            // The user is the signed-in one's, or the one this account was last known as (offline at launch).
            let userID = (app.services?.user?.id ?? app.services?.cacheUserID)?.lowercased()
            guard let services = app.services,
                  Crosslink.normalizedServer(services.client.serverURL.absoluteString) == link.server,
                  link.user == nil || link.user?.lowercased() == userID else {
                let host = URL(string: link.server)?.host ?? link.server
                return tell(String(localized: "Immich Gallery is not signed in to \(host) with this account."))
            }
            show(link.item, ticket: ticket, services: services, app: app, openLibraryWindow: openLibraryWindow)
        }
    }

    /// Signing out or switching accounts: links still looking for a window are dropped (windows drop theirs as
    /// they close for the old account).
    static func accountChanged() { navigation.invalidate() }

    private static func show(_ item: Crosslink.Item, ticket: CrosslinkNavigation.Ticket, services: AccountServices,
                             app: AppModel, openLibraryWindow: @escaping () -> Void) {
        navigation.run(ticket) {
            // At launch, the first library window may still be setting up its session: it is tried again a few
            // times. A newer link, or another account, stops this.
            await navigation.deliver(ticket, live: { app.services === services }, deliver: {
                guard let window = frontWindow(),
                      let session = services.windows.allObjects.first(where: { $0.macWindow === window }) else { return false }
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                NotificationCenter.default.post(name: .crosslinkShow, object: session, userInfo: ["item": item])
                return true
            }, hasWindow: { frontWindow() != nil }, openWindow: openLibraryWindow,
               wait: { try? await Task.sleep(for: .milliseconds(100)) })
        }
    }

    private static func frontWindow() -> NSWindow? {
        NSApp.orderedWindows.first {
            ($0.isVisible || $0.isMiniaturized) && $0.tabbingIdentifier == MacWindowRoute.tabbingIdentifier
        }
    }

    /// Nothing to show: the account cannot see the item (Immich answers 400 or 404 for that), or it could not be
    /// fetched, which the session reports as for any request.
    static func cannotShow(_ error: Error, session: LibrarySession) {
        if case ImmichError.http(let status, _) = error, [400, 403, 404].contains(status) {
            tell(String(localized: "The signed-in account cannot see what this link from another app names."))
        } else if !error.isCancellation {
            session.handle(error)
        }
    }

    static func tell(_ message: String) {
        guard telling.insert(message).inserted else { return }
        defer { telling.remove(message) }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Immich Crosslink")
        alert.informativeText = message
        alert.runModal()
    }

    private static func turnedOff() {
        let message = String(localized: "Another app asked Immich Gallery to show an item, but Immich Crosslink is turned off.")
        guard telling.insert(message).inserted else { return }
        defer { telling.remove(message) }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Immich Crosslink")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Turn On"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { UserDefaults.standard.set(true, forKey: CrosslinkSettings.enabledKey) }
    }
}

/// A library window, as showing an asset a link names needs it.
@MainActor
final class CrosslinkRevealHost: CrosslinkAssetHost {
    let session: LibrarySession
    let source: GridSource
    let alone: () -> Void
    /// Opens the asset; or, for a face below a photo, selects it in the grid, scrolled to.
    let opens: Bool

    init(session: LibrarySession, source: GridSource, opens: Bool = true, alone: @escaping () -> Void) {
        self.session = session
        self.source = source
        self.opens = opens
        self.alone = alone
    }

    func asset(_ id: String) async throws -> AssetResponse { try await session.client.asset(id) }
    func visibility(of asset: AssetResponse) -> String? { asset.visibility }

    func loadForReveal(_ asset: AssetResponse) async throws -> Bool {
        let model = session.gridModel(for: source)
        await model.loadIfNeeded()
        try await model.loadForReveal(asset)
        return model.item(asset.id) != nil
    }

    func open(_ id: String) {
        session.closeViewer() // A full-screen viewer or slideshow from this window.
        let model = session.gridModel(for: source)
        model.viewerScrollTarget = id
        if opens { model.open(id) } else { model.selection = [id] }
    }

    func showAlone(_ id: String) { alone() }
    func tell(_ message: String) { CrosslinkReceiver.tell(message) }
    func cannotShow(_ error: Error) { CrosslinkReceiver.cannotShow(error, session: session) }
}

extension LibrarySession {
    /// Opens an asset a crosslink names in the grid it was seen in; one that is not there (archived, a partner's, in
    /// an album shared with you) is shown alone, and one in the Locked Folder not at all. Stops when the link goes
    /// stale (`navigation`).
    func crosslinkReveal(_ id: String, in source: GridSource, ticket: CrosslinkNavigation.Ticket,
                         navigation: CrosslinkNavigation, opens: Bool = true, alone: @escaping () -> Void) {
        let host = CrosslinkRevealHost(session: self, source: source, opens: opens, alone: alone)
        navigation.run(ticket) { await navigation.reveal(id, ticket: ticket, host: host) }
    }
}

// MARK: Settings

/// The protocol's switch, as every app that takes part shows it, and the apps found; and the web links.
struct CrosslinkSettingsView: View {
    @AppStorage(CrosslinkSettings.enabledKey) private var enabled = true
    @AppStorage(CrosslinkSettings.webLinksKey) private var webLinks = true
    @AppStorage(CrosslinkSettings.hiddenKey) private var hidden = ""
    private let directory = CrosslinkDirectory.shared

    var body: some View {
        Form {
            Section {
                Toggle("Immich Crosslink", isOn: $enabled)
                // As macOS settings do, the link ends the description.
                Text(Self.described(String(localized: "Show photos, albums, people and places in other apps that take part, and open the items they send to Immich Gallery."),
                                    link: String(localized: "Learn more…"), to: Crosslink.site))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if directory.participants.isEmpty && directory.absent.isEmpty {
                    Text(Self.described(String(localized: "No other app that takes part has been found."),
                                        link: String(localized: "See the apps that take part…"), to: Crosslink.participantsPage))
                        .foregroundStyle(.secondary)
                }
                ForEach(directory.participants) { app in
                    row(id: app.bundleID, name: app.name, icon: app.icon, notFound: false)
                }
                // Apps seen before that are not found now: their switch still holds for when they come back.
                ForEach(directory.absent) { app in
                    row(id: app.id, name: app.name, icon: Self.absentIcon, notFound: true)
                }
            } header: {
                Text("Apps That Take Part")
            } footer: {
                Text("Apps that take part are found by themselves. Turn one off to leave it out of Show in. One not found stays listed for 30 days, so it stays off if it comes back; Forget removes it now.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!enabled)
            Section("Immich Web App") {
                Toggle("Open in Immich and Copy Immich Link", isOn: $webLinks)
                Text("Open photos, albums, people and places in Immich's web app in your browser, or copy their address.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { directory.refresh() }
    }

    /// One app: its icon and name, and its switch; one not found also says so and has Forget.
    private func row(id: String, name: String, icon: NSImage, notFound: Bool) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading) {
                    Text(verbatim: name)
                    if notFound { Text("Not found").font(.caption).foregroundStyle(.secondary) }
                }
            } icon: { Image(nsImage: icon) }
            Spacer()
            if notFound { Button("Forget") { directory.forget(id) } }
            Toggle(isOn: shown(id)) { Text(verbatim: name) }.labelsHidden()
        }
    }

    /// A sentence ending in a link, as a settings description ends in Learn more….
    private static func described(_ text: String, link title: String, to url: URL) -> AttributedString {
        var result = AttributedString(text + " ")
        var link = AttributedString(title)
        link.link = url
        result.append(link)
        return result
    }

    private static let absentIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .applicationBundle)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }()

    private func shown(_ id: String) -> Binding<Bool> {
        Binding {
            !CrosslinkSettings.hidden(hidden).contains(id)
        } set: { shown in
            var ids = CrosslinkSettings.hidden(hidden)
            if shown { ids.remove(id) } else { ids.insert(id) }
            hidden = ids.sorted().joined(separator: "\n")
        }
    }
}
