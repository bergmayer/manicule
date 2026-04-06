import XCTest
@testable import rædað

@MainActor
final class ReadingPositionTests: XCTestCase {

    // MARK: - Display Strings

    func testPDFPageDisplayString() {
        XCTAssertEqual(ReadingPosition.pdfPage(0).displayString, "Page 1")
        XCTAssertEqual(ReadingPosition.pdfPage(99).displayString, "Page 100")
    }

    func testEPubSpineDisplayString() {
        XCTAssertEqual(ReadingPosition.epubSpine(index: 2, scrollFraction: 0.5).displayString, "Chapter 3")
    }

    func testEPubCFIDisplayString() {
        let pos = ReadingPosition.epubCFI("/6/4[chap01]!/4/2/1:0", fraction: 0.42)
        XCTAssertEqual(pos.displayString, "42%")
    }

    func testTextOffsetDisplayString() {
        XCTAssertEqual(ReadingPosition.textOffset(1234).displayString, "Position 1234")
    }

    func testComicPageDisplayString() {
        XCTAssertEqual(ReadingPosition.comicPage(4).displayString, "Page 5")
    }

    // MARK: - Codable Roundtrip

    func testPDFPageCodable() throws {
        try assertCodableRoundtrip(ReadingPosition.pdfPage(42))
    }

    func testEPubSpineCodable() throws {
        try assertCodableRoundtrip(ReadingPosition.epubSpine(index: 3, scrollFraction: 0.75))
    }

    func testEPubCFICodable() throws {
        try assertCodableRoundtrip(ReadingPosition.epubCFI("/6/4!/4/2:100", fraction: 0.5))
    }

    func testTextOffsetCodable() throws {
        try assertCodableRoundtrip(ReadingPosition.textOffset(9999))
    }

    func testComicPageCodable() throws {
        try assertCodableRoundtrip(ReadingPosition.comicPage(7))
    }

    // MARK: - ePub Fraction

    func testEPubFractionFromCFI() {
        let pos = ReadingPosition.epubCFI("cfi", fraction: 0.33)
        XCTAssertEqual(pos.epubFraction, 0.33)
    }

    func testEPubFractionFromSpine() {
        let pos = ReadingPosition.epubSpine(index: 0, scrollFraction: 0.8)
        XCTAssertEqual(pos.epubFraction, 0.8)
    }

    func testEPubFractionNilForPDF() {
        XCTAssertNil(ReadingPosition.pdfPage(0).epubFraction)
    }

    func testEPubFractionNilForText() {
        XCTAssertNil(ReadingPosition.textOffset(0).epubFraction)
    }

    func testEPubFractionNilForComic() {
        XCTAssertNil(ReadingPosition.comicPage(0).epubFraction)
    }

    // MARK: - AutoSavedPosition Codable

    func testAutoSavedPositionRoundtrip() throws {
        let pos = AutoSavedPosition(
            id: "abc123",
            fileName: "Test Book.epub",
            position: .epubCFI("/6/4", fraction: 0.5),
            lastOpened: Date(timeIntervalSinceReferenceDate: 700000000),
            tocLabel: "Chapter 3",
            pinned: true
        )
        let data = try JSONEncoder().encode(pos)
        let decoded = try JSONDecoder().decode(AutoSavedPosition.self, from: data)
        XCTAssertEqual(decoded.id, pos.id)
        XCTAssertEqual(decoded.fileName, pos.fileName)
        XCTAssertEqual(decoded.position, pos.position)
        XCTAssertEqual(decoded.tocLabel, pos.tocLabel)
        XCTAssertEqual(decoded.pinned, true)
    }

    // MARK: - BookmarkEntry Codable

    func testBookmarkEntryRoundtrip() throws {
        let entry = BookmarkEntry(
            fileHash: "hash123",
            fileName: "Test.pdf",
            position: .pdfPage(5),
            lastOpened: Date(timeIntervalSinceReferenceDate: 700000000),
            tocLabel: nil
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(BookmarkEntry.self, from: data)
        XCTAssertEqual(decoded.fileHash, "hash123")
        XCTAssertEqual(decoded.fileName, "Test.pdf")
        XCTAssertEqual(decoded.position, .pdfPage(5))
    }

    func testBookmarkEntryLegacyMigration() throws {
        // Legacy entries had id = fileHash and no separate fileHash field
        let legacyJSON = """
        {
            "id": "oldhash",
            "fileName": "Old Book.pdf",
            "position": {"pdfPage": {"_0": 10}},
            "lastOpened": 700000000
        }
        """
        let decoder = JSONDecoder()
        let entry = try decoder.decode(BookmarkEntry.self, from: legacyJSON.data(using: .utf8)!)
        XCTAssertEqual(entry.fileHash, "oldhash")
        // id should be migrated to a UUID
        XCTAssertNotEqual(entry.id, "oldhash")
        XCTAssertFalse(entry.id.isEmpty)
    }

    // MARK: - Helpers

    private func assertCodableRoundtrip(_ position: ReadingPosition, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(position)
        let decoded = try JSONDecoder().decode(ReadingPosition.self, from: data)
        XCTAssertEqual(decoded, position, file: file, line: line)
    }
}
