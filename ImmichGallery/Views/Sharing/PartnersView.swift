import SwiftUI

struct PartnersView: View {
    @Environment(LibrarySession.self) private var session
    @State private var users: [User] = []
    @State private var picking = false
    @State private var removing: SharingPartner?

    var body: some View {
        let sharing = session.sharing
        List {
            Section {
                Text("Partner sharing gives another user access to your library and its metadata, including locations. Sharing is one-way.").foregroundStyle(.secondary)
            }
            Section("Shared with Me") {
                if sharing.receivedPartners.isEmpty { Text("No partners are sharing with you.").foregroundStyle(.secondary) }
                ForEach(sharing.receivedPartners) { partner in
                    HStack {
                        NavigationLink(partner.name, value: GridRoute(source: .partner(partner.id), title: partner.name))
                        Toggle("Show in timeline", isOn: Binding(get: {
                            session.sharing.receivedPartners.first { $0.id == partner.id }?.inTimeline ?? false
                        }, set: { value in
                            Task {
                                await sharing.perform { try await session.client.updateSharingPartner(partner.id, inTimeline: value) }
                                session.invalidateGrids()
                            }
                        })).disabled(sharing.busy)
                    }
                }
            }
            Section("Sharing My Library With") {
                if sharing.outgoingPartners.isEmpty { Text("You aren't sharing your library with anyone.").foregroundStyle(.secondary) }
                ForEach(sharing.outgoingPartners) { partner in
                    HStack {
                        VStack(alignment: .leading) { Text(partner.name); Text(partner.email).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Remove…", role: .destructive) { removing = partner }.disabled(sharing.busy)
                    }
                }
            }
        }
        .navigationTitle("Partner Sharing")
        .pageToolbar("partners") {
            ToolbarItem(id: "addPartner") {
                Button("Add Partner…", systemImage: "person.badge.plus") {
                    Task {
                        do { users = try await session.client.sharingUsers(); picking = true }
                        catch { sharing.error = error.localizedDescription }
                    }
                }.disabled(sharing.busy || !sharing.partnersAvailable)
            }
        }
        .sheet(isPresented: $picking) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Share Your Library").font(.title2.bold())
                Text("The selected user will be able to view and download your photos and their metadata.")
                List(users.filter { user in user.id != session.user?.id && !sharing.outgoingPartners.contains { $0.id == user.id } }) { user in
                    Button {
                        Task {
                            if await sharing.perform({ try await session.client.addSharingPartner(user.id) }) { picking = false }
                        }
                    } label: { VStack(alignment: .leading) { Text(user.name); Text(user.email).font(.caption) } }
                    .disabled(sharing.busy)
                }
                Button("Cancel") { picking = false }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width: 440, height: 400).sharingError()
        }
        .confirmationDialog("Stop sharing your library?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Partner", role: .destructive) {
                if let partner = removing { Task { await sharing.perform { try await session.client.removeSharingPartner(partner.id) }; session.invalidateGrids() } }
            }
        }
        .sharingError()
        .task { await sharing.reload() }
    }
}
