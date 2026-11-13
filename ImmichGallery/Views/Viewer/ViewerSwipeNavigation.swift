import AppKit
import SwiftUI

/// Recognises a completed, mostly horizontal two-finger trackpad swipe as one step to the
/// previous or next photo. Deltas already follow the user's scroll direction setting, so the
/// photo moves with the content like any horizontal scroll view.
struct ViewerSwipeTracker {
    enum Decision: Equatable {
        case pass, consume
        case navigate(Int)
    }

    static let claimDistance: CGFloat = 8
    static let navigateDistance: CGFloat = 40
    static let dominance: CGFloat = 1.5

    private enum State: Equatable {
        case idle
        case tracking(CGSize)
        case claimed(CGSize)
        case passing
        /// The gesture was ours: swallow what remains of it, including momentum.
        case finished
    }

    private var state = State.idle

    /// While a swipe is ours, how far it has gone across, for the photos to follow the fingers.
    var dragWidth: CGFloat? {
        if case .claimed(let total) = state { total.width } else { nil }
    }

    mutating func reset() { state = .idle }

    private static func isHorizontal(_ total: CGSize, beyond distance: CGFloat) -> Bool {
        abs(total.width) >= distance && abs(total.width) >= dominance * abs(total.height)
    }

    mutating func handle(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, delta: CGSize,
                         hasPreciseDeltas: Bool, pageSwipeEnabled: Bool) -> Decision {
        // Mouse wheels and other unphased scrolling keep their normal behaviour.
        guard hasPreciseDeltas, !(phase.isEmpty && momentumPhase.isEmpty) else { return .pass }
        if !momentumPhase.isEmpty {
            let swallow = state == .finished
            if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) { state = .idle }
            return swallow ? .consume : .pass
        }
        if phase.contains(.mayBegin) { state = .idle; return .pass }
        if phase.contains(.began) {
            state = pageSwipeEnabled ? .tracking(.zero) : .passing
        }
        switch state {
        case .idle, .passing:
            if phase.contains(.ended) || phase.contains(.cancelled) { state = .idle }
            return .pass
        case .finished:
            return .consume
        case .tracking(let total):
            let total = CGSize(width: total.width + delta.width, height: total.height + delta.height)
            if phase.contains(.ended) || phase.contains(.cancelled) { state = .idle; return .pass }
            if Self.isHorizontal(total, beyond: Self.claimDistance) { state = .claimed(total); return .consume }
            state = abs(total.height) >= Self.claimDistance ? .passing : .tracking(total)
            return .pass
        case .claimed(let total):
            let total = CGSize(width: total.width + delta.width, height: total.height + delta.height)
            if phase.contains(.cancelled) { state = .idle; return .consume }
            guard phase.contains(.ended) else { state = .claimed(total); return .consume }
            state = .finished
            guard Self.isHorizontal(total, beyond: Self.navigateDistance) else { return .consume }
            return .navigate(total.width > 0 ? -1 : 1)
        }
    }
}

/// Local scroll monitor for the photo viewport at fit. Zoomed panning stays in `ViewerScrollPan`.
struct ViewerSwipeNavigation: NSViewRepresentable {
    let isEnabled: Bool
    let isCurrent: () -> Bool
    let onNavigate: (Int) -> Void
    /// Following the fingers: how far the swipe has gone, then, when it ends, the step it makes (nil to spring back).
    /// Without them a swipe steps when it ends.
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: ((Int?) -> Void)?

    func makeNSView(context: Context) -> SwipeView { SwipeView() }

    func updateNSView(_ view: SwipeView, context: Context) {
        view.isEnabled = isEnabled
        view.isCurrent = isCurrent
        view.onNavigate = onNavigate
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
    }

    static func dismantleNSView(_ view: SwipeView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class SwipeView: NSView {
        /// Shared so the photo that appears after a swipe still swallows that gesture's momentum.
        static var tracker = ViewerSwipeTracker()
        private static var lastEvent: (id: ObjectIdentifier, time: TimeInterval, result: Bool)?

        var isEnabled = false
        var isCurrent: () -> Bool = { false }
        var onNavigate: ((Int) -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        var onDragEnd: ((Int?) -> Void)?
        var isWindowActive: (NSWindow) -> Bool = { NSApp.isActive && $0.isKeyWindow }
        var pageSwipeEnabled: () -> Bool = { NSEvent.isSwipeTrackingFromScrollEventsEnabled }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handleScroll(event)
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        func handleScroll(_ event: NSEvent) -> NSEvent? {
            // A replaced viewer fading out leaves the gesture to the current one.
            guard let window, event.window === window, isCurrent() else { return event }
            guard isEnabled, isWindowActive(window),
                  visibleRect.contains(convert(event.locationInWindow, from: nil))
            else {
                // A swipe the photos were following, dropped (the pointer left the photo, the window went to the
                // back, a zoom): they go back.
                if Self.tracker.dragWidth != nil { onDragEnd?(nil) }
                Self.tracker.reset()
                return event
            }
            let id = ObjectIdentifier(event)
            if let last = Self.lastEvent, last.id == id, last.time == event.timestamp {
                return last.result ? nil : event
            }
            let wasDragging = Self.tracker.dragWidth != nil
            let decision = Self.tracker.handle(phase: event.phase, momentumPhase: event.momentumPhase,
                                               delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
                                               hasPreciseDeltas: event.hasPreciseScrollingDeltas,
                                               pageSwipeEnabled: pageSwipeEnabled())
            Self.lastEvent = (id, event.timestamp, decision != .pass)
            if let onDragEnd {
                if case .navigate(let delta) = decision {
                    onDragEnd(delta)
                } else if let width = Self.tracker.dragWidth {
                    onDrag?(width)
                } else if wasDragging {
                    onDragEnd(nil) // Too short, or cancelled: back to the photo.
                }
                return decision == .pass ? event : nil
            }
            switch decision {
            case .pass: return event
            case .consume: return nil
            case .navigate(let delta):
                onNavigate?(delta)
                return nil
            }
        }
    }
}
