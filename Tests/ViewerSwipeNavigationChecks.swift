// swiftc -parse-as-library ImmichGallery/Views/Viewer/ViewerSwipeNavigation.swift ImmichGallery/Views/Viewer/ViewerScrollPan.swift Tests/ViewerSwipeNavigationChecks.swift -o build/check-viewer-swipe && build/check-viewer-swipe
import AppKit

@main struct ViewerSwipeNavigationChecks {
    /// Synthetic AppKit scroll event; a physical trackpad gesture still needs manual checking.
    final class ScrollEvent: NSEvent {
        weak var targetWindow: NSWindow?
        var location = CGPoint(x: 100, y: 100)
        var delta = CGSize.zero
        var gesturePhase: NSEvent.Phase = []
        var momentum: NSEvent.Phase = []
        var precise = true
        var inverted = false
        var time: TimeInterval = 0
        override var type: NSEvent.EventType { .scrollWheel }
        override var window: NSWindow? { targetWindow }
        override var locationInWindow: NSPoint { location }
        override var scrollingDeltaX: CGFloat { delta.width }
        override var scrollingDeltaY: CGFloat { delta.height }
        override var phase: NSEvent.Phase { gesturePhase }
        override var momentumPhase: NSEvent.Phase { momentum }
        override var hasPreciseScrollingDeltas: Bool { precise }
        override var isDirectionInvertedFromDevice: Bool { inverted }
        override var timestamp: TimeInterval { time }
    }

    @MainActor static var clock: TimeInterval = 0

    @MainActor static func event(_ window: NSWindow?, _ dx: CGFloat, _ dy: CGFloat = 0,
                                 phase: NSEvent.Phase = [], momentum: NSEvent.Phase = [],
                                 precise: Bool = true) -> ScrollEvent {
        clock += 0.01
        let event = ScrollEvent()
        event.targetWindow = window
        event.delta = CGSize(width: dx, height: dy)
        event.gesturePhase = phase
        event.momentum = momentum
        event.precise = precise
        event.time = clock
        return event
    }

    /// Feeds a full gesture and returns how many events were consumed.
    @MainActor @discardableResult
    static func swipe(_ view: ViewerSwipeNavigation.SwipeView, _ window: NSWindow?, steps: [(CGFloat, CGFloat)],
                      end: NSEvent.Phase = .ended, momentum: [(CGFloat, CGFloat)] = []) -> Int {
        var consumed = 0
        for (index, step) in steps.enumerated() {
            let e = event(window, step.0, step.1, phase: index == 0 ? .began : .changed)
            if view.handleScroll(e) == nil { consumed += 1 }
        }
        if view.handleScroll(event(window, 0, 0, phase: end)) == nil { consumed += 1 }
        for (index, step) in momentum.enumerated() {
            let phase: NSEvent.Phase = index == 0 ? .began : index == momentum.count - 1 ? .ended : .changed
            if view.handleScroll(event(window, step.0, step.1, momentum: phase)) == nil { consumed += 1 }
        }
        return consumed
    }

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        window.contentView = container
        let view = ViewerSwipeNavigation.SwipeView(frame: container.bounds)
        container.addSubview(view)
        var active = true
        var pageSwipe = true
        var current = true
        var steps: [Int] = []
        view.isEnabled = true
        view.isCurrent = { current }
        view.isWindowActive = { _ in active }
        view.pageSwipeEnabled = { pageSwipe }
        view.onNavigate = { steps.append($0) }
        let horizontal: [(CGFloat, CGFloat)] = [(-6, 0), (-12, 1), (-20, -1), (-15, 0)]

        // Fingers left with natural scrolling yield negative deltas: the next photo slides in.
        let consumed = swipe(view, window, steps: horizontal, momentum: [(-30, 0), (-20, 0), (-5, 0)])
        precondition(steps == [1], "One completed horizontal swipe moves exactly one photo forward")
        precondition(consumed == 3 + 1 + 3, "After claiming, the rest of the gesture and its momentum are swallowed")
        swipe(view, window, steps: horizontal.map { (-$0.0, $0.1) })
        precondition(steps == [1, -1], "Positive deltas move to the previous photo")

        // Direction comes from the deltas, which already reflect the scroll direction setting.
        let invertedStart = event(window, 10, 0, phase: .began)
        invertedStart.inverted = true
        _ = view.handleScroll(invertedStart)
        _ = view.handleScroll(event(window, 40, 0, phase: .changed))
        _ = view.handleScroll(event(window, 0, 0, phase: .ended))
        precondition(steps == [1, -1, -1], "isDirectionInvertedFromDevice must not flip the delta direction again")

        swipe(view, window, steps: [(-5, 0), (-10, 0), (-6, 0)])
        precondition(steps.count == 3, "A short swipe must not navigate")
        let cancelled = swipe(view, window, steps: horizontal, end: .cancelled)
        precondition(steps.count == 3 && cancelled == 4, "A cancelled swipe is swallowed without navigating")

        // A momentum-only stream (no new gesture) never navigates or is swallowed.
        let stray = event(window, -80, 0, momentum: .began)
        precondition(view.handleScroll(stray) === stray && steps.count == 3, "Momentum alone must not navigate")
        precondition(view.handleScroll(event(window, -80, 0, momentum: .ended)) != nil)

        // Vertical scrolling at fit passes through without navigating.
        let verticalStart = event(window, 1, -6, phase: .began)
        precondition(view.handleScroll(verticalStart) === verticalStart)
        let vertical = event(window, -2, -20, phase: .changed)
        precondition(view.handleScroll(vertical) === vertical, "Vertical scrolling passes through")
        let lateHorizontal = event(window, -80, 0, phase: .changed)
        precondition(view.handleScroll(lateHorizontal) === lateHorizontal, "Once vertical, the gesture remains vertical")
        precondition(view.handleScroll(event(window, 0, 0, phase: .ended)) != nil)
        let verticalMomentum = event(window, 0, -40, momentum: .began)
        precondition(view.handleScroll(verticalMomentum) === verticalMomentum, "Vertical momentum passes through")
        _ = view.handleScroll(event(window, 0, 0, momentum: .ended))
        swipe(view, window, steps: [(-30, -25), (-30, -25)])
        precondition(steps.count == 3, "Diagonal swipes are not navigation")

        // Traditional mouse wheels and unphased scrolling are never consumed.
        let wheel = event(window, -80, 0, precise: false)
        precondition(view.handleScroll(wheel) === wheel && steps.count == 3, "Mouse wheel scrolling is untouched")
        let unphased = event(window, -80, 0)
        precondition(view.handleScroll(unphased) === unphased, "Unphased precise scrolling is untouched")

        // Native "Swipe between pages" off: two-finger horizontal scrolls pass through.
        pageSwipe = false
        precondition(swipe(view, window, steps: horizontal) == 0 && steps.count == 3, "Respect the Swipe between pages setting")
        pageSwipe = true

        // Zoomed photos (and videos) disable the swipe; the gesture belongs to ViewerScrollPan.
        view.isEnabled = false
        precondition(swipe(view, window, steps: horizontal) == 0 && steps.count == 3, "Zoomed or video viewers keep scroll events")
        view.isEnabled = true
        _ = view.handleScroll(event(window, -20, 0, phase: .began))
        view.isEnabled = false
        _ = view.handleScroll(event(window, -40, 0, phase: .changed))
        view.isEnabled = true
        let afterZoom = event(window, -40, 0, phase: .changed)
        precondition(view.handleScroll(afterZoom) === afterZoom, "Zooming mid-gesture abandons the swipe")
        _ = view.handleScroll(event(window, 0, 0, phase: .ended))
        precondition(steps.count == 3)

        // Inactive window, other windows, outside the viewport and replaced viewers.
        active = false
        precondition(swipe(view, window, steps: horizontal) == 0 && steps.count == 3, "Inactive windows don't navigate")
        active = true
        precondition(swipe(view, nil, steps: horizontal) == 0 && steps.count == 3, "Ignore another window's events")
        let outside = event(window, -20, 0, phase: .began)
        outside.location = CGPoint(x: 400, y: 100)
        precondition(view.handleScroll(outside) === outside, "Ignore scrolling outside the photo viewport")
        current = false
        precondition(swipe(view, window, steps: horizontal) == 0 && steps.count == 3, "A fading-out viewer leaves the gesture alone")
        current = true

        // The photo shown after a swipe still swallows that gesture's momentum.
        _ = swipe(view, window, steps: horizontal)
        precondition(steps.count == 4)
        let next = ViewerSwipeNavigation.SwipeView(frame: container.bounds)
        next.isEnabled = true
        next.isCurrent = { true }
        next.isWindowActive = { _ in true }
        next.pageSwipeEnabled = { true }
        next.onNavigate = { steps.append($0) }
        current = false
        container.addSubview(next)
        let carried = event(window, -60, 0, momentum: .began)
        precondition(view.handleScroll(carried) === carried, "The replaced photo ignores the event")
        precondition(next.handleScroll(carried) == nil, "Momentum after a swipe is swallowed by the new photo")
        precondition(next.handleScroll(event(window, -10, 0, momentum: .ended)) == nil && steps.count == 4,
                     "Momentum never adds another photo change")

        // The same event delivered to two monitors is processed once.
        current = true
        let first = event(window, -20, 0, phase: .began)
        _ = view.handleScroll(first)
        _ = next.handleScroll(first)
        let middle = event(window, -40, 0, phase: .changed)
        _ = view.handleScroll(middle)
        _ = next.handleScroll(middle)
        let ending = event(window, 0, 0, phase: .ended)
        precondition(view.handleScroll(ending) == nil && next.handleScroll(ending) == nil)
        precondition(steps.count == 5, "Duplicate monitors must not navigate twice")
        next.removeFromSuperview()
        next.stopMonitoring()

        // Detached viewers stop handling scrolling.
        view.removeFromSuperview()
        precondition(swipe(view, window, steps: horizontal) == 0 && steps.count == 5, "Detached viewers must not navigate")
        view.stopMonitoring()

        // Zoomed panning keeps working exactly as before at the same time.
        let pan = ViewerScrollPan.ScrollPanView(frame: container.bounds)
        container.addSubview(pan)
        var panned: [CGSize] = []
        pan.isEnabled = true
        pan.onScroll = { panned.append($0) }
        let zoomed = event(window, -12.5, 24, phase: .changed)
        precondition(pan.handleScroll(zoomed) == nil && panned == [CGSize(width: -12.5, height: 24)],
                     "ViewerScrollPan still pans both axes when zoomed")
        pan.stopMonitoring()
        window.orderOut(nil)
        print("Viewer swipe navigation checks passed")
    }
}
