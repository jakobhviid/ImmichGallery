// swiftc ImmichGallery/App/SidebarLayout.swift Tests/SidebarLayoutChecks.swift -o build/check-sidebar-layout && build/check-sidebar-layout
import Foundation

@main struct SidebarLayoutChecks {
    static func main() throws {
        var layout = SidebarLayout()
        precondition(layout.links(in: .photos) == [.search, .library, .favorites, .videos])
        precondition(layout.links(in: .utilities).last == .locked)
        precondition(layout.move(.videos, to: .photos, relativeTo: .search))
        precondition(layout.links(in: .photos) == [.videos, .search, .library, .favorites])
        precondition(layout.move(.videos, to: .photos, relativeTo: .favorites, after: true))
        precondition(layout.links(in: .photos).last == .videos)
        precondition(layout.move(.locked, to: .photos, relativeTo: .library))
        precondition(!layout.links(in: .utilities).contains(.locked))
        precondition(layout.links(in: .photos) == [.search, .locked, .library, .favorites, .videos])
        let saved = layout.stored
        precondition(!layout.move(.library, to: .photos, relativeTo: .library))
        precondition(!layout.move(.library, to: .photos, relativeTo: .archive))
        precondition(layout.stored == saved)
        let restored = SidebarLayout(stored: saved)
        for group in SidebarGroup.allCases { precondition(restored.links(in: group) == layout.links(in: group)) }
        // Unknown, duplicate and missing entries must not lose or duplicate navigation destinations.
        let repaired = SidebarLayout(stored: #"[{"link":"library","group":"utilities"},{"link":"library","group":"photos"},{"link":"unknown","group":"photos"},{"link":"search","group":"unknown"}]"#)
        precondition(repaired.links(in: .utilities).first == .library)
        precondition(!repaired.links(in: .photos).contains(.library))
        for candidate in [repaired, restored, SidebarLayout(stored: "invalid"), SidebarLayout()] {
            let links = SidebarGroup.allCases.flatMap { candidate.links(in: $0) }
            precondition(links.count == SidebarLink.allCases.count)
            precondition(Set(links) == Set(SidebarLink.allCases))
        }
        // Empty sections accept drops; hidden features keep their relative saved position.
        for link in layout.links(in: .collections) { layout.move(link, to: .photos) }
        precondition(layout.links(in: .collections).isEmpty)
        precondition(layout.move(.map, to: .collections))
        precondition(layout.links(in: .collections) == [.map])
        precondition(SidebarLayout().links(in: .photos).first == .search)
        var dropLayout = SidebarLayout()
        // Move a lower row upwards, as People & Pets moves above Map in the reference.
        precondition(dropLayout.move(.videos, to: .photos, relativeTo: .library))
        precondition(dropLayout.links(in: .photos) == [.search, .videos, .library, .favorites])
        precondition(!dropLayout.move(.videos, to: .photos, relativeTo: .library))
        precondition(dropLayout.move(.videos, to: .photos, relativeTo: .favorites, after: true))
        precondition(dropLayout.links(in: .photos) == [.search, .library, .favorites, .videos])
        precondition(!dropLayout.move(.videos, to: .photos, relativeTo: .favorites, after: true))
        // A list drop reports an index among the rows shown, the dragged row included.
        let shown: [SidebarLink] = [.search, .library, .favorites, .videos]
        precondition(dropLayout.move(.videos, to: "photos", at: 1, among: shown))
        precondition(dropLayout.links(in: .photos) == [.search, .videos, .library, .favorites])
        let reordered = dropLayout.links(in: .photos)
        precondition(!dropLayout.move(.videos, to: "photos", at: 1, among: reordered), "Dropping a row on its own place changes nothing")
        precondition(!dropLayout.move(.videos, to: "photos", at: 2, among: reordered))
        precondition(dropLayout.move(.search, to: "photos", at: 4, among: reordered))
        precondition(dropLayout.links(in: .photos) == [.videos, .library, .favorites, .search])
        precondition(dropLayout.move(.map, to: "photos", at: 0, among: dropLayout.links(in: .photos)))
        precondition(dropLayout.links(in: .photos).first == .map && !dropLayout.links(in: .explore).contains(.map))
        // Hidden rows are not shown, so a drop after the last shown row lands before them.
        dropLayout.setHidden(true, link: .search)
        precondition(dropLayout.move(.places, to: "photos", at: 4, among: [.map, .videos, .library, .favorites]))
        precondition(dropLayout.links(in: .photos) == [.map, .videos, .library, .favorites, .places, .search])
        let customDrop = dropLayout.addSection(named: "Empty")!
        precondition(dropLayout.move(.places, to: customDrop, at: 0, among: []))
        precondition(dropLayout.links(in: customDrop) == [.places])
        // Existing saved orders migrate into the richer layout without resetting user choices.
        let migrated = SidebarLayout(stored: #"[{"link":"videos","group":"photos"},{"link":"library","group":"utilities"}]"#)
        precondition(migrated.links(in: .photos).first == .videos)
        precondition(migrated.links(in: .utilities).first == .library)
        precondition(migrated.sections.map(\.id) == SidebarGroup.allCases.map(\.rawValue))
        var customized = migrated
        precondition(customized.addSection(named: "  ") == nil)
        let customID = customized.addSection(named: "  Travel  ")!
        precondition(customized.sections.last?.name == "Travel")
        precondition(customized.move(.map, to: customID))
        precondition(customized.move(.places, to: customID, relativeTo: .map))
        precondition(customized.links(in: customID) == [.places, .map])
        let originalCustomOrder = customized.links(in: customID)
        customized.setHidden(true, link: .map)
        customized.setSectionHidden(true, id: customID)
        customized.setDynamicItemHidden(true, key: "account-a|album:123")
        precondition(!customized.isDynamicItemHidden("account-b|album:123"))
        customized = SidebarLayout(stored: customized.stored)
        precondition(customized.isHidden(.map))
        precondition(customized.isDynamicItemHidden("account-a|album:123"))
        precondition(customized.sections.first(where: { $0.id == customID })?.hidden == true)
        precondition(customized.links(in: customID) == originalCustomOrder)
        customized.setSectionHidden(false, id: customID)
        precondition(customized.isHidden(.map), "Restoring a section preserves individually hidden links")
        customized.setHidden(false, link: .map)
        customized.setDynamicItemHidden(false, key: "account-a|album:123")
        precondition(!customized.isHidden(.map))
        precondition(!customized.isDynamicItemHidden("account-a|album:123"))
        customized.renameSection(id: customID, to: "  Trips  ")
        customized.renameSection(id: customID, to: "   ")
        precondition(customized.sections.last?.name == "Trips")
        customized.renameSection(id: SidebarGroup.photos.rawValue, to: "Not a custom section")
        precondition(customized.sections.first?.name == nil)
        customized.shiftSection(id: customID, by: -1)
        precondition(customized.sections[customized.sections.count - 2].id == customID)
        for section in customized.sections { customized.setSectionHidden(true, id: section.id) }
        precondition(customized.sections.allSatisfy(\.hidden))
        precondition(SidebarLayout(stored: customized.stored).sections.allSatisfy(\.hidden))
        customized.setSectionHidden(false, id: customID)
        precondition(customized.sections.filter { !$0.hidden }.map(\.id) == [customID])
        precondition(!customized.move(.search, to: "missing-section"))
        let reset = SidebarLayout()
        precondition(reset.sections.allSatisfy { !$0.hidden && !$0.isCustom })
        precondition(SidebarLink.allCases.allSatisfy { !reset.isHidden($0) })
        // Recover destinations from a removed or corrupt custom section instead of losing them.
        var raw = try JSONSerialization.jsonObject(with: Data(customized.stored.utf8)) as! [String: Any]
        var rawSections = raw["sections"] as! [[String: Any]]
        rawSections.removeAll { ($0["id"] as? String) == customID }
        rawSections.append(rawSections[0])
        raw["sections"] = rawSections
        let repairedCustom = SidebarLayout(stored: String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self))
        precondition(repairedCustom.sections.count == SidebarGroup.allCases.count)
        precondition(repairedCustom.links(in: .explore).contains(.map))
        precondition(repairedCustom.links(in: .explore).contains(.places))
        var deletion = SidebarLayout()
        let deletedID = deletion.addSection(named: "Remove me")!
        let keptID = deletion.addSection(named: "Keep me")!
        deletion.move(.map, to: deletedID)
        deletion.move(.favorites, to: deletedID)
        deletion.move(.videos, to: keptID)
        deletion.setHidden(true, link: .map)
        deletion.setSectionHidden(true, id: SidebarGroup.utilities.rawValue)
        deletion.setDynamicItemHidden(true, key: "account-a|album:123")
        let builtins = deletion.sections.filter { !$0.isCustom }
        deletion.removeSection(id: SidebarGroup.photos.rawValue)
        deletion.removeSection(id: "missing-section")
        precondition(deletion.sections.filter { !$0.isCustom } == builtins)
        deletion.removeSection(id: deletedID)
        precondition(!deletion.sections.contains { $0.id == deletedID })
        precondition(deletion.links(in: deletedID).isEmpty)
        precondition(deletion.links(in: .explore).contains(.map))
        precondition(deletion.links(in: .photos).contains(.favorites))
        precondition(deletion.links(in: keptID) == [.videos])
        precondition(deletion.isHidden(.map))
        precondition(deletion.isDynamicItemHidden("account-a|album:123"))
        precondition(deletion.sections.first { $0.id == SidebarGroup.utilities.rawValue }?.hidden == true)
        let afterDeletion = SidebarLayout(stored: deletion.stored)
        precondition(afterDeletion.stored == deletion.stored)
        // Missing optional fields in an older saved object must not reset its section or item order.
        var partial = try JSONSerialization.jsonObject(with: Data(deletion.stored.utf8)) as! [String: Any]
        partial.removeValue(forKey: "hiddenDynamicItems")
        partial.removeValue(forKey: "hiddenLinks")
        let partialLayout = SidebarLayout(stored: String(decoding: try JSONSerialization.data(withJSONObject: partial), as: UTF8.self))
        precondition(partialLayout.sections == deletion.sections)
        precondition(partialLayout.links(in: keptID) == [.videos])
        precondition(!partialLayout.isHidden(.map))
        // Album sections keep their own count and sort; older saved layouts list every album.
        var albums = SidebarLayout(stored: partialLayout.stored)
        precondition(albums.albumLimit(in: SidebarGroup.myAlbums.rawValue) == nil)
        albums.setAlbumLimit(6, in: SidebarGroup.myAlbums.rawValue)
        albums.setAlbumLimit(0, in: SidebarGroup.sharedAlbums.rawValue)
        albums.setAlbumSorting("MostRecentPhoto", in: SidebarGroup.myAlbums.rawValue)
        albums = SidebarLayout(stored: albums.stored)
        precondition(albums.albumLimit(in: SidebarGroup.myAlbums.rawValue) == 6)
        precondition(albums.albumLimit(in: SidebarGroup.sharedAlbums.rawValue) == 1)
        precondition(albums.albumSorting(in: SidebarGroup.myAlbums.rawValue) == "MostRecentPhoto")
        precondition(albums.albumSorting(in: SidebarGroup.sharedAlbums.rawValue) == nil)
        precondition(albums.links(in: keptID) == [.videos])
        albums.setAlbumLimit(nil, in: SidebarGroup.myAlbums.rawValue)
        precondition(SidebarLayout(stored: albums.stored).albumLimit(in: SidebarGroup.myAlbums.rawValue) == nil)
        precondition(SidebarLayout(stored: #"{"albumLimits":{"myAlbums":-3}}"#).albumLimit(in: SidebarGroup.myAlbums.rawValue) == nil)
        precondition(SidebarSection(id: SidebarGroup.sharedAlbums.rawValue).listsAlbums && !SidebarSection(id: customID).listsAlbums)
        // Collapsing is saved per section, and layouts saved before it existed stay expanded.
        var collapsing = SidebarLayout(stored: albums.stored)
        precondition(collapsing.sections.allSatisfy { !$0.isCollapsed })
        collapsing.setSectionCollapsed(true, id: SidebarGroup.utilities.rawValue)
        collapsing = SidebarLayout(stored: collapsing.stored)
        precondition(collapsing.sections.first { $0.id == SidebarGroup.utilities.rawValue }?.isCollapsed == true)
        precondition(collapsing.sections.filter(\.isCollapsed).count == 1)
        collapsing.setSectionCollapsed(false, id: SidebarGroup.utilities.rawValue)
        precondition(!collapsing.stored.contains("collapsed"))
        print("Sidebar checks passed: migration, custom sections, visibility, account isolation, recovery, album limits, collapsing and insertion ordering")
    }
}
