import AppIntents
import Observation

@MainActor @Observable
final class MacIntegrationRouter {
    static let shared = MacIntegrationRouter()
    weak var app: AppModel?
    var pending: [MacWindowRoute] = []
    var widgetLinks: [WidgetFeed.Link] = [] // Widget
    var crosslinks: [String] = [] // Crosslink: links other apps sent, as they came
}

struct SearchPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Photos"
    static let description = IntentDescription("Search your signed-in Immich library in a new window.")
    static let openAppWhenRun = true
    @Parameter(title: "Search") var query: String

    @MainActor func perform() async throws -> some IntentResult {
        _ = try MacIntentAccount.require()
        MacIntegrationRouter.shared.pending.append(MacWindowRoute(query: query))
        return .result()
    }
}

struct OpenAlbumIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Album"
    static let description = IntentDescription("Open an Immich album by its exact name.")
    static let openAppWhenRun = true
    @Parameter(title: "Album Name") var name: String

    @MainActor func perform() async throws -> some IntentResult {
        let account = try MacIntentAccount.require()
        let client = ImmichClient(serverURL: account.serverURL, apiURL: account.apiURL, credential: account.credential)
        let matches = try await client.albums().filter { $0.albumName.localizedCaseInsensitiveCompare(name) == .orderedSame }
        guard matches.count == 1, let album = matches.first else { throw MacIntentError.albumName }
        let current = try MacIntentAccount.require()
        guard current.apiURL == account.apiURL, current.credential == account.credential else { throw MacIntentError.signIn }
        MacIntegrationRouter.shared.pending.append(MacWindowRoute(albumID: album.id))
        return .result()
    }
}

@MainActor private enum MacIntentAccount {
    static func require() throws -> AccountStore.Account {
        guard let services = MacIntegrationRouter.shared.app?.services,
              let account = (try? AccountVault.selectedEntry())?.account,
              account.apiURL == services.client.apiURL,
              account.credential == services.client.credential else { throw MacIntentError.signIn }
        return account
    }
}

private enum MacIntentError: LocalizedError {
    case signIn, albumName
    var errorDescription: String? {
        switch self {
        case .signIn: String(localized: "Sign in to Immich Gallery first.")
        case .albumName: String(localized: "Choose a unique, existing album name.")
        }
    }
}

struct ImmichGalleryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SearchPhotosIntent(), phrases: ["Search photos in \(.applicationName)"], shortTitle: "Search Photos", systemImageName: "magnifyingglass")
        AppShortcut(intent: OpenAlbumIntent(), phrases: ["Open album in \(.applicationName)"], shortTitle: "Open Album", systemImageName: "rectangle.stack")
    }
}
