import SwiftUI

/// Exactly one view per grid cell, whatever its content. A cell whose content may be zero or several views (a
/// `Group` with `if #available` inside an `if`) makes a lazy grid build every cell before the one
/// `ScrollViewProxy.scrollTo` looks for, to count its views: zooming, which keeps the first visible photo in place,
/// took seconds deep in a large library. A layout container is statically one view; a custom `View` wrapping one
/// isn't, so this returns the `ZStack` itself.
func gridCell<Content: View>(@ViewBuilder _ content: () -> Content) -> ZStack<Content> {
    ZStack(content: content)
}
