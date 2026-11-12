// swiftc -parse-as-library ImmichGallery/Views/Viewer/ViewerScrollPan.swift Tests/ViewerScrollPanChecks.swift -o build/check-viewer-scroll-pan && build/check-viewer-scroll-pan
import AppKit

@main struct ViewerScrollPanChecks {
    final class ScrollEvent: NSEvent {
        weak var targetWindow: NSWindow?
        var location = CGPoint(x: 100, y: 100)
        override var window: NSWindow? { targetWindow }
        override var locationInWindow: NSPoint { location }
        override var scrollingDeltaX: CGFloat { 12.5 }
        override var scrollingDeltaY: CGFloat { -24 }
    }

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = ViewerScrollPan.ScrollPanView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        window.contentView = view
        let event = ScrollEvent()
        event.targetWindow = window
        var deltas: [CGSize] = []
        view.onScroll = { deltas.append($0) }
        precondition(view.handleScroll(event) === event, "At 1×, scrolling must pass through")
        view.isEnabled = true
        precondition(view.handleScroll(event) == nil, "Zoomed photo must consume scrolling")
        precondition(deltas == [CGSize(width: 12.5, height: -24)], "Preserve both native scroll axes and direction")
        event.location = CGPoint(x: 400, y: 100)
        precondition(view.handleScroll(event) === event, "Ignore scrolling outside the viewer")
        event.location = CGPoint(x: 100, y: 100)
        event.targetWindow = nil
        precondition(view.handleScroll(event) === event, "Ignore another window's events")
        event.targetWindow = window
        view.isEnabled = false
        precondition(view.handleScroll(event) === event, "Zoom reset must restore normal scrolling")
        view.removeFromSuperview()
        view.isEnabled = true
        precondition(view.handleScroll(event) === event, "Detached viewers must not consume scrolling")
        precondition(deltas.count == 1, "Only the enabled viewer under the pointer may pan")
        view.stopMonitoring()
        window.orderOut(nil)
        print("Viewer scroll pan checks passed")
    }
}
