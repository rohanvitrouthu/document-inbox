import AppKit
import ImageIO
import PDFKit
import Vision

enum DocumentKind {
    case pdf, image

    init?(file: URL) {
        switch file.pathExtension.lowercased() {
        case "pdf": self = .pdf
        case "png", "jpg", "jpeg": self = .image
        default: return nil
        }
    }
}

private let maxOCRDimension = 3_200

func extractPages(from file: URL) throws -> [String] {
    switch DocumentKind(file: file) {
    case .pdf:
        let document = try loadPDF(file)
        return try (0..<document.pageCount).map { index in
            try autoreleasepool {
                do {
                    guard let page = document.page(at: index) else {
                        throw InboxError("Could not load PDF page.")
                    }
                    if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return text
                    }
                    return try recognizeText(in: renderPDFPage(page))
                } catch {
                    throw InboxError("Page \(index + 1): \(error.localizedDescription)")
                }
            }
        }
    case .image:
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxOCRDimension,
        ]
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw InboxError("Could not decode image.")
        }
        return [try recognizeText(in: image)]
    case nil:
        throw InboxError("Unsupported file type: \(file.path)")
    }
}

func previewURL(for file: URL, page: Int) throws -> URL {
    guard page > 0 else { throw InboxError("Page must be a positive integer.") }
    switch DocumentKind(file: file) {
    case .pdf:
        let document = try loadPDF(file)
        guard page <= document.pageCount else {
            throw InboxError("Page \(page) is out of range (PDF has \(document.pageCount) pages).")
        }
        guard let copy = document.page(at: page - 1)?.copy() as? PDFPage else {
            throw InboxError("Could not copy PDF page \(page).")
        }
        let preview = PDFDocument()
        preview.insert(copy, at: 0)
        guard let data = preview.dataRepresentation() else {
            throw InboxError("Could not create a preview for page \(page).")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("document-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent) - page \(page).pdf")
        try data.write(to: url, options: .atomic)
        return url
    case .image:
        guard page == 1 else { throw InboxError("Images only have page 1.") }
        guard FileManager.default.isReadableFile(atPath: file.path),
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw InboxError("Could not read image: \(file.path)")
        }
        return file
    case nil:
        throw InboxError("Unsupported file type: \(file.path)")
    }
}

private func loadPDF(_ file: URL) throws -> PDFDocument {
    guard let document = PDFDocument(url: file) else { throw InboxError("Could not open PDF.") }
    guard !document.isLocked else { throw InboxError("PDF is password-protected.") }
    guard document.pageCount > 0 else { throw InboxError("PDF has no pages.") }
    return document
}

private func renderPDFPage(_ page: PDFPage) throws -> CGImage {
    let size = page.bounds(for: .cropBox).size
    let longestSide = max(size.width, size.height)
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
        throw InboxError("PDF page has invalid dimensions.")
    }
    let scale = CGFloat(maxOCRDimension) / longestSide
    let target = CGSize(width: max(1, (size.width * scale).rounded()),
                        height: max(1, (size.height * scale).rounded()))
    let thumbnail = page.thumbnail(of: target, for: .cropBox)
    guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw InboxError("Could not render PDF page for OCR.")
    }
    return image
}

private func recognizeText(in image: CGImage) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
}
