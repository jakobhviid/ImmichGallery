import SwiftUI

/// Where the grid has scrolled to, for the date scroller: the first month in view, and how far into it. Apart from the
/// grid, so scrolling redraws only the scroller. From the grid's own months rather than its scroll offset, so after a
/// jump the mark is on the month jumped to, where the scroller places it.
@MainActor @Observable final class TimelineRailPosition {
    var month: String?
    /// How far into `month` the first photo in view is, from 0 to 1.
    var progress = 0.0
}

/// The date scroller beside the grid, as Immich's web app has one: the years down the side, placed where their photos
/// are, a mark where the grid is, and the month under the pointer. Clicking or dragging goes to that month. View >
/// Hide Date Scroller turns it off.
struct TimelineRail: View {
    static let width: CGFloat = 46
    /// The scroller with room between it and the photos; it can sit near the window's edge.
    static let inset = width + 18
    static let shownKey = "grid.showsDateScroller"
    /// The least room between two years' labels.
    static let labelSpacing = 34.0
    /// A month section's header, as `SectionHeader` draws it.
    static let headerHeight = 50.0

    let sections: [GridSection]
    let columns: Int
    let rowHeight: Double
    let position: TimelineRailPosition
    let jump: (GridSection) -> Void

    @State private var pointer: CGFloat?
    @State private var lastJump: Int?

    var body: some View {
        let months = sections.map { TimelineRailLayout.Month(id: $0.id, count: $0.count) }
        let fractions = TimelineRailLayout.fractions(months, columns: columns, rowHeight: rowHeight, headerHeight: Self.headerHeight)
        GeometryReader { geo in
            let height = max(1, geo.size.height)
            let marks = TimelineRailLayout.yearMarks(months, fractions: fractions, height: height, spacing: Self.labelSpacing)
            let mark = markFraction(fractions)
            ZStack {
                Canvas { context, size in
                    // A tick for each month, and a longer one where a year starts.
                    let starts = Set(marks.map(\.month))
                    for (index, fraction) in fractions.enumerated() {
                        let length: CGFloat = starts.contains(index) ? 7 : 3
                        let rect = CGRect(x: size.width - length - 2, y: fraction * size.height, width: length, height: 1)
                        context.fill(Path(rect), with: .color(.secondary.opacity(starts.contains(index) ? 0.7 : 0.35)))
                    }
                }
                ForEach(marks, id: \.month) { mark in
                    Text(verbatim: mark.year)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .position(x: geo.size.width / 2 - 5, y: labelY(mark, height: height))
                }
                Capsule()
                    .fill(.tint)
                    .frame(width: 14, height: 2)
                    .position(x: geo.size.width - 9, y: min(max(mark * height, 1), height - 1))
                if let pointer, let index = TimelineRailLayout.month(at: pointer / height, fractions: fractions),
                   let title = sections[index].title {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: .capsule)
                        .fixedSize()
                        // Out to the left, over the photos, beside the pointer.
                        .frame(width: geo.size.width, alignment: .trailing)
                        .offset(x: -18)
                        .position(x: geo.size.width / 2, y: min(max(pointer, 10), height - 10))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): pointer = location.y
                case .ended: pointer = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        pointer = value.location.y
                        go(to: value.location.y, height: height, fractions: fractions, marks: marks)
                    }
                    .onEnded { _ in lastJump = nil }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Date Scroller"))
            .accessibilityValue(Text(TimelineRailLayout.month(at: mark, fractions: fractions).flatMap { sections[$0].title } ?? ""))
            .accessibilityAdjustableAction { direction in
                // A year at a time, down the grid or back up.
                let current = TimelineRailLayout.month(at: mark, fractions: fractions) ?? 0
                let target = direction == .increment
                    ? marks.first { $0.month > current }?.month
                    : marks.last { $0.month < current }?.month
                if let target { jump(sections[target]) }
            }
        }
        .frame(width: Self.width)
        .padding(.leading, 16)
        .padding(.trailing, 2)
    }

    /// The year label at `y`, drawn just below its year's first month.
    private func labelY(_ mark: TimelineRailLayout.YearMark, height: Double) -> Double {
        min(max(mark.fraction * height + 8, 8), height - 8)
    }

    /// Where the mark goes: the first month in view, as far into it as the grid is.
    private func markFraction(_ fractions: [Double]) -> Double {
        guard let month = position.month, let index = sections.firstIndex(where: { $0.id == month }) else { return 0 }
        let next = index + 1 < fractions.count ? fractions[index + 1] : 1
        return fractions[index] + (next - fractions[index]) * min(1, max(0, position.progress))
    }

    /// A year's label goes to its first month; elsewhere, to the month under the pointer.
    private func go(to y: Double, height: Double, fractions: [Double], marks: [TimelineRailLayout.YearMark]) {
        let label = marks.first { abs(labelY($0, height: height) - y) <= 9 }
        guard let index = label?.month ?? TimelineRailLayout.month(at: y / height, fractions: fractions),
              index != lastJump else { return }
        lastJump = index
        jump(sections[index])
    }
}
