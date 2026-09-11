import XCTest
import UniformTypeIdentifiers
import PDFKit
@testable import Manicule

/// Runs every format against owned fixtures on every destination. Developers
/// may additionally supply a test_files/ corpus; its absence never makes these
/// tests silently execute zero documents.
@MainActor
final class TestFilesIntegrationTests: XCTestCase {

    private static let supportedExtensions: Set<String> = [
        "pdf", "epub", "cbz", "cbr", "txt", "md", "markdown"
    ]

    private static let testFilesDir: URL = {
        // Derive from this source file's path: …/ManiculeTests/TestFilesIntegrationTests.swift
        // Project root is one level up, then test_files/
        let thisFile = URL(fileURLWithPath: #filePath)
        let projectRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let candidate = projectRoot.appendingPathComponent("test_files")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        // Fallback: walk up from the test bundle
        var url = Bundle.main.bundleURL
        for _ in 0..<10 {
            let c = url.appendingPathComponent("test_files")
            if FileManager.default.fileExists(atPath: c.path) {
                return c
            }
            url = url.deletingLastPathComponent()
        }
        return candidate  // return the #filePath-based path even if missing (for error message)
    }()

    private static let fixtureDirectory = try! TemporaryDirectoryLease.create(prefix: "manicule-test-corpus")

    private static func testFiles() throws -> [(url: URL, ext: String)] {
        let fixtures: [(String, Data)] = [
            ("Page.pdf", DocumentContentTests.minimalPDF),
            ("Book.epub", try DocumentContentTests.minimalEPub()),
            ("Comic.cbz", try DocumentContentTests.minimalCBZ()),
            ("Stored comic.cbr", DocumentContentTests.minimalCBR),
            ("Unicode.txt", Data("Café 日本語 👋".utf8)),
            ("Notes.md", Data("# Heading\n\nA **bold** paragraph.".utf8)),
            ("Long extension.markdown", Data("## Subheading\n\nDistinct text.".utf8)),
        ]
        var result: [(URL, String)] = try fixtures.map { name, data in
            let url = fixtureDirectory.url.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return (url, url.pathExtension)
        }
        if FileManager.default.fileExists(atPath: testFilesDir.path) {
            let optional = try FileManager.default.contentsOfDirectory(at: testFilesDir,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            for url in optional where supportedExtensions.contains(url.pathExtension.lowercased()) {
                result.append((url, url.pathExtension.lowercased()))
            }
        }
        return result
    }

    func testFixtureCorpusCoversEverySupportedExtension() throws {
        XCTAssertEqual(Set(try Self.testFiles().map(\.ext)), Self.supportedExtensions)
    }

    // MARK: - Parsing (all formats)

    func testAllFilesParseSuccessfully() throws {
        for (url, ext) in try Self.testFiles() {
            let name = url.lastPathComponent
            let data = try Data(contentsOf: url)
            XCTAssertFalse(data.isEmpty, "\(name): file is empty")

            let contentType = UTType(filenameExtension: ext) ?? .data
            let content: DocumentContent
            do {
                content = try DocumentContent.parse(data: data, contentType: contentType, filename: name)
            } catch {
                XCTFail("\(name): parse failed — \(error.localizedDescription)")
                continue
            }

            // Verify the parsed type matches the extension
            switch (ext, content) {
            case ("pdf", .pdf): break
            case ("epub", .epub): break
            case ("cbz", .comic): break
            case ("cbr", .comic): break
            case ("txt", .plainText): break
            case ("md", .markdown), ("markdown", .markdown): break
            default:
                XCTFail("\(name): extension .\(ext) parsed as unexpected type")
            }
        }
    }

    // MARK: - PDF

    func testPDFFilesLoadWithPDFKit() throws {
        for (url, ext) in try Self.testFiles() where ext == "pdf" {
            let name = url.lastPathComponent
            let data = try Data(contentsOf: url)
            guard let doc = PDFDocument(data: data) else {
                XCTFail("\(name): PDFDocument failed to load")
                continue
            }
            XCTAssertGreaterThan(doc.pageCount, 0, "\(name): PDF has 0 pages")

            // Verify every page has a non-degenerate media box
            for i in 0..<min(doc.pageCount, 10) {
                guard let page = doc.page(at: i) else {
                    XCTFail("\(name): page \(i) is nil")
                    continue
                }
                let box = page.bounds(for: .mediaBox)
                XCTAssertGreaterThan(box.width, 0, "\(name): page \(i) has zero width")
                XCTAssertGreaterThan(box.height, 0, "\(name): page \(i) has zero height")
            }
        }
    }

    // MARK: - ePub

    func testEPubFilesHaveValidStructure() throws {
        for (url, ext) in try Self.testFiles() where ext == "epub" {
            let name = url.lastPathComponent
            let data = try Data(contentsOf: url)
            let book: EPubBook
            do {
                book = try EPubParser.parse(data: data)
            } catch {
                XCTFail("\(name): ePub parse failed — \(error.localizedDescription)")
                continue
            }

            XCTAssertFalse(book.metadata.title.isEmpty, "\(name): missing title")
            XCTAssertFalse(book.spine.isEmpty, "\(name): empty spine")
            XCTAssertFalse(book.manifest.isEmpty, "\(name): empty manifest")

            // Every spine item should reference a manifest entry
            for spineItem in book.spine {
                XCTAssertNotNil(
                    book.manifest[spineItem.idref],
                    "\(name): spine idref '\(spineItem.idref)' not found in manifest"
                )
            }

            // Extraction directory should exist
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: book.extractionDirectory.path),
                "\(name): extraction directory missing"
            )

            // First spine item's file should exist on disk
            if let firstSpine = book.spine.first,
               let item = book.manifest[firstSpine.idref] {
                let chapterURL = book.extractionDirectory.appendingPathComponent(item.href)
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: chapterURL.path),
                    "\(name): first chapter file missing at \(item.href)"
                )
            }
        }
    }

    // MARK: - Comics (CBZ/CBR)

    func testComicFilesHavePages() throws {
        for (url, ext) in try Self.testFiles() where ext == "cbz" || ext == "cbr" {
            let name = url.lastPathComponent
            let data = try Data(contentsOf: url)

            let archive: ComicArchive
            do {
                if ext == "cbz" {
                    archive = try ComicArchiveParser.parse(data: data)
                } else {
                    archive = try ComicArchiveParser.parseRAR(data: data)
                }
            } catch {
                XCTFail("\(name): comic parse failed — \(error.localizedDescription)")
                continue
            }

            XCTAssertGreaterThan(archive.pageCount, 0, "\(name): comic has 0 pages")

            // First page should be a loadable image
            let firstPage = archive.pages[0]
            let imageData = try Data(contentsOf: firstPage)
            XCTAssertFalse(imageData.isEmpty, "\(name): first page image is empty")
        }
    }

    // MARK: - Text / Markdown

    func testTextFilesHaveContent() throws {
        let textExts: Set<String> = ["txt", "md", "markdown"]
        for (url, ext) in try Self.testFiles() where textExts.contains(ext) {
            let name = url.lastPathComponent
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8)
            XCTAssertNotNil(text, "\(name): not valid UTF-8")
            XCTAssertGreaterThan(text?.count ?? 0, 0, "\(name): text is empty")
        }
    }

    #if os(iOS) || os(visionOS)
    func testMarkdownFilesStripCleanly() throws {
        let mdExts: Set<String> = ["md", "markdown"]
        for (url, ext) in try Self.testFiles() where mdExts.contains(ext) {
            let name = url.lastPathComponent
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { continue }

            let stripped = ReadAloudController.stripMarkdown(text)
            XCTAssertFalse(stripped.isEmpty, "\(name): stripMarkdown produced empty string")
            // Stripped text should not contain markdown heading markers
            let lines = stripped.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines {
                XCTAssertFalse(
                    line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### "),
                    "\(name): stripMarkdown left heading marker in: \(line.prefix(40))"
                )
            }
        }
    }
    #endif

    // MARK: - File Hashing

    func testAllFilesHashConsistently() throws {
        for (url, _) in try Self.testFiles() {
            let name = url.lastPathComponent
            let data = try Data(contentsOf: url)
            let h1 = FileHasher.hash(data: data)
            let h2 = FileHasher.hash(data: data)
            XCTAssertEqual(h1, h2, "\(name): hash is not deterministic")
            XCTAssertEqual(h1.count, 32, "\(name): hash is not 32 chars")
        }
    }

    func testAllFilesHashUniquely() throws {
        var hashes: [String: String] = [:] // hash -> filename
        for (url, _) in try Self.testFiles() {
            let name = url.lastPathComponent
            let data = try Data(contentsOf: url)
            let hash = FileHasher.hash(data: data)
            if let existing = hashes[hash] {
                // Only flag if it's a different file (same file copied twice is fine)
                if existing != name {
                    XCTFail("Hash collision: '\(name)' and '\(existing)' both hash to \(hash)")
                }
            }
            hashes[hash] = name
        }
    }

    // MARK: - ReaderDocument (full document init path)

    func testAllFilesLoadAsReaderDocument() throws {
        for (url, ext) in try Self.testFiles() {
            let name = url.lastPathComponent
            let data = try Data(contentsOf: url)
            let contentType = UTType(filenameExtension: ext) ?? .data

            do {
                let content = try DocumentContent.parse(data: data, contentType: contentType, filename: name)
                let doc = ReaderDocument(content: content, rawData: data)
                XCTAssertFalse(doc.rawData.isEmpty, "\(name): ReaderDocument has empty rawData")
            } catch {
                XCTFail("\(name): ReaderDocument construction failed — \(error.localizedDescription)")
            }
        }
    }
}
