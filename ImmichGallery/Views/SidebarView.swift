import SwiftUI

struct SidebarView: View {
    @Environment(LibrarySession.self) private var session
    @Binding var selection: SidebarItem?
    @AppStorage("sidebarLayout") private var storedLayout = ""
    @AppStorage("albums.filter") private var albumsFilter = AlbumsFilter.all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Editing happens in the sidebar itself, like Music's Edit and the iPadOS sidebar: hidden sections
    /// and items appear with checkboxes until Done.
    @Binding var editing: Bool
    @State private var renaming: String?
    @State private var renameDraft = ""
    @State private var removing: SidebarSection?
    @State private var confirmingReset = false

    private var layout: SidebarLayout { SidebarLayout(stored: storedLayout) }

    /// The system sidebar list, so text, icons, rows, headers and their collapse chevrons follow the system's
    /// sidebar icon size and look like Finder's and Photos'.
    var body: some View {
        let layout = self.layout
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(layout.sections.filter { editing || !$0.hidden }) { section in
                        Section(isExpanded: expanded(section)) {
                            rows(in: section, layout: layout)
                        } header: {
                            SidebarSectionHeader(section: section, editing: editing, renaming: $renaming,
                                                 setHidden: { hidden in update { $0.setSectionHidden(hidden, id: section.id) } },
                                                 rename: { name in update { $0.renameSection(id: section.id, to: name) } }, name: $renameDraft) {
                                headerMenu(section, layout: layout)
                            }
                            // An empty section takes its first item from a drop on its heading.
                            .dropDestination(for: String.self) { items, _ in
                                drop(items, in: section.id, at: .max, layout: layout)
                                return true
                            }
                            .id(section.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                // Hidden sections and items slide in and out as editing starts and ends.
                .animation(reorderAnimation, value: editing)
                .onExitCommand { if editing && renaming == nil { editing = false } }
                Divider()
                AccountSidebarFooter(services: session.services) { // Account
                    SidebarFooterControls(editing: $editing, hidden: hiddenItems(in: layout),
                                          newSection: { addSection(scroll: proxy) }, reset: { confirmingReset = true })
                }
            }
        }
        .onChange(of: editing) { _, value in if !value { finishRenaming() } }
        .confirmationDialog("Delete this custom section?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Delete Section", role: .destructive) {
                if let section = removing { update { $0.removeSection(id: section.id) } }
                removing = nil
            }
        } message: {
            Text("Items return to their default sections. Your photos and albums are not deleted.")
        }
        .confirmationDialog("Reset the sidebar?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Sidebar", role: .destructive) { storedLayout = "" }
        } message: {
            Text("This restores the default sections and item order, shows hidden items, and removes custom sections. Your photos and albums are not affected.")
        }
    }

    /// Editing exposes every item without changing the saved collapsed state.
    private func expanded(_ section: SidebarSection) -> Binding<Bool> {
        Binding(get: { editing || !section.isCollapsed },
                set: { expanded in if !editing { update { $0.setSectionCollapsed(!expanded, id: section.id) } } })
    }

    @ViewBuilder
    private func rows(in section: SidebarSection, layout: SidebarLayout) -> some View {
        let links = shownLinks(in: section.id, layout: layout)
        if editing && section.listsAlbums {
            VStack(alignment: .leading, spacing: 4) {
                albumLimitPicker(in: section.id, layout: layout)
                albumSortPicker(in: section.id, layout: layout)
            }
            .pickerStyle(.menu).controlSize(.small)
        }
        ForEach(links, id: \.self) { link in
            Group {
                if editing {
                    SidebarEditRow(isOn: Binding(get: { !layout.isHidden(link) }, set: { visible in update { $0.setHidden(!visible, link: link) } })) {
                        SidebarNavigationLabel(link: link)
                    }
                } else {
                    SidebarNavigationRow(link: link, sectionID: section.id, layout: $storedLayout, edit: { editing = true })
                        .tag(link.presentation.destination)
                }
            }
            .draggable(link.dragValue) { SidebarNavigationLabel(link: link) }
            // Drag is the main way to reorder; these keep it possible without a pointer.
            .accessibilityAction(named: Text("Move Up")) { shift(link, by: -1, in: links, sectionID: section.id) }
            .accessibilityAction(named: Text("Move Down")) { shift(link, by: 1, in: links, sectionID: section.id) }
        }
        .dropDestination(for: String.self) { items, index in drop(items, in: section.id, at: index, layout: layout) }
        if section.id == SidebarGroup.sharing.rawValue, session.sharing.partnersAvailable {
            ForEach(session.sharing.receivedPartners.filter { editing || !layout.isDynamicItemHidden(session.sidebarItemKey("partner:" + $0.id)) }) { partner in
                let key = session.sidebarItemKey("partner:" + partner.id)
                if editing {
                    SidebarEditRow(isOn: dynamicVisibility(key, layout: layout)) { Label(partner.name, systemImage: "person.2") }
                } else {
                    Label(partner.name, systemImage: "person.2")
                        .tag(SidebarItem.partner(partner.id))
                        .contextMenu {
                            Button("Hide from Sidebar") { update { $0.setDynamicItemHidden(true, key: key) } }
                        }
                }
            }
        }
        if section.listsAlbums {
            if editing {
                let albums = session.albums.filter { $0.shared == (section.id == SidebarGroup.sharedAlbums.rawValue) }
                ForEach(AlbumsArrangement.sidebar(albums, sortBy: layout.albumSortBy(in: section.id), limit: nil)) { album in
                    SidebarEditRow(isOn: dynamicVisibility(session.sidebarItemKey("album:" + album.id), layout: layout)) {
                        Label(album.albumName, systemImage: album.shared ? "person.2.crop.square.stack" : "rectangle.stack")
                    }
                }
            } else {
                AlbumSidebarRows(shared: section.id == SidebarGroup.sharedAlbums.rawValue, storedLayout: $storedLayout)
                if session.sidebarAlbumsTruncated(in: section.id, layout: layout) {
                    // Like Finder's All Tags… row: a shortened list says where the rest are.
                    Button {
                        albumsFilter = section.id == SidebarGroup.sharedAlbums.rawValue ? .shared : .owned
                        selection = .albums
                    } label: {
                        Label("Show All", systemImage: "ellipsis")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func headerMenu(_ section: SidebarSection, layout: SidebarLayout) -> some View {
        Button(section.isCollapsed ? "Expand" : "Collapse") { update { $0.setSectionCollapsed(!section.isCollapsed, id: section.id) } }
        if section.listsAlbums {
            Divider()
            albumLimitPicker(in: section.id, layout: layout)
            albumSortPicker(in: section.id, layout: layout)
        }
        Divider()
        if section.isCustom {
            Button("Rename Section") { editing = true; renaming = section.id }
            Button("Delete Section…") { removing = section }
        }
        if !section.hidden {
            Button("Hide Section") { update { $0.setSectionHidden(true, id: section.id) } }
        }
        if !editing {
            Button("Edit Sidebar") { editing = true }
        }
    }

    private func finishRenaming() {
        guard let id = renaming else { return }
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { update { $0.renameSection(id: id, to: name) } }
        renaming = nil
    }

    private func shownLinks(in sectionID: String, layout: SidebarLayout) -> [SidebarLink] {
        layout.links(in: sectionID).filter { session.sidebarLinkAvailable($0) && (editing || !layout.isHidden($0)) }
    }

    private func dynamicVisibility(_ key: String, layout: SidebarLayout) -> Binding<Bool> {
        Binding(get: { !layout.isDynamicItemHidden(key) }, set: { visible in update { $0.setDynamicItemHidden(!visible, key: key) } })
    }

    /// Everything hidden on this server, for the footer's Show in Sidebar menu.
    private func hiddenItems(in layout: SidebarLayout) -> [SidebarHiddenItem] {
        func item(_ id: String, _ title: Text, _ icon: String?, show: @escaping (inout SidebarLayout) -> Void) -> SidebarHiddenItem {
            SidebarHiddenItem(id: id, title: title, icon: icon) { update(show) }
        }
        var items = layout.sections.filter(\.hidden).map { section in
            item("section:" + section.id, section.label, nil) { $0.setSectionHidden(false, id: section.id) }
        }
        items += SidebarLink.allCases.filter { layout.isHidden($0) && session.sidebarLinkAvailable($0) }.map { link in
            item("link:" + link.rawValue, Text(link.presentation.title), link.presentation.icon) { $0.setHidden(false, link: link) }
        }
        if session.sharing.partnersAvailable {
            items += session.sharing.receivedPartners.compactMap { partner in
                let key = session.sidebarItemKey("partner:" + partner.id)
                guard layout.isDynamicItemHidden(key) else { return nil }
                return item(key, Text(verbatim: partner.name), "person.2") { $0.setDynamicItemHidden(false, key: key) }
            }
        }
        items += AlbumsArrangement.sidebar(session.albums, sortBy: .title, limit: nil).compactMap { album in
            let key = session.sidebarItemKey("album:" + album.id)
            guard layout.isDynamicItemHidden(key) else { return nil }
            return item(key, Text(verbatim: album.albumName), album.shared ? "person.2.crop.square.stack" : "rectangle.stack") {
                $0.setDynamicItemHidden(false, key: key)
            }
        }
        return items
    }

    private func addSection(scroll: ScrollViewProxy) {
        var updated = layout
        guard let id = updated.addSection(named: String(localized: "New Section")) else { return }
        storedLayout = updated.stored
        editing = true
        renaming = id
        DispatchQueue.main.async { withAnimation(reorderAnimation) { scroll.scrollTo(id, anchor: .bottom) } }
    }

    /// A sidebar row dropped into a section, before the shown row at `index` (or after the last).
    private func drop(_ items: [String], in sectionID: String, at index: Int, layout: SidebarLayout) {
        guard let link = items.lazy.compactMap(SidebarLink.init(dragValue:)).first else { return }
        let shown = shownLinks(in: sectionID, layout: layout)
        update { $0.move(link, to: sectionID, at: min(index, shown.count), among: shown) }
    }

    private func shift(_ link: SidebarLink, by offset: Int, in links: [SidebarLink], sectionID: String) {
        guard let index = links.firstIndex(of: link), links.indices.contains(index + offset) else { return }
        update { $0.move(link, to: sectionID, relativeTo: links[index + offset], after: offset > 0) }
    }

    private var reorderAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88)
    }

    /// Fixed counts, like the system's Recent items setting. A count saved by an earlier version stays listed.
    private func albumLimitPicker(in sectionID: String, layout: SidebarLayout) -> some View {
        let limit = layout.albumLimit(in: sectionID)
        return Picker("Show", selection: Binding(get: { limit }, set: { value in update { $0.setAlbumLimit(value, in: sectionID) } })) {
            Text("All Albums").tag(Int?.none)
            Divider()
            ForEach(Set([5, 10, 15, 20, 30, 50] + (limit.map { [$0] } ?? [])).sorted(), id: \.self) { count in
                Text("\(count) Albums").tag(Int?.some(count))
            }
        }
    }

    private func albumSortPicker(in sectionID: String, layout: SidebarLayout) -> some View {
        Picker("Sort By", selection: Binding(get: { layout.albumSortBy(in: sectionID) },
                                             set: { value in update { $0.setAlbumSorting(value.rawValue, in: sectionID) } })) {
            ForEach(AlbumsSortBy.allCases) { Text($0.title).tag($0) }
        }
    }

    private func update(_ change: (inout SidebarLayout) -> Void) {
        var updated = layout
        change(&updated)
        guard updated.stored != storedLayout else { return }
        withAnimation(reorderAnimation) { storedLayout = updated.stored }
    }
}

extension LibrarySession {
    func sidebarItemKey(_ item: String) -> String {
        client.serverURL.absoluteString + "|" + (user?.id ?? "") + "|" + item
    }

    /// Hidden albums are skipped before the limit applies, so the next album takes their place.
    func sidebarAlbums(in sectionID: String, layout: SidebarLayout) -> [Album] {
        let shown = albums.filter {
            $0.shared == (sectionID == SidebarGroup.sharedAlbums.rawValue) && !layout.isDynamicItemHidden(sidebarItemKey("album:" + $0.id))
        }
        return AlbumsArrangement.sidebar(shown, sortBy: layout.albumSortBy(in: sectionID), limit: layout.albumLimit(in: sectionID))
    }

    func sidebarAlbumsTruncated(in sectionID: String, layout: SidebarLayout) -> Bool {
        guard let limit = layout.albumLimit(in: sectionID) else { return false }
        return albums.count(where: {
            $0.shared == (sectionID == SidebarGroup.sharedAlbums.rawValue) && !layout.isDynamicItemHidden(sidebarItemKey("album:" + $0.id))
        }) > limit
    }

    func sidebarLinkAvailable(_ link: SidebarLink) -> Bool {
        switch link {
        case .people: features.facialRecognition
        case .map: features.map
        case .memories: services.explorePreferences?.memories?.enabled == true
        case .tags: services.explorePreferences?.tags?.enabled == true
        case .folders: services.explorePreferences?.folders?.enabled == true
        case .sharedLinks: sharing.linksAvailable
        case .partners: sharing.partnersAvailable
        case .duplicates: features.duplicateDetection == true
        case .trash: features.trash
        default: true
        }
    }
}

extension SidebarLink {
    /// What a sidebar row carries while it is dragged to another place in the sidebar.
    var dragValue: String { "immich-gallery-sidebar:" + rawValue }

    init?(dragValue: String) {
        guard dragValue.hasPrefix("immich-gallery-sidebar:") else { return nil }
        self.init(rawValue: String(dragValue.dropFirst("immich-gallery-sidebar:".count)))
    }
}

extension SidebarLayout {
    /// Album sections list recently changed albums first unless another sort is chosen.
    func albumSortBy(in sectionID: String) -> AlbumsSortBy {
        albumSorting(in: sectionID).flatMap(AlbumsSortBy.init(rawValue:)) ?? .dateModified
    }
}
