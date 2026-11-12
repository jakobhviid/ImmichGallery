import CoreGraphics

/// Where the open photo's motion starts and ends: the photo fitted in the viewer, its grid square as the grid shows it,
/// and the side the next photo comes in from.
enum ViewerMotionLayout {
    /// A photo of `ratio` (width over height) at its largest inside `rect`, centred, as `scaledToFit` draws it.
    static func fitted(_ ratio: Double, in rect: CGRect) -> CGRect {
        guard ratio > 0, rect.width > 0, rect.height > 0 else { return rect }
        let size = rect.width / rect.height > ratio
            ? CGSize(width: rect.height * ratio, height: rect.height)
            : CGSize(width: rect.width, height: rect.width / ratio)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// `rect` scaled about its centre: a photo pinched smaller before it closes.
    static func scaled(_ rect: CGRect, by scale: Double) -> CGRect {
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// How much of the viewer's backdrop stays as a photo is pinched smaller than it fits: all of it at fitted size,
    /// none by half, so the grid shows through as the photo shrinks towards it.
    static func backdrop(forPinch scale: Double) -> Double {
        min(1, max(0, (scale - 0.5) / 0.5))
    }

    /// A pinch that ends below this closes the photo.
    static let pinchCloseScale = 0.8

    /// Whether a grid square is on screen enough to fly into or out of.
    static func isShown(_ cell: CGRect, in bounds: CGRect) -> Bool {
        let shown = cell.intersection(bounds)
        return !shown.isNull && shown.width * shown.height >= cell.width * cell.height / 2
    }

    /// The side the next photo comes in from: 1 from the right, for one later in the grid; -1 from the left.
    static func direction(from old: (section: Int, item: Int), to new: (section: Int, item: Int)) -> Int {
        (new.section, new.item) > (old.section, old.item) ? 1 : -1
    }
}
