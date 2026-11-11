import SwiftUI

struct MetadataMenuItems: View {
    @Environment(LibrarySession.self) private var session
    let ids: [String]
    var canEditImage = false
    var menuBarShortcuts = false

    var body: some View {
        Group {
            Button("Adjust Date and Time…") { session.metadata.present(.date, ids: ids) }
            Button("Assign Location…") { session.metadata.present(.location, ids: ids) }
            if canEditImage, ids.count == 1, let id = ids.first,
               session.metadata.imageEligibility[id] == true, !session.metadata.unavailableEdits,
               session.version?.supportsMetadataEdits == true {
                Divider()
                rotateButton("Rotate Left", clockwise: false)
                rotateButton("Rotate Right", clockwise: true)
                Button("Crop…") { session.metadata.present(.crop, ids: ids) }
            }
        }
    }

    @ViewBuilder private func rotateButton(_ title: String, clockwise: Bool) -> some View {
        let button = Button(title) { rotate(clockwise) }
        if menuBarShortcuts {
            button.keyboardShortcut("r", modifiers: clockwise ? [.command, .option] : [.command, .shift])
        } else { button }
    }

    private func rotate(_ clockwise: Bool) {
        guard let id = ids.first else { return }
        Task { await session.metadata.rotate(id, clockwise: clockwise, session: session) }
    }
}

struct MetadataInspectorControls: View {
    @Environment(LibrarySession.self) private var session
    let asset: AssetResponse
    @State private var description = ""
    @State private var ratingsEnabled = false
    @State private var submittedDescription = ""
    @FocusState private var descriptionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Add a Description", text: $description, axis: .vertical)
                .lineLimit(2...6)
                .focused($descriptionFocused)
                .onSubmit { saveDescription() }
                .onKeyPress(keys: [.return], phases: .down) { key in
                    guard !key.modifiers.contains(.shift) else { return .ignored }
                    saveDescription()
                    descriptionFocused = false
                    return .handled
                }
            if description != (asset.exifInfo?.description ?? "") {
                Button("Save Description", action: saveDescription)
            }
            if ratingsEnabled {
                HStack(spacing: 5) {
                    ForEach(1...5, id: \.self) { rating in
                        Button {
                            Task { _ = await session.metadata.update(.init(ids: [asset.id], rating: rating), session: session) }
                        } label: {
                            Image(systemName: rating <= (asset.exifInfo?.rating ?? 0) ? "star.fill" : "star")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("\(rating) stars")
                    }
                    Button("Clear") {
                        Task { _ = await session.metadata.update(.init(ids: [asset.id], clearRating: true), session: session) }
                    }
                }
            }
            Menu("Edit Metadata") {
                MetadataMenuItems(ids: [asset.id], canEditImage: asset.type == .image && asset.livePhotoVideoId == nil)
            }
        }
        .animation(.smooth(duration: 0.2), value: description != (asset.exifInfo?.description ?? ""))
        .animation(.smooth(duration: 0.2), value: ratingsEnabled)
        .disabled(session.metadata.busy || asset.isTrashed || session.user?.id == nil || asset.ownerId != session.user?.id)
        .task(id: asset.id) {
            description = asset.exifInfo?.description ?? ""
            submittedDescription = description
            ratingsEnabled = (try? await session.client.metadataPreferences().ratings?.enabled) == true
        }
        .onChange(of: descriptionFocused) { if !descriptionFocused { saveDescription() } }
        .onDisappear { saveDescription() }
    }

    private func saveDescription() {
        guard description != submittedDescription else { return }
        let value = description
        let id = asset.id
        submittedDescription = value
        Task {
            if !(await session.metadata.update(.init(ids: [id], description: value), session: session)) {
                submittedDescription = asset.exifInfo?.description ?? ""
            }
        }
    }
}

struct MetadataHost: ViewModifier {
    @Environment(LibrarySession.self) private var session
    let model: AssetGridModel

    func body(content: Content) -> some View {
        @Bindable var metadata = session.metadata
        content
            .sheet(item: $metadata.presentation) { request in
                MetadataSheet(request: request)
            }
            .alert("Metadata", isPresented: Binding(get: { metadata.error != nil }, set: { if !$0 { metadata.error = nil } })) {
                Button("OK") { metadata.error = nil }
            } message: { Text(metadata.error ?? "") }
            .task(id: model.viewerID.map { [$0] } ?? Array(model.selection).sorted()) {
                await metadata.checkImageEligibility(model.viewerID.map { [$0] } ?? Array(model.selection), session: session)
            }
            .task(id: metadata.revision) {
                guard let id = model.viewerID, let asset = try? await session.client.asset(id), !Task.isCancelled else { return }
                metadata.viewerSnapshot = AssetItem(asset)
            }
            .task(id: metadata.gridRevision) {
                guard metadata.gridRevision > 0 else { return }
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                let month = metadata.viewerSnapshot?.date.map(ImmichDate.monthKey)
                await model.reload()
                guard !Task.isCancelled else { return }
                if let month, let index = model.sections.firstIndex(where: { $0.id.hasPrefix(String(month.prefix(7))) }) {
                    model.ensureLoaded(index)
                }
            }
    }
}
