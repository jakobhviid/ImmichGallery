import CoreTransferable
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// The single drag payload of a grid or viewer asset. Outside the app it is only the original
/// file; the marker and album asset IDs follow it for the app's own drop targets.
struct OriginalTransfer: Transferable, Identifiable, Sendable {
    let id: String
    var isVideo = false
    let client: ImmichClient
    /// Asset IDs for album drops. `nil` (Locked Folder, viewer) exports no album representation.
    var albumIDs: [String]? = nil
    /// The original's name and type, read only once a drag starts.
    let file: OriginalFile

    init(id: String, isVideo: Bool = false, client: ImmichClient, albumIDs: [String]? = nil) {
        self.id = id
        self.isVideo = isVideo
        self.client = client
        self.albumIDs = albumIDs
        file = OriginalFile(id: id, client: client)
    }

    static var transferRepresentation: some TransferRepresentation {
        // The original first: the Finder saves the first representation it can. Exactly one of these is exported,
        // with its real name: receivers name the file before it is downloaded. It is the original's own format
        // when known, else its kind: data-only receivers can decode public.jpeg and derive an extension,
        // whereas public.image can leave them an unnamed temporary file with no usable extension.
        formats
        original(.image)
        original(.movie)
        original(.data)
        ProxyRepresentation(exporting: { _ in OriginalDragMarker() })
        ProxyRepresentation(exporting: { item in AlbumAssetTransfer(ids: item.albumIDs ?? []) })
            .exportingCondition { $0.albumIDs != nil }
    }

    /// CoreTransferable takes one static type per representation: one for each of `OriginalFile.formats`.
    @TransferRepresentationBuilder<OriginalTransfer>
    private static var formats: some TransferRepresentation<OriginalTransfer> {
        original(.jpeg)
        original(.heic)
        original(.heif)
        original(.png)
        original(.gif)
        original(.webP)
        original(.tiff)
        original(.quickTimeMovie)
        original(.mpeg4Movie)
    }

    private static func original(_ type: UTType) -> some TransferRepresentation<OriginalTransfer> {
        FileRepresentation(exportedContentType: type) { item in
            // A copy for the receiver: the cached original expires after ten minutes.
            SentTransferredFile(try await item.client.macIntegrationOriginal(item.id), allowAccessingOriginalFile: false)
        }
        .exportingCondition { $0.file.resolved.type == type }
        .suggestedFileName { $0.file.resolved.name }
    }
}

/// The name and type of an original, which receivers such as the Finder take when the drag starts, before the
/// original is downloaded. The timeline has neither, so they come from the asset's details, read only for the
/// assets being dragged and waited for only briefly, since the drag can't start until then.
final class OriginalFile: Sendable {
    struct Resolved: Sendable, Equatable {
        let name: String
        /// One of `formats` when the name's extension is one, else `.image`, `.movie` or `.data`: Immich's kind of asset.
        let type: UTType
    }

    /// The formats advertised under their own type. `OriginalTransfer` has a representation for each.
    static let formats: [UTType] = [.jpeg, .heic, .heif, .png, .gif, .webP, .tiff, .quickTimeMovie, .mpeg4Movie]

    static let timeout: TimeInterval = 1
    private let id: String
    private let client: ImmichClient
    private let lookup = DispatchGroup()
    private let state = Mutex<(started: Date?, resolved: Resolved?, decision: Resolved?)>((nil, nil, nil))

    init(id: String, client: ImmichClient) {
        self.id = id
        self.client = client
    }

    /// Starts reading the details, so a multi-item drag reads them all at once.
    func start() {
        state.withLock { state in
            guard state.started == nil else { return }
            state.started = Date()
            lookup.enter()
            Task.detached { [self] in
                let asset = try? await client.asset(id)
                self.state.withLock { $0.resolved = asset.map(Self.resolve) }
                lookup.leave()
            }
        }
    }

    /// The server's name and kind, or the asset ID and generic data when they don't arrive in time.
    var resolved: Resolved {
        if let decision = state.withLock({ $0.decision }) { return decision }
        start()
        let deadline = state.withLock { $0.started! }.addingTimeInterval(Self.timeout)
        _ = lookup.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow))
        return state.withLock { state in
            if let decision = state.decision { return decision }
            let decision = state.resolved ?? Resolved(name: id, type: .data)
            state.decision = decision
            return decision
        }
    }

    static func resolve(_ asset: AssetResponse) -> Resolved {
        let name = (asset.originalFileName as NSString).lastPathComponent
        let kind: UTType = switch asset.type {
        case .image: .image
        case .video: .movie
        default: .data
        }
        // From the extension, so the type always agrees with the suggested name. Never for other kinds of asset.
        let format = kind == .data ? nil : UTType(filenameExtension: (name as NSString).pathExtension, conformingTo: kind)
        return Resolved(name: name.isEmpty || name == "." || name == ".." ? asset.id : name,
                        type: format.flatMap { formats.contains($0) ? $0 : nil } ?? kind)
    }
}
