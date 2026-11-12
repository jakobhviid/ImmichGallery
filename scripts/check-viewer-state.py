#!/usr/bin/env python3
"""Run production navigation/close methods with in-memory mocks, never the app."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
source = (repo / 'ImmichGallery/App/ViewerState.swift').read_text()

def method(name, source=source):
    source = source.replace('    private func ', '    func ')
    start = source.index('    func ' + name + '(')
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

harness = r'''
import Foundation
class NSText: NSObject {}
struct TestWindow { var firstResponder: NSObject? }
@MainActor enum NSApp { static var keyWindow: TestWindow? }
enum NSCursor { static func setHiddenUntilMouseMoves(_ hidden: Bool) {} }
struct AssetItem { let id: String; var isVideo = false; var livePhotoVideoID: String? = nil }
enum PressKey { case leftArrow, rightArrow, space, escape, `return`, delete, deleteForward, character }
struct PressModifiers: OptionSet {
    let rawValue: Int
    static let command = PressModifiers(rawValue: 1)
    static let shift = PressModifiers(rawValue: 2)
    static let option = PressModifiers(rawValue: 4)
    static let control = PressModifiers(rawValue: 8)
}
enum ZoomRequest { case zoomIn, zoomOut, toggle }
struct GridSourceStub { var albumID: String? }
struct KeyPress {
    enum Result: Equatable { case handled, ignored }
    let key: PressKey
    var modifiers: PressModifiers = []
    var characters = ""
}
@MainActor final class AssetGridModel {
    var viewerID: String? = "a"
    var selection: Set<String> = ["a"]
    var ids = ["a", "b", "c"]
    var delay = false
    var source = GridSourceStub()
    var favoriteToggles: [[String]] = []
    func toggleFavorite(_ ids: [String]) async { favoriteToggles.append(ids) }
    func item(_ id: String) -> AssetItem? { ids.contains(id) ? AssetItem(id: id) : nil }
    func neighbor(of id: String, delta: Int) async -> AssetItem? {
        if delay { try? await Task.sleep(for: .milliseconds(20)) }
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + delta) else { return nil }
        return item(ids[index + delta])
    }
}
@MainActor final class ViewerCommandContext {
    static let shared = ViewerCommandContext()
    var presentation: ViewerState?
}
@MainActor final class ViewerState {
    func close() { windowWillClose(Notification(name: Notification.Name("close"))) }
    let model = AssetGridModel()
    var sequence: [String] = []
    var sequenceIndex: [String: Int] = [:]
    var navigating = false
    var pendingStep = 0
    var playbackGeneration = 0
    var elapsed = 5.0
    var videoStalledElapsed = 5.0
    var rotation = 90
    var paused = false
    var window: NSObject? = NSObject()
    var slideshow = true
    var settingsPresented = true
    var controlsVisible = false
'''
harness += '\n'.join(method(name) for name in ['neighbor', 'stepWithoutWrapping', 'step', 'windowWillClose'])
harness += r'''
}
@MainActor final class ViewerKeyHarness {
    var viewer: ViewerState?
    var isPresentation = true
    let model: AssetGridModel
    var item = AssetItem(id: "a")
    var playLive = false
    var zooms: [ZoomRequest] = []
    var deleted: [[String]] = []
    var removed: [[String]] = []
    lazy var onZoom: (ZoomRequest) -> Void = { [unowned self] in self.zooms.append($0) }
    lazy var onDelete: ([String]) -> Void = { [unowned self] in self.deleted.append($0) }
    lazy var onRemove: ([String]) -> Void = { [unowned self] in self.removed.append($0) }
    init(_ state: ViewerState) { viewer = state; model = state.model }
    func step(_ delta: Int) { viewer?.step(delta) }
'''
viewer_source = (repo / 'ImmichGallery/Views/Viewer/AssetViewer.swift').read_text()
harness += method('handleKey', viewer_source) + '\n' + method('delete', viewer_source)
harness += r'''
}
@main struct Check {
    @MainActor static func main() async {
        let keyboardState = ViewerState()
        keyboardState.slideshow = false
        let keys = ViewerKeyHarness(keyboardState)
        assert(keys.handleKey(KeyPress(key: .space)) == .handled)
        assert(keys.handleKey(KeyPress(key: .return)) == .handled)
        assert(keyboardState.model.viewerID == "a" && !keyboardState.paused, "Space/Return must preserve non-slideshow viewer")
        keyboardState.slideshow = true
        _ = keys.handleKey(KeyPress(key: .space))
        assert(keyboardState.paused && keyboardState.model.viewerID == "a")
        _ = keys.handleKey(KeyPress(key: .escape))
        assert(keyboardState.model.viewerID == nil)
        keyboardState.model.viewerID = "a"
        NSApp.keyWindow = TestWindow(firstResponder: NSText())
        assert(keys.handleKey(KeyPress(key: .rightArrow)) == .ignored)
        assert(keys.handleKey(KeyPress(key: .space)) == .ignored)
        assert(keys.handleKey(KeyPress(key: .return, characters: ".")) == .ignored)
        assert(keyboardState.model.viewerID == "a", "Editing photo details must not navigate or close the viewer")
        NSApp.keyWindow = nil

        // Photos' keys on the open photo: ⌥Space plays a Live Photo without closing, Z zooms, ⌫/⌘⌫ delete or remove.
        keyboardState.slideshow = false
        keys.isPresentation = false
        keys.item = AssetItem(id: "a", livePhotoVideoID: "live")
        assert(keys.handleKey(KeyPress(key: .space, modifiers: .option)) == .handled)
        assert(keys.playLive && keyboardState.model.viewerID == "a", "Option-Space plays the Live Photo and keeps the viewer open")
        keys.item = AssetItem(id: "a")
        assert(keys.handleKey(KeyPress(key: .space, modifiers: .option)) == .handled)
        assert(keys.playLive && keyboardState.model.viewerID == "a", "Option-Space without a Live Photo neither closes nor toggles")
        assert(keys.handleKey(KeyPress(key: .character, characters: "z")) == .handled && keys.zooms == [.toggle], "Z zooms the photo")
        assert(keys.handleKey(KeyPress(key: .character, modifiers: .command, characters: "z")) == .ignored && keys.zooms == [.toggle])
        keys.item = AssetItem(id: "a", isVideo: true)
        assert(keys.handleKey(KeyPress(key: .character, characters: "z")) == .ignored && keys.zooms == [.toggle], "Z doesn't zoom a video")
        keys.item = AssetItem(id: "a")
        assert(keys.handleKey(KeyPress(key: .character, characters: ".")) == .handled)
        try? await Task.sleep(for: .milliseconds(20))
        assert(keyboardState.model.favoriteToggles == [["a"]], "Period toggles Favorite")
        assert(keys.handleKey(KeyPress(key: .character, characters: "q")) == .ignored)
        assert(keys.handleKey(KeyPress(key: .deleteForward, modifiers: .shift)) == .ignored && keys.deleted.isEmpty)
        assert(keys.handleKey(KeyPress(key: .delete, modifiers: .option)) == .ignored && keys.deleted.isEmpty)
        assert(keys.handleKey(KeyPress(key: .delete, modifiers: .control)) == .ignored && keys.deleted.isEmpty)
        assert(keys.handleKey(KeyPress(key: .delete)) == .handled && keys.deleted == [["a"]] && keys.removed.isEmpty, "Delete outside an album deletes")
        keyboardState.model.source.albumID = "album"
        assert(keys.handleKey(KeyPress(key: .delete)) == .handled && keys.removed == [["a"]] && keys.deleted == [["a"]], "Delete in an album removes from it")
        assert(keys.handleKey(KeyPress(key: .deleteForward, modifiers: .command)) == .handled && keys.deleted == [["a"], ["a"]], "Command-Delete deletes even in an album")
        keyboardState.model.source.albumID = nil
        assert(keyboardState.model.viewerID == "a", "Deleting is left to the caller; the key doesn't close the viewer")

        let state = ViewerState()
        state.sequence = ["a", "c", "b"]
        state.sequenceIndex = Dictionary(uniqueKeysWithValues: state.sequence.enumerated().map { ($0.element, $0.offset) })
        let next = await state.neighbor(of: "a", delta: 1)
        let previous = await state.neighbor(of: "a", delta: -1)
        assert(next?.id == "c" && previous?.id == "b", "Use slideshow sequence, including backward wrap")
        state.step(1)
        try? await Task.sleep(for: .milliseconds(50))
        assert(state.model.viewerID == "c" && state.model.selection == ["c"])
        assert(state.elapsed == 0 && state.videoStalledElapsed == 0 && state.rotation == 0)

        state.stepWithoutWrapping(1)
        try? await Task.sleep(for: .milliseconds(50))
        assert(state.model.viewerID == "b", "Swipes move forward through the sequence")
        state.stepWithoutWrapping(1)
        try? await Task.sleep(for: .milliseconds(50))
        assert(state.model.viewerID == "b", "Swipes stop at the end of a repeating sequence")
        state.model.viewerID = "a"
        state.stepWithoutWrapping(-1)
        try? await Task.sleep(for: .milliseconds(50))
        assert(state.model.viewerID == "a", "Swipes stop at the start of a repeating sequence")
        state.model.viewerID = "c"

        state.sequence = ["c"]
        state.sequenceIndex = ["c": 0]
        let generation = state.playbackGeneration
        state.step(1)
        try? await Task.sleep(for: .milliseconds(50))
        assert(state.model.viewerID == "c" && state.playbackGeneration == generation + 1, "Restart same-item video")

        state.sequence = []
        state.sequenceIndex = [:]
        state.model.viewerID = "a"
        state.model.delay = true
        state.step(1)
        try? await Task.sleep(for: .milliseconds(5))
        state.step(1)
        try? await Task.sleep(for: .milliseconds(100))
        assert(state.model.viewerID == "c", "Navigation arriving during loading must be coalesced")
        state.step(1)
        try? await Task.sleep(for: .milliseconds(50))
        assert(state.paused, "Ordered collection pauses at boundary")

        ViewerCommandContext.shared.presentation = state
        state.windowWillClose(Notification(name: Notification.Name("close")))
        assert(state.model.viewerID == nil && state.model.selection == ["c"])
        assert(!state.slideshow && !state.settingsPresented && state.controlsVisible && state.window == nil)
        assert(ViewerCommandContext.shared.presentation == nil)

        let closing = ViewerState()
        closing.model.delay = true
        closing.step(1)
        try? await Task.sleep(for: .milliseconds(5))
        closing.windowWillClose(Notification(name: Notification.Name("close")))
        try? await Task.sleep(for: .milliseconds(50))
        assert(closing.model.viewerID == nil, "An in-flight navigation must not reopen the inline viewer")
        print("Viewer state checks passed: keyboard, sequence, wraparound, swipe boundaries, coalescing, restart, boundary and close")
    }
}
'''
(repo / 'build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='viewer-state-check-', dir=repo / 'build') as directory:
    swift = Path(directory) / 'Checks.swift'
    executable = Path(directory) / 'checks'
    swift.write_text(harness)
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
