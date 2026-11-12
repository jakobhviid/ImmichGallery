import Foundation

struct ExploreFolderNode: Identifiable, Hashable {
    let id: String
    var children: [ExploreFolderNode]?
    var name: String { URL(fileURLWithPath: id).lastPathComponent }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func tree(_ paths: [String]) -> [Self] {
        var children: [String: Set<String>] = [:]
        for path in paths {
            var parent = ""
            for part in path.split(separator: "/") {
                let next = parent + "/" + part
                children[parent, default: []].insert(next)
                parent = next
            }
        }
        func nodes(_ parent: String) -> [Self] {
            (children[parent] ?? []).sorted().map { path in
                let nested = nodes(path)
                return Self(id: path, children: nested.isEmpty ? nil : nested)
            }
        }
        return nodes("")
    }
}

