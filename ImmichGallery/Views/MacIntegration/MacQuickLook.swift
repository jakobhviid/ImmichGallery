import AppKit
import Quartz

/// Space: Quick Look of the selection, as in Finder and Photos. While the panel is open it follows the grid's
/// selection, and with one item shown the arrow keys move the grid, so stepping through photos works from the panel
/// too. Originals are fetched as they are needed, the neighbours ahead of time.
@MainActor
final class MacQuickLook: NSResponder, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = MacQuickLook()
    private weak var sourceWindow: NSWindow?
    private weak var session: LibrarySession?
    /// What the panel shows, in the grid's order (at most 20).
    private var ids: [String] = []
    /// Downloaded originals by asset id: those shown, and the neighbours fetched ahead.
    private var files: [String: URL] = [:]
    private var loading: [String: Task<Void, Never>] = [:]
    private var onError: ((String) -> Void)?
    /// Moves the grid's selection for an arrow key; true when it did.
    private var onArrow: ((NSEvent) -> Bool)?
    private var generation = UUID()
    private var opened = false

    var isOpen: Bool { opened || !ids.isEmpty }

    func toggle(_ ids: [String], ahead: [String] = [], session: LibrarySession, onError: @escaping (String) -> Void,
                onArrow: ((NSEvent) -> Bool)? = nil) {
        if isOpen {
            dismiss()
            return
        }
        guard !ids.isEmpty else { return }
        sourceWindow = NSApp.keyWindow
        self.session = session
        self.onError = onError
        self.onArrow = onArrow
        generation = UUID()
        show(ids, ahead: ahead)
    }

    /// The grid's selection changed while the panel is open: show it instead.
    func follow(_ ids: [String], ahead: [String] = []) {
        guard isOpen, !ids.isEmpty, Array(ids.prefix(20)) != self.ids else { return }
        show(ids, ahead: ahead)
    }

    private func show(_ newIDs: [String], ahead: [String]) {
        ids = Array(newIDs.prefix(20))
        let keep = Set(ids).union(ahead)
        // Only what is shown and what is next stay on disk.
        for (id, url) in files where !keep.contains(id) {
            MacTransferCache.release(url.deletingLastPathComponent(), remove: true)
            files[id] = nil
        }
        for (id, task) in loading where !keep.contains(id) {
            task.cancel()
            loading[id] = nil
        }
        for id in ids + ahead { load(id) }
        update()
    }

    private func load(_ id: String) {
        guard files[id] == nil, loading[id] == nil, let session else { return }
        let current = generation
        loading[id] = Task {
            do {
                let url = try await session.client.macIntegrationOriginal(id, preview: true)
                guard !Task.isCancelled, generation == current, loading[id] != nil else {
                    MacTransferCache.release(url.deletingLastPathComponent(), remove: true)
                    return
                }
                loading[id] = nil
                files[id] = url
                if ids.contains(id) { update() }
            } catch {
                loading[id] = nil
                if generation == current, !error.isCancellation, ids.contains(id) {
                    session.handle(error)
                    onError?(error.localizedDescription)
                }
            }
        }
    }

    /// Opens the panel once the first item is there, and shows what has arrived since.
    private func update() {
        guard !ids.isEmpty, ids.contains(where: { files[$0] != nil }) else { return }
        let panel = QLPreviewPanel.shared()!
        if !opened {
            opened = true
            nextResponder = sourceWindow?.nextResponder
            sourceWindow?.nextResponder = self
            panel.makeKeyAndOrderFront(nil)
            panel.currentPreviewItemIndex = 0
        }
        panel.reloadData()
        if panel.currentPreviewItemIndex >= shown.count { panel.currentPreviewItemIndex = 0 }
    }

    private var shown: [URL] { ids.compactMap { files[$0] } }

    func dismiss() {
        generation = UUID()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        cleanUp()
    }

    private func cleanUp() {
        loading.values.forEach { $0.cancel() }
        loading = [:]
        if let sourceWindow, sourceWindow.nextResponder === self { sourceWindow.nextResponder = nextResponder }
        sourceWindow = nil
        nextResponder = nil
        files.values.forEach { MacTransferCache.release($0.deletingLastPathComponent(), remove: true) }
        files = [:]
        ids = []
        opened = false
        onArrow = nil
        onError = nil
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            generation = UUID()
            cleanUp()
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { shown.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let shown = shown
        return shown.indices.contains(index) ? shown[index] as NSURL : nil
    }

    /// With one item shown, the arrow keys move the grid's selection, which the panel then follows; with several,
    /// the panel steps through them itself, as Finder's does.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, ids.count <= 1, let onArrow else { return false }
        return onArrow(event)
    }
}
