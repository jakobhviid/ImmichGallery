import SwiftUI

struct AlbumSharingSheet: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State var album: AlbumDetails
    @State private var users: [User] = []
    @State private var selectedUser = ""
    @State private var role = "viewer"
    @State private var busy = false
    @State private var error: String?
    @State private var unavailable = false

    private var owner: Bool { album.isOwner(session.user?.id) }
    private var candidates: [User] {
        users.filter { user in user.id != album.albumOwner?.id && album.albumUsers?.contains(where: { $0.id == user.id }) != true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(owner ? "Share Album" : "Album Members").font(.title2.bold())
            if let owner = album.albumOwner {
                HStack(spacing: 8) {
                    UserAvatar(user: owner, size: 24)
                    Text("Owner: \(owner.name)").foregroundStyle(.secondary)
                }
            }
            List(album.albumUsers ?? []) { member in
                HStack {
                    UserAvatar(user: member.user, size: 28)
                    VStack(alignment: .leading) { Text(member.user.name); Text(member.user.email).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if owner && member.id != album.albumOwner?.id {
                        Picker("Role", selection: Binding(get: { member.role }, set: { role in
                            mutate { try await session.client.updateAlbumUser(album.id, userID: member.id, role: role) }
                        })) {
                            Text("Viewer").tag("viewer")
                            Text("Editor").tag("editor")
                        }.labelsHidden().frame(width: 105)
                        Button("Remove", role: .destructive) {
                            mutate { try await session.client.removeAlbumUser(album.id, userID: member.id) }
                        }
                    } else { Text(member.role.capitalized).foregroundStyle(.secondary) }
                }
            }.frame(height: 220)
            if owner && !unavailable {
                Picker("User", selection: $selectedUser) {
                    Text("Choose a user").tag("")
                    ForEach(candidates) { Text("\($0.name) (\($0.email))").tag($0.id) }
                }
                HStack {
                    Picker("Permission", selection: $role) { Text("Viewer").tag("viewer"); Text("Editor").tag("editor") }
                    Button("Add User") {
                        mutate {
                            try await session.client.addAlbumUser(album.id, userID: selectedUser, role: role)
                            selectedUser = ""
                        }
                    }.disabled(selectedUser.isEmpty)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { if busy { ProgressView().controlSize(.small) }; Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 540).disabled(busy)
        .task {
            guard owner else { return }
            do { users = try await session.client.albumUsers() }
            catch {
                if case ImmichError.http(404, _) = error { unavailable = true }
                session.handle(error); self.error = error.localizedDescription
            }
        }
    }

    private func mutate(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await action()
                album = try await session.client.albumDetails(album.id)
                await session.reloadAlbums()
                error = nil
            } catch { session.handle(error); self.error = error.localizedDescription }
        }
    }
}
