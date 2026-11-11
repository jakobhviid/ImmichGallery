import SwiftUI

struct SharedLinkEditor: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var link: SharedLink?
    var albumID: String?
    var assetIDs: [String] = []
    @State private var options = SharingOptions()
    @State private var expires = false
    @State private var expiry = Date().addingTimeInterval(86400 * 7)
    @State private var busy = false
    @State private var error: String?
    @State private var resultURL: URL?
    @State private var preservePassword = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(link == nil ? "Create Public Link" : "Edit Public Link").font(.title2.bold())
            if let resultURL {
                Text(resultURL.absoluteString).textSelection(.enabled)
                HStack {
                    Button("Copy Link") { SharingClipboard.copy(resultURL) }
                    ShareLink(item: resultURL)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Form {
                    TextField("Description", text: $options.description)
                    TextField("Custom URL slug", text: $options.slug)
                    if link?.hasPassword == true {
                        Toggle("Keep existing password", isOn: $preservePassword.animation(.smooth(duration: 0.25)))
                    }
                    if link?.hasPassword != true || !preservePassword {
                        SecureField("Password (empty for none)", text: $options.password)
                    }
                    Toggle("Expires", isOn: $expires.animation(.smooth(duration: 0.25)))
                    if expires { DatePicker("Expiration", selection: $expiry, in: min(Date(), expiry)...) }
                    Toggle("Show metadata", isOn: $options.showMetadata)
                        .onChange(of: options.showMetadata) { _, value in if !value { options.allowDownload = false } }
                    Toggle("Allow download", isOn: $options.allowDownload).disabled(!options.showMetadata)
                    Toggle("Allow upload", isOn: $options.allowUpload.animation(.smooth(duration: 0.25)))
                    if options.allowUpload { Text("Visitors can upload photos to your account.").font(.caption).foregroundStyle(.secondary) }
                }.formStyle(.grouped)
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button(link == nil ? "Create Link" : "Save") { Task { await save() } }
                        .keyboardShortcut(.defaultAction).disabled(busy)
                }
            }
        }
        .padding(24).frame(width: 480)
        .onAppear {
            if let link {
                options.description = link.description ?? ""
                options.slug = link.slug ?? ""
                options.allowDownload = link.allowDownload
                options.allowUpload = link.allowUpload
                options.showMetadata = link.showMetadata
                if let date = link.expiresAt.flatMap(ImmichDate.parse) { expires = true; expiry = date }
            }
        }
    }

    private func save() async {
        error = nil
        busy = true
        defer { busy = false }
        options.expiresAt = expires ? ISO8601DateFormatter().string(from: expiry) : nil
        do {
            let result: SharedLink
            if let link {
                // The response only indicates password presence; never send its masked value back.
                result = try await session.client.editSharedLink(link.id, options: options, keepPassword: link.hasPassword && preservePassword)
            } else {
                result = try await session.client.createSharedLink(albumID: albumID, assetIDs: assetIDs, options: options)
            }
            resultURL = try ImmichClient.sharingURL(result, externalDomain: nil, serverURL: session.client.serverURL)
            resultURL = try await session.client.sharingPublicURL(result)
            await session.sharing.reload()
        } catch { self.error = error.localizedDescription; session.handle(error) }
    }
}
