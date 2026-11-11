import SwiftUI
import UniformTypeIdentifiers

struct UploadCommands: Commands {
    let app: AppModel
    @FocusedValue(\.librarySession) private var session
    var body: some Commands {
        CommandGroup(before: .importExport) {
            Button("Import…") { session?.upload.chooseFiles() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(session == nil)
        }
    }
}

struct UploadToolbar: CustomizableToolbarContent {
    let queue: UploadQueue
    var body: some CustomizableToolbarContent {
        // Not there by default, as in Photos: File > Import… and dropping files import, and the button can be added.
        ToolbarItem(id: "import", showsByDefault: false) { UploadToolbarButton(queue: queue) }
    }
}

private struct UploadToolbarButton: View {
    let queue: UploadQueue
    // On macOS 15 a toolbar item is rebuilt whenever its root view reads changing data, and
    // a popover bound straight to an @Observable property rebuilds it on every update
    // (infinite layout loop, then a crash). So the popover uses local state mirrored to the
    // model, and the changing progress is read only by the label view.
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: { UploadToolbarLabel(queue: queue) }
            .help("Import photos and videos")
            .popover(isPresented: $showing) { UploadProgressView(queue: queue) }
            .background { UploadPopoverSync(queue: queue, showing: $showing) }
    }
}

private struct UploadToolbarLabel: View {
    let queue: UploadQueue
    var body: some View {
        if queue.isRunning {
            ProgressView(value: Double(queue.completed), total: Double(max(1, queue.items.count)))
                .progressViewStyle(.circular).controlSize(.small)
                .accessibilityLabel("Importing \(queue.completed) of \(queue.items.count)")
        } else {
            Label("Import", systemImage: "arrow.up.to.line")
        }
    }
}

/// Mirrors `queue.showingProgress` (set by the queue on errors) and the popover state.
private struct UploadPopoverSync: View {
    let queue: UploadQueue
    @Binding var showing: Bool
    var body: some View {
        Color.clear
            .onChange(of: queue.showingProgress, initial: true) { _, value in if showing != value { showing = value } }
            .onChange(of: showing) { _, value in if queue.showingProgress != value { queue.showingProgress = value } }
    }
}

private struct UploadProgressView: View {
    @Bindable var queue: UploadQueue
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Import").font(.headline)
                Spacer()
                Button("Import…") { queue.chooseFiles() }.disabled(queue.discovering)
            }
            if queue.discovering { ProgressView("Scanning files…") }
            if let error = queue.lastError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if queue.unreadableCount > 0 { Text("\(queue.unreadableCount) items could not be read").foregroundStyle(.orange) }
            if queue.unsupportedCount > 0 { Text("\(queue.unsupportedCount) unsupported files ignored").foregroundStyle(.secondary) }
            if queue.items.isEmpty {
                Text("Choose files or drop photos, videos, or folders onto the window. Drop onto an album to import there.")
                    .foregroundStyle(.secondary)
            } else {
                Text(queue.summary).font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(queue.items) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.url.lastPathComponent).lineLimit(1).help(item.url.path)
                                Text(item.state.title).font(.caption).foregroundStyle(.secondary)
                                if item.response?.isTrashed == true { Text("(in Recently Deleted)").font(.caption).foregroundStyle(.secondary) }
                                if item.state == .uploading {
                                    ProgressView(value: Double(item.sent), total: Double(max(1, item.total)))
                                    Text("\(ByteCountFormatter.string(fromByteCount: item.sent, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: item.total, countStyle: .file))")
                                        .font(.caption).monospacedDigit()
                                }
                                if let error = item.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                            }
                        }
                    }
                }.frame(maxHeight: 320)
                HStack {
                    if queue.isRunning { Button("Cancel All", role: .cancel) { queue.cancelAll() } }
                    else {
                        Button("Retry Failed") { queue.retryFailed() }
                            .disabled(queue.failed + queue.cancelled == 0)
                        Spacer()
                        Button("Clear") { queue.clear() }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

struct UploadDropModifier: ViewModifier {
    let queue: UploadQueue
    var albumID: String?
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .onDrop(of: [UTType.fileURL], delegate: UploadFileDrop(queue: queue, albumID: albumID, targeted: $targeted))
            .overlay { if targeted { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).allowsHitTesting(false) } }
            .animation(.easeOut(duration: 0.15), value: targeted)
    }

    static func enqueue(_ providers: [NSItemProvider], queue: UploadQueue, albumID: String?) -> Bool {
        guard !providers.isEmpty, !UploadDropPolicy.isInternal(providers) else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            if !urls.isEmpty { queue.enqueue(urls, albumID: albumID) }
            else { queue.lastError = String(localized: "The dropped files could not be read. Try Import… instead.") }
        }
        return !providers.isEmpty
    }
}

private struct UploadFileDrop: DropDelegate {
    let queue: UploadQueue
    let albumID: String?
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL]) && !UploadDropPolicy.isInternal(info.itemProviders(for: [.fileURL]))
    }

    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info) else { return false }
        return UploadDropModifier.enqueue(info.itemProviders(for: [.fileURL]), queue: queue, albumID: albumID)
    }
}
