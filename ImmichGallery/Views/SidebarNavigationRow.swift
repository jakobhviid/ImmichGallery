import SwiftUI

extension SidebarGroup {
    var title: LocalizedStringKey {
        switch self {
        case .photos: "Photos"
        case .explore: "Explore"
        case .collections: "Collections"
        case .sharing: "Sharing"
        case .utilities: "Utilities"
        case .myAlbums: "My Albums"
        case .sharedAlbums: "Shared Albums"
        }
    }
}

extension SidebarSection {
    var label: Text {
        if let group = SidebarGroup(rawValue: id) { Text(group.title) }
        else { Text(verbatim: name ?? "") }
    }
}

extension SidebarLink {
    var presentation: (title: LocalizedStringKey, icon: String, destination: SidebarItem) {
        switch self {
        case .search: ("Search", "magnifyingglass", .search)
        case .library: ("Library", "photo.on.rectangle", .library)
        case .favorites: ("Favorites", "heart", .favorites)
        case .videos: ("Videos", "video", .videos)
        case .map: ("Map", "map", .explore(.map))
        case .places: ("Places", "globe.europe.africa", .explore(.places))
        case .memories: ("Memories", "sparkles.rectangle.stack", .explore(.memories))
        case .tags: ("Tags", "tag", .explore(.tags))
        case .folders: ("Folders", "folder", .explore(.folders))
        case .albums: ("Albums", "rectangle.stack", .albums)
        case .people: ("People", "person.crop.square", .people)
        case .sharedLinks: ("Shared Links", "link", .sharedLinks)
        case .partners: ("Partner Sharing", "person.2", .partners)
        case .duplicates: ("Duplicates", "square.on.square", .duplicates)
        case .largeFiles: ("Large Files", "externaldrive", .largeFiles)
        case .geolocation: ("Assign Location", "mappin.and.ellipse", .geolocation)
        case .archive: ("Archive", "archivebox", .archive)
        case .trash: ("Recently Deleted", "trash", .trash)
        case .locked: ("Locked Folder", "lock", .explore(.locked))
        }
    }
}

struct SidebarNavigationRow: View {
    let link: SidebarLink
    let sectionID: String
    @Binding var layout: String
    let edit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SidebarNavigationLabel(link: link)
            .contextMenu {
                Menu("Move to Section") {
                    ForEach(SidebarLayout(stored: layout).sections.filter { !$0.hidden && $0.id != sectionID }) { destination in
                        Button { move(link, to: destination.id) } label: { destination.label }
                    }
                }
                Divider()
                Button("Hide from Sidebar") {
                    var updated = SidebarLayout(stored: layout)
                    updated.setHidden(true, link: link)
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { layout = updated.stored }
                }
                Button("Edit Sidebar", action: edit)
            }
    }

    private func move(_ source: SidebarLink, to sectionID: String) {
        var updated = SidebarLayout(stored: layout)
        guard updated.move(source, to: sectionID) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { layout = updated.stored }
    }
}

struct SidebarNavigationLabel: View {
    let link: SidebarLink
    var body: some View {
        Label(link.presentation.title, systemImage: link.presentation.icon)
    }
}
