import SwiftUI

/// The faces Immich found in the open photo. The photo's page owns them, as Photos' View > Show Face Names belongs to
/// the window: the page loads them, its toolbar and the View menu show and hide them, and its Manage Faces sheet edits
/// them. The photo only draws them (`PhotoFaceBoxes`).
@MainActor @Observable final class PhotoFaces {
    static let shownKey = "showPeopleFaces"

    private(set) var assetID: String?
    private(set) var faces: [PeopleFace] = []
    /// Immich's boxes are for the unedited photo, so an edited one shows none.
    private(set) var coordinatesMatch = false
    /// False on a server without the faces API.
    private(set) var supported = true
    private(set) var busy = false
    var error: String?

    /// The boxes to draw on a photo: none until its own faces have loaded, and none on an edited photo.
    func boxes(for assetID: String) -> [PeopleFace] {
        self.assetID == assetID && coordinatesMatch ? faces : []
    }

    func load(_ assetID: String, session: LibrarySession) async {
        do {
            // TODO: allow edited boxes once the viewer requests edited=true for previews AND originals.
            let asset = try await session.client.asset(assetID)
            let faces = try await session.client.faces(assetID: assetID)
            coordinatesMatch = asset.isEdited == false
            self.faces = faces
            self.assetID = assetID
        }
        catch ImmichError.http(404, _) { supported = false }
        catch {
            guard !error.isCancellation else { return }
            session.handle(error)
            self.error = error.localizedDescription
        }
    }

    func perform(on assetID: String, session: LibrarySession, _ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await action()
                await load(assetID, session: session)
                session.invalidateGrids()
                NotificationCenter.default.post(name: .peopleChanged, object: session.services)
            } catch { session.handle(error); self.error = error.localizedDescription }
        }
    }

    func setFeaturedPhoto(_ personID: String, assetID: String, session: LibrarySession) async throws {
        let previous = try? await session.client.data(for: session.client.personThumbnailRequest(personID))
        _ = try await session.client.editPerson(personID, PersonEdit(featureFaceAssetId: assetID))
        session.pipeline.invalidatePerson(personID)
        NotificationCenter.default.post(name: .personThumbnailChanged, object: session.services, userInfo: ["personID": personID])
        await session.pipeline.refreshPersonThumbnail(personID, replacing: previous)
        NotificationCenter.default.post(name: .personThumbnailChanged, object: session.services, userInfo: ["personID": personID])
    }
}

/// Face Names and Manage Faces in the photo's toolbar, before the search field.
struct PeopleFaceToolbarItems: CustomizableToolbarContent {
    @Binding var showingList: Bool
    /// Dimmed for a video: the items stay, so the toolbar keeps its layout from one photo to the next.
    var isEnabled = true
    @AppStorage(PhotoFaces.shownKey) private var shown = false

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "manageFaces") {
            Button { showingList = true } label: { Label("Manage Faces", systemImage: "person.2") }
                .disabled(!isEnabled)
        }
        ToolbarItem(id: "showFaces") {
            Toggle(isOn: $shown) { Label("Face Names", systemImage: "person.crop.rectangle") }
                .help(shown ? "Hide Face Names" : "Show Face Names")
                .disabled(!isEnabled)
        }
    }
}

/// Immich's face boxes and names, on the photo itself: they're laid out in the photo's own frame, so they zoom and pan
/// with it, and the outlines and names keep their size as it zooms, as Photos' face names do. Passive, so pinching
/// and dragging the photo still work; face actions are in Manage Faces.
struct PhotoFaceBoxes: View {
    let faces: [PeopleFace]
    /// The photo's zoom, which the outlines and names undo.
    let zoom: CGFloat

    var body: some View {
        GeometryReader { geo in
            ForEach(faces) { face in
                let rect = face.rect(in: geo.size)
                let name = face.person?.displayName ?? "Unassigned Face"
                Rectangle()
                    .strokeBorder(.white, lineWidth: 2 / zoom)
                    .frame(width: rect.width, height: rect.height)
                    .overlay(alignment: .bottom) {
                        Text(name)
                            .font(.caption).padding(3).background(.black.opacity(0.7)).foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                            .scaleEffect(1 / zoom, anchor: .top)
                            .alignmentGuide(.bottom) { $0[.top] }
                    }
                    .position(x: rect.midX, y: rect.midY)
                    .accessibilityElement()
                    .accessibilityLabel(Text(name))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Manage Faces and what it opens, presented by the photo's page.
struct PhotoFacesSheets: ViewModifier {
    @Environment(LibrarySession.self) private var session
    let faces: PhotoFaces
    let assetID: String?
    @Binding var showingList: Bool
    @State private var assigning: PeopleFace?
    @State private var removing: PeopleFace?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingList) {
                VStack(spacing: 16) {
                    Text("Faces in This Photo").font(.headline)
                    if let assetID, faces.assetID == assetID, !faces.coordinatesMatch {
                        Text("Face boxes are unavailable for edited photos.").foregroundStyle(.secondary)
                    }
                    let shown = faces.assetID == assetID ? faces.faces : []
                    if shown.isEmpty { Text("No faces found.").foregroundStyle(.secondary) }
                    List(shown) { face in
                        HStack {
                            Text(face.person?.displayName ?? "Unassigned Face")
                            Spacer()
                            Button("Assign…") { showingList = false; assigning = face }
                            if let person = face.person, let assetID {
                                Button("Use as Featured Photo") {
                                    faces.perform(on: assetID, session: session) {
                                        try await faces.setFeaturedPhoto(person.id, assetID: assetID, session: session)
                                    }
                                }
                                Button("Remove…", role: .destructive) { showingList = false; removing = face }
                            }
                        }.disabled(faces.busy)
                    }
                    Button("Done") { showingList = false }.keyboardShortcut(.cancelAction)
                }.padding(20).frame(width: 600, height: 360)
                    .task { if let assetID { await faces.load(assetID, session: session) } }
            }
            .sheet(item: $assigning) { face in
                PeoplePicker(title: "Assign Face", excludedID: face.person?.id, allowsCreation: true) { person in
                    _ = try await session.client.reassignFace(face.id, to: person.id)
                    if let assetID { await faces.load(assetID, session: session) }
                    session.invalidateGrids()
                    NotificationCenter.default.post(name: .peopleChanged, object: session.services)
                }
            }
            .confirmationDialog("Remove Face?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove Face", role: .destructive) {
                    guard let face = removing, let assetID else { return }
                    removing = nil
                    faces.perform(on: assetID, session: session) { try await session.client.removeFace(face.id) }
                }
            } message: { Text("Remove this face from the photo. The photo itself will be kept.") }
            .alert("Faces", isPresented: Binding(get: { faces.error != nil }, set: { if !$0 { faces.error = nil } })) {
                Button("OK") { faces.error = nil }
            } message: { Text(faces.error ?? "") }
    }
}
