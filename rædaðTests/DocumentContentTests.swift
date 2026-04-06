import XCTest
import UniformTypeIdentifiers
import ZIPFoundation
@testable import rædað

@MainActor
final class DocumentContentTests: XCTestCase {

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
    private static let minimalPDF: Data = {
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
    private static func minimalEPub() throws -> Data {
        let archive = Archive(accessMode: .create)!

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
            <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
          </spine>
        </package>
        """
        try addTextEntry(to: archive, path: "OEBPS/content.opf", content: opf)

        let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Chapter 1</title></head>
        <body><p>Hello, World!</p></body>
        </html>
        """
        try addTextEntry(to: archive, path: "OEBPS/chapter1.xhtml", content: xhtml)

        return archive.data!
    }

    /// Creates a minimal CBZ (ZIP containing one small PNG).
    private static func minimalCBZ() throws -> Data {
        let archive = Archive(accessMode: .create)!
        let png = Self.onePxPNG
        try archive.addEntry(with: "page001.png",
                             type: .file,
                             uncompressedSize: Int64(png.count),
                             provider: { position, size in png })
        return archive.data!
    }

    private static func addTextEntry(to archive: Archive, path: String, content: String) throws {
        let data = content.data(using: .utf8)!
        try archive.addEntry(with: path,
                             type: .file,
                             uncompressedSize: Int64(data.count),
                             provider: { position, size in data })
    }

    /// 1x1 red PNG image.
    private static let onePxPNG: Data = {
        var d = Data()
        // PNG signature
        d.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // IHDR chunk (1x1, 8-bit RGB)
        let ihdr: [UInt8] = [0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                             0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
                             0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE]
        d.append(contentsOf: ihdr)
        // IDAT chunk (raw red pixel via zlib)
        let idat: [UInt8] = [0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
                             0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00,
                             0x00, 0x03, 0x00, 0x01, 0x36, 0x28, 0x19, 0x00]
        d.append(contentsOf: idat)
        // IEND chunk
        let iend: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        d.append(contentsOf: iend)
        return d
    }()
}
