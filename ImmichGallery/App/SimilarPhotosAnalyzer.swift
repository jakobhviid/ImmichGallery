import CoreGraphics
import Foundation
import Vision

/// What Find Similar Photos learns from one photo, on this Mac.
struct SimilarPhotoFeatures: Sendable {
    /// Vision image feature print, revision 2.
    let featurePrint: [Float]
    let score: SimilarPhotos.Score
}

protocol SimilarPhotosAnalyzing: Sendable {
    func analyze(_ id: String) async throws -> SimilarPhotoFeatures
}

enum SimilarPhotosAnalysisError: Error { case unreadableImage, noFeaturePrint }

/// Downloads the server's preview (already rotated upright), shrinks it to 720 pixels and runs Vision on device.
/// Nothing leaves the Mac except the preview request to the user's own server.
struct SimilarPhotosVisionAnalyzer: SimilarPhotosAnalyzing {
    static let edge = 720
    let client: ImmichClient

    @concurrent func analyze(_ id: String) async throws -> SimilarPhotoFeatures {
        let data = try await client.data(for: client.thumbnailRequest(id, size: .preview))
        try Task.checkCancellation()
        guard let image = ImagePipeline.decode(data, maxPixelSize: Self.edge) else { throw SimilarPhotosAnalysisError.unreadableImage }
        return try Self.features(of: image)
    }

    static func features(of image: CGImage) throws -> SimilarPhotoFeatures {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateImageFeaturePrintRequest()
        // Distances are only comparable within one revision; pin it so an OS update can't mix them.
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        try handler.perform([request])
        guard let observation = request.results?.first, observation.elementCount > 0 else { throw SimilarPhotosAnalysisError.noFeaturePrint }
        let vector: [Float] = observation.data.withUnsafeBytes { bytes in
            switch observation.elementType {
            case .double: bytes.bindMemory(to: Double.self).map { Float($0) }
            default: Array(bytes.bindMemory(to: Float.self))
            }
        }
        // The aesthetics score only ranks the cover suggestion; a failure there doesn't drop the photo.
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        let aestheticsScore = (try? handler.perform([aesthetics])).flatMap { aesthetics.results?.first?.overallScore }
        return SimilarPhotoFeatures(featurePrint: vector, score: .init(aesthetics: aestheticsScore, sharpness: sharpness(of: image)))
    }

    /// Euclidean distance between two feature prints, as `VNFeaturePrintObservation.computeDistance` reports it.
    static func distance(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var sum: Float = 0
        for i in a.indices { let d = a[i] - b[i]; sum += d * d }
        return sum.squareRoot()
    }

    /// Variance of the Laplacian on a 256-pixel grayscale copy: blurred or shaken shots score lower.
    static func sharpness(of image: CGImage) -> Double? {
        let scale = 256 / Double(max(image.width, image.height, 1))
        let width = max(3, Int(Double(image.width) * min(scale, 1))), height = max(3, Int(Double(image.height) * min(scale, 1)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.bindMemory(to: UInt8.self, capacity: width * height) else { return nil }
        var sum = 0.0, squares = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let value = 4 * Double(pixels[i]) - Double(pixels[i - 1]) - Double(pixels[i + 1]) - Double(pixels[i - width]) - Double(pixels[i + width])
                sum += value
                squares += value * value
            }
        }
        let count = Double((width - 2) * (height - 2))
        let mean = sum / count
        return squares / count - mean * mean
    }
}
