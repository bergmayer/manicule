import XCTest
@testable import rædað

@MainActor
final class RelocateEventTests: XCTestCase {

    func testParsesFullEvent() {
        let dict: [String: Any] = [
            "fraction": 0.42,
            "cfi": "/6/4[chap01]!/4/2/1:0",
            "tocItem": ["label": "Chapter 1", "href": "ch1.xhtml"],
            "atStart": false,
            "atEnd": false,
            "page": 3,
            "pages": 100
        ]
        let event = RelocateEvent(from: dict)
        XCTAssertEqual(event.fraction, 0.42)
        XCTAssertEqual(event.cfi, "/6/4[chap01]!/4/2/1:0")
        XCTAssertEqual(event.tocLabel, "Chapter 1")
        XCTAssertEqual(event.atStart, false)
        XCTAssertEqual(event.atEnd, false)
        XCTAssertEqual(event.page, 3)
        XCTAssertEqual(event.pages, 100)
    }

    func testParsesEmptyEvent() {
        let event = RelocateEvent(from: [:])
        XCTAssertNil(event.fraction)
        XCTAssertNil(event.cfi)
        XCTAssertNil(event.tocLabel)
        XCTAssertNil(event.atStart)
        XCTAssertNil(event.atEnd)
        XCTAssertNil(event.page)
        XCTAssertNil(event.pages)
    }

    func testParsesPartialEvent() {
        let dict: [String: Any] = [
            "fraction": 0.8,
            "atEnd": true
        ]
        let event = RelocateEvent(from: dict)
        XCTAssertEqual(event.fraction, 0.8)
        XCTAssertNil(event.cfi)
        XCTAssertNil(event.tocLabel)
        XCTAssertEqual(event.atEnd, true)
    }

    func testTocLabelFromNestedDict() {
        let dict: [String: Any] = [
            "tocItem": ["label": "Appendix A"]
        ]
        let event = RelocateEvent(from: dict)
        XCTAssertEqual(event.tocLabel, "Appendix A")
    }

    func testTocLabelNilWhenTocItemNotDict() {
        let dict: [String: Any] = [
            "tocItem": "not a dict"
        ]
        let event = RelocateEvent(from: dict)
        XCTAssertNil(event.tocLabel)
    }
}
