import SwiftUI
import AppKit

struct SharingPresentation: Identifiable {
    enum Kind { case create, add, files }
    let id = UUID()
    let kind: Kind
    let assetIDs: [String]
    var albumID: String?
}

struct SharingMenu: View {
    @Environment(LibrarySession.self) private var session
    let assetIDs: [String]
    var allowPublicLinks = true
    var albumID: String?
    var body: some View {
        Menu {
            SharingMenuItems(assetIDs: assetIDs, allowPublicLinks: allowPublicLinks, albumID: albumID)
        } label: { Label("Share", systemImage: "square.and.arrow.up") }
        // Never an empty menu: with nothing to share, the button is dimmed.
        .disabled(assetIDs.isEmpty && !(albumID != nil && allowPublicLinks && session.sharing.linksAvailable))
    }
}

struct SharingMenuItems: View {
    @Environment(LibrarySession.self) private var session
    let assetIDs: [String]
    var allowPublicLinks = true
    var albumID: String?
    var body: some View {
        if allowPublicLinks && session.sharing.linksAvailable {
            if let albumID {
                Button("Create Album Public Link…") { session.sharing.presentation = .init(kind: .create, assetIDs: [], albumID: albumID) }
            }
            if !assetIDs.isEmpty {
                Button("Create Public Link…") { session.sharing.presentation = .init(kind: .create, assetIDs: assetIDs) }
            }
            if !assetIDs.isEmpty {
                Button("Add to Public Link…") { session.sharing.presentation = .init(kind: .add, assetIDs: assetIDs) }
            }
        }
        if !assetIDs.isEmpty {
            Button("Share Original Files…") { session.sharing.presentation = .init(kind: .files, assetIDs: assetIDs) }
        }
    }
}

private struct SharingPresentationModifier: ViewModifier {
    @Environment(LibrarySession.self) private var session
    func body(content: Content) -> some View {
        @Bindable var sharing = session.sharing
        content.sheet(item: $sharing.presentation) { presentation in
            switch presentation.kind {
            case .create: SharedLinkEditor(albumID: presentation.albumID, assetIDs: presentation.assetIDs)
            case .add: AddToSharedLinkView(assetIDs: presentation.assetIDs)
            case .files: ShareFilesView(assetIDs: presentation.assetIDs)
            }
        }
    }
}
extension View {
    func sharingPresentation() -> some View { modifier(SharingPresentationModifier()) }
}

private struct AddToSharedLinkView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let assetIDs: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add to Public Link").font(.title2.bold())
            Text("The selected photos will become accessible to anyone who can open the link.")
            List(session.sharing.links.filter { $0.type == "INDIVIDUAL" }) { link in
                Button(link.title) {
                    Task {
                        if await session.sharing.perform({ try await session.client.changeSharedLinkAssets(link.id, assetIDs: assetIDs, adding: true) }) { dismiss() }
                    }
                }.disabled(session.sharing.busy)
            }
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 440, height: 360).sharingError()
            .task { await session.sharing.reload() }
    }
}

private struct ShareFilesView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let assetIDs: [String]
    @State private var urls: [URL] = []
    @State private var completed = 0
    @State private var error: String?
    @State private var folder: URL?
    @State private var sharing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Share Original Files").font(.title2.bold())
            if let error { Text(error).foregroundStyle(.red) }
            else if completed < assetIDs.count {
                ProgressView("Downloading \(completed) of \(assetIDs.count)", value: Double(completed), total: Double(assetIDs.count))
            } else {
                ShareOriginalFilesButton(urls: urls, sharing: $sharing) {
                    removeFiles()
                    dismiss()
                }
                Text("Originals include embedded metadata such as location.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(sharing)
        }.padding(24).frame(width: 420)
        .interactiveDismissDisabled(sharing)
        .task { await download() }
        .onDisappear {
            removeFiles()
        }
    }
    private func removeFiles() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func download() async {
        do {
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ImmichShare-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            folder = destination
            for id in assetIDs {
                try Task.checkCancellation()
                let (temp, response) = try await session.client.session.download(for: session.client.originalRequest(id))
                guard let response = response as? HTTPURLResponse else { throw ImmichError.http(400, String(localized: "Couldn't download an original.")) }
                if response.statusCode == 401 { throw ImmichError.unauthorized(nil) }
                guard (200..<300).contains(response.statusCode) else { throw ImmichError.http(response.statusCode, String(localized: "Couldn't download an original.")) }
                try Task.checkCancellation()
                // Separate directories preserve original names and avoid collisions or path traversal.
                let itemFolder = destination.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: true)
                let name = URL(fileURLWithPath: response.suggestedFilename ?? id).lastPathComponent
                let safeName = name.isEmpty || name == "." || name == ".." ? id : name
                let file = itemFolder.appendingPathComponent(safeName)
                try FileManager.default.moveItem(at: temp, to: file)
                urls.append(file)
                completed += 1
            }
        } catch {
            removeFiles()
            if !error.isCancellation { self.error = error.localizedDescription; session.handle(error) }
        }
    }
}

// Keep files until the selected sharing service has finished consuming them.
private struct ShareOriginalFilesButton: NSViewRepresentable {
    let urls: [URL]
    @Binding var sharing: Bool
    let finished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSButton {
        NSButton(title: String(localized: "Share \(urls.count) Files…"), target: context.coordinator, action: #selector(Coordinator.share(_:)))
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = !sharing
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        var parent: ShareOriginalFilesButton
        var picker: NSSharingServicePicker?
        init(parent: ShareOriginalFilesButton) { self.parent = parent }
        @objc func share(_ sender: NSButton) {
            let picker = NSSharingServicePicker(items: parent.urls)
            self.picker = picker
            picker.delegate = self
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            parent.sharing = service != nil
        }
        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? { self }
        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { parent.finished() }
        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) { parent.finished() }
    }
}

enum SharingTemporaryFiles {
    static func sweep() {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey])) ?? []
        for folder in folders where folder.lastPathComponent.hasPrefix("ImmichShare-") {
            // Other windows or app instances may still be sharing recent downloads.
            guard let values = try? folder.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey]),
                  values.isDirectory == true, let created = values.creationDate,
                  created < Date().addingTimeInterval(-3600) else { continue }
            try? manager.removeItem(at: folder)
        }
    }
}
