import Foundation
import SQLite3

struct SearchHit: Equatable {
    let path: String
    let page: Int
    let snippet: String
}

final class IndexStore {
    private let connection: OpaquePointer

    init(url: URL, writable: Bool) throws {
        let files = FileManager.default
        if writable {
            let directory = url.deletingLastPathComponent()
            if !files.fileExists(atPath: directory.path) {
                try files.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
                )
            }
        } else if !files.fileExists(atPath: url.path) {
            throw InboxError("No index at \(url.path). Run `inbox index <folder>` first.")
        }
        var handle: OpaquePointer?
        let flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let error = databaseError(handle)
            sqlite3_close(handle)
            throw error
        }
        connection = handle
        sqlite3_busy_timeout(handle, 5_000)
        if writable {
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS inbox (id INTEGER PRIMARY KEY CHECK (id = 1), root TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS documents (path TEXT PRIMARY KEY, modified REAL NOT NULL, size INTEGER NOT NULL)")
                try execute("CREATE VIRTUAL TABLE IF NOT EXISTS pages USING fts5(path UNINDEXED, page UNINDEXED, text)")
            }
        }
    }

    deinit { sqlite3_close(connection) }

    func transaction<T>(_ action: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try action()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func bindRoot(_ root: String) throws {
        try statement("INSERT INTO inbox (id, root) VALUES (1, ?) ON CONFLICT(id) DO NOTHING") { stmt in
            try bind(root, to: 1, in: stmt)
            try finish(stmt)
        }
        try statement("SELECT root FROM inbox WHERE id = 1") { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw databaseError(connection) }
            let existing = text(at: 0, in: stmt)
            guard existing == root else {
                throw InboxError("This index belongs to \(existing). Use --db with a different database to index \(root).")
            }
        }
    }

    func documents() throws -> [String: FileStamp] {
        try statement("SELECT path, modified, size FROM documents") { stmt in
            var result: [String: FileStamp] = [:]
            while try nextRow(stmt) {
                result[text(at: 0, in: stmt)] = FileStamp(
                    modified: sqlite3_column_double(stmt, 1), size: sqlite3_column_int64(stmt, 2)
                )
            }
            return result
        }
    }

    func remove(_ path: String) throws {
        for sql in ["DELETE FROM pages WHERE path = ?", "DELETE FROM documents WHERE path = ?"] {
            try statement(sql) { stmt in
                try bind(path, to: 1, in: stmt)
                try finish(stmt)
            }
        }
    }

    func insert(_ path: String, stamp: FileStamp, pages: [String]) throws {
        try statement("INSERT INTO documents (path, modified, size) VALUES (?, ?, ?)") { stmt in
            try bind(path, to: 1, in: stmt)
            try check(sqlite3_bind_double(stmt, 2, stamp.modified))
            try check(sqlite3_bind_int64(stmt, 3, stamp.size))
            try finish(stmt)
        }
        try statement("INSERT INTO pages (path, page, text) VALUES (?, ?, ?)") { stmt in
            try bind(path, to: 1, in: stmt)
            for (index, text) in pages.enumerated() where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try check(sqlite3_bind_int64(stmt, 2, Int64(index + 1)))
                try bind(text, to: 3, in: stmt)
                try finish(stmt)
                try check(sqlite3_reset(stmt))
            }
        }
    }

    func search(_ query: String) throws -> [SearchHit] {
        // Do not interpret the caller's input as FTS operators or column names.
        let words = query.split(whereSeparator: \.isWhitespace)
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        guard !words.isEmpty else { return [] }
        return try statement("""
            SELECT path, page, snippet(pages, 2, '[', ']', '…', 20) FROM pages
            WHERE pages MATCH ? ORDER BY rank, path, page LIMIT 20
            """) { stmt in
            try bind(words.joined(separator: " AND "), to: 1, in: stmt)
            var hits: [SearchHit] = []
            while try nextRow(stmt) {
                hits.append(SearchHit(path: text(at: 0, in: stmt),
                                      page: Int(sqlite3_column_int64(stmt, 1)),
                                      snippet: text(at: 2, in: stmt)))
            }
            return hits
        }
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(connection, sql, nil, nil, nil))
    }

    private func statement<T>(_ sql: String, _ action: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        try check(sqlite3_prepare_v2(connection, sql, -1, &stmt, nil))
        guard let stmt else { throw InboxError("SQLite did not prepare a statement.") }
        defer { sqlite3_finalize(stmt) }
        return try action(stmt)
    }

    private func bind(_ string: String, to index: Int32, in stmt: OpaquePointer) throws {
        // SQLITE_TRANSIENT makes SQLite copy the buffer before the closure returns.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let count = string.utf8.count
        try string.withCString { ptr in
            try check(sqlite3_bind_text64(stmt, index, ptr, UInt64(count), transient, UInt8(SQLITE_UTF8)))
        }
    }

    private func text(at column: Int32, in stmt: OpaquePointer) -> String {
        guard let bytes = sqlite3_column_text(stmt, column) else { return "" }
        let count = Int(sqlite3_column_bytes(stmt, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    private func nextRow(_ stmt: OpaquePointer) throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw databaseError(connection)
        }
    }

    private func finish(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError(connection) }
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw databaseError(connection) }
    }
}

private func databaseError(_ connection: OpaquePointer?) -> InboxError {
    let message = sqlite3_errmsg(connection).map { String(cString: $0) } ?? "Could not open database."
    return InboxError("SQLite: \(message)")
}
