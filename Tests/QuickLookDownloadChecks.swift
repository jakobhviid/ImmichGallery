// The runner compiles the real MacQuickLook with private visibility opened in a temporary copy.
// No panel is opened: selected IDs are cleared before a successful download is delivered.
import Foundation

@MainActor final class FakeOriginalClient {
    var pending: [String: [CheckedContinuation<URL, Error>]] = [:]
    func macIntegrationOriginal(_ id: String, preview: Bool) async throws -> URL {
        try await withCheckedThrowingContinuation { pending[id, default: []].append($0) }
    }
}
@MainActor final class LibrarySession {
    let client = FakeOriginalClient()
    func handle(_ error: Error) {}
}
@MainActor enum MacTransferCache {
    static var releases: [URL] = []
    static func release(_ url: URL, remove: Bool) { releases.append(url) }
}
extension Error { var isCancellation: Bool { self is CancellationError } }

@main struct QuickLookDownloadChecks {
    @MainActor static func main() async {
        for oldSucceeds in [false, true] {
            for reopen in [false, true] {
                let session = LibrarySession(), quickLook = MacQuickLook()
                quickLook.session = session
                quickLook.show(["first"], ahead: ["A"])
                while session.client.pending["A"]?.count != 1 { await Task.yield() }
                if reopen {
                    quickLook.generation = UUID()
                    quickLook.cleanUp()
                    quickLook.session = session
                    quickLook.show(["A"], ahead: [])
                } else {
                    quickLook.follow(["second"], ahead: [])
                    quickLook.follow(["A"], ahead: [])
                }
                while session.client.pending["A"]?.count != 2 { await Task.yield() }
                let replacement = quickLook.loading["A"]!.token
                let old = session.client.pending["A"]!.removeFirst()
                if oldSucceeds { old.resume(returning: URL(fileURLWithPath: "/tmp/quicklook-check-old/A.png")) }
                else { old.resume(throwing: CancellationError()) }
                for _ in 0..<30 { await Task.yield() }
                precondition(quickLook.loading["A"]?.token == replacement, "An old completion must not remove its replacement")
                quickLook.ids = [] // Keep this offline: the real update() must not request a QLPreviewPanel.
                let valid = URL(fileURLWithPath: "/tmp/quicklook-check-new/A.png")
                session.client.pending["A"]!.removeFirst().resume(returning: valid)
                for _ in 0..<100 where quickLook.files["A"] == nil { await Task.yield() }
                precondition(quickLook.files["A"] == valid && quickLook.loading["A"] == nil)
                quickLook.cleanUp()
                for continuations in session.client.pending.values {
                    for continuation in continuations { continuation.resume(throwing: CancellationError()) }
                }
                for _ in 0..<30 { await Task.yield() }
            }
        }
        print("Quick Look replacement downloads survive late cancellation and success, including reopen")
    }
}
