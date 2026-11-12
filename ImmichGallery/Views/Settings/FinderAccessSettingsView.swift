import SwiftUI

/// Settings ▸ Finder (issue #23): each saved account's Immich library as an optional Finder location.
struct FinderAccessSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var model = FinderAccessModel.shared
    @State private var confirmingOff: AccountVault.Entry?

    var body: some View {
        Form {
            Section {
                Text("Show your Immich library in the Finder sidebar, with folders for Albums, Library (by year and month) and Favorites. Photos download only when you open them.")
                    .foregroundStyle(.secondary)
                if !model.available {
                    Label("Finder access needs a copy of Immich Gallery signed with its App Group.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
            if app.entries.isEmpty {
                Section { Text("Sign in to show an account in Finder.").foregroundStyle(.secondary) }
            }
            ForEach(app.entries) { entry in
                FinderAccessAccountSection(entry: entry, model: model, confirmingOff: $confirmingOff)
            }
            let orphans = model.locations.filter { location in
                !app.entries.contains { FinderAccess.domainIdentifier(apiURL: $0.account.apiURL, userID: $0.userID) == location.id }
            }
            if !orphans.isEmpty {
                Section {
                    ForEach(orphans) { location in
                        HStack {
                            Text(location.displayName)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                Task { await model.disable(location.id, client: nil) }
                            }.disabled(model.busy.contains(location.id))
                        }
                    }
                } header: {
                    Text("Locations Without a Saved Account")
                } footer: {
                    Text("Removing a location deletes its downloaded files from this Mac. Its key can then only be deleted in Account Settings ▸ API Keys on the server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            }
            if let notice = model.notice {
                Section { Text(notice).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .task { await model.reload() }
        .confirmationDialog("Remove this account from Finder?", isPresented: Binding(get: { confirmingOff != nil }, set: { if !$0 { confirmingOff = nil } }),
                            presenting: confirmingOff) { entry in
            Button("Remove from Finder", role: .destructive) {
                Task {
                    let id = FinderAccess.domainIdentifier(apiURL: entry.account.apiURL, userID: entry.userID)
                    let client = ImmichClient(serverURL: entry.account.serverURL, apiURL: entry.account.apiURL, credential: entry.account.credential)
                    await model.disable(id, client: client)
                }
            }
        } message: { _ in
            Text("The location and the photos downloaded from it are removed from this Mac. Nothing is deleted from Immich.")
        }
    }
}

private struct FinderAccessAccountSection: View {
    let entry: AccountVault.Entry
    let model: FinderAccessModel
    @Binding var confirmingOff: AccountVault.Entry?

    private var domainID: String { FinderAccess.domainIdentifier(apiURL: entry.account.apiURL, userID: entry.userID) }

    var body: some View {
        let location = model.location(for: entry)
        let configuration = location?.configuration
        let busy = model.busy.contains(domainID)
        Section {
            HStack {
                Toggle(isOn: Binding(get: { location != nil }, set: { on in
                    if on { Task { await model.enable(entry) } } else { confirmingOff = entry }
                })) {
                    VStack(alignment: .leading) {
                        Text("Show in Finder")
                        Text(entry.name + " · " + (entry.account.serverURL.host() ?? entry.account.serverURL.absoluteString))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(busy || !model.available)
                if busy { ProgressView().controlSize(.small) }
            }
            if let configuration {
                Toggle(isOn: Binding(get: { configuration.allowChanges }, set: { model.setOptions(domainID, allowChanges: $0) })) {
                    VStack(alignment: .leading) {
                        Text("Allow Changes")
                        Text("Drop photos and videos into Albums, Library or Favorites to upload them. A new folder in Albums makes an album, renaming a folder renames your album, and dragging a photo onto an album or Favorites adds it there.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(busy)
                Toggle(isOn: Binding(get: { configuration.allowRemoving }, set: { model.setOptions(domainID, allowRemoving: $0) })) {
                    VStack(alignment: .leading) {
                        Text("Allow Removing")
                        Text("Deleting a photo in an album folder removes it from the album; in Favorites, unfavorites it; in Library, moves it to Immich's Trash. Deleting an album folder deletes the album, and its photos stay in your library. Dragging a photo between albums moves it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(busy || !configuration.allowChanges)
                HStack {
                    Button("Show in Finder") { Task { await model.reveal(domainID) } }
                    Button("Refresh") { model.refresh(domainID) }
                        .help("Check every folder in Finder against the server again")
                    Spacer()
                    if configuration.keyID != nil {
                        Button("Reconnect") { Task { await model.reconnect(entry) } }
                            .help("Make a new Finder key, for example after deleting it on the server")
                    }
                }.disabled(busy)
            }
        } footer: {
            if location == nil {
                if case .apiKey = entry.account.credential {
                    Text("Finder uses this account's API key. It never opens the Locked Folder.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Turning this on creates an API key named “\(FinderAccessModel.keyName)” on your server, used only by Finder. It can't open the Locked Folder. Turning it off deletes the key, the location and its downloaded files.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
