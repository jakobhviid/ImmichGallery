import Foundation

/// The date scroller beside the grid: where each month falls on it, which years it labels, and which month a point on
/// it stands for. Positions are fractions of the grid's height, worked out from each month's photo count, so months
/// that haven't loaded yet take their place like loaded ones.
enum TimelineRailLayout {
    struct Month: Equatable {
        /// The timeline bucket, "2024-03-01T00:00:00.000Z".
        let id: String
        let count: Int
    }

    struct YearMark: Equatable {
        let year: String
        /// The year's first month in the grid's order.
        let month: Int
        let fraction: Double
    }

    /// Only the timeline's month sections have dates; search results and the like don't get a scroller.
    static func isMonth(_ id: String) -> Bool {
        id.count >= 7 && id.prefix(7).enumerated().allSatisfy { index, character in
            index == 4 ? character == "-" : character.isASCII && character.isNumber
        }
    }

    /// Each month's top, as a fraction of the grid: the months before it, each a header and rows of `columns` photos.
    static func fractions(_ months: [Month], columns: Int, rowHeight: Double, headerHeight: Double) -> [Double] {
        let columns = max(1, columns)
        var tops: [Double] = []
        var total = 0.0
        for month in months {
            tops.append(total)
            let rows = (month.count + columns - 1) / columns
            total += headerHeight + Double(rows) * rowHeight
        }
        guard total > 0 else { return months.map { _ in 0 } }
        return tops.map { $0 / total }
    }

    /// The years to label, at their first month, leaving out a year that would crowd the one labelled before it.
    static func yearMarks(_ months: [Month], fractions: [Double], height: Double, spacing: Double) -> [YearMark] {
        var marks: [YearMark] = []
        var lastYear: Substring?
        for (index, month) in months.enumerated() where index < fractions.count {
            let year = month.id.prefix(4)
            guard year != lastYear else { continue }
            lastYear = year
            if let previous = marks.last, (fractions[index] - previous.fraction) * height < spacing { continue }
            marks.append(YearMark(year: String(year), month: index, fraction: fractions[index]))
        }
        return marks
    }

    /// The month at a point on the scroller: the last one that starts at or above it.
    static func month(at fraction: Double, fractions: [Double]) -> Int? {
        guard !fractions.isEmpty else { return nil }
        return fractions.lastIndex { $0 <= fraction } ?? 0
    }
}
