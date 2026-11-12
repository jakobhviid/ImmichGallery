import SwiftUI

struct AccountPreferencesView: View {
    let session: AccountServices
    @State private var draft = AccountPreferences()
    @State private var operation = AccountOperation()
    @State private var loaded = false
    /// What the server last returned: saving sends what the draft changes from it.
    @State private var saved: AccountPreferences?
    @State private var pendingSave: Task<Void, Never>?

    var body: some View {
        Form {
            if loaded && !operation.unavailable {
                AccountFeaturePreference(title: "Memories", value: $draft.memories)
                AccountFeaturePreference(title: "Ratings", value: $draft.ratings)
                AccountFeaturePreference(title: "Folders", value: $draft.folders)
                AccountFeaturePreference(title: "Tags", value: $draft.tags)
                AccountFeaturePreference(title: "People", value: $draft.people)
                AccountFeaturePreference(title: "Shared Links", value: $draft.sharedLinks)
                if draft.memories?.duration != nil {
                    Stepper("Memory Duration: \(draft.memories?.duration ?? 5) seconds", value: Binding(
                        get: { draft.memories?.duration ?? 5 }, set: { draft.memories?.duration = $0 }), in: 1...60)
                }
                if draft.people != nil {
                    Stepper("Minimum Faces: \(draft.people?.minimumFaces ?? 1)", value: Binding(
                        get: { draft.people?.minimumFaces ?? 1 }, set: { draft.people?.minimumFaces = $0 }), in: 1...1000)
                    Picker("People Update Strategy", selection: Binding(
                        get: { draft.people?.updateStrategy ?? "self" }, set: { draft.people?.updateStrategy = $0 })) {
                        Text("Only This Person").tag("self")
                        Text("Everyone").tag("everyone")
                    }
                }
                if draft.albums != nil {
                    Picker("Default Album Order", selection: Binding(
                        get: { draft.albums?.defaultAssetOrder ?? "desc" }, set: { draft.albums?.defaultAssetOrder = $0 })) {
                        Text("Newest First").tag("desc")
                        Text("Oldest First").tag("asc")
                    }
                }
                if draft.download != nil {
                    Section("Downloads") {
                        TextField("Archive Size (GiB)", value: Binding(
                            get: { Double(draft.download?.archiveSize ?? 4_294_967_296) / 1_073_741_824 },
                            set: { value in
                                // Leaving the field commits the rounded number it shows; that isn't a change.
                                let current = Double(draft.download?.archiveSize ?? 4_294_967_296) / 1_073_741_824
                                guard value.isFinite, abs(value - current) > 0.001 else { return }
                                draft.download?.archiveSize = Int64(min(max(value, 0.01), 8192) * 1_073_741_824)
                            }), format: .number)
                        if draft.download?.includeEmbeddedVideos != nil {
                            Toggle("Include Embedded Videos", isOn: Binding(get: { draft.download?.includeEmbeddedVideos ?? false }, set: { draft.download?.includeEmbeddedVideos = $0 }))
                        }
                    }
                }
                if draft.emailNotifications != nil {
                    Section("Email Notifications") {
                        Toggle("Enable Email Notifications", isOn: Binding(get: { draft.emailNotifications?.enabled ?? false }, set: { draft.emailNotifications?.enabled = $0 }))
                        Toggle("Album Invitations", isOn: Binding(get: { draft.emailNotifications?.albumInvite ?? false }, set: { draft.emailNotifications?.albumInvite = $0 }))
                        Toggle("Album Updates", isOn: Binding(get: { draft.emailNotifications?.albumUpdate ?? false }, set: { draft.emailNotifications?.albumUpdate = $0 }))
                    }
                }
                if draft.cast?.gCastEnabled != nil {
                    Toggle("Google Cast", isOn: Binding(get: { draft.cast?.gCastEnabled ?? false }, set: { draft.cast?.gCastEnabled = $0 }))
                }
                if draft.recentlyAdded?.sidebarWeb != nil {
                    Toggle("Recently Added in Web Sidebar", isOn: Binding(get: { draft.recentlyAdded?.sidebarWeb ?? false }, set: { draft.recentlyAdded?.sidebarWeb = $0 }))
                }
                if draft.purchase?.showSupportBadge != nil {
                    Toggle("Show Support Badge", isOn: Binding(get: { draft.purchase?.showSupportBadge ?? false }, set: { draft.purchase?.showSupportBadge = $0 }))
                }
                Text("Changes are saved on your Immich server as you make them. Web sidebar options affect the web client.").font(.caption).foregroundStyle(.secondary)
            }
            AccountOperationStatus(operation: operation)
        }
        .formStyle(.grouped).disabled(operation.busy)
        // As in System Settings, a change applies as it is made: a switch or stepper after a brief pause, the
        // archive size once the field is left, and anything still pending when Settings closes.
        .onChange(of: draft) {
            if loaded { scheduleSave() }
        }
        .onDisappear {
            pendingSave?.cancel()
            if loaded { save(draft) }
        }
        // A failure from anywhere in this long form, or from a save made as Settings closed, is told where it is
        // seen rather than at the bottom of the form.
        .alert("Couldn't Save Preferences", isPresented: Binding(
            get: { loaded && session.preferencesSaveError != nil }, set: { if !$0 { session.preferencesSaveError = nil } })) {
            Button("OK") { session.preferencesSaveError = nil }
        } message: {
            Text(session.preferencesSaveError ?? "")
        }
        .task {
            operation.run(probe: true) {
                // Waits for a save made as Settings last closed, so this reads what it stored.
                let preferences = try await session.queuePreferences { try await session.client.accountPreferences() }
                saved = preferences
                draft = preferences
                session.setPreferences(preferences)
                loaded = true
            }
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            save(draft)
        }
    }

    /// Saves queue behind earlier ones and send only what `value` changes from what the server last returned, so
    /// switching something back while a save is in flight is saved too. A failed save puts back the server's
    /// values and says why.
    private func save(_ value: AccountPreferences) {
        let session = session
        Task {
            do {
                let stored = try await session.queuePreferences { () async throws -> AccountPreferences? in
                    guard let base = saved else { return nil }
                    let changes = value.changes(from: base)
                    guard changes != AccountPreferences() else { return nil }
                    return try await session.client.updateAccountPreferences(changes)
                }
                guard let stored else { return }
                session.setPreferences(stored)
                saved = stored
                // Later edits made while this was saving stay in the draft for their own save.
                if draft == value { draft = stored }
            } catch {
                session.handle(error)
                session.preferencesSaveError = error.localizedDescription
                if draft == value, let saved { draft = saved }
            }
        }
    }
}

private struct AccountFeaturePreference: View {
    let title: String
    @Binding var value: AccountPreferences.Feature?
    var body: some View {
        if value != nil {
            Section(title) {
                if value?.enabled != nil {
                    Toggle("Enabled", isOn: Binding(get: { value?.enabled ?? false }, set: { value?.enabled = $0 }))
                }
                if value?.sidebarWeb != nil {
                    Toggle("Show in Web Sidebar", isOn: Binding(get: { value?.sidebarWeb ?? false }, set: { value?.sidebarWeb = $0 }))
                }
            }
        }
    }
}
