// swiftc ImmichGallery/App/LibraryOverviewArrangement.swift Tests/LibraryOverviewChecks.swift -o build/check-library-overview && build/check-library-overview
import Foundation

@main struct LibraryOverviewChecks {
    static func main() {
        typealias A = LibraryOverviewArrangement
        // Years keep the grid's order, and the card shows the fullest month (the first one on a tie).
        let years = A.years([("2024-03-01T00:00:00.000Z", 5), ("2024-01-01T00:00:00.000Z", 9), ("2023-12-01T00:00:00.000Z", 2),
                             ("2023-11-01T00:00:00.000Z", 2), ("results", 3)])
        precondition(years.map(\.id) == ["2024", "2023"])
        precondition(years[0].months == ["2024-03-01T00:00:00.000Z", "2024-01-01T00:00:00.000Z"])
        precondition(years[0].keyMonth == "2024-01-01T00:00:00.000Z")
        precondition(years[1].keyMonth == "2023-12-01T00:00:00.000Z")
        precondition(A.years([]).isEmpty)

        func date(_ day: Int, _ hour: Int = 12) -> Date {
            var components = DateComponents(year: 2024, month: 3, day: day, hour: hour)
            components.timeZone = TimeZone(identifier: "UTC")
            return Calendar(identifier: .gregorian).date(from: components)!
        }
        // One photo a day, the middle one, a still before a video, days in the grid's order.
        let photos: [A.Photo] = [
            .init(id: "a", date: date(20, 20), isVideo: false), .init(id: "b", date: date(20, 10), isVideo: false), .init(id: "c", date: date(20, 8), isVideo: false),
            .init(id: "v", date: date(9), isVideo: true), .init(id: "d", date: date(9), isVideo: false),
            .init(id: "w", date: date(3), isVideo: true),
        ]
        precondition(A.picks(photos) == [.init(id: "b", day: 20), .init(id: "d", day: 9), .init(id: "w", day: 3)])
        // More days than tiles: spread over the month, first and last included.
        let many = (1...10).reversed().map { A.Photo(id: "p\($0)", date: date($0), isVideo: false) }
        precondition(A.picks(many, limit: 4).map(\.day) == [10, 7, 4, 1])
        precondition(A.picks(many, limit: 1).map(\.day) == [10])
        precondition(A.picks([], limit: 4).isEmpty)
        precondition(A.picks(many, limit: 0).isEmpty)
        // Photos without a date still show.
        precondition(A.picks([.init(id: "x", date: nil, isVideo: false)]) == [.init(id: "x", day: nil)])
        print("Library overview checks passed: years, key months, day picks")
    }
}
