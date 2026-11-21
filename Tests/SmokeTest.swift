import AppKit
import CoreText
import PDFKit

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func check(_ condition: Bool, _ description: String) throws {
    guard condition else { throw TestFailure(description) }
}

func require<T>(_ value: T?, _ description: String) throws -> T {
    guard let value else { throw TestFailure(description) }
    return value
}

struct RunResult {
    let status: Int32
    let output: String

    func expect(_ text: String, status expected: Int32 = 0) throws {
        try check(status == expected && output.contains(text),
                  "Expected status \(expected) and \(String(reflecting: text)), got \(status):\n\(output)")
    }
}

func run(_ executable: URL, _ arguments: [String]) throws -> RunResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return RunResult(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
}

private let pageBounds = CGRect(x: 0, y: 0, width: 1_200, height: 600)

func drawText(_ text: String, in context: CGContext) {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 60, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textPosition = CGPoint(x: 90, y: 320)
    CTLineDraw(line, context)
}

func makeImage(_ text: String) throws -> CGImage {
    let context = try require(CGContext(
        data: nil, width: Int(pageBounds.width), height: Int(pageBounds.height),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ), "Could not create image fixture context")
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(pageBounds)
    drawText(text, in: context)
    return try require(context.makeImage(), "Could not create image fixture")
}

func writeImage(_ text: String, as type: NSBitmapImageRep.FileType, to url: URL) throws {
    let bitmap = NSBitmapImageRep(cgImage: try makeImage(text))
    let data = try require(bitmap.representation(using: type, properties: [:]), "Could not encode image fixture")
    try data.write(to: url)
}

func writeMixedPDF(to url: URL) throws {
    var bounds = pageBounds
    let context = try require(CGContext(url as CFURL, mediaBox: &bounds, nil), "Could not create PDF fixture")
    context.beginPDFPage(nil)
    drawText("ALPHA OR BETA INVOICE-123", in: context)
    context.endPDFPage()
    context.beginPDFPage(nil)
    context.draw(try makeImage("ORANGE SCANNER"), in: bounds)
    context.endPDFPage()
    context.beginPDFPage(nil)
    drawText("ALPHA", in: context)
    context.endPDFPage()
    context.closePDF()

    let document = try require(PDFDocument(url: url), "Could not reopen PDF fixture")
    try check(document.page(at: 0)?.string?.contains("INVOICE-123") == true, "PDF fixture must have embedded text")
    try check(document.page(at: 1)?.string?.isEmpty ?? true, "Page 2 must require OCR")
}

func smokeTest(_ executable: URL) throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("inbox-test-\(UUID().uuidString)", isDirectory: true)
    let folder = root.appendingPathComponent("Drop folder", isDirectory: true)
    let nested = folder.appendingPathComponent("Screenshots", isDirectory: true)
    try files.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    let db = root.appendingPathComponent("Index/index.sqlite3").path
    func inbox(_ arguments: String...) throws -> RunResult {
        try run(executable, ["--db", db] + arguments)
    }

    let pdf = folder.appendingPathComponent("Mixed pages.pdf")
    let png = nested.appendingPathComponent("Today's screen.PNG")
    let jpeg = folder.appendingPathComponent("Photo.jpeg")
    try writeMixedPDF(to: pdf)
    try writeImage("MORNING CONSOLE", as: .png, to: png)
    try writeImage("GARDEN CAMERA", as: .jpeg, to: jpeg)
    try writeImage("HIDDEN", as: .png, to: folder.appendingPathComponent(".hidden.png"))
    try writeImage("IGNORED", as: .png, to: folder.appendingPathComponent("ignored.bmp"))
    try files.createSymbolicLink(at: folder.appendingPathComponent("link.png"), withDestinationURL: png)

    try inbox("search", "invoice").expect("Run `inbox index <folder>` first.", status: 1)
    try inbox("index", folder.path).expect("Indexed 3, skipped 0 unchanged, removed 0, failed 0.")
    try inbox("search", "\"invoice-123\"").expect("Mixed pages.pdf (page 1)")
    let literalHit = try inbox("search", "alpha OR beta")
    try literalHit.expect("Mixed pages.pdf (page 1)")
    try literalHit.expect("[OR]")
    try check(!literalHit.output.contains("(page 3)"), "Search must treat OR as a literal word")
    let scanHit = try inbox("search", "scanner", "orange")
    try scanHit.expect("Mixed pages.pdf (page 2)")
    try scanHit.expect("[ORANGE]")
    try inbox("search", "console").expect("Today's screen.PNG (page 1)")
    try inbox("search", "camera").expect("Photo.jpeg (page 1)")
    for query in ["hidden", "ignored", "text:alpha", "\""] {
        try inbox("search", query).expect("No matches.")
    }

    let previewResult = try run(executable, ["open", "--print-path", pdf.path, "2"])
    try previewResult.expect("Mixed pages - page 2.pdf")
    let preview = URL(fileURLWithPath: previewResult.output.trimmingCharacters(in: .newlines))
    let previewFolder = preview.deletingLastPathComponent()
    try check(previewFolder.deletingLastPathComponent() == files.temporaryDirectory.standardizedFileURL
              && previewFolder.lastPathComponent.hasPrefix("document-inbox-"), "Expected a private temp preview path")
    defer { try? files.removeItem(at: previewFolder) }
    let document = try require(PDFDocument(url: preview), "Could not read generated PDF preview")
    try check(document.pageCount == 1, "Expected a single-page preview")
    let previewDB = root.appendingPathComponent("preview.sqlite3").path
    try run(executable, ["--db", previewDB, "index", previewFolder.path]).expect("Indexed 1")
    try run(executable, ["--db", previewDB, "search", "orange"]).expect("Mixed pages - page 2.pdf (page 1)")
    try run(executable, ["open", "--print-path", pdf.path, "4"]).expect("out of range", status: 1)
    try run(executable, ["open", "--print-path", png.path]).expect(png.path)
    try run(executable, ["open", "--print-path", png.path, "2"]).expect("Images only have page 1.", status: 1)

    try inbox("index", folder.path).expect("Indexed 0, skipped 3 unchanged, removed 0, failed 0.")
    try Data("not a PNG".utf8).write(to: png)
    try inbox("index", folder.path).expect("Indexed 0, skipped 2 unchanged, removed 0, failed 1.", status: 1)
    try inbox("search", "console").expect("Today's screen.PNG (page 1)")
    try writeImage("AFTERNOON NOTEBOOK", as: .png, to: png)
    try files.removeItem(at: jpeg)
    try inbox("index", folder.path).expect("Indexed 1, skipped 1 unchanged, removed 1, failed 0.")
    try inbox("search", "console").expect("No matches.")
    try inbox("search", "camera").expect("No matches.")
    try inbox("search", "notebook").expect("Today's screen.PNG (page 1)")
    try inbox("index", nested.path).expect("This index belongs to", status: 1)
    try inbox("search", "invoice").expect("Mixed pages.pdf (page 1)")
}

do {
    let path = try require(CommandLine.arguments.dropFirst().first, "Pass the path to the inbox executable.")
    try smokeTest(URL(fileURLWithPath: path))
    print("Inbox smoke test passed.")
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
