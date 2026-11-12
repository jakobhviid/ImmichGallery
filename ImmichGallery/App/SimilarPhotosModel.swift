import Foundation
import Observation

/// Find Similar Photos (#41): collects every eligible photo in the chosen scope, analyzes photos taken close together on
/// this Mac, and suggests groups. Nothing is written until `apply()`, which the sheet calls only after confirmation.
@MainActor @Observable
final class SimilarPhotosModel {
    enum Scope: Equatable {
        case selection([String])
        case range(SimilarPhotosRange)
    }

    enum Phase: Equatable {
        case idle
        case collecting(found: Int)
        case analyzing(done: Int, total: Int)
        case ready
        case applying(done: Int, total: Int)
        /// More eligible photos than `SimilarPhotos.candidateLimit`; nothing was analyzed.
        case tooMany
        case failed(String)
    }

    enum GroupStatus: Equatable, Sendable {
        case pending
        case stacked(stackID: String)
        /// Stacked, but the server kept another cover.
        case coverNotSet(stackID: String)
        /// Some photo changed since the scan (deleted, moved, stacked, now someone else's); left untouched.
        case changed
        case failed(String)
    }

    struct Group: Identifiable, Equatable, Sendable {
        let id: String
        let members: [SimilarPhotos.Candidate]
        let suggestedCover: String
        var cover: String
        var removed: Set<String> = []
        var included = true
        var status = GroupStatus.pending

        var activeMembers: [SimilarPhotos.Candidate] { members.filter { !removed.contains($0.id) } }
        /// The cover first: Immich makes the first ID of a new stack its primary.
        var stackIDs: [String] { [cover] + activeMembers.map(\.id).filter { $0 != cover } }
        var canStack: Bool { status == .pending && included && activeMembers.count >= SimilarPhotos.minMembers }
    }

    /// What a finished scan covered, so the sheet can say exactly what was and wasn't checked.
    struct Coverage: Equatable {
        var scope: Scope?
        /// Photos returned by the server, or selected items read back.
        var seen = 0
        var eligible = 0
        var excluded: [SimilarPhotos.Exclusion: Int] = [:]
        /// Selected items the server couldn't return.
        var unreadable = 0
        /// Photos with a close neighbor in time, which needed analysis.
        var analyzed = 0
        var analysisFailures = 0
    }

    private(set) var phase = Phase.idle
    private(set) var groups: [Group] = []
    private(set) var coverage = Coverage()
    private(set) var needsRescan = false
    /// Responses for the photos in groups, for thumbnails and the stack browser.
    private(set) var assets: [String: AssetResponse] = [:]

    private let client: ImmichClient
    private let userID: String
    private let analyzer: any SimilarPhotosAnalyzing
    private let isCurrent: @MainActor () -> Bool
    private let didChangeLibrary: @MainActor () -> Void
    /// Lets the session sign out after an expired-session error, as other requests do.
    private let handleError: @MainActor (Error) -> Void
    private let concurrency: Int
    /// Bumped by every scan and cancellation; work from an older generation never updates state or writes.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    /// `isCurrent` is false once the account that started this model is switched or signed out.
    init(client: ImmichClient, userID: String?, analyzer: any SimilarPhotosAnalyzing, concurrency: Int = 3,
         isCurrent: @escaping @MainActor () -> Bool, didChangeLibrary: @escaping @MainActor () -> Void,
         handleError: @escaping @MainActor (Error) -> Void = { _ in }) {
        self.client = client
        self.userID = userID ?? ""
        self.analyzer = analyzer
        self.concurrency = min(max(concurrency, 2), 4)
        self.isCurrent = isCurrent
        self.didChangeLibrary = didChangeLibrary
        self.handleError = handleError
    }

    var isBusy: Bool {
        switch phase {
        case .collecting, .analyzing, .applying: true
        default: false
        }
    }

    var stackableGroups: [Group] { groups.filter(\.canStack) }

    // MARK: Scanning

    func scan(_ scope: Scope, options: SimilarPhotos.Options) {
        cancel()
        let generation = generation
        groups = []
        needsRescan = false
        assets = [:]
        coverage = Coverage(scope: scope)
        guard !userID.isEmpty else { phase = .failed(String(localized: "Your account isn't loaded yet. Try again in a moment.")); return }
        phase = .collecting(found: 0)
        task = Task { await run(scope, options: options, generation: generation) }
    }

    /// Stops a scan, or stops stacking before the next group. A request already sent can't be recalled; its result is kept.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        switch phase {
        case .collecting, .analyzing: phase = .idle; groups = []
        case .applying: phase = .ready
        default: break
        }
    }

    private func live(_ generation: Int) -> Bool { generation == self.generation && isCurrent() && !Task.isCancelled }

    private func run(_ scope: Scope, options: SimilarPhotos.Options, generation: Int) async {
        do {
            let found: [AssetResponse]?
            switch scope {
            case .selection(let ids): found = try await readSelection(ids, generation: generation)
            case .range(let range): found = try await collect(range, generation: generation)
            }
            guard let found, live(generation) else { return }
            await analyze(found, options: options, generation: generation)
        } catch {
            guard live(generation) else { return }
            handleError(error)
            phase = .failed(error.localizedDescription)
        }
    }

    private func admit(_ asset: AssetResponse, into eligible: inout [AssetResponse]) {
        coverage.seen += 1
        if let reason = SimilarPhotos.exclusion(asset, userID: userID) { coverage.excluded[reason, default: 0] += 1 }
        else { eligible.append(asset); coverage.eligible = eligible.count }
    }

    /// Every page of the range, not just the photos a grid happens to have loaded.
    private func collect(_ range: SimilarPhotosRange, generation: Int) async throws -> [AssetResponse]? {
        let (after, before) = range.bounds()
        var page = ImmichClient.SearchPage(page: 1)
        var eligible: [AssetResponse] = []
        var seenPages = Set<String>()
        while true {
            let result = try await client.similarPhotosPage(takenAfter: after, takenBefore: before, page: page)
            guard live(generation) else { return nil }
            for asset in result.items { admit(asset, into: &eligible) }
            if eligible.count > SimilarPhotos.candidateLimit { phase = .tooMany; return nil }
            phase = .collecting(found: eligible.count)
            let next: ImmichClient.SearchPage
            if let cursor = result.nextCursor { next = .init(cursor: cursor) }
            else if let number = result.nextPage.flatMap(Int.init) { next = .init(page: number) }
            else { break }
            // A server repeating a page would otherwise loop forever.
            guard !result.items.isEmpty, seenPages.insert("\(next.page ?? -1)|\(next.cursor ?? "")").inserted else {
                throw ImmichError.http(500, String(localized: "The server returned the same page twice. Try again."))
            }
            page = next
        }
        return eligible
    }

    /// Selected items are read back from the server, so stale grid data can't add a photo that was moved or deleted.
    private func readSelection(_ ids: [String], generation: Int) async throws -> [AssetResponse]? {
        var unique = Set<String>()
        let ids = ids.filter { unique.insert($0).inserted }
        guard ids.count <= SimilarPhotos.candidateLimit else { phase = .tooMany; return nil }
        var eligible: [AssetResponse] = []
        let client = client
        try await withThrowingTaskGroup(of: AssetResponse?.self) { group in
            var iterator = ids.makeIterator()
            func next() -> Bool {
                guard let id = iterator.next() else { return false }
                group.addTask {
                    do { return try await client.asset(id) }
                    catch {
                        // Cancellation and an expired session end the scan; any other failure is counted and reported.
                        if error is CancellationError || (error as? URLError)?.code == .cancelled || SimilarPhotosModel.isUnauthorized(error) { throw error }
                        return nil
                    }
                }
                return true
            }
            for _ in 0..<concurrency { _ = next() }
            while let result = try await group.next() {
                guard live(generation) else { group.cancelAll(); return }
                if let result { admit(result, into: &eligible) } else { coverage.unreadable += 1; coverage.seen += 1 }
                phase = .collecting(found: eligible.count)
                _ = next()
            }
        }
        return live(generation) ? eligible : nil
    }

    nonisolated private static func isUnauthorized(_ error: Error) -> Bool {
        if case ImmichError.unauthorized = error { true } else { false }
    }

    private func analyze(_ found: [AssetResponse], options: SimilarPhotos.Options, generation: Int) async {
        let candidates = found.compactMap(SimilarPhotos.candidate)
        let runs = SimilarPhotos.timeRuns(candidates, maxGap: options.maxGap)
        // Only photos with a neighbor in time are downloaded and analyzed.
        let needed = runs.flatMap { $0 }.map(\.id)
        coverage.analyzed = needed.count
        phase = .analyzing(done: 0, total: needed.count)
        var features: [String: SimilarPhotoFeatures] = [:]
        let analyzer = analyzer
        await withTaskGroup(of: (String, SimilarPhotoFeatures?).self) { group in
            var iterator = needed.makeIterator()
            func next() -> Bool {
                guard let id = iterator.next() else { return false }
                group.addTask { (id, try? await analyzer.analyze(id)) }
                return true
            }
            for _ in 0..<concurrency { _ = next() }
            var done = 0
            while let (id, result) = await group.next() {
                guard live(generation) else { group.cancelAll(); return }
                done += 1
                if let result { features[id] = result } else { coverage.analysisFailures += 1 }
                phase = .analyzing(done: done, total: needed.count)
                _ = next()
            }
        }
        guard live(generation) else { return }
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard let groups = try? await Self.cluster(runs, features: features, options: options), live(generation) else { return }
        assets = byID.filter { id, _ in groups.contains { $0.members.contains { $0.id == id } } }
        self.groups = groups
        phase = .ready
    }

    /// Distance computation and complete-link merging can be expensive even after the preview analysis.
    @concurrent static func cluster(_ runs: [[SimilarPhotos.Candidate]], features: [String: SimilarPhotoFeatures],
                                    options: SimilarPhotos.Options) async throws -> [Group] {
        var groups: [Group] = []
        let scores = features.mapValues(\.score)
        for run in runs {
            try Task.checkCancellation()
            let found = SimilarPhotos.groups(run, threshold: options.sensitivity.threshold, isCancelled: { Task.isCancelled }) { i, j in
                guard let a = features[run[i].id], let b = features[run[j].id] else { return nil }
                return SimilarPhotosVisionAnalyzer.distance(a.featurePrint, b.featurePrint)
            }
            try Task.checkCancellation()
            for indices in found {
                let members = indices.map { run[$0] }
                let cover = SimilarPhotos.topPick(members, scores: scores) ?? members[0].id
                groups.append(Group(id: members[0].id, members: members, suggestedCover: cover, cover: cover))
            }
        }
        return groups
    }

    // MARK: Review

    /// A browser mutation invalidates only that applied result; pending choices remain intact.
    func invalidateStack(_ stackID: String) {
        groups.removeAll {
            switch $0.status {
            case .stacked(let id), .coverNotSet(let id): id == stackID
            default: false
            }
        }
        needsRescan = true
    }


    func setCover(_ id: String, in groupID: String) {
        guard let i = editableIndex(groupID), groups[i].activeMembers.contains(where: { $0.id == id }) else { return }
        groups[i].cover = id
    }

    /// Takes a photo out of the group; the cover moves to the next suggestion if needed.
    func remove(_ id: String, from groupID: String) {
        guard let i = editableIndex(groupID) else { return }
        groups[i].removed.insert(id)
        if groups[i].cover == id, let first = groups[i].activeMembers.first {
            let remaining = groups[i].activeMembers
            groups[i].cover = remaining.contains { $0.id == groups[i].suggestedCover } ? groups[i].suggestedCover : first.id
        }
    }

    func restoreMembers(of groupID: String) {
        guard let i = editableIndex(groupID) else { return }
        groups[i].removed = []
    }

    func setIncluded(_ included: Bool, groupID: String) {
        guard let i = editableIndex(groupID) else { return }
        groups[i].included = included
    }

    private func editableIndex(_ groupID: String) -> Int? {
        guard phase == .ready, let i = groups.firstIndex(where: { $0.id == groupID }), groups[i].status == .pending else { return nil }
        return i
    }

    // MARK: Stacking

    /// Stacks every included group, one at a time. Each photo is read back first; a group with any change is skipped.
    /// A group is never sent twice, even when its request failed, because a failure may still have created the stack.
    func apply() async {
        guard phase == .ready, !userID.isEmpty, isCurrent() else { return }
        let generation = generation
        let targets = groups.filter(\.canStack).map(\.id)
        guard !targets.isEmpty else { return }
        phase = .applying(done: 0, total: targets.count)
        var changedLibrary = false
        defer {
            if changedLibrary { didChangeLibrary() }
            if generation == self.generation, case .applying = phase { phase = .ready }
        }
        for (done, groupID) in targets.enumerated() {
            guard live(generation), let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
            let group = groups[index]
            let ids = group.stackIDs
            let current: [AssetResponse]
            do { current = try await read(ids) }
            catch {
                guard live(generation) else { return }
                handleError(error)
                setStatus(.failed(error.localizedDescription), of: groupID)
                continue
            }
            guard live(generation) else { return }
            if current.count != ids.count || current.contains(where: { SimilarPhotos.exclusion($0, userID: userID) != nil }) {
                setStatus(.changed, of: groupID)
                phase = .applying(done: done + 1, total: targets.count)
                continue
            }
            let stack: AssetsStack
            do {
                stack = try await client.assetsCreateStack(ids)
                changedLibrary = true
            } catch {
                handleError(error)
                setStatus(.failed(error.localizedDescription), of: groupID)
                if Self.isUnauthorized(error) { return }
                phase = .applying(done: done + 1, total: targets.count)
                continue
            }
            setStatus(.coverNotSet(stackID: stack.id), of: groupID)
            if stack.primaryAssetId == group.cover {
                setStatus(.stacked(stackID: stack.id), of: groupID)
            } else if live(generation) {
                // Immich makes the first ID the primary; if a server didn't, set it explicitly and check again.
                if let updated = try? await client.assetsSetPrimary(stack: stack.id, asset: group.cover), updated.primaryAssetId == group.cover {
                    setStatus(.stacked(stackID: stack.id), of: groupID)
                }
            }
            guard live(generation) else { return }
            phase = .applying(done: done + 1, total: targets.count)
        }
    }

    private func setStatus(_ status: GroupStatus, of groupID: String) {
        if let i = groups.firstIndex(where: { $0.id == groupID }) { groups[i].status = status }
    }

    /// A photo the server no longer returns (deleted for good, or now someone else's) counts as changed.
    private func read(_ ids: [String]) async throws -> [AssetResponse] {
        var result: [AssetResponse] = []
        for id in ids {
            do { result.append(try await client.asset(id)) }
            catch ImmichError.http(let code, _) where code == 400 || code == 403 || code == 404 { continue }
        }
        return result
    }
}
