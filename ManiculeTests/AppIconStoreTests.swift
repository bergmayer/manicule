#if os(iOS)
import XCTest
@testable import Manicule

@MainActor
final class AppIconStoreTests: XCTestCase {
    func testOnlyOneChangeRunsAndSelectionUpdatesAfterSuccess() async throws {
        var requestedNames: [String?] = []
        var completion: CheckedContinuation<Void, Error>?
        let started = expectation(description: "Icon change started")
        let store = AppIconStore(currentChoice: .forest, supportsAlternateIcons: true) { name in
            requestedNames.append(name)
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                started.fulfill()
            }
        }

        let first = Task { try await store.change(to: .ochre) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(store.choice, .forest)
        XCTAssertEqual(store.changingTo, .ochre)

        try await store.change(to: .indigo)
        XCTAssertEqual(requestedNames, ["AppIconOchre"])

        completion?.resume()
        try await first.value
        XCTAssertEqual(store.choice, .ochre)
        XCTAssertNil(store.changingTo)
    }

    func testFailureKeepsConfirmedChoiceAndAllowsRetry() async throws {
        var calls = 0
        let store = AppIconStore(currentChoice: .ochre, supportsAlternateIcons: true) { _ in
            calls += 1
            if calls == 1 { throw NSError(domain: "IconTest", code: 1) }
        }

        do {
            try await store.change(to: .indigo)
            XCTFail("Expected the icon change to fail")
        } catch {
            XCTAssertEqual((error as NSError).domain, "IconTest")
        }
        XCTAssertEqual(store.choice, .ochre)
        XCTAssertNil(store.changingTo)
        XCTAssertEqual(calls, 1)

        try await store.change(to: .indigo)
        XCTAssertEqual(store.choice, .indigo)
        XCTAssertNil(store.changingTo)
        XCTAssertEqual(calls, 2)
    }

    func testRestoringForestUsesPrimaryIconAndRepeatedSelectionDoesNothing() async throws {
        var names: [String?] = []
        let store = AppIconStore(currentChoice: .ochre, supportsAlternateIcons: true) { names.append($0) }
        try await store.change(to: .ochre)
        XCTAssertTrue(names.isEmpty)
        try await store.change(to: .forest)
        XCTAssertEqual(names.count, 1)
        XCTAssertNil(names[0])
        XCTAssertEqual(store.choice, .forest)
    }

    func testUnsupportedDeviceDoesNotRequestChange() async throws {
        let store = AppIconStore(currentChoice: .forest, supportsAlternateIcons: false) { _ in
            XCTFail("Unsupported devices must not request an alternate icon")
        }
        try await store.change(to: .ochre)
        XCTAssertEqual(store.choice, .forest)
        XCTAssertNil(store.changingTo)
    }
}
#endif
