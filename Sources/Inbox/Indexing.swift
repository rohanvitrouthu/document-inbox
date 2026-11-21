import Foundation

struct FileStamp: Equatable {
    let modified: Double
    let size: Int64

    init(modified: Double, size: Int64) {
        self.modified = modified
        self.size = size
    }

    init(file: URL) throws {
        // Use a fresh URL so Foundation doesn't reuse metadata from enumeration.
        let values = try URL(fileURLWithPath: file.path).resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let modified = values.contentModificationDate, let size = values.fileSize else {
            throw InboxError("Could not read file metadata.")
        }
        self.init(modified: modified.timeIntervalSince1970, size: Int64(size))
    }
}

struct IndexReport {
    var indexed = 0
    var skipped = 0
    var removed = 0
    var failures: [String] = []
}

func indexFolder(_ folder: URL, into database: URL) throws -> IndexReport {
    let root = folder.standardizedFileURL.resolvingSymlinksInPath()
    guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
        throw InboxError("Not a directory: \(root.path)")
    }
    let store = try IndexStore(url: database, writable: true)
    return try store.transaction {
        try store.bindRoot(root.path)
        let previous = try store.documents()
        let files = try discoverDocuments(in: root)
        let present = Set(files.map(\.path))
        var report = IndexReport()
        for file in files {
            let stamp: FileStamp
            let pages: [String]
            do {
                stamp = try FileStamp(file: file)
                if previous[file.path] == stamp {
                    report.skipped += 1
                    continue
                }
                pages = try autoreleasepool { try extractPages(from: file) }
                guard try FileStamp(file: file) == stamp else {
                    throw InboxError("File changed during indexing; run index again.")
                }
            } catch {
                // Don't replace a previous successful extraction with a failed one.
                report.failures.append("\(file.path): \(error.localizedDescription)")
                continue
            }
            if previous[file.path] != nil { try store.remove(file.path) }
            try store.insert(file.path, stamp: stamp, pages: pages)
            report.indexed += 1
        }
        for path in previous.keys where !present.contains(path) {
            try store.remove(path)
            report.removed += 1
        }
        return report
    }
}

private func discoverDocuments(in root: URL) throws -> [URL] {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
    var traversalError: (URL, Error)?
    guard let entries = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles, .skipsPackageDescendants],
        errorHandler: { url, error in
            traversalError = (url, error)
            return false
        }
    ) else {
        throw InboxError("Could not read folder: \(root.path)")
    }
    var files: [URL] = []
    for case let file as URL in entries where DocumentKind(file: file) != nil {
        let values = try file.resourceValues(forKeys: keys)
        if values.isRegularFile == true, values.isSymbolicLink != true { files.append(file) }
    }
    if let (url, error) = traversalError {
        throw InboxError("Could not scan \(url.path): \(error.localizedDescription)")
    }
    return files.sorted { $0.path < $1.path }
}
