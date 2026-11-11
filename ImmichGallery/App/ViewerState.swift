import AppKit
import ImageIO
import Observation
import SwiftUI

@MainActor @Observable
final class ViewerState: NSObject, NSWindowDelegate {
    let model: AssetGridModel
    let session: LibrarySession
    var rotation = 0
    var slideshow = false { didSet { updateActivity() } }
    var paused = false { didSet { updateActivity() } }
    var settingsPresented = false
    var window: NSWindow?
    var preparing = false
    var elapsed = 0.0
    var sequence: [String] = []
    private var selectionSequence: [String] = []
    private var navigating = false
    private var pendingStep = 0
    private var sequenceIndex: [String: Int] = [:]
    private var activity: NSObjectProtocol?
    private static var copying = false
    var playbackGeneration = 0
    var videoStalledElapsed = 0.0

    /// Zooming the open photo from the keyboard: ⌘+ and ⌘− step, Z toggles as double-clicking does.
    enum Zoom: Equatable { case zoomIn, zoomOut, toggle }
    struct ZoomRequest: Equatable {
        let zoom: Zoom
        let generation: Int
    }
    private(set) var zoomRequest: ZoomRequest?
    func zoom(_ zoom: Zoom) { zoomRequest = ZoomRequest(zoom: zoom, generation: (zoomRequest?.generation ?? 0) + 1) }

    private func updateActivity() {
        if slideshow && !paused && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled, reason: "Playing a slideshow")
        } else if (!slideshow || paused), let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
    var controlsVisible = true
    var interval: Double = UserDefaults.standard.object(forKey: "viewer.interval") as? Double ?? 5 {
        didSet { UserDefaults.standard.set(interval, forKey: "viewer.interval") }
    }
    var shuffle = UserDefaults.standard.bool(forKey: "viewer.shuffle") {
        didSet { UserDefaults.standard.set(shuffle, forKey: "viewer.shuffle"); Task { await rebuildSequence() } }
    }
    var fade = UserDefaults.standard.object(forKey: "viewer.fade") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fade, forKey: "viewer.fade") }
    }
    var limitVideos = UserDefaults.standard.bool(forKey: "viewer.limitVideos") {
        didSet { UserDefaults.standard.set(limitVideos, forKey: "viewer.limitVideos") }
    }

    init(model: AssetGridModel, session: LibrarySession) {
        self.model = model
        self.session = session
    }

    var currentID: String? { model.viewerID ?? (model.selection.count == 1 ? model.selection.first : nil) }

    func present(slideshow: Bool) {
        guard !preparing else { return }
        preparing = true
        Task {
            defer { preparing = false }
            await model.loadIfNeeded()
            if model.viewerID == nil {
                if model.sections.first?.assets == nil { await model.viewerLoadSection(0) }
                model.viewerID = model.sections.flatMap { $0.assets ?? [] }.first { model.selection.contains($0.id) }?.id ?? model.sections.first?.assets?.first?.id
            }
            guard model.viewerID != nil else { return }
            self.slideshow = slideshow
            paused = false
            elapsed = 0
            selectionSequence = model.selection.count > 1
                ? model.sections.flatMap { $0.assets ?? [] }.filter { model.selection.contains($0.id) }.map(\.id) : []
            await rebuildSequence()
            if let id = model.viewerID { model.selection = [id] }
            guard window == nil else { return }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = String(localized: "Viewer")
            window.collectionBehavior = [.fullScreenPrimary]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: ViewerPresentation(state: self).environment(session).environment(\.viewerContext, self))
            self.window = window
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.toggleFullScreen(nil)
        }
    }

    private func rebuildSequence() async {
        guard slideshow else { sequence = []; sequenceIndex = [:]; return }
        do {
            var nextSequence = selectionSequence
            if shuffle {
                if nextSequence.isEmpty { nextSequence = try await model.viewerAllItems().map(\.id) }
                nextSequence.shuffle()
            }
            guard slideshow else { return }
            sequence = nextSequence
            // shortcut: shuffle materializes collection metadata once; use lazy bucket shuffle for very large libraries.
            sequenceIndex = Dictionary(sequence.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        } catch { model.lastError = error.localizedDescription; session.handle(error) }
    }

    func neighbor(of id: String, delta: Int) async -> AssetItem? {
        if !sequence.isEmpty, let index = sequenceIndex[id] {
            let next = sequence[((index + delta) % sequence.count + sequence.count) % sequence.count]
            return model.item(next)
        }
        return await model.neighbor(of: id, delta: delta)
    }

    func step(_ delta: Int) {
        pendingStep += delta
        guard !navigating else { return }
        navigating = true
        Task {
            defer { navigating = false }
            while pendingStep != 0 {
                let delta = pendingStep > 0 ? 1 : -1
                pendingStep -= delta
                guard let id = model.viewerID else { pendingStep = 0; return }
                let next = await neighbor(of: id, delta: delta)?.id
                guard model.viewerID != nil else { pendingStep = 0; return }
                guard let next else { paused = true; pendingStep = 0; return }
                model.viewerID = next
                model.selection = [next]
                playbackGeneration += 1
                elapsed = 0
                videoStalledElapsed = 0
                rotation = 0
            }
        }
    }

    func close() { window?.close() }
    func windowWillClose(_ notification: Notification) {
        window = nil
        NSCursor.setHiddenUntilMouseMoves(false)
        if ViewerCommandContext.shared.presentation === self { ViewerCommandContext.shared.presentation = nil }
        model.viewerID = nil
        pendingStep = 0
        slideshow = false
        settingsPresented = false
        controlsVisible = true
        sequence = []
        sequenceIndex = [:]
    }
    func windowDidBecomeKey(_ notification: Notification) { ViewerCommandContext.shared.presentation = self }
    func windowDidResignKey(_ notification: Notification) {
        if ViewerCommandContext.shared.presentation === self { ViewerCommandContext.shared.presentation = nil }
    }
    func windowDidExitFullScreen(_ notification: Notification) { close() }

    func copy(original: Bool = false, asFile: Bool = false) {
        guard let id = currentID, !Self.copying else { return }
        Self.copying = true
        Self.pruneClipboard()
        Task {
            defer { Self.copying = false }
            do {
                if asFile {
                    let asset = try await session.client.asset(id)
                    let (temporaryFile, response) = try await session.client.session.download(for: session.client.originalRequest(id))
                    defer { try? FileManager.default.removeItem(at: temporaryFile) }
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CocoaError(.fileReadUnknown) }
                    guard session.lockedFolder?.isDiscarded != true else { return }
                    // Locked Folder copies stay in its own folder, which is removed on lock.
                    let directory = (session.client.transferRoot?.appendingPathComponent("Clipboard")
                        ?? FileManager.default.temporaryDirectory.appendingPathComponent("ViewerClipboard")).appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let file = directory.appendingPathComponent((asset.originalFileName as NSString).lastPathComponent)
                    try FileManager.default.copyItem(at: temporaryFile, to: file)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([file as NSURL])
                    session.lockedFolder?.pasteboardChangeCount = NSPasteboard.general.changeCount
                } else {
                    let image: NSImage
                    if original {
                        let (file, response) = try await session.client.session.download(for: session.client.originalRequest(id))
                        defer { try? FileManager.default.removeItem(at: file) }
                        guard (response as? HTTPURLResponse)?.statusCode == 200,
                              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
                        image = NSImage(cgImage: decoded, size: .zero)
                    } else {
                        guard let preview = await session.pipeline.thumbnail(id, size: .preview) else { throw CocoaError(.fileReadCorruptFile) }
                        image = NSImage(cgImage: preview, size: .zero)
                    }
                    guard session.lockedFolder?.isDiscarded != true else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                    session.lockedFolder?.pasteboardChangeCount = NSPasteboard.general.changeCount
                }
            } catch { model.lastError = error.localizedDescription; session.handle(error) }
        }
    }

    func showInLibrary() {
        guard model.source != .locked else { return }
        guard let id = currentID else { return }
        Self.showInLibrary(id: id, model: model, session: session, close: { self.close() })
    }

    static func pruneClipboard() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ViewerClipboard")
        try? FileManager.default.removeItem(at: directory)
    }

    static func showInLibrary(id: String, model: AssetGridModel, session: LibrarySession, close: @escaping () -> Void = {}) {
        guard model.source != .locked, session.lockedFolder == nil else { return }
        Task {
            do {
                let asset = try await session.client.asset(id)
                let library = session.gridModel(for: .library)
                await library.loadIfNeeded()
                try await library.loadForReveal(asset)
                guard library.item(id) != nil else {
                    model.lastError = library.arrangement?.isFiltered == true
                        ? String(localized: "This item isn't shown in All Photos with its current view options. Choose All Items in View Options to find it.")
                        : String(localized: "This item isn't in All Photos. It may be archived, hidden, trashed, or part of a stack.")
                    return
                }
                close()
                model.viewerID = nil
                library.viewerID = nil
                if model !== library || !library.selection.contains(id) { library.selection = [id] }
                library.viewerScrollTarget = id
                NotificationCenter.default.post(name: .viewerShowLibrary, object: session)
            } catch { model.lastError = error.localizedDescription; session.handle(error) }
        }
    }
}

extension Notification.Name {
    static let viewerShowLibrary = Notification.Name("viewerShowLibrary")
}
