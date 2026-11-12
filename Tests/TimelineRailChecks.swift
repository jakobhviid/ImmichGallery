// swiftc -parse-as-library ImmichGallery/App/TimelineRailLayout.swift Tests/TimelineRailChecks.swift -o build/check-timeline-rail && build/check-timeline-rail
import Foundation

@main struct TimelineRailChecks {
    static func main() {
        typealias L = TimelineRailLayout
        precondition(L.isMonth("2024-03-01T00:00:00.000Z"))
        precondition(L.isMonth("2024-03-01"))
        precondition(!L.isMonth("results"))
        precondition(!L.isMonth("2024"))

        let months: [L.Month] = [.init(id: "2024-03-01T00:00:00.000Z", count: 8), .init(id: "2024-01-01T00:00:00.000Z", count: 4),
                                 .init(id: "2023-12-01T00:00:00.000Z", count: 2), .init(id: "2021-06-01T00:00:00.000Z", count: 6)]
        // Four columns, rows of 10 and headers of 20: heights 40, 30, 30, 40 of 140.
        let fractions = L.fractions(months, columns: 4, rowHeight: 10, headerHeight: 20)
        precondition(fractions == [0, 40.0 / 140, 70.0 / 140, 100.0 / 140])
        precondition(L.fractions([], columns: 4, rowHeight: 10, headerHeight: 20).isEmpty)
        precondition(L.fractions([.init(id: "2024-01-01", count: 0)], columns: 0, rowHeight: 10, headerHeight: 0) == [0])

        // A year is labelled at its first month; one too close to the label above is left out.
        let tall = L.yearMarks(months, fractions: fractions, height: 1400, spacing: 18)
        precondition(tall.map(\.year) == ["2024", "2023", "2021"])
        precondition(tall.map(\.month) == [0, 2, 3])
        let short = L.yearMarks(months, fractions: fractions, height: 50, spacing: 18)
        precondition(short.map(\.year) == ["2024", "2023"])

        // A point stands for the month that starts at or above it.
        precondition(L.month(at: 0, fractions: fractions) == 0)
        precondition(L.month(at: 0.3, fractions: fractions) == 1)
        precondition(L.month(at: 0.99, fractions: fractions) == 3)
        precondition(L.month(at: -1, fractions: fractions) == 0)
        precondition(L.month(at: 0.5, fractions: []) == nil)
        print("Timeline rail checks passed.")
    }
}
