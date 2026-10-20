import XCTest
@testable import Manicule

final class PageNavigationTests: XCTestCase {
    func testPageEntryUsesOneBasedNumbersAndRejectsInvalidInput() {
        XCTAssertEqual(PageNavigation.requestedIndex("1", pageCount: 4), 0)
        XCTAssertEqual(PageNavigation.requestedIndex(" 4 ", pageCount: 4), 3)
        for text in ["", "0", "-1", "5", "2.5", "abc", "9999999999999999999999999999999"] {
            XCTAssertNil(PageNavigation.requestedIndex(text, pageCount: 4), text)
        }
        XCTAssertNil(PageNavigation.requestedIndex("1", pageCount: 0))
    }

    func testShiftedSpreadsVisitEveryPageOnceAndReverseWithoutSkippingCover() {
        for count in 1...12 {
            var current = 0
            var visited = [Int]()
            var starts = [Int]()
            repeat {
                starts.append(current)
                if current == 0 { visited.append(0) }
                else { visited.append(contentsOf: current..<min(count, current + 2)) }
                let next = PageNavigation.next(current: current, pageCount: count, twoUp: true, coverOnRight: true)
                if next == current { break }
                current = next
            } while starts.count < count + 1
            XCTAssertEqual(visited, Array(0..<count))
            XCTAssertEqual(starts.count, PageNavigation.spreadCount(pageCount: count, coverOnRight: true))
            for (ordinal, start) in starts.enumerated() {
                XCTAssertEqual(PageNavigation.spreadIndex(page: start, coverOnRight: true), ordinal)
                XCTAssertEqual(PageNavigation.spreadStart(index: ordinal, coverOnRight: true), start)
                XCTAssertEqual(PageNavigation.previous(current: start, pageCount: count, twoUp: true, coverOnRight: true),
                               starts[max(0, ordinal - 1)])
            }
        }
    }

    @MainActor
    func testShiftedPairingNormalizesRightPagesAndLabelsTheCoverAlone() {
        XCTAssertEqual(PageNavigation.normalizedStart(current: 2, pageCount: 6, twoUp: true, coverOnRight: true), 1)
        XCTAssertEqual(PageNavigation.normalizedStart(current: 4, pageCount: 6, twoUp: true, coverOnRight: true), 3)
        XCTAssertEqual(ReaderHelpers.pageLabel(current: 0, total: 6, twoUp: true, coverOnRight: true), "1 of 6")
        XCTAssertEqual(ReaderHelpers.pageLabel(current: 1, total: 6, twoUp: true, coverOnRight: true), "2–3 of 6")
        XCTAssertEqual(ReaderHelpers.pageLabel(current: 5, total: 6, twoUp: true, coverOnRight: true), "6 of 6")
    }

    @MainActor
    func testCoverPreferenceDecodesOldBooksAndRoundTripsNewBooks() throws {
        let legacy = try JSONDecoder().decode(BookOverride.self, from: Data("{\"twoUp\":true}".utf8))
        XCTAssertNil(legacy.coverOnRight)
        let shifted = BookOverride(twoUp: true, coverOnRight: true)
        let decoded = try JSONDecoder().decode(BookOverride.self, from: JSONEncoder().encode(shifted))
        XCTAssertEqual(decoded.coverOnRight, true)
        XCTAssertFalse(BookOverride(coverOnRight: true).isEmpty)
    }

    func testNearestFirstVisitsNeighborsOnceInReadingOrder() {
        XCTAssertEqual(PageNavigation.nearestFirst(center: 2, pageCount: 5), [2, 3, 1, 4, 0])
        XCTAssertEqual(PageNavigation.nearestFirst(center: 0, pageCount: 4), [0, 1, 2, 3])
        XCTAssertEqual(PageNavigation.nearestFirst(center: 3, pageCount: 4), [3, 2, 1, 0])
    }

    func testNearestFirstClampsRestoredPositionsAndHandlesEmptyDocuments() {
        XCTAssertEqual(PageNavigation.nearestFirst(center: -3, pageCount: 2), [0, 1])
        XCTAssertEqual(PageNavigation.nearestFirst(center: 99, pageCount: 2), [1, 0])
        XCTAssertEqual(PageNavigation.nearestFirst(center: 0, pageCount: 0), [])
        XCTAssertEqual(PageNavigation.nearestFirst(center: 0, pageCount: 1), [0])
    }

    func testEvenTwoUpDocumentStopsAtFinalSpread() {
        XCTAssertEqual(PageNavigation.next(current: 8, pageCount: 10, twoUp: true), 8)
        XCTAssertFalse(PageNavigation.canGoNext(current: 8, pageCount: 10, twoUp: true))
    }

    func testOddTwoUpDocumentAdvancesToUnpairedLastPage() {
        XCTAssertEqual(PageNavigation.next(current: 6, pageCount: 9, twoUp: true), 8)
        XCTAssertFalse(PageNavigation.canGoNext(current: 8, pageCount: 9, twoUp: true))
    }

    func testTwoUpNormalizesExternallySelectedRightPage() {
        XCTAssertEqual(PageNavigation.normalizedStart(current: 9, pageCount: 10, twoUp: true), 8)
        XCTAssertEqual(PageNavigation.previous(current: 9, pageCount: 10, twoUp: true), 6)
    }

    func testSinglePageNavigationStillReachesLastPage() {
        XCTAssertEqual(PageNavigation.next(current: 8, pageCount: 10, twoUp: false), 9)
        XCTAssertEqual(PageNavigation.next(current: 9, pageCount: 10, twoUp: false), 9)
    }

    func testEmptyDocumentIsSafe() {
        XCTAssertEqual(PageNavigation.normalizedStart(current: 3, pageCount: 0, twoUp: true), 0)
        XCTAssertFalse(PageNavigation.canGoNext(current: 0, pageCount: 0, twoUp: true))
    }
}
