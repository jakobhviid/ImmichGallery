import AppKit
import SwiftUI

/// The grid squares' places on the page, for the open photo to fly out of and back into. Not observed: the squares
/// report as they scroll, and only the motion reads them.
final class ViewerCellFrames {
    static let space = "viewerMotion"
    var frames: [String: CGRect] = [:]
}

/// A grid square's place and the photo in it, as it reports them.
struct ViewerCellFrame: Equatable {
    let id: String?
    let frame: CGRect
}

/// The open photo's zoom out of its grid square into the viewer and back, as Photos has it. It runs once, from its
/// start to `done`. Sliding to the next photo is `ViewerSlider`'s.
struct ViewerMotion: Equatable {
    enum Kind: Equatable {
        /// The photo flies from `from` to `to`, opening (out of its square) or closing (back into it). Closing, the grid
        /// starts dimmed by `dim`: less after a pinch has let it show through.
        case flight(from: CGRect, to: CGRect, opening: Bool, dim: Double)
    }

    let id: String
    let kind: Kind
    let generation: Int
    var done = false

    var isFlight: Bool { true }
}

/// Sliding from one photo to the next, as in Photos, in Core Animation: pictures of the two photos move on layers of
/// one AppKit view that stays for as long as a photo is open, while SwiftUI swaps the photo underneath without
/// animating. Nothing is laid out while they move. Sliding SwiftUI views instead, while the photo underneath was
/// replaced, made AppKit's layout loop (an endless Update Constraints pass) and throw. A trackpad swipe moves the same
/// layers with the fingers, then finishes the step or springs back.
@MainActor final class ViewerSlider {
    fileprivate weak var view: ViewerSlideLayerView?
    /// A swipe has finished its step on the layers: the photo it swaps to doesn't slide again.
    private var swipedTo: String?

    /// The next photo comes in from the side of `direction` (1: the right) as `outgoing` leaves the other way.
    func slide(from outgoing: CGImage, to incoming: CGImage, direction: Int, toID: String) {
        if swipedTo == toID { swipedTo = nil; return }
        view?.slide(from: outgoing, to: incoming, direction: direction)
    }

    /// The photos follow a swipe `width` across: the open one, and its neighbour on the side it uncovers.
    func drag(_ width: CGFloat, current: CGImage, previous: CGImage?, next: CGImage?) {
        view?.drag(width, current: current, previous: previous, next: next)
    }

    /// The swipe ended: the step to `toID` in `direction`, or back to the photo.
    func endDrag(direction: Int?, toID: String?) {
        swipedTo = direction == nil ? nil : toID
        view?.endDrag(direction: direction)
    }
}

/// `ViewerSlider`'s view: hidden, and passing clicks through, but while photos slide.
struct ViewerSlideLayer: NSViewRepresentable {
    let slider: ViewerSlider

    func makeNSView(context: Context) -> ViewerSlideLayerView {
        let view = ViewerSlideLayerView()
        slider.view = view
        return view
    }

    func updateNSView(_ view: ViewerSlideLayerView, context: Context) { slider.view = view }
}

final class ViewerSlideLayerView: NSView {
    private let backdrop = CALayer()
    /// The photo leaving, or the open one under a swipe.
    private let currentLayer = CALayer()
    /// The photo coming in.
    private let incomingLayer = CALayer()
    private var generation = 0
    private var dragging = false
    /// The side the swipe's neighbour comes from: 1 the right (the next photo), -1 the left.
    private var dragSide = 0
    /// The gap between two photos as they slide, as in Photos.
    private static let gap: CGFloat = 40
    private static let timing = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.3, 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for photo in [currentLayer, incomingLayer] {
            photo.contentsGravity = .resizeAspect
            photo.minificationFilter = .trilinear
            // As `HDRImageLayer`: an HDR photo slides as bright as the viewer shows it.
            if #available(macOS 26, *) {
                photo.preferredDynamicRange = .high
            } else {
                photo.wantsExtendedDynamicRangeContent = true
            }
        }
        layer?.addSublayer(backdrop)
        layer?.addSublayer(currentLayer)
        layer?.addSublayer(incomingLayer)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var middle: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var span: CGFloat { bounds.width + Self.gap }

    func slide(from outgoing: CGImage, to incoming: CGImage, direction: Int) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        dragging = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        show(current: outgoing)
        finish()
        incomingLayer.contents = incoming
        incomingLayer.isHidden = false
        let distance = span * CGFloat(direction)
        move(currentLayer, from: middle, to: CGPoint(x: middle.x - distance, y: middle.y), duration: 0.3)
        move(incomingLayer, from: CGPoint(x: middle.x + distance, y: middle.y), to: middle, duration: 0.3)
        CATransaction.commit()
    }

    func drag(_ width: CGFloat, current: CGImage, previous: CGImage?, next: CGImage?) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !dragging {
            dragging = true
            show(current: current)
        }
        // Moving right uncovers the previous photo, on the left; moving left the next one.
        let side = width > 0 ? -1 : 1
        let neighbour = side < 0 ? previous : next
        // Past the first or the last photo, the photo gives a little and springs back.
        let offset = neighbour == nil ? width / 3 : width
        currentLayer.removeAllAnimations()
        incomingLayer.removeAllAnimations()
        currentLayer.position = CGPoint(x: middle.x + offset, y: middle.y)
        dragSide = neighbour == nil ? 0 : side
        incomingLayer.isHidden = neighbour == nil
        if let neighbour {
            incomingLayer.contents = neighbour
            incomingLayer.position = CGPoint(x: middle.x + offset + span * CGFloat(side), y: middle.y)
        }
        CATransaction.commit()
    }

    func endDrag(direction: Int?) {
        guard dragging else { return }
        dragging = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        finish()
        let current = currentLayer.presentation()?.position ?? currentLayer.position
        let incoming = incomingLayer.presentation()?.position ?? incomingLayer.position
        if let direction, direction == dragSide {
            let distance = span * CGFloat(direction)
            move(currentLayer, from: current, to: CGPoint(x: middle.x - distance, y: middle.y), duration: 0.25)
            move(incomingLayer, from: incoming, to: middle, duration: 0.25)
        } else {
            move(currentLayer, from: current, to: middle, duration: 0.25)
            move(incomingLayer, from: incoming, to: CGPoint(x: middle.x + span * CGFloat(dragSide), y: middle.y), duration: 0.25)
        }
        CATransaction.commit()
    }

    /// Over the photo underneath, the open photo where it is.
    private func show(current: CGImage) {
        generation += 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            backdrop.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        backdrop.frame = bounds
        for photo in [currentLayer, incomingLayer] {
            photo.removeAllAnimations()
            photo.bounds = CGRect(origin: .zero, size: bounds.size)
            photo.position = middle
        }
        currentLayer.contents = current
        incomingLayer.isHidden = true
        isHidden = false
    }

    /// Hides the layers when the animations added after it end, unless something newer has started. Set before the
    /// animations: Core Animation calls it at once when none are added after it, which hid the slide as it began.
    private func finish() {
        let current = generation
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == current, !self.dragging else { return }
            self.isHidden = true
            self.currentLayer.contents = nil
            self.incomingLayer.contents = nil
        }
    }

    private func move(_ photo: CALayer, from start: CGPoint, to end: CGPoint, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: start)
        animation.toValue = NSValue(point: end)
        animation.duration = duration
        animation.timingFunction = Self.timing
        photo.position = end
        photo.add(animation, forKey: "slide")
    }
}

/// Whether the pointer is over the page, for the open photo's side arrows: an AppKit tracking area on a view that stays
/// while photos change. SwiftUI's hover, on each photo's viewer, started out as not over it until the pointer moved,
/// and missed some moves. This one also asks where the pointer is whenever its area changes.
struct ViewerPointerTracking: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }

    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var isInside: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp,
                                                                  .inVisibleRect], owner: self))
            locatePointer()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            locatePointer()
        }

        override func mouseEntered(with event: NSEvent) { report(true) }
        override func mouseMoved(with event: NSEvent) { report(true) }
        override func mouseExited(with event: NSEvent) { report(false) }

        /// Where the pointer is, without waiting for it to move. After the layout pass that asked: the page's state
        /// can't change during one.
        private func locatePointer() {
            Task { @MainActor [weak self] in
                guard let self, let window = self.window else { return }
                self.report(self.visibleRect.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)))
            }
        }

        private func report(_ inside: Bool) {
            guard inside != isInside else { return }
            isInside = inside
            onChange?(inside)
        }
    }
}

/// A two-finger double-tap on the trackpad, Photos' smart zoom. It arrives as an AppKit event, not a SwiftUI gesture.
struct ViewerSmartZoom: NSViewRepresentable {
    let onSmartZoom: () -> Void

    func makeNSView(context: Context) -> SmartZoomView { SmartZoomView() }

    func updateNSView(_ view: SmartZoomView, context: Context) { view.onSmartZoom = onSmartZoom }

    static func dismantleNSView(_ view: SmartZoomView, coordinator: ()) { view.stopMonitoring() }

    final class SmartZoomView: NSView {
        var onSmartZoom: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .smartMagnify) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.onSmartZoom?()
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
