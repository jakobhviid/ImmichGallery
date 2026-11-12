import Foundation

/// Crosslink: the protocol's test links (immich-crosslink draft 0.2, tests/links.json at 8a3c16e, copied to
/// Tests/Fixtures/crosslink-links.json): every link written byte for byte, every link read to the given result.
@main struct CrosslinkChecks {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/crosslink-links.json"))
        let fixtures = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(fixtures["draft"] as? String == Crosslink.draft, "The test links are for another draft")

        for entry in fixtures["make"] as! [[String: Any]] {
            let name = entry["name"] as! String
            let item = try makeItem(entry["item"] as! [String: String])
            let server = entry["server"] as! String
            check(Crosslink.path(item) == entry["path"] as! String, "make \(name): path \(Crosslink.path(item))")
            let link = Crosslink.link(item, server: server, user: entry["user"] as? String, scheme: Crosslink.protocolScheme)
            check(link == entry["link"] as! String, "make \(name): link \(link)")
            // What is written reads back to the same item.
            check(Crosslink.read(link, scheme: Crosslink.protocolScheme) == .show(.init(item: item, server: Crosslink.serverAddress(server), user: entry["user"] as? String)),
                  "make \(name): reads back")
        }

        for entry in fixtures["read"] as! [[String: Any]] {
            let name = entry["name"] as! String
            let reading = Crosslink.read(entry["link"] as! String, scheme: Crosslink.protocolScheme)
            switch entry["result"] as! String {
            case "show":
                guard case .show(let link) = reading else { check(false, "read \(name): \(reading)"); continue }
                check(link.item.kind.rawValue == entry["kind"] as! String, "read \(name): kind \(link.item.kind)")
                check(Crosslink.path(link.item) == entry["path"] as! String, "read \(name): path \(Crosslink.path(link.item))")
                check(link.server == entry["server"] as! String, "read \(name): server \(link.server)")
                check(link.user == entry["user"] as? String, "read \(name): user \(String(describing: link.user))")
            case "cannot-show": check(reading == .cannotShow, "read \(name): \(reading)")
            case "invalid": check(reading == .invalid, "read \(name): \(reading)")
            default: check(false, "read \(name): unknown result")
            }
        }

        // Announcements: only this draft, kinds it does not know left out.
        let announcement: [String: Any] = ["ImmichCrosslink": ["Version": "0.2", "Shows": ["asset", "album", "tag"]]]
        check(Crosslink.announcedKinds(announcement) == [.asset, .album], "announcement: kinds")
        check(Crosslink.announcedKinds(["ImmichCrosslink": ["Version": "0.1", "Shows": ["asset"]]]) == nil, "announcement: another draft")
        check(Crosslink.announcedKinds([:]) == nil, "announcement: none")
        // Copy Immich Link gives the web address.
        check(Crosslink.webAddress(.album("b2a1c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"), server: "https://photos.example.com/")
              == "https://photos.example.com/albums/b2a1c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d", "web address")

        // This build's scheme: the protocol's in Release, Dev's own in Debug. A link reads only in the scheme the
        // build takes, so Dev never shows the public app's links, nor the public app Dev's.
        #if DEBUG
        check(Crosslink.scheme == "immich-crosslink-dev", "Debug scheme")
        #else
        check(Crosslink.scheme == Crosslink.protocolScheme && Crosslink.protocolScheme == "immich-crosslink", "Release scheme")
        #endif
        let asset = Crosslink.Item.asset("b2a1c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d", .favorites)
        let server = "https://photos.example.com"
        let dev = "immich-crosslink-dev"
        let devLink = Crosslink.link(asset, server: server, user: nil, scheme: dev)
        let publicLink = Crosslink.link(asset, server: server, user: nil, scheme: Crosslink.protocolScheme)
        check(devLink.hasPrefix(dev + "://"), "Dev link: \(devLink)")
        check(Crosslink.read(devLink, scheme: dev) == .show(.init(item: asset, server: server, user: nil)), "Dev reads its own link")
        check(Crosslink.read(publicLink, scheme: dev) == .invalid, "Dev does not read the public scheme")
        check(Crosslink.read(devLink, scheme: Crosslink.protocolScheme) == .invalid, "the public app does not read Dev's")
        check(Crosslink.read(publicLink, scheme: Crosslink.protocolScheme) != .invalid, "the public app reads the protocol's")

        if failures > 0 { print("\(failures) crosslink checks failed"); exit(1) }
        print("Crosslink checks passed: \((fixtures["make"] as! [Any]).count) links made, \((fixtures["read"] as! [Any]).count) read")
    }

    nonisolated(unsafe) static var failures = 0
    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAILED: \(message)") }
    }

    struct UnknownItem: Error {}

    static func makeItem(_ fields: [String: String]) throws -> Crosslink.Item {
        let place = Crosslink.Place(city: fields["city"], country: fields["country"])
        switch fields["kind"] {
        case "asset":
            let context: Crosslink.Context? =
                if let album = fields["album"] { .album(album) }
                else if let person = fields["person"] { .person(person) }
                else if fields["country"] != nil { .search(place) }
                else { nil }
            return .asset(fields["asset"]!, context)
        case "album": return .album(fields["album"]!)
        case "person": return .person(fields["person"]!)
        case "place": return .place(place)
        case "page": return .page(Crosslink.Page(rawValue: fields["page"]!)!)
        default: throw UnknownItem()
        }
    }
}
