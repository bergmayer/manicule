import XCTest
@testable import Manicule

final class PageNavigationTests: XCTestCase {
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
