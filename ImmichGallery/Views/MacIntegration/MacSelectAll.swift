import AppKit
import SwiftUI

/// ⌘A selects every photo in the grid a window shows, wherever the window's focus is, as in Photos. The Edit menu's
/// Select All comes before Select All Photos and goes to the focused view, so with the sidebar focused (after opening
/// an album from it) ⌘A selected the sidebar's row instead. Text fields, sheets and dialogs keep the system's.
@MainActor
enum MacSelectAll {
    private final class Entry {
        weak var window: NSWindow?
        weak var model: AssetGridModel?
        var enabled = true
    }

    /// The grids shown in each window, the last one on top (a page opened from another).
    private static var entries: [Entry] = []
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    fileprivate static func register(_ model: AssetGridModel, in window: NSWindow, enabled: Bool) {
        entries.removeAll { $0.window == nil || $0.model == nil || $0.model === model }
        let entry = Entry()
        entry.window = window
        entry.model = model
        entry.enabled = enabled
        entries.append(entry)
    }

    fileprivate static func setEnabled(_ enabled: Bool, for model: AssetGridModel) {
        entries.first { $0.model === model }?.enabled = enabled
    }

    fileprivate static func unregister(_ model: AssetGridModel) {
        entries.removeAll { $0.model == nil || $0.model === model }
    }

    private static func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "a",
              let window = event.window, window.attachedSheet == nil,
              !(window.firstResponder is NSText),
              let entry = entries.last(where: { $0.window === window && $0.model != nil }),
              entry.enabled, let model = entry.model, model.viewerID == nil else { return false }
        model.selectAll()
        return true
    }
}

extension View {
    /// Makes this grid the one ⌘A selects in its window while it's on screen and `enabled` (not Years or Months).
    func selectAllTarget(_ model: AssetGridModel, enabled: Bool) -> some View {
        background(MacSelectAllRegistrar(model: model, enabled: enabled))
    }
}

private struct MacSelectAllRegistrar: NSViewRepresentable {
    let model: AssetGridModel
    let enabled: Bool

    func makeNSView(context: Context) -> RegistrarView { RegistrarView(model: model, enabled: enabled) }

    func updateNSView(_ view: RegistrarView, context: Context) {
        view.enabled = enabled
        MacSelectAll.setEnabled(enabled, for: model)
    }

    final class RegistrarView: NSView {
        let model: AssetGridModel
        var enabled: Bool

        init(model: AssetGridModel, enabled: Bool) {
            self.model = model
            self.enabled = enabled
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MacSelectAll.register(model, in: window, enabled: enabled) } else { MacSelectAll.unregister(model) }
        }
    }
}
