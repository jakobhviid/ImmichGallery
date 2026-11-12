import Foundation

/// Find Similar Photos (#41): which photos qualify, how they group, and which one is suggested as the cover.
/// Pure logic; Vision and the network stay in `SimilarPhotosAnalyzer` and `SimilarPhotosModel`.
enum SimilarPhotos {
    /// Groups never span more than a minute or hold more than 20 photos.
    static let maxDuration: TimeInterval = 60
    static let maxMembers = 20
    static let minMembers = 2
    /// A scan stops, with a message, rather than analyzing more than this many photos.
    static let candidateLimit = 2000
    static let gapChoices: [TimeInterval] = [5, 10, 30]
    static let defaultGap: TimeInterval = 10

    enum Sensitivity: String, CaseIterable, Identifiable, Sendable {
        case strict, normal, loose
        var id: Self { self }
        /// Largest Vision feature-print distance (revision 2) allowed between any two photos of a group.
        /// Starting points measured on synthetic bursts, not a guarantee of what counts as "similar".
        var threshold: Float {
            switch self {
            case .strict: 0.25
            case .normal: 0.35
            case .loose: 0.45
            }
        }
    }

    struct Options: Sendable, Equatable {
        var sensitivity = Sensitivity.normal
        /// Longest pause between two consecutive photos of a group.
        var maxGap = SimilarPhotos.defaultGap
    }

    /// Why a photo isn't offered for stacking.
    enum Exclusion: Hashable, Sendable {
        case notPhoto, notOwned, trashed, hiddenOrLocked, stacked, noDate
    }

    struct Candidate: Identifiable, Hashable, Sendable {
        let id: String
        let date: Date
        let isFavorite: Bool
        let pixels: Int
    }

    /// Only the user's own still photos on the timeline or in the archive, outside the trash and not already in a stack.
    /// Live Photos count once, as their still; their hidden video part is excluded.
    static func exclusion(_ asset: AssetResponse, userID: String) -> Exclusion? {
        if asset.type != .image { return .notPhoto }
        if userID.isEmpty || asset.ownerId != userID { return .notOwned }
        if asset.isTrashed { return .trashed }
        if let visibility = asset.visibility, visibility != "timeline", visibility != "archive" { return .hiddenOrLocked }
        if asset.stack != nil { return .stacked }
        if ImmichDate.parse(asset.fileCreatedAt) == nil { return .noDate }
        return nil
    }

    static func candidate(_ asset: AssetResponse) -> Candidate? {
        guard let date = ImmichDate.parse(asset.fileCreatedAt) else { return nil }
        return Candidate(id: asset.id, date: date, isFavorite: asset.isFavorite, pixels: (asset.width ?? 0) * (asset.height ?? 0))
    }

    static func sorted(_ candidates: [Candidate]) -> [Candidate] {
        candidates.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
    }

    /// Splits photos, oldest first, wherever the pause between two shots exceeds `maxGap` (a pause of exactly
    /// `maxGap` keeps them together). Only runs of two or more photos can hold a group.
    static func timeRuns(_ candidates: [Candidate], maxGap: TimeInterval) -> [[Candidate]] {
        var runs: [[Candidate]] = []
        var current: [Candidate] = []
        for candidate in sorted(candidates) {
            if let last = current.last, candidate.date.timeIntervalSince(last.date) > maxGap {
                if current.count >= minMembers { runs.append(current) }
                current = []
            }
            current.append(candidate)
        }
        if current.count >= minMembers { runs.append(current) }
        return runs
    }

    /// Pairs in a run close enough in time to share a group, for which a distance is needed.
    static func pairs(in run: [Candidate]) -> [(Int, Int)] {
        var result: [(Int, Int)] = []
        for i in run.indices {
            for j in (i + 1)..<run.count {
                if run[j].date.timeIntervalSince(run[i].date) > maxDuration { break }
                result.append((i, j))
            }
        }
        return result
    }

    private struct Pair: Hashable { let a: Int, b: Int }

    /// Complete-link grouping of one time run (sorted oldest first): every two photos of a group are within
    /// `threshold`, so A≈B and B≈C don't pull in a different C. Closest pairs merge first; ties go to the earlier
    /// photos, so the result doesn't depend on hashing order. `distance` returns nil when a photo couldn't be analyzed,
    /// which keeps it out of every group. Returns run indices.
    static func groups(_ run: [Candidate], threshold: Float, isCancelled: () -> Bool = { false }, distance: (Int, Int) -> Float?) -> [[Int]] {
        var members: [Int: [Int]] = [:]
        for i in run.indices { members[i] = [i] }
        var links: [Pair: Float] = [:]
        for i in run.indices {
            for j in (i + 1)..<run.count {
                if isCancelled() { return [] }
                if run[j].date.timeIntervalSince(run[i].date) > maxDuration { break }
                if let d = distance(i, j), d.isFinite, d <= threshold { links[Pair(a: i, b: j)] = d }
            }
        }
        func fits(_ a: [Int], _ b: [Int]) -> Bool {
            let all = a + b
            guard all.count <= maxMembers, let first = all.min(), let last = all.max() else { return false }
            return run[last].date.timeIntervalSince(run[first].date) <= maxDuration
        }
        while true {
            var best: (pair: Pair, distance: Float)?
            for (pair, d) in links {
                if isCancelled() { return [] }
                guard fits(members[pair.a]!, members[pair.b]!) else { links[pair] = nil; continue } // groups only grow
                if let current = best, (current.distance, current.pair.a, current.pair.b) <= (d, pair.a, pair.b) { continue }
                best = (pair, d)
            }
            guard let (pair, _) = best else { break }
            let (keep, gone) = (pair.a, pair.b) // a < b: the merged group keeps its earliest photo as its key
            members[keep] = (members[keep]! + members[gone]!).sorted()
            members[gone] = nil
            links[pair] = nil
            for other in Array(members.keys) where other != keep {
                let toKeep = Pair(a: min(keep, other), b: max(keep, other))
                let toGone = Pair(a: min(gone, other), b: max(gone, other))
                // Complete link: the merged group is as far from `other` as its farthest part.
                if let d1 = links[toKeep], let d2 = links[toGone] { links[toKeep] = max(d1, d2) } else { links[toKeep] = nil }
                links[toGone] = nil
            }
        }
        return members.values.filter { $0.count >= minMembers }.sorted { $0[0] < $1[0] }
    }

    struct Score: Sendable, Equatable {
        /// Vision's overall aesthetics score, -1…1; nil when it couldn't be computed.
        var aesthetics: Float?
        /// Variance of the Laplacian of the downscaled photo: higher is sharper.
        var sharpness: Double?
    }

    /// The suggested cover: a favorite first, then Vision's aesthetics score, sharpness, resolution, and finally the
    /// earlier shot and its ID, so the same photos always give the same suggestion.
    static func topPick(_ members: [Candidate], scores: [String: Score]) -> String? {
        func key(_ c: Candidate) -> (Int, Float, Double, Int) {
            let score = scores[c.id]
            return (c.isFavorite ? 1 : 0, score?.aesthetics ?? -.infinity, score?.sharpness ?? -.infinity, c.pixels)
        }
        return members.min { a, b in
            let (ka, kb) = (key(a), key(b))
            if ka != kb { return ka > kb }
            return (a.date, a.id) < (b.date, b.id)
        }?.id
    }
}

/// The days a scan covers, inclusive, in the user's calendar.
struct SimilarPhotosRange: Equatable, Sendable {
    var start: Date
    var end: Date

    static func lastDays(_ days: Int, now: Date = .now, calendar: Calendar = .current) -> SimilarPhotosRange {
        let today = calendar.startOfDay(for: now)
        return SimilarPhotosRange(start: calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today, end: today)
    }

    /// From the start of the first day to the last moment of the last day. A reversed range is swapped.
    func bounds(calendar: Calendar = .current) -> (after: Date, before: Date) {
        let first = calendar.startOfDay(for: min(start, end))
        let last = calendar.startOfDay(for: max(start, end))
        let dayAfter = calendar.date(byAdding: .day, value: 1, to: last) ?? last
        return (first, dayAfter.addingTimeInterval(-0.001))
    }
}
