import Foundation

/// Library's Years, Months and All Photos, as in Photos.
enum LibraryMode: String, CaseIterable, Identifiable {
    case years, months, all
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .years: "Years"
        case .months: "Months"
        case .all: "All Photos"
        }
    }
}

/// What Years and Months show, from the timeline's month buckets ("2024-03-01T00:00:00.000Z") in the grid's order.
enum LibraryOverviewArrangement {
    struct Year: Identifiable, Equatable {
        let id: String
        /// The year's months, in the grid's order.
        let months: [String]
        /// The month the year's card shows a photo from: its fullest.
        let keyMonth: String
    }

    struct Photo: Equatable {
        let id: String
        let date: Date?
        let isVideo: Bool
    }

    struct Pick: Equatable {
        let id: String
        let day: Int?
    }

    static func years(_ months: [(id: String, count: Int)]) -> [Year] {
        var order: [String] = []
        var byYear: [String: [(id: String, count: Int)]] = [:]
        for month in months {
            let year = String(month.id.prefix(4))
            guard year.count == 4, Int(year) != nil else { continue }
            if byYear[year] == nil { order.append(year) }
            byYear[year, default: []].append(month)
        }
        return order.map { year in
            let months = byYear[year]!
            // The first of the fullest months, so a tie keeps the grid's order.
            let key = months.reduce(months[0]) { $1.count > $0.count ? $1 : $0 }
            return Year(id: year, months: months.map(\.id), keyMonth: key.id)
        }
    }

    /// A month's mosaic: one photo from each of up to `limit` days, spread over the month, in the grid's order.
    /// Within a day, the photo in the middle, and a photo before a video.
    static func picks(_ photos: [Photo], limit: Int = 4) -> [Pick] {
        guard limit > 0 else { return [] }
        var days: [Int?] = []
        var byDay: [Int?: [Photo]] = [:]
        for photo in photos {
            let day = photo.date.map { calendar.component(.day, from: $0) }
            if byDay[day] == nil { days.append(day) }
            byDay[day, default: []].append(photo)
        }
        let chosen: [Int?]
        if days.count <= limit {
            chosen = days
        } else {
            chosen = (0..<limit).map { days[$0 * (days.count - 1) / (limit - 1 == 0 ? 1 : limit - 1)] }
        }
        return chosen.map { day in
            let candidates = byDay[day]!
            let stills = candidates.filter { !$0.isVideo }
            let pool = stills.isEmpty ? candidates : stills
            return Pick(id: pool[pool.count / 2].id, day: day)
        }
    }

    /// Timeline dates are wall-clock times stored as UTC (see `ImmichDate`).
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
