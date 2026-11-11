import SwiftUI

struct AssetsStackButton: View {
    @Environment(LibrarySession.self) private var session
    let item: AssetItem
    let model: AssetGridModel
    @State private var stack: AssetsStackSummary?
    @State private var presented = false
    @State private var loading = false
    var body: some View {
        if let count = item.stackCount {
            Button {
                loading = true
                Task {
                    defer { loading = false }
                    do {
                        stack = try await session.client.asset(item.id).stack
                        presented = stack != nil
                    } catch { session.handle(error); model.lastError = error.localizedDescription }
                }
            } label: { Label("Browse Stack (\(count))", systemImage: "square.stack.3d.up") }
                .disabled(loading)
                .buttonStyle(.bordered).padding()
                .sheet(isPresented: $presented) {
                    if let stack { AssetsStackBrowser(stackID: stack.id, model: model) }
                }
        }
    }
}

struct AssetsStackBrowser: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let stackID: String
    let model: AssetGridModel
    @State private var stack: AssetsStack?
    @State private var selected: String?
    @State private var error: String?
    @State private var busy = false
    @State private var unstack = false
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Stack").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let stack, let asset = stack.assets.first(where: { $0.id == selected }) {
                AssetsPreview(asset: asset).frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(stack.assets) { member in
                            Button { withAnimation(.easeInOut(duration: 0.2)) { selected = member.id } } label: {
                                ThumbnailCell(asset: AssetItem(member), isSelected: selected == member.id, size: .thumbnail)
                                    .frame(width: 80, height: 80)
                            }.buttonStyle(.plain).help(member.originalFileName)
                        }
                    }
                }
                HStack {
                    Text(asset.originalFileName).lineLimit(1)
                    Spacer()
                    Button("Set Primary") { perform { _ = try await session.client.assetsSetPrimary(stack: stackID, asset: asset.id) } }
                        .disabled(asset.id == stack.primaryAssetId)
                    Button("Remove from Stack") { perform { try await session.client.assetsRemoveFromStack(stackID, asset: asset.id) } }
                        .disabled(asset.id == stack.primaryAssetId)
                    Button("Unstack…") { unstack = true }
                }.disabled(busy || model.source == .trash || stack.assets.contains { $0.ownerId != session.user?.id })
            } else if error == nil { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .padding(20).frame(minWidth: 700, idealWidth: 900, minHeight: 550, idealHeight: 700)
        .task { await load() }
        .onDisappear { Task { await model.reload() } }
        .confirmationDialog("Unstack all members?", isPresented: $unstack, titleVisibility: .visible) {
            Button("Unstack") { perform { try await session.client.assetsUnstack(stackID); dismiss() } }
        } message: { Text("All photos remain in your library.") }
    }
    private func load() async {
        do {
            let loaded = try await session.client.assetsStack(stackID)
            stack = AssetsStack(id: loaded.id, primaryAssetId: loaded.primaryAssetId, assets: loaded.assets.filter { ($0.visibility == "locked") == (model.source == .locked) })
            if stack?.assets.contains(where: { $0.id == selected }) != true { selected = stack?.primaryAssetId }
        } catch ImmichError.http(404, _) { dismiss() }
        catch { session.handle(error); self.error = error.localizedDescription }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await action()
                session.invalidateGrids()
                await load()
            } catch { session.handle(error); self.error = error.localizedDescription }
        }
    }
}

struct AssetsPreview: View {
    @Environment(LibrarySession.self) private var session
    let asset: AssetResponse
    var clickToPlay = false
    @State private var playing = false
    @State private var image: CGImage?
    /// Which photo `image` is, so choosing another one cross-fades between them.
    @State private var imageID: String?
    var body: some View {
        Group {
            if asset.type == .video && (!clickToPlay || playing) {
                VideoPlayerView(url: session.client.videoURL(asset.id), headers: session.client.credential?.headers ?? [:]).id(asset.id)
            } else if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .id(imageID)
                    .transition(.opacity)
            } else { ProgressView() }
        }
        .overlay {
            if clickToPlay && asset.type == .video && !playing {
                Button { playing = true } label: { Label("Play Video", systemImage: "play.circle.fill") }.buttonStyle(.borderedProminent)
            }
        }
        .task(id: "\(asset.id)-\(session.metadata.imageRevision)") {
            // The previous photo stays until the next has loaded, then they cross-fade, instead of a spinner between.
            playing = false
            let loaded = await session.pipeline.thumbnail(asset.id, size: .preview)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { image = loaded; imageID = asset.id }
        }
    }
}
