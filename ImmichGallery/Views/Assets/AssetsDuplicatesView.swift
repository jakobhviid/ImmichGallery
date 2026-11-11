import SwiftUI

struct AssetsDuplicatesView: View {
    @Environment(LibrarySession.self) private var session
    @State private var groups: [AssetsDuplicate] = []
    @State private var keep: [String: Set<String>] = [:]
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?
    @State private var pending: AssetsDuplicate?
    @State private var dismissGroup = false
    @AppStorage("duplicates.sortBy") private var sortBy = DuplicatesSortBy.server
    var body: some View {
        Group {
            if loading { ProgressView() }
            else if groups.isEmpty {
                ContentUnavailableView(error ?? "No Duplicates", systemImage: "square.on.square")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(DuplicatesArrangement(sortBy: sortBy).sorted(groups)) { group in
                            VStack(alignment: .leading) {
                                Text("\(group.assets.count) similar items").font(.headline)
                                ScrollView(.horizontal) {
                                    HStack(alignment: .top, spacing: 16) {
                                        ForEach(group.assets) { asset in
                                            VStack(alignment: .leading, spacing: 8) {
                                                AssetsPreview(asset: asset, clickToPlay: true).id(asset.id).frame(width: 280, height: 240)
                                                Text(asset.originalFileName).lineLimit(1)
                                                Text(asset.exifInfo?.fileSizeInByte.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Size unavailable")
                                                    .foregroundStyle(.secondary)
                                                Toggle("Keep", isOn: Binding(get: { keep[group.id, default: []].contains(asset.id) }, set: { value in
                                                    if value { keep[group.id, default: []].insert(asset.id) }
                                                    else { keep[group.id, default: []].remove(asset.id) }
                                                }))
                                            }.frame(width: 280)
                                        }
                                    }
                                }
                                HStack {
                                    Button(session.features.trash ? "Keep Selected, Trash Others…" : "Keep Selected, Delete Others…") { dismissGroup = false; pending = group }
                                        .disabled(keep[group.id, default: []].isEmpty || keep[group.id]?.count == group.assets.count)
                                    Button("Dismiss Group…") { dismissGroup = true; pending = group }
                                }
                            }
                            Divider()
                        }
                    }.padding(24)
                }
            }
        }
        .navigationTitle("Duplicates")
        .disabled(busy)
        .pageToolbar("duplicates") {
            ToolbarItem(id: "viewOptions") {
                Menu {
                    Picker("Sort By", selection: $sortBy.animation(.smooth(duration: 0.35))) {
                        ForEach(DuplicatesSortBy.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("View Options", systemImage: "line.3.horizontal.decrease")
                }
                .menuIndicator(.hidden)
                .help("View Options")
            }
            ToolbarItem(id: "reload") { Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } } }
        }
        .task { await load() }
        .confirmationDialog(dismissGroup ? "Dismiss this duplicate group?" : (session.features.trash ? "Move unselected items to Recently Deleted?" : "Permanently delete unselected items?"),
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let group = pending {
                Button(dismissGroup ? "Dismiss Group" : (session.features.trash ? "Trash Others" : "Delete Permanently"), role: dismissGroup ? nil : .destructive) {
                    let dismissing = dismissGroup
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            if dismissing { try await session.client.assetsDismissDuplicate(group.id) }
                            else { try await session.client.assetsResolveDuplicate(group, keep: keep[group.id, default: []]) }
                            session.invalidateGrids()
                            await session.reloadAlbums()
                            // The resolved group closes up, as a deleted photo does.
                            withAnimation(.smooth(duration: 0.35)) { groups.removeAll { $0.id == group.id } }
                            keep[group.id] = nil
                        } catch { session.handle(error); self.error = error.localizedDescription }
                    }
                }
            }
        } message: { Text(dismissGroup ? "All items remain in your library and will no longer be suggested as this duplicate group." : (session.features.trash ? "Selected items stay in your library. The other items are moved to Recently Deleted." : "Selected items stay in your library. The other items are permanently deleted. This cannot be undone.")) }
        .alert("Duplicates", isPresented: Binding(get: { error != nil && !groups.isEmpty }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func load() async {
        error = nil
        defer { loading = false }
        do {
            groups = try await session.client.assetsDuplicates()
            for group in groups where keep[group.id] == nil { keep[group.id] = Set(group.suggestedKeepAssetIds ?? group.assets.prefix(1).map(\.id)) }
        } catch ImmichError.http(404, _) { error = String(localized: "Duplicates are unavailable on this server.") }
        catch { session.handle(error); self.error = error.localizedDescription }
    }
}
