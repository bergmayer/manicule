import XCTest
import UniformTypeIdentifiers
import ZIPFoundation
import PDFKit
import CoreText
import ImageIO
@testable import Manicule

@MainActor
final class DocumentContentTests: XCTestCase {

    #if !os(macOS)
    func testBookPairingLeavesCoverOnRightThenShowsPagesTwoAndThree() throws {
        let document = try XCTUnwrap(PDFDocument(data: Self.minimalPDF))
        for index in 1..<4 {
            document.insert(try XCTUnwrap(PDFDocument(data: Self.minimalPDF)?.page(at: 0)), at: index)
        }
        for index in [0, 1] {
            let configuration = PDFViewRepresentable(
                pdfDocument: document, currentPageIndex: .constant(index), twoUp: true, coverOnRight: true)
            let controller = PDFSpreadViewController(pageIndex: index, configuration: configuration)
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
            controller.view.layoutIfNeeded()
            let pdf = try XCTUnwrap(controller.pdfView)
            func rect(_ index: Int) throws -> CGRect {
                let page = try XCTUnwrap(document.page(at: index))
                return pdf.convert(pdf.convert(page.bounds(for: .cropBox), from: page), to: controller.view)
            }
            if index == 0 {
                XCTAssertGreaterThanOrEqual(try rect(0).minX, controller.view.bounds.midX - 1)
            } else {
                XCTAssertLessThan(try rect(1).midX, controller.view.bounds.midX)
                XCTAssertGreaterThan(try rect(2).midX, controller.view.bounds.midX)
            }
        }
    }

    func testFacingSpreadDefersPanningToPagerAtFitAndKeepsPinchZoom() throws {
        let document = try XCTUnwrap(PDFDocument(data: Self.minimalPDF))
        let configuration = PDFViewRepresentable(
            pdfDocument: document, currentPageIndex: .constant(0), twoUp: true)
        let controller = PDFSpreadViewController(pageIndex: 0, configuration: configuration)
        controller.loadViewIfNeeded()
        let view = try XCTUnwrap(controller.pdfView)
        controller.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        controller.view.layoutIfNeeded()
        view.layoutIfNeeded()
        let scroll = try XCTUnwrap(scrollView(in: view))
        XCTAssertFalse(scroll.isScrollEnabled)
        XCTAssertTrue(try XCTUnwrap(scroll.pinchGestureRecognizer).isEnabled)
        UIView.performWithoutAnimation { view.toggleZoom() }
        XCTAssertTrue(scroll.isScrollEnabled)
        // A parent update must preserve an in-progress zoom on the existing spread.
        controller.update(configuration)
        XCTAssertEqual(view.scaleFactor / view.scaleFactorForSizeToFit, 2.5, accuracy: 0.01)
        UIView.performWithoutAnimation { view.toggleZoom() }
        XCTAssertFalse(scroll.isScrollEnabled)
        XCTAssertEqual(controller.pageIndex, 0)
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    func testPDFZoomRequestedBeforeLayoutAppliesWhenSpreadBecomesVisible() throws {
        let view = TouchReaderPDFView()
        view.document = try XCTUnwrap(PDFDocument(data: Self.minimalPDF))
        view.displayMode = .twoUp
        view.applyRequestedZoom(2.5)
        view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        view.layoutIfNeeded()
        XCTAssertEqual(view.scaleFactor / view.scaleFactorForSizeToFit, 2.5, accuracy: 0.01)
    }

    func testPDFZoomRemainsNearFitAndDoubleTapTogglesBack() throws {
        let view = TouchReaderPDFView(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        view.document = try XCTUnwrap(PDFDocument(data: Self.minimalPDF))
        view.displayMode = .singlePage
        view.autoScales = true
        view.layoutIfNeeded()
        view.updateZoomLimits()
        let fit = view.scaleFactorForSizeToFit
        XCTAssertGreaterThan(fit, 0)
        view.scaleFactor = fit * 0.1
        XCTAssertEqual(view.scaleFactor, fit * 0.95, accuracy: 0.01)
        UIView.performWithoutAnimation { view.toggleZoom() }
        XCTAssertEqual(view.scaleFactor, fit * 2.5, accuracy: 0.01)
        UIView.performWithoutAnimation { view.toggleZoom() }
        XCTAssertEqual(view.scaleFactor, fit, accuracy: 0.01)
        view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        view.layoutIfNeeded()
        view.updateZoomLimits()
        XCTAssertEqual(view.minScaleFactor, view.scaleFactorForSizeToFit * 0.95, accuracy: 0.01)
        view.applyRequestedZoom(0.1)
        XCTAssertEqual(view.scaleFactor, view.minScaleFactor, accuracy: 0.01)
        // Unrelated SwiftUI updates must preserve a user's pinch or double-tap.
        view.toggleZoom()
        let zoomed = view.scaleFactor
        view.applyRequestedZoom(0.1)
        XCTAssertEqual(view.scaleFactor, zoomed, accuracy: 0.01)
    }
    func testPDFZoomLimitsInPagingSpreadAndContinuousLayouts() async throws {
        for mode in [PDFDisplayMode.singlePage, .twoUp, .singlePageContinuous] {
            let view = TouchReaderPDFView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
            let document = try XCTUnwrap(PDFDocument(data: Self.minimalPDF))
            let secondDocument = try XCTUnwrap(PDFDocument(data: Self.minimalPDF))
            document.insert(try XCTUnwrap(secondDocument.page(at: 0)), at: 1)
            view.document = document
            view.displayMode = mode
            if mode == .singlePage { view.usePageViewController(true) }
            view.autoScales = true
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            let controller = UIViewController()
            controller.view = view
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            // PDFKit's page controller creates its visible page asynchronously.
            for _ in 0..<100 {
                window.layoutIfNeeded()
                view.layoutIfNeeded()
                if view.scaleFactor > 0 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            view.layoutIfNeeded()
            view.updateZoomLimits()
            let fit = view.scaleFactorForSizeToFit
            XCTAssertGreaterThan(fit, 0)
            view.scaleFactor = fit * 0.1
            XCTAssertEqual(view.scaleFactor, fit * 0.95, accuracy: 0.01)
            view.go(to: try XCTUnwrap(document.page(at: 1)))
            view.layoutIfNeeded()
            view.updateZoomLimits()
            XCTAssertEqual(view.minScaleFactor, view.scaleFactorForSizeToFit * 0.95, accuracy: 0.01)
        }
    }
    #endif

    func testPDFRendererProducesThumbnailFromSnapshotAndRejectsInvalidPages() async throws {
        let renderer = PDFPageRenderer(data: Self.minimalPDF, fileHash: "test-pdf")
        let rendered = await renderer.thumbnail(at: 0, width: 160)
        let image = try XCTUnwrap(rendered)
        XCTAssertEqual(Double(image.width) / Double(image.height), 612.0 / 792.0, accuracy: 0.02)
        let missing = await renderer.thumbnail(at: 1, width: 160)
        let negative = await renderer.thumbnail(at: -1, width: 160)
        XCTAssertNil(missing)
        XCTAssertNil(negative)
    }

    func testCoordinatedReadPreservesSourceAndSnapshotAfterReplacement() async throws {
        let original = Data("Café 👋 — original".utf8)
        let directory = try TemporaryDirectoryLease.writing(original, filename: "book.txt")
        let url = directory.url.appendingPathComponent("book.txt")
        let document = try await Task.detached { try ReaderDocument.read(from: url) }.value
        XCTAssertEqual(try Data(contentsOf: url), original)
        try Data("replacement".utf8).write(to: url, options: .atomic)
        XCTAssertEqual(document.rawData, original)
        XCTAssertEqual(document.fileHash, FileHasher.hash(data: original))
        guard case .plainText(let text) = document.content else { return XCTFail("Expected text") }
        XCTAssertEqual(text, "Café 👋 — original")
    }

    func testCoordinatedReadReportsMissingFile() async throws {
        let directory = try TemporaryDirectoryLease.create(prefix: "manicule-test")
        let url = directory.url.appendingPathComponent("missing.txt")
        do {
            _ = try await Task.detached { try ReaderDocument.read(from: url) }.value
            XCTFail("Missing file must fail")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testCancelledReadDoesNotPublishADocument() async throws {
        let directory = try TemporaryDirectoryLease.writing(Data("text".utf8), filename: "book.txt")
        let url = directory.url.appendingPathComponent("book.txt")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ReaderDocument.read(from: url)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled read must fail")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testRenderWorkspaceIsUniqueAndRemovedAfterRelease() throws {
        let data = Data("<p>Rendered text</p>".utf8)
        var first: TemporaryDirectoryLease? = try .writing(data, filename: "content.html")
        let firstURL = try XCTUnwrap(first?.url)
        let second = try TemporaryDirectoryLease.writing(data, filename: "content.html")
        XCTAssertNotEqual(firstURL, second.url)
        XCTAssertEqual(try Data(contentsOf: firstURL.appendingPathComponent("content.html")), data)
        first = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
    }

    func testRenderWorkspaceDoesNotPublishFailedWrite() {
        XCTAssertThrowsError(try TemporaryDirectoryLease.writing(Data(), filename: "missing/content.html"))
    }

    // MARK: - PDF Detection

    func testParsePDFByContentType() throws {
        let data = Self.minimalPDF
        let content = try DocumentContent.parse(data: data, contentType: .pdf)
        guard case .pdf(let pdfData) = content else {
            XCTFail("Expected .pdf, got \(content)")
            return
        }
        XCTAssertEqual(pdfData, data)
    }

    func testParsePDFByExtension() throws {
        let data = Self.minimalPDF
        let content = try DocumentContent.parse(data: data, contentType: .data, filename: "test.pdf")
        guard case .pdf = content else {
            XCTFail("Expected .pdf, got \(content)")
            return
        }
    }

    func testParsePDFByMagicBytes() throws {
        let data = Self.minimalPDF
        let content = try DocumentContent.parse(data: data, contentType: .data)
        guard case .pdf = content else {
            XCTFail("Expected .pdf from magic bytes, got \(content)")
            return
        }
    }

    // MARK: - Plain Text Detection

    func testParsePlainText() throws {
        let text = "Hello, World!"
        let data = text.data(using: .utf8)!
        let content = try DocumentContent.parse(data: data, contentType: .plainText)
        guard case .plainText(let parsed) = content else {
            XCTFail("Expected .plainText, got \(content)")
            return
        }
        XCTAssertEqual(parsed, text)
    }

    func testParsePlainTextByExtension() throws {
        let data = "Test content".data(using: .utf8)!
        let content = try DocumentContent.parse(data: data, contentType: .data, filename: "readme.txt")
        guard case .plainText = content else {
            XCTFail("Expected .plainText, got \(content)")
            return
        }
    }

    func testParseWindows1252TextDoesNotBecomeBlank() throws {
        let data = Data([0x43, 0x61, 0x66, 0xE9]) // Café in Windows-1252/Latin-1
        let content = try DocumentContent.parse(
            data: data, contentType: .plainText, filename: "cafe.txt")
        guard case .plainText(let parsed) = content else {
            return XCTFail("Expected plain text")
        }
        XCTAssertEqual(parsed, "Café")
    }

    func testUTF16TextWithoutBOMUsesNullByteHeuristic() throws {
        let expected = "Hello"
        let data = expected.data(using: .utf16LittleEndian)!
        let content = try DocumentContent.parse(
            data: data, contentType: .plainText, filename: "utf16.txt")
        guard case .plainText(let parsed) = content else {
            return XCTFail("Expected plain text")
        }
        XCTAssertEqual(parsed, expected)
    }

    // MARK: - Markdown Detection

    func testParseMarkdownByExtension() throws {
        let md = "# Hello\n\nSome **bold** text."
        let data = md.data(using: .utf8)!
        let content = try DocumentContent.parse(data: data, contentType: .data, filename: "notes.md")
        guard case .markdown(let parsed) = content else {
            XCTFail("Expected .markdown, got \(content)")
            return
        }
        XCTAssertEqual(parsed, md)
    }

    func testParseMarkdownLongExtension() throws {
        let data = "# Title".data(using: .utf8)!
        let content = try DocumentContent.parse(data: data, contentType: .data, filename: "file.markdown")
        guard case .markdown = content else {
            XCTFail("Expected .markdown for .markdown, got \(content)")
            return
        }
    }

    func testMdownNotTreatedAsMarkdown() {
        let data = "# Title".data(using: .utf8)!
        // .mdown is NOT a recognized markdown extension
        XCTAssertThrowsError(try DocumentContent.parse(data: data, contentType: .data, filename: "file.mdown"))
    }

    // MARK: - ePub Detection

    func testParseEPub() throws {
        let data = try Self.minimalEPub()
        let content = try DocumentContent.parse(data: data, contentType: .epub)
        guard case .epub(let book) = content else {
            XCTFail("Expected .epub, got \(content)")
            return
        }
        XCTAssertEqual(book.metadata.title, "Test Book")
        XCTAssertFalse(book.spine.isEmpty)
    }

    func testParseEPubByExtension() throws {
        let data = try Self.minimalEPub()
        let content = try DocumentContent.parse(data: data, contentType: .data, filename: "book.epub")
        guard case .epub = content else {
            XCTFail("Expected .epub by extension, got \(content)")
            return
        }
    }

    func testParseEPubByMagicBytes() throws {
        let data = try Self.minimalEPub()
        // ZIP magic bytes should trigger ePub detection (has container.xml)
        let content = try DocumentContent.parse(data: data, contentType: .data)
        guard case .epub = content else {
            XCTFail("Expected .epub from magic bytes, got \(content)")
            return
        }
    }

    func testNestedNCXPreservesEachNavPointsOwnTitleAndSource() throws {
        let book = try EPubParser.parse(data: Self.epubWithNestedNCX())
        let parent = try XCTUnwrap(book.tableOfContents.first)
        XCTAssertEqual(parent.title, "Parent")
        XCTAssertEqual(parent.href, "OEBPS/parent.xhtml")
        let child = try XCTUnwrap(parent.children.first)
        XCTAssertEqual(child.title, "Child")
        XCTAssertEqual(child.href, "OEBPS/child.xhtml")
    }

    func testEPubRejectsContainerOPFTraversal() throws {
        let archive = try Archive(accessMode: .create)
        try Self.addTextEntry(to: archive, path: "META-INF/container.xml", content: """
        <?xml version="1.0"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="../../etc/passwd"/></rootfiles>
        </container>
        """)
        let data = try XCTUnwrap(archive.data)
        XCTAssertThrowsError(try EPubParser.parse(data: data))
    }

    func testZipExtractorSkipsTraversalEntry() throws {
        let archive = try Archive(accessMode: .create)
        let escapedName = "manicule-escape-\(UUID().uuidString).txt"
        try Self.addTextEntry(to: archive, path: "../\(escapedName)", content: "nope")
        let extraction = try ZipExtractor.extract(data: try XCTUnwrap(archive.data))
        defer { try? FileManager.default.removeItem(at: extraction) }
        let escaped = extraction.deletingLastPathComponent().appendingPathComponent(escapedName)
        defer { try? FileManager.default.removeItem(at: escaped) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
    }

    func testEPubExtractionIsRemovedWhenBookIsReleased() throws {
        let directory = try Self.makeAndReleaseEPub()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testComicExtractionIsRemovedWhenArchiveIsReleased() throws {
        let directory = try Self.makeAndReleaseComic()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - CBZ Detection

    func testParseCBZByExtension() throws {
        let data = try Self.minimalCBZ()
        let content = try DocumentContent.parse(data: data, contentType: .data, filename: "comic.cbz")
        guard case .comic(let archive) = content else {
            XCTFail("Expected .comic, got \(content)")
            return
        }
        XCTAssertEqual(archive.pageCount, 1)
    }

    // MARK: - Unsupported Type

    func testUnsupportedTypeThrows() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertThrowsError(try DocumentContent.parse(data: data, contentType: .data)) { error in
            XCTAssertTrue(error is DocumentError)
        }
    }

    // MARK: - Fixtures

    /// Minimal valid PDF (1 page, no content).
    static let minimalPDF: Data = {
        let pdf = """
        %PDF-1.0
        1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
        2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
        3 0 obj<</Type/Page/MediaBox[0 0 612 792]/Parent 2 0 R>>endobj
        xref
        0 4
        0000000000 65535 f\u{20}
        0000000009 00000 n\u{20}
        0000000058 00000 n\u{20}
        0000000115 00000 n\u{20}
        trailer<</Size 4/Root 1 0 R>>
        startxref
        190
        %%EOF
        """
        return pdf.data(using: .ascii)!
    }()

    /// Creates a minimal valid ePub (ZIP with container.xml, content.opf, and one XHTML chapter).
    static func minimalEPub(chapterText: String = "Hello, World!", chapterCount: Int = 1) throws -> Data {
        let archive = try Archive(accessMode: .create)

        try archive.addEntry(with: "mimetype",
                             type: .file,
                             uncompressedSize: Int64("application/epub+zip".utf8.count),
                             provider: { position, size in "application/epub+zip".data(using: .utf8)! })

        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try addTextEntry(to: archive, path: "META-INF/container.xml", content: container)

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Test Book</dc:title>
            <dc:identifier id="uid">urn:uuid:test-12345</dc:identifier>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            \((1...chapterCount).map { "<item id=\"ch\($0)\" href=\"chapter\($0).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined())
          </manifest>
          <spine>
            \((1...chapterCount).map { "<itemref idref=\"ch\($0)\"/>" }.joined())
          </spine>
        </package>
        """
        try addTextEntry(to: archive, path: "OEBPS/content.opf", content: opf)

        let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Chapter 1</title></head>
        <body><p>\(chapterText)</p></body>
        </html>
        """
        for chapter in 1...chapterCount {
            try addTextEntry(to: archive, path: "OEBPS/chapter\(chapter).xhtml", content: xhtml)
        }

        return archive.data!
    }

    /// Creates a minimal CBZ (ZIP containing one small PNG).
    static func minimalCBZ() throws -> Data {
        let archive = try Archive(accessMode: .create)
        let png = Self.onePxPNG
        try archive.addEntry(with: "page001.png",
                             type: .file,
                             uncompressedSize: Int64(png.count),
                             provider: { position, size in png })
        return archive.data!
    }

    private static func epubWithNestedNCX() throws -> Data {
        let archive = try Archive(accessMode: .create)
        try addTextEntry(to: archive, path: "mimetype", content: "application/epub+zip")
        try addTextEntry(to: archive, path: "META-INF/container.xml", content: """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)
        try addTextEntry(to: archive, path: "OEBPS/content.opf", content: """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>NCX Test</dc:title></metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="parent" href="parent.xhtml" media-type="application/xhtml+xml"/>
            <item id="child" href="child.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx"><itemref idref="parent"/><itemref idref="child"/></spine>
        </package>
        """)
        try addTextEntry(to: archive, path: "OEBPS/toc.ncx", content: """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="parent"><navLabel><text>Parent</text></navLabel><content src="parent.xhtml"/>
              <navPoint id="child"><navLabel><text>Child</text></navLabel><content src="child.xhtml"/></navPoint>
            </navPoint>
          </navMap>
        </ncx>
        """)
        try addTextEntry(to: archive, path: "OEBPS/parent.xhtml", content: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>Parent</body></html>")
        try addTextEntry(to: archive, path: "OEBPS/child.xhtml", content: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>Child</body></html>")
        return try XCTUnwrap(archive.data)
    }

    private static func makeAndReleaseEPub() throws -> URL {
        let book = try EPubParser.parse(data: minimalEPub())
        let directory = book.extractionDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        return directory
    }

    private static func makeAndReleaseComic() throws -> URL {
        let comic = try ComicArchiveParser.parse(data: minimalCBZ())
        let directory = comic.extractionDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        return directory
    }

    private static func addTextEntry(to archive: Archive, path: String, content: String) throws {
        let data = content.data(using: .utf8)!
        try archive.addEntry(with: path,
                             type: .file,
                             uncompressedSize: Int64(data.count),
                             provider: { position, size in data })
    }

    /// Deterministic valid PNG, shared by ZIP and stored-RAR fixtures.
    static let onePxPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!

    /// Two original PNG pages in an uncompressed RAR4 archive, with valid CRCs.
    static let minimalCBR = Data(base64Encoded: "UmFyIRoHAM+QcwAADQAAAAAAAADhqnQAgCoARQAAAEUAAAADUQ/aAgAAAAAUMAoApIEAAHBhZ2UxMC5wbmeJUE5HDQoaCgAAAA1JSERSAAAAAQAAAAEIAgAAAJB3U94AAAAMSURBVHicY/jPwAAAAwEBAMn+ku8AAAAASUVORK5CYIKppnQAgCkARQAAAEUAAAADUQ/aAgAAAAAUMAkApIEAAHBhZ2UyLnBuZ4lQTkcNChoKAAAADUlIRFIAAAABAAAAAQgCAAAAkHdT3gAAAAxJREFUeJxj+M/AAAADAQEAyf6S7wAAAABJRU5ErkJggsQ9ewBABwA=")!
}

@MainActor
final class ReaderFailureTests: XCTestCase {
    func testStoredRARExtractsInNaturalOrderAndRejectsCorruption() throws {
        let archive = try ComicArchiveParser.parseRAR(data: DocumentContentTests.minimalCBR)
        XCTAssertEqual(archive.pages.map(\.lastPathComponent), ["page2.png", "page10.png"])
        for page in archive.pages { XCTAssertEqual(try Data(contentsOf: page), DocumentContentTests.onePxPNG) }
        var broken = DocumentContentTests.minimalCBR
        broken[80] ^= 0xff
        XCTAssertThrowsError(try ComicArchiveParser.parseRAR(data: broken))
    }

    func testRenamedZIPComicStillOpensAsCBR() throws {
        let archive = try ComicArchiveParser.parseRAR(data: DocumentContentTests.minimalCBZ())
        XCTAssertEqual(archive.pageCount, 1)
    }

    static func image(text: String) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 900, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
        draw(text, in: context)
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func pdf(text: String, pages: Int = 2) throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            draw(text, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func draw(_ text: String, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 48, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        context.textPosition = CGPoint(x: 50, y: 450)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
    }

    func testPDFSearchTransfersRangesForEveryMatch() async throws {
        let bytes = try Self.pdf(text: "Café searchable text")
        let renderer = PDFPageRenderer(data: bytes, fileHash: "pdf-search-test")
        let matches = try await renderer.search("searchable")
        XCTAssertEqual(matches.count, 2)
        let display = try XCTUnwrap(PDFDocument(data: bytes))
        for (index, ranges) in matches.enumerated() {
            let range = try XCTUnwrap(ranges.first)
            XCTAssertEqual(range.pageIndex, index)
            XCTAssertEqual(display.page(at: index)?.selection(for: range.range)?.string, "searchable")
        }
    }

    func testOCRRecognizesOwnedImageFixture() async throws {
        let directory = try TemporaryDirectoryLease.writing(Self.image(text: "Manicule searchable page"), filename: "page.png")
        let results = try await OCRService.shared.recognizeText(in: directory.url.appendingPathComponent("page.png"))
        XCTAssertTrue(results.contains { $0.text.localizedCaseInsensitiveContains("searchable") })
    }

    func testOCRDistinguishesUnreadableImageFromBlankImage() async throws {
        let directory = try TemporaryDirectoryLease.writing(Data("not an image".utf8), filename: "broken.png")
        do {
            _ = try await OCRService.shared.recognizeText(in: directory.url.appendingPathComponent("broken.png"))
            XCTFail("Unreadable image must fail, not return zero search results")
        } catch { XCTAssertFalse(error is CancellationError) }
        let valid = try TemporaryDirectoryLease.writing(Self.image(text: ""), filename: "blank.png")
        let results = try await OCRService.shared.recognizeText(in: valid.url.appendingPathComponent("blank.png"))
        XCTAssertTrue(results.isEmpty)
    }
}

@MainActor
final class FileChangeObservationTests: XCTestCase {
    func testCoordinatedExternalReplacementNotifiesAndPresenterIsReleased() async throws {
        let directory = try TemporaryDirectoryLease.writing(Data("original".utf8), filename: "source.txt")
        let url = directory.url.appendingPathComponent("source.txt")
        let observation = FileChangeObservation(url: url)
        defer { observation.stop() }
        let received = expectation(description: "Source change observed")
        let listener = Task {
            for await changedURL in observation.changes {
                XCTAssertEqual(changedURL, url)
                received.fulfill()
                break
            }
        }
        defer { listener.cancel() }
        try await Task.detached {
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                do { try Data("replacement".utf8).write(to: target, options: .atomic) }
                catch { writeError = error }
            }
            if let error = coordinationError ?? writeError { throw error }
        }.value
        await fulfillment(of: [received], timeout: 5)
        observation.stop()
        XCTAssertFalse(NSFileCoordinator.filePresenters.contains { $0 === observation })
    }
}

@MainActor
final class SavedFileIdentityTests: XCTestCase {
    func testMovedBookMatchesButSamePathReplacementIsRejected() throws {
        let directory = try TemporaryDirectoryLease.writing(Data("Original Café 👋".utf8), filename: "Book.txt")
        let original = directory.url.appendingPathComponent("Book.txt")
        let hash = FileHasher.hash(data: try Data(contentsOf: original))
        let moved = directory.url.appendingPathComponent("Renamed.txt")
        try FileManager.default.moveItem(at: original, to: moved)
        XCTAssertEqual(try ReaderDocument.read(from: moved, expectedHash: hash).fileHash, hash)
        try Data("A different book".utf8).write(to: moved, options: .atomic)
        XCTAssertThrowsError(try ReaderDocument.read(from: moved, expectedHash: hash)) { error in
            guard case DocumentError.differentDocument = error else { return XCTFail("Unexpected error: \(error)") }
        }
        // Deliberate new-file opening still accepts the changed content.
        XCTAssertNotEqual(try ReaderDocument.read(from: moved).fileHash, hash)
        XCTAssertEqual(try Data(contentsOf: moved), Data("A different book".utf8))
    }
}
