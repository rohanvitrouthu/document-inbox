import AppKit
import Foundation

struct InboxError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}

@main
enum InboxCommand {
    static let usage = """
        Usage:
          inbox [--db <path>] index <folder>
          inbox [--db <path>] search <query>
          inbox open [--print-path] <file> [<page>]

        Searches use literal words, not SQLite query syntax. Quote a multiword
        query or pass it as separate arguments. Page numbers start at 1.
        With --print-path, prepare the preview without launching a viewer.
        """

    static func main() {
        do {
            exit(try run(Array(CommandLine.arguments.dropFirst())))
        } catch {
            writeError("inbox: \(error.localizedDescription)")
            exit(EXIT_FAILURE)
        }
    }

    static func run(_ arguments: [String]) throws -> Int32 {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
            print(usage)
            return EXIT_SUCCESS
        }

        var args = ArraySlice(arguments)
        var database: URL?
        if args.first == "--db" {
            args.removeFirst()
            guard let path = args.popFirst(), !path.isEmpty else { throw InboxError(usage) }
            database = URL(fileURLWithPath: path)
        }
        guard let command = args.popFirst() else { throw InboxError(usage) }

        switch command {
        case "index":
            guard args.count == 1, let folder = args.first, !folder.isEmpty else {
                throw InboxError(usage)
            }
            let report = try indexFolder(
                URL(fileURLWithPath: folder, isDirectory: true),
                into: database ?? defaultDatabase()
            )
            for failure in report.failures { writeError("inbox: \(failure)") }
            print("Indexed \(report.indexed), skipped \(report.skipped) unchanged, removed \(report.removed), failed \(report.failures.count).")
            return report.failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE
        case "search":
            let query = args.joined(separator: " ")
            guard !query.split(whereSeparator: \.isWhitespace).isEmpty else {
                throw InboxError(usage)
            }
            let store = try IndexStore(url: database ?? defaultDatabase(), writable: false)
            let hits = try store.search(query)
            if hits.isEmpty { print("No matches.") }
            for hit in hits {
                print("\(hit.path) (page \(hit.page))")
                let excerpt = hit.snippet.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                print("  \(excerpt)")
            }
        case "open":
            let printPath = args.first == "--print-path"
            if printPath { args.removeFirst() }
            guard database == nil, (1...2).contains(args.count),
                  let path = args.popFirst(), !path.isEmpty else { throw InboxError(usage) }
            let page = try args.first.map { value in
                guard let number = Int(value), number > 0 else {
                    throw InboxError("Page must be a positive integer.")
                }
                return number
            } ?? 1
            let target = try previewURL(for: URL(fileURLWithPath: path), page: page)
            if printPath {
                print(target.path)
            } else if !NSWorkspace.shared.open(target) {
                throw InboxError("macOS could not open \(target.path). Is a desktop session available?")
            }
        default:
            throw InboxError(usage)
        }
        return EXIT_SUCCESS
    }

    private static func defaultDatabase() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        .appendingPathComponent("DocumentInbox", isDirectory: true)
        .appendingPathComponent("index.sqlite3")
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
