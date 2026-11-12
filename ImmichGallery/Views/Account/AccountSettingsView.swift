import SwiftUI
import UniformTypeIdentifiers
import ImageIO

struct AccountSettingsView: View {
    let session: AccountServices
    @State private var operation = AccountOperation()
    @State private var name = ""
    @State private var importing = false

    var body: some View {
        Form {
            Section("Profile") {
                HStack {
                    AccountAvatar(services: session, size: 64)
                    VStack(alignment: .leading) {
                        Text(session.user?.name ?? "").font(.headline)
                        Text(session.user?.email ?? "").textSelection(.enabled)
                    }
                }
                TextField("Name", text: $name)
                Button("Save Name") {
                    operation.run {
                        _ = try await session.client.updateAccountName(name.trimmingCharacters(in: .whitespacesAndNewlines))
                        try await session.refreshAccountUser()
                        operation.message = String(localized: "Name saved.")
                    }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines) == session.user?.name)
                HStack {
                    Button("Choose Profile Picture…") { importing = true }
                    Button("Remove Picture", role: .destructive) {
                        operation.run {
                            try await session.client.removeAccountPicture()
                            try await session.refreshAccountUser()
                        }
                    }.disabled(session.user?.profileImagePath?.isEmpty != false)
                }
            }
            Section("Storage") {
                if let used = session.user?.quotaUsageInBytes {
                    LabeledContent("Used", value: used.formatted(.byteCount(style: .file)))
                    if let quota = session.user?.quotaSizeInBytes, quota > 0 {
                        ProgressView(value: Double(min(max(used, 0), quota)), total: Double(quota))
                        LabeledContent("Quota", value: quota.formatted(.byteCount(style: .file)))
                    } else { LabeledContent("Quota", value: "Unlimited") }
                } else { Text("Storage usage is unavailable.").foregroundStyle(.secondary) }
            }
            Section("Server") {
                LabeledContent("Address") { Text(session.client.serverURL.absoluteString).textSelection(.enabled) }
                LabeledContent("Version", value: session.version?.description ?? "—")
                LabeledContent("Signed in with") {
                    switch session.client.credential {
                    case .apiKey: Text("API Key")
                    default: Text("Password")
                    }
                }
            }
            AccountOperationStatus(operation: operation)
        }
        .formStyle(.grouped)
        .disabled(operation.busy)
        .task { name = session.user?.name ?? "" }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            operation.run {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let jpeg = try await Task.detached(priority: .userInitiated) {
                    try accountProfileJPEG(url: url)
                }.value
                try await session.client.uploadAccountPicture(jpeg)
                try await session.refreshAccountUser()
            }
        }
    }
}

struct AccountOperationStatus: View {
    let operation: AccountOperation
    var body: some View {
        if operation.busy { ProgressView().controlSize(.small) }
        if let error = operation.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        if let message = operation.message { Text(message).foregroundStyle(.secondary) }
    }
}

struct AccountSettingsTabs: View {
    /// Stored so the account menu can open Settings on the Account tab.
    static let selectionKey = "settingsTab"
    @Environment(AppModel.self) private var app
    @AppStorage(selectionKey) private var tab = "general"
    var body: some View {
        TabView(selection: $tab) {
            SettingsView().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            if let session = app.services {
                AccountSettingsView(session: session).id("profile-\(ObjectIdentifier(session))")
                    .tabItem { Label("Account", systemImage: "person.crop.circle") }.tag("account")
                AccountSecurityView(session: session).id("security-\(ObjectIdentifier(session))")
                    .tabItem { Label("Security", systemImage: "lock") }.tag("security")
                AccountPreferencesView(session: session).id("preferences-\(ObjectIdentifier(session))")
                    .tabItem { Label("Preferences", systemImage: "switch.2") }.tag("preferences")
            }
            AccountSwitcherView().tabItem { Label("Accounts", systemImage: "person.2") }.tag("accounts")
            FinderAccessSettingsView().tabItem { Label("Finder", systemImage: "folder") }.tag("finder") // Finder access
            CrosslinkSettingsView().tabItem { Label("Other Apps", systemImage: "link") }.tag("crosslink") // Crosslink
            UpdateSettingsView().tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }.tag("updates")
        }
        .frame(width: 640, height: tab == "general" ? 440 : tab == "updates" ? 320 : tab == "crosslink" ? 420 : 650)
        // The window changes height with the tab, as the system's settings windows do.
        .animation(.smooth(duration: 0.25), value: tab)
        .onChange(of: app.services == nil, initial: true) { _, signedOut in
            if signedOut, !["general", "accounts", "updates", "crosslink", "finder"].contains(tab) { tab = "general" }
        }
    }
}

struct AccountSwitcherView: View {
    @Environment(AppModel.self) private var app
    @State private var operation = AccountOperation()
    @State private var adding = false
    var body: some View {
        Form {
            Section("Saved Accounts") {
                ForEach(app.entries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.name + " · " + entry.email)
                            Text(entry.account.serverURL.absoluteString).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if app.currentAccountID == entry.id {
                            Image(systemName: "checkmark").accessibilityLabel("Current account")
                        } else {
                            Button("Switch") { operation.run { try await app.switchAccount(entry) } }
                        }
                        Button("Remove", role: .destructive) {
                            operation.run { try app.removeAccount(entry) }
                        }.help("Remove saved credentials from this Mac")
                    }
                }
                Button("Add Account…") { adding = true }
            }
            AccountOperationStatus(operation: operation)
        }
        .formStyle(.grouped).disabled(operation.busy || app.switching)
        .sheet(isPresented: $adding) {
            VStack {
                LoginView()
                Button("Cancel") { adding = false }.keyboardShortcut(.cancelAction).padding()
            }.frame(width: 500, height: 600).environment(app)
                .onChange(of: app.services.map(ObjectIdentifier.init)) { _, _ in adding = false }
        }
    }
}

nonisolated func accountProfileJPEG(url: URL) throws -> Data {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 50 * 1024 * 1024,
          let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512
          ] as CFDictionary) else {
        throw ImmichError.http(400, String(localized: "Choose a supported image smaller than 50 MB."))
    }
    let side = min(image.width, image.height)
    guard let square = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)) else {
        throw ImmichError.http(400, String(localized: "Could not crop the profile picture."))
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw ImmichError.http(400, String(localized: "Could not encode the profile picture."))
    }
    CGImageDestinationAddImage(destination, square, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ImmichError.http(400, String(localized: "Could not encode the profile picture.")) }
    return data as Data
}
