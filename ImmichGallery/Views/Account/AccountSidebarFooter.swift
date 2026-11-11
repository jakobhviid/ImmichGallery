import SwiftUI

/// The signed-in account and its notifications, at the bottom of the sidebar. They are about
/// who is signed in to which server, not about the page shown, so they stay out of the toolbar.
struct AccountSidebarFooter<Controls: View>: View {
    let services: AccountServices
    @ViewBuilder let controls: Controls

    var body: some View {
        HStack(spacing: 6) {
            AccountMenu(services: services)
            AccountNotificationBell(session: services)
            controls
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

struct AccountMenu: View {
    let services: AccountServices
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AccountSettingsTabs.selectionKey) private var settingsTab = "general"
    @State private var error: String?
    @State private var adding = false

    var body: some View {
        Menu {
            if let user = services.user {
                Text(user.email)
                if let storage = storageText(user) { Text(storage) }
                Divider()
            }
            Button("Account Settings…") { settingsTab = "account"; openSettings() }
            if services.user?.isAdmin == true {
                Button("Administration…") { openWindow(id: "admin") } // Admin
            }
            if app.entries.count > 1 {
                Section("Switch Account") {
                    // A Toggle gives the native menu checkmark for the current account.
                    ForEach(app.entries) { entry in
                        Toggle("\(entry.email) · \(entry.account.serverURL.host() ?? "")", isOn: Binding(
                            get: { app.currentAccountID == entry.id },
                            set: { on in
                                guard on else { return }
                                Task { do { try await app.switchAccount(entry) } catch { self.error = error.localizedDescription } }
                            }))
                        .disabled(app.switching)
                    }
                }
            } else {
                Divider()
            }
            Button("Add Account…") { adding = true }.disabled(app.switching)
            Divider()
            Button("Sign Out", role: .destructive) { Task { await app.signOut() } }.disabled(app.switching)
        } label: {
            AccountMenuLabel(services: services)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Account")
        .sheet(isPresented: $adding) {
            VStack {
                LoginView()
                Button("Cancel") { adding = false }.keyboardShortcut(.cancelAction).padding()
            }.frame(width: 500, height: 600).environment(app)
                .onChange(of: app.services.map(ObjectIdentifier.init)) { _, _ in adding = false }
        }
        .alert("Could Not Switch Account", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func storageText(_ user: User) -> String? {
        guard let used = user.quotaUsageInBytes else { return nil }
        let usedText = used.formatted(.byteCount(style: .file))
        if let quota = user.quotaSizeInBytes, quota > 0 {
            return String(localized: "\(usedText) of \(quota.formatted(.byteCount(style: .file))) used")
        }
        return String(localized: "\(usedText) used")
    }
}

private struct AccountMenuLabel: View {
    let services: AccountServices

    var body: some View {
        HStack(spacing: 8) {
            AccountAvatar(services: services, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName).lineLimit(1)
                Text(services.client.serverURL.host() ?? services.client.serverURL.absoluteString)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var displayName: String {
        guard let user = services.user else { return String(localized: "Account") }
        return user.name.isEmpty ? user.email : user.name
    }
}

/// The profile picture, or Immich-style initials on the user's avatar colour.
struct AccountAvatar: View {
    let services: AccountServices
    let size: CGFloat

    var body: some View {
        Group {
            if let picture = services.profilePicture {
                Image(nsImage: picture).resizable().scaledToFill()
            } else {
                UserInitials(name: services.user?.name ?? "", email: services.user?.email ?? "", avatarColor: services.user?.avatarColor, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Another user's picture (an album's members): any signed-in user may load it, as Immich's web app does. Users
/// without one, or whose picture can't be loaded, show their initials.
struct UserAvatar: View {
    @Environment(LibrarySession.self) private var session
    let user: User
    let size: CGFloat
    @State private var picture: NSImage?

    @MainActor private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let picture {
                Image(nsImage: picture).resizable().scaledToFill()
            } else {
                UserInitials(name: user.name, email: user.email, avatarColor: user.avatarColor, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: user.profileImagePath) { await load() }
    }

    private func load() async {
        guard let path = user.profileImagePath, !path.isEmpty else { picture = nil; return }
        let key = "\(session.client.serverURL.absoluteString)|\(user.id)|\(path)" as NSString
        if let cached = Self.cache.object(forKey: key) { picture = cached; return }
        guard let request = try? session.client.request("users/\(user.id)/profile-image"),
              let data = try? await session.client.data(for: request),
              let image = NSImage(data: data), !Task.isCancelled else { return }
        Self.cache.setObject(image, forKey: key)
        withAnimation(.easeOut(duration: 0.2)) { picture = image }
    }
}

/// Immich-style initials on the user's avatar colour.
struct UserInitials: View {
    let name: String
    let email: String
    let avatarColor: String?
    let size: CGFloat

    var body: some View {
        Circle().fill(color).overlay {
            Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        let words = name.split(separator: " ")
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return letters.isEmpty ? String(email.first ?? "?").uppercased() : String(letters).uppercased()
    }

    private var color: Color {
        switch avatarColor {
        case "pink": .pink
        case "red": .red
        case "yellow": .yellow
        case "blue": .blue
        case "green": .green
        case "purple": .purple
        case "orange": .orange
        case "gray": .gray
        case "amber": Color(red: 1, green: 0.75, blue: 0)
        default: .accentColor
        }
    }
}
