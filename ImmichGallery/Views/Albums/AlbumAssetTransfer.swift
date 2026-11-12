import CoreTransferable
import UniformTypeIdentifiers

/// Internal album drops use data, leaving room for original-file representations.
struct AlbumAssetTransfer: Codable, Transferable {
    let ids: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .albumAssetIDs)
    }

    /// The IDs of all dropped items, in order and without repeats.
    static func mergedIDs(_ values: [AlbumAssetTransfer]) -> [String] {
        var seen = Set<String>()
        return values.flatMap(\.ids).filter { seen.insert($0).inserted }
    }
}

extension UTType {
    static let albumAssetIDs = UTType(exportedAs: "dev.igol.ImmichGallery.asset-ids", conformingTo: .data)
}
