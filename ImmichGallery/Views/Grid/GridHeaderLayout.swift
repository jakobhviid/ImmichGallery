import SwiftUI

extension View {
    /// Keep custom grid controls inside the inspector's content host so their inset is preserved.
    @ViewBuilder
    func gridHeader<Header: View>(_ header: Header, shown: Bool = true) -> some View {
        if Header.self == EmptyView.self || !shown {
            self
        } else if #available(macOS 26, *) {
            safeAreaBar(edge: .top, spacing: 0) { header }
        } else {
            safeAreaInset(edge: .top, spacing: 0) { header.background(.bar) }
        }
    }
}
