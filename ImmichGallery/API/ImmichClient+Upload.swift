import Foundation
import Darwin
import CryptoKit
import UniformTypeIdentifiers

extension ImmichClient {
    func uploadMediaTypes() async throws -> UploadMediaTypes { try await get("server/media-types") }

    func checkUpload(checksum: String, name: String) async throws -> UploadCheckResponse {
        struct Item: Encodable { let id: String; let checksum: String }
        struct Body: Encodable { let assets: [Item] }
        return try await send("POST", "assets/bulk-upload-check", body: Body(assets: [Item(id: name, checksum: checksum)]))
    }

    func addUploadToAlbum(_ assetID: String, albumID: String) async throws {
        struct Body: Encodable { let ids: [String] }
        let results: [UploadAlbumResult] = try await send("PUT", "albums/\(albumID)/assets", body: Body(ids: [assetID]))
        guard let result = results.first, result.success || result.error == "duplicate" else {
            throw ImmichError.http(400, results.first?.errorMessage ?? String(localized: "Could not add the imported item to the album."))
        }
    }

    /// `name` and the dates override the file's own (the File Provider uploads a system copy of the dropped file).
    func uploadFile(_ file: URL, checksum: String, legacy: Bool, name: String? = nil, created: Date? = nil, modified: Date? = nil,
                    progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> UploadResponse {
        let preparation = Task.detached { try UploadMultipart.make(file, legacy: legacy, name: name, created: created, modified: modified) }
        let multipart = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: { preparation.cancel() }
        defer { try? FileManager.default.removeItem(at: multipart.file) }
        try Task.checkCancellation()
        var request = try request("assets", method: "POST")
        request.timeoutInterval = 3600
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(checksum, forHTTPHeaderField: "x-immich-checksum")
        // A dedicated configuration also covers URLSession's request-level idle timeout.
        let configuration = session.configuration
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        let uploadSession = URLSession(configuration: configuration)
        defer { uploadSession.finishTasksAndInvalidate() }
        let size = try multipart.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        progress(0, Int64(size))
        let (data, response) = try await uploadSession.upload(for: request, fromFile: multipart.file, delegate: UploadProgress(progress))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ImmichError.unauthorized(nil) }
            struct Failure: Decodable { let message: String? }
            throw ImmichError.http(http.statusCode, (try? JSONDecoder().decode(Failure.self, from: data))?.message)
        }
        return try JSONDecoder().decode(UploadResponse.self, from: data)
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var lastUpdate = ProcessInfo.processInfo.systemUptime
    let update: @Sendable (Int64, Int64) -> Void
    init(_ update: @escaping @Sendable (Int64, Int64) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let emit = now - lastUpdate >= 0.1
        if emit { lastUpdate = now }
        lock.unlock()
        if emit { update(totalBytesSent, totalBytesExpectedToSend) }
    }
}

/// A disk-backed multipart body keeps memory bounded even for large videos.
struct UploadMultipart: Sendable {
    let file: URL
    let boundary: String

    /// Only remove our own bodies whose owner process has exited, including crashed copies.
    static func sweepStale(in directory: URL = FileManager.default.temporaryDirectory) {
        let prefix = "ImmichGallery-upload-"
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            let name = file.lastPathComponent
            guard name.hasPrefix(prefix),
                  let pid = Int32(name.dropFirst(prefix.count).split(separator: "-").first ?? ""), pid > 0,
                  kill(pid, 0) == -1, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func checksum(_ file: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = Insecure.SHA1()
        while try autoreleasepool(invoking: { () throws -> Bool in
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            hash.update(data: chunk)
            return true
        }) {}
        return Data(hash.finalize()).base64EncodedString()
    }

    static func make(_ source: URL, legacy: Bool, name: String? = nil, created: Date? = nil, modified: Date? = nil) throws -> UploadMultipart {
        let boundary = "ImmichGallery-\(UUID().uuidString)"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ImmichGallery-upload-\(getpid())-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            func write(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
            let dates = try source.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let fileName = name ?? source.lastPathComponent
            let modified = modified ?? dates.contentModificationDate ?? created ?? dates.creationDate ?? Date()
            let formatter = ISO8601DateFormatter()
            var fields = ["fileCreatedAt": formatter.string(from: created ?? dates.creationDate ?? modified),
                          "fileModifiedAt": formatter.string(from: modified), "isFavorite": "false"]
            // v2 requires device identifiers; v3 removed them from the upload DTO.
            if legacy {
                fields["deviceId"] = "ImmichGallery"
                fields["deviceAssetId"] = "mac-\(fileName)-\(modified.timeIntervalSince1970)"
            }
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
            }
            let name = fileName.replacingOccurrences(of: "\r", with: "_")
                .replacingOccurrences(of: "\n", with: "_").replacingOccurrences(of: "\"", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
            let mime = UTType(filenameExtension: (fileName as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\n\r\n")
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            while try autoreleasepool(invoking: { () throws -> Bool in
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                try output.write(contentsOf: chunk)
                return true
            }) {}
            try write("\r\n--\(boundary)--\r\n")
            return UploadMultipart(file: file, boundary: boundary)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}
