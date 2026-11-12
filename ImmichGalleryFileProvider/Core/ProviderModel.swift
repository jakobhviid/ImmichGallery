import Foundation
import CryptoKit
import UniformTypeIdentifiers

// Finder access (issue #23): the File Provider's model, independent of the FileProvider framework so it can be
// checked offline (Tests/FileProviderChecks.swift).
//
//   <Account>/
//   ├── Albums/<album>/<photo>     owned and shared albums
//   ├── Library/<year>/<month>/<photo>   the user's own timeline (no archive, partners, trash or Locked Folder)
//   └── Favorites/<photo>
//
// A photo in two albums is two items: identifiers carry their container, so each has exactly one parent, as the
// File Provider requires. Nothing in the Locked Folder, the trash or hidden live-photo parts is ever an item.

/// Where an item lives.
enum ProviderNode: Hashable, Sendable {
    case root, albums, library, favorites
    case album(String)
    case year(Int)
    case month(Int, Int)
    indirect case asset(ProviderNode, String)

    static let rootIdentifier = "NSFileProviderRootContainerItemIdentifier"
    static let workingSetIdentifier = "NSFileProviderWorkingSetContainerItemIdentifier"
    static let trashIdentifier = "NSFileProviderTrashContainerItemIdentifier"

    var identifier: String {
        switch self {
        case .root: Self.rootIdentifier
        case .albums: "albums"
        case .library: "library"
        case .favorites: "favorites"
        case .album(let id): "album:" + id
        case .year(let year): String(format: "year:%04d", year)
        case .month(let year, let month): String(format: "month:%04d-%02d", year, month)
        case .asset(let container, let id): "asset|" + container.identifier + "|" + id
        }
    }

    init?(identifier: String) {
        switch identifier {
        case Self.rootIdentifier: self = .root
        case "albums": self = .albums
        case "library": self = .library
        case "favorites": self = .favorites
        default:
            if identifier.hasPrefix("album:") {
                let id = String(identifier.dropFirst(6))
                guard Self.isServerID(id) else { return nil }
                self = .album(id)
            } else if identifier.hasPrefix("year:") {
                guard let year = Self.number(identifier.dropFirst(5), digits: 4), (1...9999).contains(year) else { return nil }
                self = .year(year)
            } else if identifier.hasPrefix("month:") {
                let parts = identifier.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count == 2, let year = Self.number(parts[0], digits: 4), let month = Self.number(parts[1], digits: 2),
                      (1...9999).contains(year), (1...12).contains(month) else { return nil }
                self = .month(year, month)
            } else if identifier.hasPrefix("asset|") {
                let parts = identifier.split(separator: "|", omittingEmptySubsequences: false)
                guard parts.count == 3, let container = ProviderNode(identifier: String(parts[1])), container.holdsAssets,
                      Self.isServerID(String(parts[2])) else { return nil }
                self = .asset(container, String(parts[2]))
            } else {
                return nil
            }
        }
    }

    /// Immich IDs are UUIDs. Anything else could reach a URL path, so it is never accepted.
    static func isServerID(_ value: String) -> Bool {
        (1...64).contains(value.count) && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }
    }

    private static func number(_ text: Substring, digits: Int) -> Int? {
        guard text.count == digits, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) else { return nil }
        return Int(text)
    }

    /// Folders photos can be in. Library and years only hold a photo just dropped there, until the next refresh shows
    /// it in the month it was taken.
    var holdsAssets: Bool {
        switch self {
        case .album, .month, .favorites, .library, .year: true
        default: false
        }
    }

    var isFolder: Bool { if case .asset = self { false } else { true } }

    var parent: ProviderNode? {
        switch self {
        case .root: nil
        case .albums, .library, .favorites: .root
        case .album: .albums
        case .year: .library
        case .month(let year, _): .year(year)
        case .asset(let container, _): container
        }
    }

    var assetID: String? { if case .asset(_, let id) = self { id } else { nil } }
    var albumID: String? {
        switch self {
        case .album(let id): id
        case .asset(.album(let id), _): id
        default: nil
        }
    }
    /// Library, a year or a month: photos dropped there are uploaded to the timeline.
    var isLibrary: Bool {
        switch self {
        case .library, .year, .month: true
        default: false
        }
    }
}

/// Mirrors `NSFileProviderItemCapabilities` (folders: reading = content enumerating, writing = adding sub-items).
struct ProviderCapabilities: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt
    static let reading = ProviderCapabilities(rawValue: 1 << 0)
    static let writing = ProviderCapabilities(rawValue: 1 << 1)
    static let reparenting = ProviderCapabilities(rawValue: 1 << 2)
    static let renaming = ProviderCapabilities(rawValue: 1 << 3)
    static let deleting = ProviderCapabilities(rawValue: 1 << 5)
}

/// What the user allowed in Settings ▸ Finder for this account.
struct ProviderOptions: Equatable, Sendable {
    var allowChanges = true
    var allowRemoving = false
}

/// An Immich asset as the File Provider needs it.
struct RemoteAsset: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var size: Int64?
    var created: Date?
    var modified: Date?
    /// Month of the asset's local date, which is how Immich's timeline groups it.
    var localYear: Int?
    var localMonth: Int?
    var isVideo = false
    var mimeType: String?
    var ownerID: String?
    /// From an external library: Immich doesn't own the file, so Finder never offers to delete it.
    var external = false
    var visibility: String?
    var trashed = false
    var favorite = false
    var checksum: String?

    /// Never shown: trashed, Locked Folder and the hidden video half of live photos.
    var isListable: Bool { !trashed && visibility != "locked" && visibility != "hidden" }
    var inTimeline: Bool { isListable && (visibility ?? "timeline") == "timeline" }
}

struct RemoteAlbum: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var owner: Bool
    var editable: Bool
    var assetCount: Int
    var created: Date?
    var modified: Date?
    /// Changes when the album's contents may have changed: count, update time, last asset time.
    var signature: String
}

struct RemoteMonth: Equatable, Sendable {
    var year: Int
    var month: Int
    var count: Int
}

/// One item as last reported to the system, with the facts its capabilities are derived from.
struct ProviderItem: Codable, Equatable, Sendable {
    var identifier: String
    var parent: String
    var name: String
    /// The name before disambiguation, so a renamed album or a new same-named photo gets a fresh name.
    var baseName: String
    var isFolder: Bool
    var asset: RemoteAsset?
    var album: RemoteAlbum?
    var childCount: Int?
    var created: Date?
    var modified: Date?
    var capabilities: ProviderCapabilities = []

    var node: ProviderNode? { ProviderNode(identifier: identifier) }
    var size: Int64? { asset?.size }

    var contentType: UTType {
        if isFolder { return .folder }
        let fallback: UTType = asset?.isVideo == true ? .movie : .image
        if let type = UTType(filenameExtension: (name as NSString).pathExtension), type.conforms(to: .image) || type.conforms(to: .audiovisualContent) {
            return type
        }
        if let mime = asset?.mimeType, let type = UTType(mimeType: mime) { return type }
        return fallback
    }

    /// Originals never change in Immich, so the checksum identifies the content.
    var contentVersion: Data { Data((asset?.checksum ?? asset?.id ?? "folder").utf8) }

    var metadataVersion: Data {
        let text = [identifier, parent, name, String(capabilities.rawValue), size.map(String.init) ?? "",
                    created.map { String($0.timeIntervalSince1970) } ?? "", modified.map { String($0.timeIntervalSince1970) } ?? ""]
            .joined(separator: "\u{1f}")
        return Data(SHA256.hash(data: Data(text.utf8)).prefix(16))
    }

    func sameVersion(as other: ProviderItem) -> Bool {
        contentVersion == other.contentVersion && metadataVersion == other.metadataVersion
    }
}

/// Localized names of the fixed folders, provided by the extension.
struct ProviderFolderNames: Sendable {
    var albums = "Albums"
    var library = "Library"
    var favorites = "Favorites"
    var month: @Sendable (Int) -> String = { String(format: "%02d", $0) }
}

enum ProviderNaming {
    /// A server name as a Finder name: "/" becomes ":" (shown as "/" by Finder), no control characters, no leading
    /// dot (hidden), at most 255 UTF-8 bytes with the extension kept.
    static func sanitize(_ raw: String, fallback: String) -> String {
        var name = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .replacingOccurrences(of: "/", with: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix(".") { name = "_" + name.dropFirst() }
        if name.isEmpty || name == "_" { name = fallback }
        return truncate(name)
    }

    /// The album name a Finder folder name stands for.
    static func albumName(fromFolderName name: String) -> String {
        name.replacingOccurrences(of: ":", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func truncate(_ name: String, limit: Int = 255) -> String {
        guard name.utf8.count > limit else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 32 ? "" : "." + ext
        var stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
        while stem.utf8.count + suffix.utf8.count > limit { stem.removeLast() }
        return stem + suffix
    }

    /// APFS compares names case- and normalization-insensitively by default.
    static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    /// Uses the end of the ID: Immich's newer IDs start with a timestamp, shared by photos added together.
    static func disambiguated(_ base: String, id: String, folder: Bool, length: Int) -> String {
        let tag = String(id.replacingOccurrences(of: "-", with: "").suffix(length))
        let ext = folder ? "" : (base as NSString).pathExtension
        let stem = ext.isEmpty ? base : (base as NSString).deletingPathExtension
        return truncate(ext.isEmpty ? "\(stem) (\(tag))" : "\(stem) (\(tag)).\(ext)")
    }

    /// Gives every item a name unique in its folder. Items already listed keep their name, so names don't change
    /// between refreshes; new same-named items get a short ID suffix, in a fixed order.
    static func assign(_ items: [ProviderItem], previous: [String: ProviderItem]) -> [ProviderItem] {
        var result = items
        var used = Set<String>()
        var pending: [Int] = []
        for index in result.indices {
            if let old = previous[result[index].identifier], old.baseName == result[index].baseName, !used.contains(key(old.name)) {
                result[index].name = old.name
                used.insert(key(old.name))
            } else {
                pending.append(index)
            }
        }
        pending.sort { a, b in
            let lhs = result[a], rhs = result[b]
            if lhs.baseName != rhs.baseName { return lhs.baseName < rhs.baseName }
            let l = lhs.created ?? .distantPast, r = rhs.created ?? .distantPast
            return l != r ? l < r : lhs.identifier < rhs.identifier
        }
        for index in pending {
            let item = result[index]
            let id = item.asset?.id ?? item.album?.id ?? item.identifier
            var candidates = [item.baseName] + [8, 12, 32].map { disambiguated(item.baseName, id: id, folder: item.isFolder, length: $0) }
            var counter = 2
            while candidates.allSatisfy({ used.contains(key($0)) }) {
                candidates = [disambiguated(item.baseName, id: id + "-\(counter)", folder: item.isFolder, length: 40)]
                counter += 1
            }
            let name = candidates.first { !used.contains(key($0)) }!
            result[index].name = name
            used.insert(key(name))
        }
        return result
    }
}

enum ProviderRendering {
    static func folder(_ node: ProviderNode, name: String, options: ProviderOptions, album: RemoteAlbum? = nil,
                       childCount: Int? = nil) -> ProviderItem {
        var item = ProviderItem(identifier: node.identifier, parent: node.parent?.identifier ?? ProviderNode.rootIdentifier,
                                name: name, baseName: name, isFolder: true, album: album, childCount: childCount,
                                created: album?.created, modified: album?.modified)
        item.capabilities = capabilities(item, options: options)
        return item
    }

    static func asset(_ asset: RemoteAsset, in container: ProviderNode, options: ProviderOptions, album: RemoteAlbum?,
                      userID: String) -> ProviderItem {
        let base = sanitize(asset)
        var item = ProviderItem(identifier: ProviderNode.asset(container, asset.id).identifier, parent: container.identifier,
                                name: base, baseName: base, isFolder: false, asset: asset, album: album,
                                created: asset.created, modified: asset.modified ?? asset.created)
        item.capabilities = capabilities(item, options: options, userID: userID)
        return item
    }

    static func sanitize(_ asset: RemoteAsset) -> String {
        ProviderNaming.sanitize(asset.name, fallback: asset.id + (asset.isVideo ? ".mov" : ".jpg"))
    }

    /// What Finder offers. Everything else is refused, so the system never asks for something Immich can't do.
    static func capabilities(_ item: ProviderItem, options: ProviderOptions, userID: String? = nil) -> ProviderCapabilities {
        guard let node = item.node else { return [.reading] }
        let change = options.allowChanges, remove = options.allowRemoving
        switch node {
        case .root: return [.reading]
        // Adding to Albums makes an album; to Library, a year or a month uploads; to Favorites uploads and favorites.
        case .albums, .library, .favorites, .year, .month: return change ? [.reading, .writing] : [.reading]
        case .album:
            var result: ProviderCapabilities = [.reading]
            if change, item.album?.editable == true { result.insert(.writing) }
            if change, item.album?.owner == true { result.insert(.renaming) }
            if remove, item.album?.owner == true { result.insert(.deleting) }
            return result
        case .asset(let container, _):
            var result: ProviderCapabilities = [.reading]
            if change { result.insert(.reparenting) }
            let owned = item.asset?.ownerID != nil && item.asset?.ownerID == userID
            switch container {
            case .album: if remove, item.album?.editable == true { result.insert(.deleting) }
            case .favorites: if remove, owned { result.insert(.deleting) }
            case .month: if remove, owned, item.asset?.external == false { result.insert(.deleting) }
            default: break
            }
            return result
        }
    }

    static func rerender(_ item: ProviderItem, options: ProviderOptions, userID: String) -> ProviderItem {
        var copy = item
        copy.capabilities = capabilities(item, options: options, userID: userID)
        return copy
    }
}

/// Changes to report to the system.
struct ProviderChanges: Sendable, Equatable {
    var updated: [ProviderItem] = []
    var deleted: [String] = []
    var isEmpty: Bool { updated.isEmpty && deleted.isEmpty }
    mutating func merge(_ other: ProviderChanges) {
        let removed = Set(other.deleted)
        updated.removeAll { removed.contains($0.identifier) }
        let replaced = Set(other.updated.map(\.identifier))
        updated.removeAll { replaced.contains($0.identifier) }
        updated += other.updated
        deleted.removeAll { replaced.contains($0) }
        deleted += other.deleted.filter { !deleted.contains($0) }
    }
}

/// Failures, mapped to `NSFileProviderError` by the extension.
enum ProviderFailure: Error, Equatable, Sendable {
    case notAuthenticated
    case serverUnreachable
    case noSuchItem
    case cancelled
    /// The system restores the item: `item` is how it still is (added by `ProviderEngine.delete`).
    case deletionRejected(String, item: ProviderItem? = nil)
    case directoryNotEmpty
    /// Shown to the user on the item; the local file is kept.
    case cannotSynchronize(String)
    /// Kept on disk only, never uploaded (hidden and system files).
    case excludedFromSync
    case syncAnchorExpired
    case pageExpired
}
