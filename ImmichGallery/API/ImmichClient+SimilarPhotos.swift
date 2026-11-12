import Foundation

extension ImmichClient {
    /// Find Similar Photos: one page of timeline photos taken in a date range, oldest first. takenAfter/takenBefore are
    /// deprecated since v3.2 but still honored in v3.3.5, and are the only date filter v2 servers understand.
    func similarPhotosPage(takenAfter: Date, takenBefore: Date, page: SearchPage, size: Int = 250) async throws -> SearchResponse.Assets {
        struct Body: Encodable {
            let type = "IMAGE"
            let visibility = "timeline"
            let takenAfter: String
            let takenBefore: String
            let page: Int?
            let cursor: String?
            let size: Int
            let order = "asc"
            let withStacked = true
        }
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let response: SearchResponse = try await send("POST", "search/metadata", body: Body(
            takenAfter: takenAfter.formatted(format), takenBefore: takenBefore.formatted(format),
            page: page.page, cursor: page.cursor, size: size))
        return response.assets
    }
}
