import PDFKit

/// Owns a private PDFKit snapshot for trimming and sidebar thumbnails.
/// Only images and rectangles cross back to the main actor; the displayed
/// PDFDocument is never accessed by background rendering work.
actor PDFPageRenderer {
    private let data: Data
    private let fileHash: String
    private lazy var document = PDFDocument(data: data)

    init(data: Data, fileHash: String) {
        self.data = data
        self.fileHash = fileHash
    }

    struct TextRange: Sendable {
        let pageIndex: Int
        let range: NSRange
    }

    /// Preserve PDFKit's matching semantics (including multi-page selections)
    /// while transferring only character ranges to the displayed document.
    func search(_ query: String) throws -> [[TextRange]] {
        try Task.checkCancellation()
        guard let document else { throw CocoaError(.fileReadCorruptFile) }
        let selections = document.findString(query, withOptions: [.caseInsensitive])
        try Task.checkCancellation()
        return selections.map { selection in
            selection.pages.flatMap { page in
                (0..<selection.numberOfTextRanges(on: page)).map {
                    TextRange(pageIndex: document.index(for: page), range: selection.range(at: $0, on: page))
                }
            }
        }
    }

    func ocrImage(at index: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard let page = page(at: index) else { throw CocoaError(.fileReadCorruptFile) }
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(2, 2_000 / max(bounds.width, bounds.height))
        guard bounds.width > 0, bounds.height > 0,
              let image = render(page, size: CGSize(width: bounds.width * scale, height: bounds.height * scale)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return image
    }

    func cropBox(at index: Int) -> CGRect? {
        guard !Task.isCancelled, let page = page(at: index) else { return nil }
        let mediaBox = page.bounds(for: .mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else { return nil }
        let scale = min(1000 / mediaBox.width, 1000 / mediaBox.height, 2.0)
        let size = CGSize(width: mediaBox.width * scale, height: mediaBox.height * scale)
        guard let image = render(page, size: size) else { return nil }
        let rect = ContentTrimmer.shared.contentRect(for: image, key: "pdf-crop-\(fileHash)-\(index)")
        guard rect != CGRect(x: 0, y: 0, width: 1, height: 1) else { return nil }
        return CGRect(
            x: mediaBox.minX + rect.minX * mediaBox.width,
            y: mediaBox.minY + (1 - rect.maxY) * mediaBox.height,
            width: rect.width * mediaBox.width,
            height: rect.height * mediaBox.height
        )
    }

    func thumbnail(at index: Int, width: CGFloat) -> CGImage? {
        guard !Task.isCancelled, let page = page(at: index) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard width > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        return render(page, size: CGSize(width: width, height: width * bounds.height / bounds.width))
    }

    private func page(at index: Int) -> PDFPage? {
        guard let document, (0..<document.pageCount).contains(index) else { return nil }
        return document.page(at: index)
    }

    private func render(_ page: PDFPage, size: CGSize) -> CGImage? {
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)
        #if canImport(UIKit)
        return thumbnail.cgImage
        #else
        return thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
}
