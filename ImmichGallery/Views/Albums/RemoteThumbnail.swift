import SwiftUI

/// Square, cropped thumbnail for an asset id (album covers etc.).
struct RemoteThumbnail: View {
    let pipeline: ImagePipeline
    let assetID: String?
    var size: ImmichClient.ThumbnailSize = .thumbnail
    var placeholderSystemImage: String? = nil
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else if assetID == nil || placeholderSystemImage != nil {
                    Image(systemName: placeholderSystemImage ?? "photo.on.rectangle")
                        .font(placeholderSystemImage == nil ? .largeTitle : .body)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .task(id: assetID) {
                image = nil
                guard let assetID else { return }
                image = pipeline.cachedThumbnail(assetID, size: size)
                if image == nil {
                    let loaded = await pipeline.thumbnail(assetID, size: size)
                    guard !Task.isCancelled else { return }
                    // Fades in when it arrives; from the cache it is just there.
                    withAnimation(.easeOut(duration: 0.2)) { image = loaded }
                }
            }
    }
}
