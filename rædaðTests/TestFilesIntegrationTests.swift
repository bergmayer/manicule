import XCTest
import UniformTypeIdentifiers
import PDFKit
@testable import Manicule

/// Integration tests that run against real files in the `test_files/` directory.
///
/// Drop any supported files into `test_files/` at the project root. The tests
/// dynamically discover all files and verify each one can be parsed, has valid
/// content, and (for formats the Quick Look extension supports) can be previewed.
///
/// Supported extensions: .pdf, .epub, .cbz, .cbr, .txt, .md, .markdown
///
/// `test_files/` is in .gitignore — each developer supplies their own files.
@MainActor
final class TestFilesIntegrationTests: XCTestCase {

    private static let supportedExtensions: Set<String> = [
        "pdf", "epub", "cbz", "cbr", "txt", "md", "markdown"
    ]

    private static let testFilesDir: URL = {
        // Derive from this source file's path: …/rædaðTests/TestFilesIntegrationTests.swift
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

    private static var testFiles: [(url: URL, ext: String)] = {
        guard FileManager.default.fileExists(atPath: testFilesDir.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: testFilesDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var files: [(URL, String)] = []
        while let url = enumerator.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            if supportedExtensions.contains(ext) {
                files.append((url, ext))
            }
        }
        return files.sorted { $0.0.lastPathComponent < $1.0.lastPathComponent }
    }()

    // MARK: - Discovery

    func testTestFilesDirectoryExists() throws {
        guard FileManager.default.fileExists(atPath: Self.testFilesDir.path) else {
            throw XCTSkip("Optional test_files/ corpus is not installed at \(Self.testFilesDir.path)")
        }
    }

    func testAtLeastOneTestFile() throws {
        guard !Self.testFiles.isEmpty else {
            throw XCTSkip("Optional test_files/ corpus contains no supported documents")
        }
    }

    // MARK: - Parsing (all formats)

    func testAllFilesParseSuccessfully() throws {
        for (url, ext) in Self.testFiles {
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
        for (url, ext) in Self.testFiles where ext == "pdf" {
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
        for (url, ext) in Self.testFiles where ext == "epub" {
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
        for (url, ext) in Self.testFiles where ext == "cbz" || ext == "cbr" {
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
        for (url, ext) in Self.testFiles where textExts.contains(ext) {
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
        for (url, ext) in Self.testFiles where mdExts.contains(ext) {
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
        for (url, _) in Self.testFiles {
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
        for (url, _) in Self.testFiles {
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
        for (url, ext) in Self.testFiles {
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
