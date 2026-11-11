import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var viewerContext: ViewerState? = nil
}

// NSHostingView windows do not publish scene focus to the app's Window scene.
@MainActor @Observable
final class ViewerCommandContext {
    static let shared = ViewerCommandContext()
    var presentation: ViewerState?
}

@MainActor
private func copyViewerImage(_ press: KeyPress, state: ViewerState?) -> KeyPress.Result {
    guard press.modifiers == .command, press.characters == "c",
          !(NSApp.keyWindow?.firstResponder is NSText),
          !(NSApp.keyWindow?.firstResponder is NSTextField),
          let state, let id = state.currentID, state.model.item(id)?.isVideo == false else { return .ignored }
    state.copy()
    return .handled
}

extension FocusedValues {
    @Entry var viewerState: ViewerState?
}

struct ViewerIntegration: ViewModifier {
    @Environment(LibrarySession.self) private var session
    let model: AssetGridModel
    @State private var state: ViewerState?

    func body(content: Content) -> some View {
        content
            .environment(\.viewerContext, state)
            .focusedSceneValue(\.viewerState, state)
            .toolbar(id: "viewer") {
                if let state {
                    ToolbarItem(id: "slideshow", showsByDefault: false) { // View > Start Slideshow
                        Button { state.present(slideshow: true) } label: { Label("Slideshow", systemImage: "play.rectangle") }
                            .disabled(model.totalCount == 0 || state.preparing)
                    }
                    if model.viewerID != nil {
                        ToolbarItem(id: "fullScreen", showsByDefault: false) {
                            Button { state.present(slideshow: false) } label: { Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                        }
                    }
                }
            }
            .onKeyPress(keys: ["c"]) { copyViewerImage($0, state: state) }
            .onAppear {
                if state == nil { state = ViewerState(model: model, session: session) }
                let current = state
                session.closeViewer = { [weak current] in current?.close() }
            }
            .onChange(of: model.viewerID) { state?.rotation = 0; state?.elapsed = 0 }
            .onDisappear { state?.close() }
    }
}

struct ViewerCommands: Commands {
    @FocusedValue(\.viewerState) private var focusedState
    @State private var context = ViewerCommandContext.shared
    private var state: ViewerState? { context.presentation ?? focusedState }
    private var canRotate: Bool {
        guard let state, let id = state.model.viewerID else { return false }
        return state.model.item(id)?.isVideo == false
    }

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Copy Image") { state?.copy() }
                .disabled(state?.currentID == nil || state?.model.item(state?.currentID ?? "")?.isVideo == true)
            Button("Copy Original Image") { state?.copy(original: true) }
                .disabled(state?.currentID == nil || state?.model.item(state?.currentID ?? "")?.isVideo == true)
            Button("Copy as File") { state?.copy(asFile: true) }.disabled(state?.currentID == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Start Slideshow") { state?.present(slideshow: true) }.disabled(state == nil || state?.model.totalCount == 0)
            Button("Open Full-Screen Viewer") { state?.present(slideshow: false) }.disabled(state?.currentID == nil)
            Button("Rotate View Temporarily Left") { state?.rotation -= 90 }.disabled(!canRotate)
            Button("Rotate View Temporarily Right") { state?.rotation += 90 }.disabled(!canRotate)
            Button("Show in All Photos") { state?.showInLibrary() }.disabled(state?.currentID == nil || state?.model.source == .locked)
        }
    }
}

struct ViewerContextMenu: View {
    @Environment(LibrarySession.self) private var session
    let model: AssetGridModel
    let asset: AssetItem
    var body: some View {
        Button("Show in All Photos") {
            if !model.selection.contains(asset.id) { model.selection = [asset.id] }
            ViewerState.showInLibrary(id: asset.id, model: model, session: session)
        }
    }
}

struct ViewerPresentation: View {
    @Bindable var state: ViewerState
    @State private var live = false
    @State private var lastInteraction = Date()
    @State private var overControls = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            if let id = state.model.viewerID, let item = state.model.item(id) {
                AssetViewer(model: state.model, item: item, playLive: $live, onDelete: { _ in }, isPresentation: true)
                    .id(id)
                    .transition(state.fade ? .opacity : .identity)
            }
            if state.controlsVisible {
                HStack(spacing: 20) {
                    Button { state.close() } label: { Label("Exit Full Screen", systemImage: "xmark") }
                    Button { state.step(-1) } label: { Label("Previous", systemImage: "backward.end.fill") }
                    if state.slideshow {
                        Button { state.paused.toggle() } label: { Label(state.paused ? "Play" : "Pause", systemImage: state.paused ? "play.fill" : "pause.fill") }
                    }
                    Button { state.step(1) } label: { Label("Next", systemImage: "forward.end.fill") }
                    if state.model.source != .locked {
                        Button { state.showInLibrary() } label: { Label("Show in All Photos", systemImage: "square.grid.2x2") }
                    }
                    Button { state.settingsPresented.toggle() } label: { Label("Slideshow Settings", systemImage: "gearshape") }
                        .popover(isPresented: $state.settingsPresented) { ViewerSlideshowSettings(state: state) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .padding(20)
                .adaptiveGlass(in: .capsule)
                .padding(24)
                .onHover { overControls = $0 }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.controlsVisible)
        .environment(\.colorScheme, .dark)
        .animation(state.fade ? .easeInOut(duration: 0.35) : nil, value: state.model.viewerID)
        .focusedSceneValue(\.viewerState, state)
        .alert("Something Went Wrong", isPresented: Binding(get: { state.model.lastError != nil }, set: { if !$0 { state.model.lastError = nil } })) {
            Button("OK") {}
        } message: { Text(state.model.lastError ?? "") }
        .onKeyPress(keys: ["c"]) { copyViewerImage($0, state: state) }
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            if !state.controlsVisible { state.controlsVisible = true }
            if Date().timeIntervalSince(lastInteraction) > 0.25 { lastInteraction = .now }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                if Date().timeIntervalSince(lastInteraction) > 2.5 && !overControls && !state.settingsPresented {
                    if state.controlsVisible {
                        state.controlsVisible = false
                        NSCursor.setHiddenUntilMouseMoves(true)
                    }
                }
                guard state.slideshow, !state.paused, !state.settingsPresented else { continue }
                let isVideo = state.model.viewerID.flatMap(state.model.item)?.isVideo == true
                if isVideo {
                    state.videoStalledElapsed += 0.25
                    if state.videoStalledElapsed >= 30 { state.step(1); state.videoStalledElapsed = 0; continue }
                }
                guard !isVideo || state.limitVideos else { continue }
                state.elapsed += 0.25
                if state.elapsed >= state.interval { state.elapsed = 0; state.step(1) }
            }
        }
    }
}

struct ViewerSlideshowSettings: View {
    @Bindable var state: ViewerState
    var body: some View {
        Form {
            Text("Slideshow Settings").font(.headline)
            Picker("Interval", selection: $state.interval) {
                ForEach([2.0, 3, 5, 10, 15, 30], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
            }
            Toggle("Shuffle", isOn: $state.shuffle)
            Toggle("Fade Transition", isOn: $state.fade)
            Toggle("Limit Videos to Slide Interval", isOn: $state.limitVideos)
            Text("Videos otherwise play to the end. Space pauses or resumes playback.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 320)
    }
}
