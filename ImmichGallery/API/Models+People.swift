import Foundation
import CoreGraphics

struct PeopleStatistics: Decodable, Sendable { let assets: Int }

struct PeopleOperationResult: Decodable, Sendable {
    let id: String
    let success: Bool
    let error: String?
    let errorMessage: String?
}

struct PersonEdit: Encodable, Sendable {
    var name: String?
    var birthDate: String?
    var clearBirthDate = false
    var isHidden: Bool?
    var isFavorite: Bool?
    var featureFaceAssetId: String?

    enum CodingKeys: String, CodingKey { case name, birthDate, isHidden, isFavorite, featureFaceAssetId }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        if clearBirthDate { try c.encodeNil(forKey: .birthDate) }
        else { try c.encodeIfPresent(birthDate, forKey: .birthDate) }
        try c.encodeIfPresent(isHidden, forKey: .isHidden)
        try c.encodeIfPresent(isFavorite, forKey: .isFavorite)
        try c.encodeIfPresent(featureFaceAssetId, forKey: .featureFaceAssetId)
    }
}

struct PeopleFace: Decodable, Sendable, Identifiable {
    let id: String
    let imageWidth: Int
    let imageHeight: Int
    let boundingBoxX1: Int
    let boundingBoxY1: Int
    let boundingBoxX2: Int
    let boundingBoxY2: Int
    let person: Person?

    /// The face in the photo as drawn at `size`: Immich's box is in the photo's pixels, so it's the same share of it.
    func rect(in size: CGSize) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return .zero }
        let x1 = min(CGFloat(imageWidth), max(0, CGFloat(boundingBoxX1)))
        let y1 = min(CGFloat(imageHeight), max(0, CGFloat(boundingBoxY1)))
        let x2 = min(CGFloat(imageWidth), max(x1, CGFloat(boundingBoxX2)))
        let y2 = min(CGFloat(imageHeight), max(y1, CGFloat(boundingBoxY2)))
        let scaleX = size.width / CGFloat(imageWidth)
        let scaleY = size.height / CGFloat(imageHeight)
        return CGRect(x: x1 * scaleX, y: y1 * scaleY, width: (x2 - x1) * scaleX, height: (y2 - y1) * scaleY)
    }
}

extension Person {
    var displayName: String { name.isEmpty ? String(localized: "Unnamed Person") : name }
    var birthday: Date? {
        guard let birthDate else { return nil }
        return Self.birthdayFormatter.date(from: String(birthDate.prefix(10)))
    }
    static let birthdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
