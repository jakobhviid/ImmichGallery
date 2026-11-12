import Foundation

struct AccountAPIKey: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let permissions: [String]
    let createdAt: String?
}

struct AccountAPIKeySecret: Decodable, Sendable {
    let secret: String
    let apiKey: AccountAPIKey?
    let id: String?
}

struct AccountDevice: Decodable, Identifiable, Sendable {
    let id: String
    let current: Bool
    let deviceOS: String
    let deviceType: String
    let appVersion: String?
    let updatedAt: String
}

struct AccountNotification: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let description: String?
    let level: String
    let createdAt: String
    let readAt: String?
}

/// Optional groups preserve compatibility with servers predating individual preferences.
struct AccountPreferences: Codable, Equatable, Sendable {
    struct Feature: Codable, Equatable, Sendable {
        var enabled: Bool?
        var sidebarWeb: Bool?
        var duration: Int?
        var minimumFaces: Int?
        var updateStrategy: String?
    }
    struct Download: Codable, Equatable, Sendable {
        var archiveSize: Int64?
        var includeEmbeddedVideos: Bool?
    }
    struct Email: Codable, Equatable, Sendable {
        var enabled: Bool?
        var albumInvite: Bool?
        var albumUpdate: Bool?
    }
    struct Albums: Codable, Equatable, Sendable { var defaultAssetOrder: String? }
    struct Cast: Codable, Equatable, Sendable { var gCastEnabled: Bool? }
    struct RecentlyAdded: Codable, Equatable, Sendable { var sidebarWeb: Bool? }
    struct Purchase: Codable, Equatable, Sendable { var showSupportBadge: Bool?; var hideBuyButtonUntil: String? }
    var memories: Feature?
    var ratings: Feature?
    var folders: Feature?
    var tags: Feature?
    var people: Feature?
    var sharedLinks: Feature?
    var download: Download?
    var emailNotifications: Email?
    var albums: Albums?
    var cast: Cast?
    var recentlyAdded: RecentlyAdded?
    var purchase: Purchase?

    /// Only the groups that differ from `base`, so saving leaves alone what was changed elsewhere (the web client)
    /// since `base` was read. Absent groups are not sent.
    func changes(from base: AccountPreferences) -> AccountPreferences {
        var changes = AccountPreferences()
        if memories != base.memories { changes.memories = memories }
        if ratings != base.ratings { changes.ratings = ratings }
        if folders != base.folders { changes.folders = folders }
        if tags != base.tags { changes.tags = tags }
        if people != base.people { changes.people = people }
        if sharedLinks != base.sharedLinks { changes.sharedLinks = sharedLinks }
        if download != base.download { changes.download = download }
        if emailNotifications != base.emailNotifications { changes.emailNotifications = emailNotifications }
        if albums != base.albums { changes.albums = albums }
        if cast != base.cast { changes.cast = cast }
        if recentlyAdded != base.recentlyAdded { changes.recentlyAdded = recentlyAdded }
        if purchase != base.purchase { changes.purchase = purchase }
        return changes
    }
}
