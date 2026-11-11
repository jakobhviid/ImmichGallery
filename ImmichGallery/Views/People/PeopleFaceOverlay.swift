import SwiftUI

/// Passive boxes in viewer coordinates; face actions live in Manage Faces so pan/zoom stays available.
struct PeopleFaceOverlay: View {
    @Environment(LibrarySession.self) private var session
    let assetID: String
    let imageSize: CGSize
    let zoom: CGFloat
    let offset: CGSize
    @State private var faces: [PeopleFace] = []
    @AppStorage("showPeopleFaces") private var visible = false
    @State private var coordinatesMatch = false
    @State private var showingList = false
    @State private var supported = true
    @State private var assigning: PeopleFace?
    @State private var removing: PeopleFace?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        GeometryReader { geo in
            if visible && coordinatesMatch {
                ForEach(faces) { face in
                    let rect = face.displayedRect(in: geo.size, imageSize: imageSize, zoom: zoom, offset: offset)
                    Rectangle().stroke(.white, lineWidth: 2)
                        .overlay(alignment: .bottom) {
                            Text(face.person?.displayName ?? "Unassigned Face")
                                .font(.caption).padding(3).background(.black.opacity(0.7)).foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .frame(width: rect.width, height: rect.height)
                        .clipped()
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: visible && coordinatesMatch)
        .toolbar(id: "faces") {
            if session.features.facialRecognition && supported {
                ToolbarItem(id: "manageFaces") {
                    Button { showingList = true } label: { Label("Manage Faces", systemImage: "person.2") }
                }
                ToolbarItem(id: "showFaces") {
                    Toggle(isOn: $visible) { Label("Show Faces", systemImage: "person.crop.rectangle") }
                        .help("Show faces and manage people")
                }
            }
        }
        .task(id: visible) { if visible { await load() } }
        .sheet(isPresented: $showingList) {
            VStack(spacing: 16) {
                Text("Faces in This Photo").font(.headline)
                if !coordinatesMatch {
                    Text("Face boxes are unavailable for edited photos.").foregroundStyle(.secondary)
                }
                if faces.isEmpty { Text("No faces found.").foregroundStyle(.secondary) }
                List(faces) { face in
                    HStack {
                        Text(face.person?.displayName ?? "Unassigned Face")
                        Spacer()
                        Button("Assign…") { showingList = false; assigning = face }
                        if let person = face.person {
                            Button("Use as Featured Photo") {
                                perform { try await setFeaturedPhoto(person.id) }
                            }
                            Button("Remove…", role: .destructive) { showingList = false; removing = face }
                        }
                    }.disabled(busy)
                }
                Button("Done") { showingList = false }.keyboardShortcut(.cancelAction)
            }.padding(20).frame(width: 600, height: 360)
                .task { await load() }
        }
        .sheet(item: $assigning) { face in
            PeoplePicker(title: "Assign Face", excludedID: face.person?.id, allowsCreation: true) { person in
                _ = try await session.client.reassignFace(face.id, to: person.id)
                await load()
                session.invalidateGrids()
                NotificationCenter.default.post(name: .peopleChanged, object: session.services)
            }
        }
        .confirmationDialog("Remove Face?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Face", role: .destructive) {
                guard let face = removing else { return }
                removing = nil
                perform { try await session.client.removeFace(face.id) }
            }
        } message: { Text("Remove this face from the photo. The photo itself will be kept.") }
        .alert("Faces", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func setFeaturedPhoto(_ personID: String) async throws {
        let previous = try? await session.client.data(for: session.client.personThumbnailRequest(personID))
        _ = try await session.client.editPerson(personID, PersonEdit(featureFaceAssetId: assetID))
        session.pipeline.invalidatePerson(personID)
        NotificationCenter.default.post(name: .personThumbnailChanged, object: session.services, userInfo: ["personID": personID])
        await session.pipeline.refreshPersonThumbnail(personID, replacing: previous)
        NotificationCenter.default.post(name: .personThumbnailChanged, object: session.services, userInfo: ["personID": personID])
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await action()
                await load()
                session.invalidateGrids()
                NotificationCenter.default.post(name: .peopleChanged, object: session.services)
            } catch { session.handle(error); self.error = error.localizedDescription }
        }
    }
    private func load() async {
        do {
            // TODO: allow edited boxes once the viewer requests edited=true for previews AND originals.
            let asset = try await session.client.asset(assetID)
            coordinatesMatch = asset.isEdited == false
            faces = try await session.client.faces(assetID: assetID)
        }
        catch ImmichError.http(404, _) { supported = false; visible = false }
        catch { session.handle(error); self.error = error.localizedDescription }
    }
}
