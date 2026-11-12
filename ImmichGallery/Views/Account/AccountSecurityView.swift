import SwiftUI

struct AccountSecurityView: View {
    let session: AccountServices
    @State private var operation = AccountOperation()
    @State private var keys: [AccountAPIKey] = []
    @State private var devices: [AccountDevice] = []
    @State private var keysUnavailable = false
    @State private var devicesUnavailable = false
    @State private var editingKey: AccountAPIKey?
    @State private var showingKey = false
    @State private var password = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var invalidateSessions = false
    @State private var pendingAction: (@MainActor () async throws -> Void)?
    @State private var confirming = false
    @AppStorage(LockedFolderTouchID.enabledKey) private var touchIDEnabled = true

    var body: some View {
        Form {
            if session.features.passwordLogin {
                Section("Change Password") {
                    SecureField("Current Password", text: $password)
                    SecureField("New Password", text: $newPassword)
                    SecureField("Confirm New Password", text: $confirmPassword)
                    Toggle("Log out of other devices", isOn: $invalidateSessions)
                    Button("Change Password") {
                        operation.run {
                            try await session.client.changeAccountPassword(current: password, new: newPassword, invalidateSessions: invalidateSessions)
                            password = ""; newPassword = ""; confirmPassword = ""
                            if let refreshed = try? await session.client.accountDevices() { devices = refreshed }
                            try? await session.refreshAccountUser()
                            operation.message = String(localized: "Password changed.")
                        }
                    }.disabled(password.isEmpty || newPassword.count < 8 || newPassword != confirmPassword)
                    Text("Use at least 8 characters.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if session.client.exploreSupportsLockedFolder {
                Section("Locked Folder") {
                    Toggle("Unlock with Touch ID", isOn: $touchIDEnabled)
                        .disabled(!LockedFolderTouchID.isAvailable && !touchIDEnabled)
                        .onChange(of: touchIDEnabled) { _, enabled in
                            // Either way, kept PINs are forgotten: turned on again, the PIN is asked once more.
                            do { try LockedFolderTouchID.forgetAll() }
                            catch {
                                operation.error = error.localizedDescription
                                // Off until the kept PINs can be forgotten, so none is used.
                                if enabled { touchIDEnabled = false }
                            }
                        }
                    Text(LockedFolderTouchID.isAvailable
                         ? "After you unlock the Locked Folder with your PIN once, Touch ID unlocks it. The PIN is kept in your login keychain on this Mac and given back by the app only after Touch ID. It's forgotten when you turn this off, sign out, or add or remove a fingerprint."
                         : "This Mac doesn't have Touch ID set up.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !keysUnavailable {
                Section("API Keys") {
                    ForEach(keys) { key in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(key.name)
                                Text(key.permissions.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("Rename") { editingKey = key; showingKey = true }
                            Button("Delete", role: .destructive) {
                                confirm {
                                    try await session.client.deleteAccountKey(key.id)
                                    keys = try await session.client.accountKeys()
                                }
                            }
                        }
                    }
                    Button("Create API Key…") { editingKey = nil; showingKey = true }
                }
            }
            if !devicesUnavailable {
                Section("Sessions and Devices") {
                    ForEach(devices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                let title = [device.deviceType, device.deviceOS, device.appVersion ?? ""].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " · ")
                                Text(title.isEmpty ? "Unknown device" : title)
                                Text("Last active: \(accountDate(device.updatedAt))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.current { Text("This device").foregroundStyle(.secondary) }
                            else {
                                Button("Log Out", role: .destructive) {
                                    confirm {
                                        try await session.client.deleteAccountDevice(device.id)
                                        devices = try await session.client.accountDevices()
                                    }
                                }
                            }
                        }
                    }
                    if case .accessToken = session.client.credential {
                        Button("Log Out All Other Devices…", role: .destructive) {
                            confirm {
                                try await session.client.deleteOtherAccountDevices()
                                devices = try await session.client.accountDevices()
                            }
                        }
                    }
                }
            }
            AccountOperationStatus(operation: operation)
        }
        .formStyle(.grouped).disabled(operation.busy)
        .task {
            do { keys = try await session.client.accountKeys() }
            catch ImmichError.http(404, _) { keysUnavailable = true }
            catch { operation.error = error.localizedDescription }
            do { devices = try await session.client.accountDevices() }
            catch ImmichError.http(404, _) { devicesUnavailable = true }
            catch { operation.error = error.localizedDescription }
        }
        .sheet(isPresented: $showingKey) {
            AccountKeyEditor(session: session, key: editingKey) {
                keys = try await session.client.accountKeys()
            }
        }
        .confirmationDialog("This will revoke access. Continue?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Revoke Access", role: .destructive) {
                if let action = pendingAction { operation.run(action) }
                pendingAction = nil
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        }
    }

    private func confirm(_ action: @escaping @MainActor () async throws -> Void) {
        pendingAction = action
        confirming = true
    }
}

private struct AccountKeyEditor: View {
    let session: AccountServices
    let key: AccountAPIKey?
    let onSave: @MainActor () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var permissions: Set<String> = ["asset.read"]
    @State private var search = ""
    @State private var secret: String?
    @State private var operation = AccountOperation()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(key == nil ? "Create API Key" : "Rename API Key").font(.title2)
            if let secret {
                Text("Copy this key now. It cannot be shown again.")
                Text(secret).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Button("Copy Key") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(secret, forType: .string) }
                Button("Done") { self.secret = nil; dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                if key == nil {
                    Text("Choose only the permissions this key needs.").foregroundStyle(.secondary)
                    TextField("Filter permissions", text: $search).textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(AccountPermissions.all.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { permission in
                                Toggle(permission, isOn: Binding(get: { permissions.contains(permission) }, set: {
                                    if $0 { permissions.insert(permission) } else { permissions.remove(permission) }
                                }))
                            }
                        }
                    }
                }
                AccountOperationStatus(operation: operation)
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(key == nil ? "Create" : "Save") {
                        operation.run {
                            if let key {
                                try await session.client.renameAccountKey(id: key.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                                try await onSave()
                                dismiss()
                            } else {
                                let created = try await session.client.createAccountKey(name: name.trimmingCharacters(in: .whitespacesAndNewlines), permissions: permissions.sorted())
                                secret = created.secret
                                try await onSave()
                            }
                        }
                    }.keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (key != nil && name.trimmingCharacters(in: .whitespacesAndNewlines) == key?.name) || permissions.isEmpty || operation.busy)
                }
            }
        }
        .padding(24).frame(width: 480, height: key == nil ? 520 : 220)
        .interactiveDismissDisabled(secret != nil || operation.busy)
        .onAppear { name = key?.name ?? "" }
        .onDisappear { secret = nil }
    }
}
