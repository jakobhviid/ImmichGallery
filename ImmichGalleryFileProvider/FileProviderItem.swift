import FileProvider
import UniformTypeIdentifiers

/// A `ProviderItem` as the system sees it.
final class FileProviderItem: NSObject, NSFileProviderItem {
    let item: ProviderItem

    init(_ item: ProviderItem) { self.item = item }

    var itemIdentifier: NSFileProviderItemIdentifier { NSFileProviderItemIdentifier(item.identifier) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { NSFileProviderItemIdentifier(item.parent) }
    var filename: String { item.name }
    var contentType: UTType { item.contentType }
    var capabilities: NSFileProviderItemCapabilities { NSFileProviderItemCapabilities(rawValue: item.capabilities.rawValue) }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: item.contentVersion, metadataVersion: item.metadataVersion)
    }
    var documentSize: NSNumber? { item.size.map { NSNumber(value: $0) } }
    var childItemCount: NSNumber? { item.childCount.map { NSNumber(value: $0) } }
    var creationDate: Date? { item.created }
    var contentModificationDate: Date? { item.modified }
    /// Originals download when opened; Finder can remove the download again.
    var contentPolicy: NSFileProviderContentPolicy { .downloadLazily }

    /// Photos are read-only on disk (Immich can't replace an original); folders are writable only where adding works.
    var fileSystemFlags: NSFileProviderFileSystemFlags {
        if item.isFolder {
            return item.capabilities.contains(.writing) ? [.userReadable, .userWritable, .userExecutable] : [.userReadable, .userExecutable]
        }
        return [.userReadable]
    }
}
