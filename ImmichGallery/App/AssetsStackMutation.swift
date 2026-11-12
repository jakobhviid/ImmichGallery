import Foundation

/// Revalidate the visible stack and account immediately before a recoverable trash request.
@MainActor enum AssetsStackMutation {
    static func trashOthers(client: ImmichClient, stackID: String, shown: AssetsStack, userID: String,
                            isCurrent: () -> Bool) async throws {
        guard !userID.isEmpty, isCurrent(), !Task.isCancelled else { throw CancellationError() }
        let current = try await client.assetsStack(stackID)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        guard current.primaryAssetId == shown.primaryAssetId else {
            throw ImmichError.http(409, String(localized: "The stack changed. Check it again before moving photos."))
        }
        let visible = Set(shown.assets.map(\.id))
        let ids = current.assets
            .filter { $0.id != current.primaryAssetId && visible.contains($0.id) && $0.ownerId == userID && !$0.isTrashed && $0.visibility != "locked" }
            .map(\.id)
        guard !ids.isEmpty else { return }
        // Missing or unavailable features must not turn this recoverable action into permanent deletion.
        struct Features: Decodable { let trash: Bool }
        let features: Features = try await client.get("server/features")
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        guard features.trash else {
            throw ImmichError.http(409, String(localized: "Recently Deleted is unavailable. No photos were removed."))
        }
        try await client.delete(ids, force: false)
    }
}
