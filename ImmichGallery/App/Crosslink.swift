import Foundation

// Crosslink: immich-crosslink, links between Immich apps on the same computer (https://jakob.hviid.phd/immich-crosslink/).
// Links name an item by Immich's own web path, with the server's address; this file reads and writes them, with no
// AppKit, so Tests/CrosslinkChecks.swift runs it against the protocol's test links.

enum Crosslink {
    /// The protocol's scheme, which the public app registers.
    static let protocolScheme = "immich-crosslink"
    /// The scheme this build registers, sends and finds other apps by (Info.plist, `IMMICH_CROSSLINK_SCHEME`): the
    /// protocol's in Release; a Dev-only one in Debug, so the Dev app never takes, or sends, the public app's links.
    #if DEBUG
    static let scheme = "immich-crosslink-dev"
    #else
    static let scheme = protocolScheme
    #endif
    /// The draft this app follows, announced in Info.plist (`ImmichCrosslink`).
    static let draft = "0.2"
    static let site = URL(string: "https://jakob.hviid.phd/immich-crosslink/")!
    static let participantsPage = URL(string: "https://jakob.hviid.phd/immich-crosslink/participants.html")!

    enum Kind: String, CaseIterable, Sendable {
        case asset, album, person, place, page
    }

    enum Page: String, CaseIterable, Sendable {
        case photos, albums, people, places, favorites, archive
    }

    /// A place, as Immich's metadata search names it.
    struct Place: Hashable, Sendable {
        var city: String?
        var country: String?
    }

    /// Where an asset was seen; a receiver without that view shows the asset alone.
    enum Context: Hashable, Sendable {
        case album(String), person(String), favorites, archive, search(Place)
    }

    enum Item: Hashable, Sendable {
        case asset(String, Context?)
        case album(String)
        case person(String)
        case place(Place)
        case page(Page)

        var kind: Kind {
            switch self {
            case .asset: .asset
            case .album: .album
            case .person: .person
            case .place: .place
            case .page: .page
            }
        }
    }

    struct Link: Hashable, Sendable {
        var item: Item
        /// The server address as it compares: lower-case scheme and host, no default port, no trailing slash.
        var server: String
        var user: String?
    }

    enum Reading: Hashable, Sendable {
        case show(Link)
        case cannotShow
        case invalid
    }

    // MARK: Writing

    /// The Immich path of an item: the path of Immich's web app for it.
    static func path(_ item: Item) -> String {
        switch item {
        case .asset(let id, nil): "/photos/\(id)"
        case .asset(let id, .album(let album)?): "/albums/\(album)/photos/\(id)"
        case .asset(let id, .person(let person)?): "/people/\(person)/photos/\(id)"
        case .asset(let id, .favorites?): "/favorites/photos/\(id)"
        case .asset(let id, .archive?): "/archive/photos/\(id)"
        case .asset(let id, .search(let place)?): "/search/photos/\(id)?query=\(encodeComponent(json(place)))"
        case .album(let id): "/albums/\(id)"
        case .person(let id): "/people/\(id)"
        case .place(let place): "/search?query=\(encodeComponent(json(place)))"
        case .page(let page): "/\(page.rawValue)"
        }
    }

    /// The item's crosslink, for sending to one other app.
    static func link(_ item: Item, server: String, user: String?, scheme: String = scheme) -> String {
        let path = path(item)
        var link = "\(scheme)://\(path)\(path.contains("?") ? "&" : "?")server=\(encodeComponent(serverAddress(server)))"
        if let user { link += "&user=\(encodeComponent(user))" }
        return link
    }

    /// The item's address in Immich's web app, for Copy Immich Link.
    static func webAddress(_ item: Item, server: String) -> String { serverAddress(server) + path(item) }

    /// The JSON Immich's web app writes for a place search (`JSON.stringify`): keys in this order, no spaces.
    static func json(_ place: Place) -> String {
        struct Search: Encodable { let city: String?; let country: String? } // nil keys are left out
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes] // "city" sorts before "country"
        let data = (try? encoder.encode(Search(city: place.city, country: place.country))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// As JavaScript's `encodeURIComponent`: every byte but `A-Z a-z 0-9 - _ . ! ~ * ' ( )` as `%XX` of its UTF-8.
    static func encodeComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    // MARK: Reading

    /// Reads a link into the protocol's three results. Only ever names an item: what to do with it is the caller's,
    /// and a link from anywhere may only be shown.
    /// `scheme` is the one this build takes (`Crosslink.scheme`); a link in another scheme is invalid here.
    static func read(_ text: String, scheme: String = scheme) -> Reading {
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == scheme,
              (components.host ?? "").isEmpty, components.port == nil, components.user == nil else { return .invalid }
        var parameters: [String: String] = [:]
        for pair in (components.percentEncodedQuery ?? "").split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts[0].removingPercentEncoding,
                  let value = (parts.count > 1 ? String(parts[1]) : "").removingPercentEncoding else { return .invalid }
            if parameters[name] == nil { parameters[name] = value }
        }
        guard let rawServer = parameters["server"], let server = normalizedServer(rawServer) else { return .invalid }
        // The user is an Immich user id: a UUID, compared in either case.
        var user: String?
        if let given = parameters["user"] {
            guard isUUID(given) else { return .invalid }
            user = given.lowercased()
        }
        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.first == "", segments.count >= 2 else { return .cannotShow }
        let parts = Array(segments.dropFirst())

        func id(_ text: String) -> String? { isUUID(text) ? text.lowercased() : nil }
        func show(_ item: Item) -> Reading { .show(Link(item: item, server: server, user: user)) }
        func asset(_ text: String, _ context: Context?) -> Reading {
            guard let asset = id(text) else { return .invalid }
            return show(.asset(asset, context))
        }
        /// A place search, or why not: no search, or one by anything but a place, cannot be shown; a search that is
        /// not JSON is invalid.
        func place() -> Result<Place, ReadFailure> {
            guard let query = parameters["query"] else { return .failure(.cannotShow) }
            guard let data = query.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return .failure(.invalid) }
            guard let fields = object as? [String: Any], !fields.isEmpty,
                  Set(fields.keys).isSubset(of: ["city", "country"]) else { return .failure(.cannotShow) }
            let city = fields["city"], country = fields["country"]
            guard city == nil || city is String, country == nil || country is String else { return .failure(.invalid) }
            return .success(Place(city: city as? String, country: country as? String))
        }

        switch parts.count {
        case 1:
            if let page = Page(rawValue: parts[0]) { return show(.page(page)) }
            if parts[0] == "search" {
                switch place() {
                case .success(let place): return show(.place(place))
                case .failure(let failure): return failure.reading
                }
            }
        case 2:
            switch parts[0] {
            case "photos": return asset(parts[1], nil)
            case "albums": return id(parts[1]).map { show(.album($0)) } ?? .invalid
            case "people": return id(parts[1]).map { show(.person($0)) } ?? .invalid
            default: break
            }
        case 3 where parts[1] == "photos":
            switch parts[0] {
            case "favorites": return asset(parts[2], .favorites)
            case "archive": return asset(parts[2], .archive)
            case "search":
                switch place() {
                case .success(let place): return asset(parts[2], .search(place))
                case .failure(let failure): return failure.reading
                }
            default: break
            }
        case 4 where parts[2] == "photos":
            switch parts[0] {
            case "albums":
                guard let album = id(parts[1]) else { return .invalid }
                return asset(parts[3], .album(album))
            case "people":
                guard let person = id(parts[1]) else { return .invalid }
                return asset(parts[3], .person(person))
            default: break
            }
        default: break
        }
        return .cannotShow
    }

    private enum ReadFailure: Error {
        case invalid, cannotShow
        var reading: Reading { self == .invalid ? .invalid : .cannotShow }
    }

    static func isUUID(_ text: String) -> Bool {
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        return groups.map(\.count) == [8, 4, 4, 4, 12] && groups.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }

    /// A server address as it compares, or nil if it is not an absolute http or https URL.
    static func normalizedServer(_ text: String) -> String? {
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let port = components.port.flatMap { (scheme == "https" && $0 == 443) || (scheme == "http" && $0 == 80) ? nil : $0 }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host.lowercased())\(port.map { ":\($0)" } ?? "")\(path)"
    }

    /// The server address a link carries: as it compares, or as given when it does not parse.
    static func serverAddress(_ server: String) -> String { normalizedServer(server) ?? server }

    // MARK: Announcements

    /// What another app announces in its Info.plist: the kinds it shows, if it follows this draft.
    static func announcedKinds(_ info: [String: Any]?) -> Set<Kind>? {
        guard let announcement = info?["ImmichCrosslink"] as? [String: Any],
              announcement["Version"] as? String == draft,
              let shows = announcement["Shows"] as? [String] else { return nil }
        return Set(shows.compactMap(Kind.init(rawValue:))) // kinds this draft does not know are ignored
    }
}
