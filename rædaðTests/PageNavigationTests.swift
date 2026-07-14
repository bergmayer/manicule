import XCTest
@testable import rædað

final class PageNavigationTests: XCTestCase {
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
