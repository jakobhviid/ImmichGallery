// Compile alongside API/Models.swift and API/Models+People.swift, then run with
// an optional directory containing live people.json, person.json, statistics.json and faces.json.
import Foundation
import CoreGraphics

@main struct PeopleChecks {
    static func main() throws {
        let decoder = JSONDecoder()
        let faceJSON = #"{"id":"face","imageWidth":100,"imageHeight":100,"boundingBoxX1":25,"boundingBoxY1":20,"boundingBoxX2":75,"boundingBoxY2":60,"person":null}"#
        let face = try decoder.decode(PeopleFace.self, from: Data(faceJSON.utf8))
        assert(face.person == nil)
        // The photo drawn at twice its size: the box is the same share of it.
        assert(face.rect(in: CGSize(width: 200, height: 200)) == CGRect(x: 50, y: 40, width: 100, height: 80))
        assert(face.rect(in: .zero) == .zero)
        let edit = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PersonEdit(clearBirthDate: true))) as! [String: Any]
        assert(edit["birthDate"] is NSNull)
        assert(edit["name"] == nil && edit["clearBirthDate"] == nil)
        let unchanged = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PersonEdit(name: "New Name"))) as! [String: Any]
        assert(unchanged["birthDate"] == nil)
        if CommandLine.arguments.count > 1 {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            _ = try decoder.decode(PeopleResponse.self, from: Data(contentsOf: root.appendingPathComponent("people.json")))
            _ = try decoder.decode(Person.self, from: Data(contentsOf: root.appendingPathComponent("person.json")))
            _ = try decoder.decode(PeopleStatistics.self, from: Data(contentsOf: root.appendingPathComponent("statistics.json")))
            let faces = try decoder.decode([PeopleFace].self, from: Data(contentsOf: root.appendingPathComponent("faces.json")))
            assert(!faces.isEmpty)
            print("Live People, Person, Statistics and Face DTO decoding passed.")
        }
        print("Face geometry and birthday patch checks passed.")
    }
}
