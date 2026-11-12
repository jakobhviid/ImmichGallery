// Run by scripts/check-integration.py ('inspector-editing'). Offline: loads are driven by hand-resolved continuations.
import Foundation

@MainActor final class Loads {
    var assets: [String: [CheckedContinuation<AssetResponse, Error>]] = [:]
    var albums: [String: [CheckedContinuation<[Album], Never>]] = [:]
    var state = AssetInspectorState()

    func asset(_ id: String) async throws -> AssetResponse {
        try await withCheckedThrowingContinuation { assets[id, default: []].append($0) }
    }

    func albumList(_ id: String) async -> [Album] {
        await withCheckedContinuation { albums[id, default: []].append($0) }
    }

    /// Starts the inspector's real load routine for `id`, as its `.task` does.
    func start(_ id: String?) -> Task<Void, Never> {
        Task { @MainActor in
            await AssetInspectorState.load(id, asset: asset, albums: albumList, update: { $0(&self.state) })
        }
    }

    func waitForAsset(_ id: String) async { while assets[id]?.isEmpty != false { await Task.yield() } }
    func waitForAlbums(_ id: String) async { while albums[id]?.isEmpty != false { await Task.yield() } }

    func answer(_ id: String, _ result: Result<AssetResponse, Error>) async {
        await waitForAsset(id)
        assets[id]!.removeFirst().resume(with: result)
    }

    func answerAlbums(_ id: String, _ names: [String]) async {
        await waitForAlbums(id)
        albums[id]!.removeFirst().resume(returning: names.map(album))
    }
}

func asset(_ id: String, description: String? = nil) -> AssetResponse {
    let exif = description.map { #", "exifInfo": {"description": "\#($0)"}"# } ?? ""
    let json = #"{"id": "\#(id)", "type": "IMAGE", "originalFileName": "\#(id).jpg", "fileCreatedAt": "2024-01-01T00:00:00.000Z", "localDateTime": "2024-01-01T00:00:00.000Z", "isFavorite": false, "isTrashed": false\#(exif)}"#
    return try! JSONDecoder().decode(AssetResponse.self, from: Data(json.utf8))
}

func album(_ name: String) -> Album {
    try! JSONDecoder().decode(Album.self, from: Data(#"{"id": "\#(name)", "albumName": "\#(name)", "assetCount": 1, "shared": false}"#.utf8))
}

struct Offline: Error {}

@main struct InspectorEditingChecks {
    @MainActor static func main() async {
        await inspectorLoads()
        descriptionDrafts()
        inlineEdits()
        print("inspector editing checks passed")
    }

    @MainActor static func inspectorLoads() async {
        let loads = Loads()
        precondition(loads.state.phase(for: nil) == .none)

        // A loads: its own details, editable, with its albums.
        var task = loads.start("A")
        precondition(loads.state.phase(for: "A") == .loading && !loads.state.canEdit("A"))
        await loads.answer("A", .success(asset("A")))
        await loads.answerAlbums("A", ["Trip"])
        await task.value
        precondition(loads.state.phase(for: "A") == .current && loads.state.canEdit("A"))
        precondition(loads.state.albums.map(\.albumName) == ["Trip"])

        // B is selected: before its load even starts, A's details are stale and not editable for B.
        precondition(loads.state.phase(for: "B") == .stale && !loads.state.canEdit("B"))

        // A reload of A (after a metadata edit) is slow, B is selected, B answers first, then A's late answer arrives.
        let reloadA = loads.start("A")
        await loads.waitForAsset("A")
        reloadA.cancel()
        task = loads.start("B")
        await loads.answer("B", .success(asset("B")))
        await loads.waitForAlbums("B")
        precondition(loads.state.phase(for: "B") == .current && loads.state.canEdit("B"))
        precondition(loads.state.albums.isEmpty, "A's albums must not show with B")
        await loads.answer("A", .success(asset("A")))
        await reloadA.value
        precondition(loads.state.asset?.id == "B" && loads.state.canEdit("B"), "a cancelled late answer must not replace B")
        await loads.answerAlbums("B", ["Home"])
        await task.value
        precondition(loads.state.albums.map(\.albumName) == ["Home"])

        // An answer for another photo, as a people refresh could deliver, is ignored.
        loads.state.loaded(asset("A"), for: "A")
        loads.state.loaded(asset("X"), for: "B")
        precondition(loads.state.asset?.id == "B")

        // C fails while B is still on screen: C's error, not B's details.
        task = loads.start("C")
        precondition(loads.state.phase(for: "C") == .stale && !loads.state.canEdit("C"))
        await loads.answer("C", .failure(Offline()))
        await task.value
        precondition(loads.state.phase(for: "C") == .failed && !loads.state.canEdit("C"))
        precondition(loads.state.phase(for: "B") == .current, "B's details are still B's")

        // Try Again for C: stale while loading, then C's own details.
        task = loads.start("C")
        await loads.waitForAsset("C")
        precondition(loads.state.phase(for: "C") == .stale)
        await loads.answer("C", .success(asset("C")))
        await loads.answerAlbums("C", [])
        await task.value
        precondition(loads.state.phase(for: "C") == .current && loads.state.canEdit("C"))

        // A cancelled load that later fails leaves the next photo alone.
        let cancelledD = loads.start("D")
        await loads.waitForAsset("D")
        cancelledD.cancel()
        task = loads.start("E")
        await loads.answer("D", .failure(Offline()))
        await cancelledD.value
        precondition(loads.state.phase(for: "E") == .stale, "D's failure must not show for E")
        await loads.answer("E", .success(asset("E")))
        await loads.answerAlbums("E", [])
        await task.value
        precondition(loads.state.phase(for: "E") == .current)

        // A reload of the shown photo keeps it editable until it fails, then shows the error.
        task = loads.start("E")
        await loads.waitForAsset("E")
        precondition(loads.state.canEdit("E"))
        await loads.answer("E", .failure(Offline()))
        await task.value
        precondition(loads.state.phase(for: "E") == .failed && !loads.state.canEdit("E"))

        // No selection.
        await loads.start(nil).value
        precondition(loads.state.phase(for: nil) == .none && loads.state.asset == nil)
    }

    static func descriptionDrafts() {
        // A draft typed for A is saved to A, once, even when finished after the selection moved to B.
        var draft = DescriptionDraft(assetID: "A", saved: "old")
        precondition(draft.takeChange() == nil, "nothing typed, nothing saved")
        draft.text = "new"
        let change = draft.takeChange()
        precondition(change?.assetID == "A" && change?.description == "new")
        precondition(draft.takeChange() == nil, "blur after Return doesn't save again")

        // A failed save can be retried; a failure of an older save doesn't undo a newer one.
        draft.saveFailed("new", saved: "old")
        precondition(draft.takeChange()?.description == "new")
        draft.text = "newer"
        precondition(draft.takeChange()?.description == "newer")
        draft.saveFailed("new", saved: "old")
        precondition(draft.takeChange() == nil)
    }

    static func inlineEdits() {
        var edit = InlineEdit()
        precondition(edit.finish(current: "Trip", allowsEmpty: false) == nil, "not editing")

        // Return saves once; focus leaving afterwards doesn't save again.
        edit.begin("Trip")
        precondition(edit.editing && edit.draft == "Trip")
        edit.draft = "  Summer Trip "
        precondition(edit.finish(current: "Trip", allowsEmpty: false) == "Summer Trip")
        precondition(!edit.editing && edit.finish(current: "Trip", allowsEmpty: false) == nil)

        // Escape cancels; the focus change that follows doesn't save.
        edit.begin("Trip")
        edit.draft = "Changed"
        edit.cancel()
        precondition(!edit.editing && edit.finish(current: "Trip", allowsEmpty: false) == nil)

        // Clicking away saves.
        edit.begin("Trip")
        edit.draft = "Clicked Away"
        precondition(edit.finish(current: "Trip", allowsEmpty: false) == "Clicked Away")

        // Unchanged text, and an empty name, aren't saved; an empty description clears it.
        edit.begin("Trip")
        precondition(edit.finish(current: "Trip", allowsEmpty: false) == nil)
        edit.begin("Ann")
        edit.draft = "  "
        precondition(edit.finish(current: "Ann", allowsEmpty: false) == nil)
        edit.begin("Notes")
        edit.draft = ""
        precondition(edit.finish(current: "Notes", allowsEmpty: true) == "")

        // A description keeps its line breaks, without blank lines at its ends.
        edit.begin("")
        edit.draft = "\nFirst line\nSecond line\n"
        precondition(edit.finish(current: "", allowsEmpty: true) == "First line\nSecond line")
    }
}
