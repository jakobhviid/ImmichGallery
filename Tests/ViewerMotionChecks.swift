// swiftc -parse-as-library ImmichGallery/App/ViewerMotionLayout.swift Tests/ViewerMotionChecks.swift -o build/check-viewer-motion && build/check-viewer-motion
import CoreGraphics
import Foundation

@main struct ViewerMotionChecks {
    static func main() {
        typealias L = ViewerMotionLayout
        let viewer = CGRect(x: 0, y: 0, width: 1000, height: 500)
        // A wide photo fills the width; a tall one the height; both centred.
        precondition(L.fitted(4, in: viewer) == CGRect(x: 0, y: 125, width: 1000, height: 250))
        precondition(L.fitted(0.5, in: viewer) == CGRect(x: 375, y: 0, width: 250, height: 500))
        precondition(L.fitted(1, in: CGRect(x: 10, y: 20, width: 100, height: 100)) == CGRect(x: 10, y: 20, width: 100, height: 100))
        precondition(L.fitted(0, in: viewer) == viewer)

        precondition(L.scaled(CGRect(x: 0, y: 0, width: 100, height: 50), by: 0.5) == CGRect(x: 25, y: 12.5, width: 50, height: 25))

        // A square at least half on screen counts as shown.
        precondition(L.isShown(CGRect(x: 10, y: 10, width: 100, height: 100), in: viewer))
        precondition(L.isShown(CGRect(x: -40, y: 10, width: 100, height: 100), in: viewer))
        precondition(!L.isShown(CGRect(x: -60, y: 10, width: 100, height: 100), in: viewer))
        precondition(!L.isShown(CGRect(x: 0, y: 900, width: 100, height: 100), in: viewer))

        // The backdrop fades from fitted size to half, and stays faded below.
        precondition(L.backdrop(forPinch: 1) == 1)
        precondition(L.backdrop(forPinch: 1.2) == 1)
        precondition(L.backdrop(forPinch: 0.75) == 0.5)
        precondition(L.backdrop(forPinch: 0.4) == 0)

        precondition(L.direction(from: (0, 3), to: (0, 4)) == 1)
        precondition(L.direction(from: (1, 0), to: (0, 9)) == -1)
        precondition(L.direction(from: (0, 9), to: (1, 0)) == 1)
        print("Viewer motion checks passed.")
    }
}
