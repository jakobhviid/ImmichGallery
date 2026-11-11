import SwiftUI

struct ExploreMemoriesView: View {
    @Environment(LibrarySession.self) private var session
    @State private var memories: [ExploreMemory] = []
    @Environment(\.openWindow) private var openWindow
    @State private var error: String?
    @State private var duration = 5
    @State private var page = 1
    @State private var hasMore = false
    @State private var busy = false
    @State private var deleting: ExploreMemory?
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340))]) {
                ForEach(memories) { memory in
                    Button { openWindow(id: "explore-memory", value: memory.id) } label: {
                        VStack(alignment: .leading) {
                            RemoteThumbnail(pipeline: session.pipeline, assetID: memory.assets.first?.id, size: .preview).aspectRatio(1.4, contentMode: .fit).clipShape(.rect(cornerRadius: 12))
                            Text(memory.title).font(.headline)
                            Text("\(memory.assets.count) photos").foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete Memory…", role: .destructive) { deleting = memory }
                    }
                }
            }.padding()
            if hasMore { Button("Load More") { Task { await load() } }.disabled(busy) }
        }
        .pageToolbar("memories")
        .task {
            do {
                let preferences = try await session.client.explorePreferences()
                guard preferences.memories?.enabled == true else { error = String(localized: "Memories are disabled in Immich Account Settings."); hasMore = false; return }
                duration = max(1, preferences.memories?.duration ?? 5)
                await load()
            } catch { self.error = error.localizedDescription }
        }
        .confirmationDialog("Delete Memory?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Memory", role: .destructive) {
                guard let memory = deleting else { return }
                Task {
                    do { try await session.client.exploreDeleteMemory(memory.id); withAnimation(.smooth(duration: 0.35)) { memories.removeAll { $0.id == memory.id } } }
                    catch { self.error = error.localizedDescription }
                }
            }
        } message: { Text("The photos in this memory are kept.") }
        .alert("Memories", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }
    private func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let batch = try await session.client.exploreMemories(page: page)
            memories.append(contentsOf: batch.map { memory in
                var visible = memory
                visible.assets.removeAll { $0.visibility == "locked" }
                return visible
            }.filter { !$0.assets.isEmpty })
            page += 1; hasMore = batch.count == 100
        } catch { self.error = error.localizedDescription }
    }
}

struct ExploreMemoryPlayer: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State var memory: ExploreMemory
    let duration: Int
    @State private var index = 0
    @State private var paused = false
    @State private var image: CGImage?
    /// Which photo `image` is, so the slides cross-fade by photo.
    @State private var imageID: String?
    @State private var error: String?
    private var asset: AssetResponse? { memory.assets.indices.contains(index) ? memory.assets[index] : nil }
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().padding(.bottom, 80)
                    .id(imageID)
                    .transition(.opacity)
            }
            VStack {
                HStack {
                    Text(memory.title)
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Spacer()
                HStack {
                    Button("Previous", systemImage: "backward.fill") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                    Button(paused ? "Play" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") { paused.toggle() }.keyboardShortcut(.space, modifiers: [])
                    Button("Next", systemImage: "forward.fill") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                    Text("\(memory.assets.isEmpty ? 0 : index + 1) / \(memory.assets.count)")
                    Button("Remove from Memory") {
                        guard let asset else { return }
                        Task {
                            do {
                                try await session.client.exploreRemoveMemoryAsset(memory.id, asset: asset.id)
                                withAnimation(.smooth(duration: 0.3)) {
                                    memory.assets.removeAll { $0.id == asset.id }; index = min(index, max(0, memory.assets.count - 1))
                                }
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(asset == nil)
                }
            }.padding(24).foregroundStyle(.white)
        }
        .task { do { try await session.client.exploreSeenMemory(memory.id) } catch { self.error = error.localizedDescription } }
        .onChange(of: session.services.hiddenAssetIDs) {
            memory.assets.removeAll { session.services.hiddenAssetIDs.contains($0.id) }
            index = min(index, max(0, memory.assets.count - 1))
            image = nil
        }
        .task(id: "\(asset?.id ?? "")-\(session.metadata.imageRevision)") {
            // The previous photo stays until the next has loaded, then they cross-fade, without a black frame between.
            guard let asset else { image = nil; return }
            let loaded = await session.pipeline.thumbnail(asset.id, size: .preview)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) { image = loaded; imageID = asset.id }
        }
        .task(id: "\(paused)-\(index)") {
            guard !paused else { return }
            do { try await Task.sleep(for: .seconds(duration)); if index + 1 < memory.assets.count { step(1) } else { paused = true } } catch {}
        }
        .alert("Memory", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }
    private func step(_ delta: Int) { index = min(max(index + delta, 0), max(memory.assets.count - 1, 0)) }
}
