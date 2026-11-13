import SwiftUI

extension Notification.Name {
    static let peopleChanged = Notification.Name("peopleChanged")
    static let personThumbnailChanged = Notification.Name("personThumbnailChanged")
}

struct PersonDetailView: View {
    @Environment(LibrarySession.self) private var session
    @State var person: Person
    @State private var count: Int?
    @State private var editing = false
    @State private var merging = false
    @State private var mergeCandidate: Person?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        // As in Immich, the person's header is where they are recognised and named: the face, the name and birthday
        // edited in place, and how many photos. It scrolls away with the photos, and the toolbar shows the name
        // once it has.
        AssetGridContainer(source: .person(person.id), title: Text(verbatim: person.displayName), headerScrolls: true) {
            header
        }
        .toolbar(id: "person") {
            if grid.viewerID == nil {
                ToolbarItem(id: "personMenu") { personMenu }
            }
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .peopleChanged, object: session.services)) { _ in
            Task { await reload(); await session.gridModel(for: .person(person.id)).reload() }
        }
        .sheet(isPresented: $editing) {
            PersonEditSheet(person: person) { person = $0; changed() }
        }
        .sheet(isPresented: $merging) {
            PeoplePicker(title: "Merge into \(person.displayName)", excludedID: person.id) { mergeCandidate = $0 }
        }
        .confirmationDialog("Merge People?", isPresented: Binding(get: { mergeCandidate != nil }, set: { if !$0 { mergeCandidate = nil } }), titleVisibility: .visible) {
            Button("Merge", role: .destructive) {
                guard let candidate = mergeCandidate else { return }
                mergeCandidate = nil
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        try await session.client.mergePeople(into: person.id, ids: [candidate.id])
                        changed()
                    } catch { report(error) }
                }
            }
        } message: {
            Text("All faces of \(mergeCandidate?.displayName ?? "this person") will move to \(person.displayName). This cannot be undone.")
        }
        .alert("People", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var grid: AssetGridModel { session.gridModel(for: .person(person.id)) }

    private var header: some View {
        HStack(spacing: 20) {
            PersonCell(person: person, showsName: false).frame(width: 96)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    InlineEditableText(text: person.name, placeholder: "Add a Name", font: .largeTitle.bold(), enabled: !busy) { name in
                        update(PersonEdit(name: name))
                    }
                    if person.isFavorite == true {
                        Image(systemName: "heart.fill").foregroundStyle(.red).accessibilityLabel("Favorite")
                    }
                }
                HStack(spacing: 6) {
                    if let count { Text("\(count) photos and videos") }
                    if let birthday = person.birthday {
                        let age = Calendar.current.dateComponents([.year], from: birthday, to: .now).year ?? 0
                        if count != nil { Text(verbatim: "·") }
                        Text("\(birthday.formatted(date: .abbreviated, time: .omitted)) · Age \(age)")
                            .onTapGesture { editing = true }
                            .help("Edit Name and Birthday…")
                    } else {
                        if count != nil { Text(verbatim: "·") }
                        Button("Add Birthday") { editing = true }.buttonStyle(.link)
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }

    /// The person's actions, in a toolbar menu of their own beside the photos' controls: what Immich puts in its
    /// person page's menu.
    private var personMenu: some View {
        Menu {
            Button("Edit Name and Birthday…") { editing = true }
            Button("Use as Face Photo") { useAsFacePhoto() }
                .disabled(grid.selection.count != 1)
            Divider()
            Button(person.isFavorite == true ? "Unfavorite Person" : "Favorite Person") {
                update(PersonEdit(isFavorite: person.isFavorite != true))
            }
            Button(person.isHidden ? "Unhide Person" : "Hide Person") {
                update(PersonEdit(isHidden: !person.isHidden))
            }
            Divider()
            Button("Merge with Another Person…") { merging = true }
        } label: { Label("Person", systemImage: "person.crop.circle") }
        .menuIndicator(.hidden)
        .help("Person")
        .disabled(busy)
    }

    /// The selected photo becomes the person's face, as the viewer's face tools do it.
    private func useAsFacePhoto() {
        guard grid.selection.count == 1, let assetID = grid.selection.first else { return }
        let personID = person.id
        busy = true
        Task {
            defer { busy = false }
            do {
                let previous = try? await session.client.data(for: session.client.personThumbnailRequest(personID))
                person = try await session.client.editPerson(personID, PersonEdit(featureFaceAssetId: assetID))
                session.pipeline.invalidatePerson(personID)
                NotificationCenter.default.post(name: .personThumbnailChanged, object: session.services, userInfo: ["personID": personID])
                await session.pipeline.refreshPersonThumbnail(personID, replacing: previous)
                NotificationCenter.default.post(name: .personThumbnailChanged, object: session.services, userInfo: ["personID": personID])
            } catch { report(error) }
        }
    }

    private func update(_ edit: PersonEdit) {
        busy = true
        Task {
            defer { busy = false }
            do { person = try await session.client.editPerson(person.id, edit); changed() }
            catch { report(error) }
        }
    }
    private func reload() async {
        do {
            person = try await session.client.person(person.id)
            count = try await session.client.personStatistics(person.id).assets
        } catch { report(error) }
    }
    private func report(_ error: Error) { session.handle(error); self.error = error.localizedDescription }
    private func changed() {
        session.invalidateGrids()
        NotificationCenter.default.post(name: .peopleChanged, object: session.services)
    }
}

struct PersonEditSheet: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let person: Person
    let saved: (Person) -> Void
    @State private var name = ""
    @State private var birthday = Date.now
    @State private var hasBirthday = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit Person").font(.headline)
            TextField("Name", text: $name)
            Toggle("Birthday", isOn: $hasBirthday.animation(.smooth(duration: 0.25)))
            if hasBirthday { DatePicker("Date of Birth", selection: $birthday, in: ...Date.now, displayedComponents: .date) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            let edit = PersonEdit(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  birthDate: hasBirthday ? Person.birthdayFormatter.string(from: birthday) : nil,
                                                  clearBirthDate: !hasBirthday)
                            saved(try await session.client.editPerson(person.id, edit))
                            dismiss()
                        } catch { session.handle(error); self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction)
            }.disabled(busy)
        }
        .padding(24).frame(width: 380)
        .onAppear { name = person.name; birthday = person.birthday ?? .now; hasBirthday = person.birthday != nil }
    }
}

/// The people in a photo, in the Info panel: their round faces and names. A person shows their page with the photo
/// selected in it, as a face below the photo does.
struct InspectorPeopleList: View {
    @Environment(LibrarySession.self) private var session
    let assetID: String
    let people: [AssetPerson]
    var source: GridSource?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if people.isEmpty { Text("No people").foregroundStyle(.secondary) }
            ForEach(people) { person in
                Button {
                    session.showFace(of: person.id, in: assetID, shownFrom: source)
                } label: {
                    HStack(spacing: 8) {
                        InspectorPersonFace(personID: person.id)
                        Text(person.name.isEmpty ? "Unnamed Person" : person.name)
                            .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A person's face, small and round, as people show beside their names elsewhere.
private struct InspectorPersonFace: View {
    @Environment(LibrarySession.self) private var session
    let personID: String
    @State private var image: CGImage?

    var body: some View {
        Circle().fill(.quaternary)
            .overlay { if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() } }
            .clipShape(Circle())
            .frame(width: 26, height: 26)
            .task(id: personID) { image = await session.pipeline.personThumbnail(personID) }
    }
}
