import XCTest
#if os(iOS)
import UIKit
#endif

#if os(iOS)
@MainActor
final class FacingPageUITests: XCTestCase {
    func testLandscapePDFSwipesTurnSpreadsAndPreserveZoomPanning() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let url = try makePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let app = XCUIApplication()
        app.open(url)
        defer { app.terminate() }
        let first = app.staticTexts["1–2 of 4"]
        let second = app.staticTexts["3–4 of 4"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), app.debugDescription)
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        // A short drag should visibly move the spread, then cancel on release.
        let shortDrag = app.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.5))
        right.press(forDuration: 0.05, thenDragTo: shortDrag, withVelocity: .slow, thenHoldForDuration: 2)
        XCTAssertTrue(first.exists, "A short drag must return to its original spread")
        right.press(forDuration: 0.05, thenDragTo: left)
        XCTAssertTrue(second.waitForExistence(timeout: 5), app.debugDescription)
        left.press(forDuration: 0.05, thenDragTo: right)
        XCTAssertTrue(first.waitForExistence(timeout: 5), app.debugDescription)
        center.doubleTap()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "pdf-reader").allElementsBoundByIndex.first(where: { $0.isHittable })?.value as? String, "Zoom 250%")
        right.press(forDuration: 0.05, thenDragTo: left)
        XCTAssertTrue(first.exists, "A zoomed page must pan without turning the spread")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "pdf-reader").allElementsBoundByIndex.first(where: { $0.isHittable })?.value as? String, "Zoom 250%")
        center.doubleTap()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "pdf-reader").allElementsBoundByIndex.first(where: { $0.isHittable })?.value as? String, "Zoom 100%")
        right.press(forDuration: 0.05, thenDragTo: left)
        XCTAssertTrue(second.waitForExistence(timeout: 5), app.debugDescription)
    }

    func testTwoPagesChoiceShiftsCoverAndRemembersPairing() throws {
        try exercisePairing(url: makePDF())
    }

    func testCBZTwoPagesChoiceShiftsCoverAndRemembersPairing() throws {
        try exercisePairing(url: makeCBZ())
    }

    private func exercisePairing(url: URL) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        defer { try? FileManager.default.removeItem(at: url) }
        let app = XCUIApplication()
        app.open(url)
        defer { app.terminate() }
        func expect(_ label: String) {
            XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 10), app.debugDescription)
        }
        func flipPairing() {
            app.buttons["Menu"].tap()
            app.buttons["Two Pages"].tap()
        }
        expect("1–2 of 4")
        flipPairing()
        expect("1 of 4")
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        right.press(forDuration: 0.05, thenDragTo: left)
        expect("2–3 of 4")
        flipPairing()
        expect("1–2 of 4")
        flipPairing()
        expect("2–3 of 4")
        // Enter a shifted spread from page 3, then switch through one page.
        // Re-entering two-up must anchor on page 2, not retain page 3's old anchor.
        flipPairing()
        right.press(forDuration: 0.05, thenDragTo: left)
        expect("3–4 of 4")
        flipPairing()
        expect("2–3 of 4")
        app.buttons["Menu"].tap()
        app.buttons["Single Page"].tap()
        expect("2 of 4")
        flipPairing()
        expect("2–3 of 4")
        flipPairing()
        expect("1–2 of 4")
        flipPairing()
        expect("2–3 of 4")
        app.terminate()
        app.open(url)
        expect("2–3 of 4")
        right.press(forDuration: 0.05, thenDragTo: left)
        expect("4 of 4")
        left.press(forDuration: 0.05, thenDragTo: right)
        expect("2–3 of 4")
        left.press(forDuration: 0.05, thenDragTo: right)
        expect("1 of 4")
    }

    func testPageFieldJumpsAndRejectsOutOfRangePages() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let url = try makePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let app = XCUIApplication()
        app.open(url)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["1 of 4"].waitForExistence(timeout: 15))
        let field = app.textFields["reader-page-number"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.buttons["reader-page-focus"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Tapping the page control must open the keyboard")
        field.tap()
        field.typeText("0")
        XCTAssertEqual(field.value as? String, "0")
        let go = app.buttons["reader-page-go"]
        XCTAssertFalse(go.isEnabled)
        field.typeText(XCUIKeyboardKey.delete.rawValue + "4")
        XCTAssertEqual(field.value as? String, "4")
        XCTAssertTrue(go.isEnabled)
        go.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["4 of 4"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(field.value as? String, "4")
        // Return must reach the same PDF page as the Go button.
        field.tap()
        field.typeText("1\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 of 4"].waitForExistence(timeout: 10))
        field.tap()
        field.typeText("4\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["4 of 4"].waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "4")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        if UIDevice.current.userInterfaceIdiom == .phone {
            // Phones keep one page in landscape until the reader chooses two.
            app.buttons["Menu"].tap()
            app.buttons["Two Pages"].tap()
        }
        XCTAssertTrue(app.staticTexts["3–4 of 4"].waitForExistence(timeout: 10))
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("2")
        go.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1–2 of 4"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(field.value as? String, "1")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Legible reader controls"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Invalid Return must also leave the current spread unchanged.
        field.tap()
        field.typeText("0\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1–2 of 4"].exists)
    }

    func testFlowingPageFieldOpensKeyboardAndJumpsAcrossBook() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pages-\(UUID().uuidString).txt")
        try String(repeating: "Readable text across the whole book. ", count: 3000).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let app = XCUIApplication()
        app.open(url)
        defer { app.terminate() }
        let field = app.textFields["reader-page-number"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), app.debugDescription)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: field)
        waitForExpectations(timeout: 20)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("20")
        XCTAssertEqual(field.value as? String, "20")
        app.buttons["reader-page-go"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let moved = NSPredicate(format: "value != %@", "1")
        expectation(for: moved, evaluatedWith: field)
        waitForExpectations(timeout: 10)
        let range = app.staticTexts["reader-page-range"]
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        let goResult = range.label
        let bounds = goResult.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        XCTAssertEqual(bounds.count, 3, goResult)
        XCTAssertLessThanOrEqual(bounds[0], 20)
        XCTAssertGreaterThanOrEqual(bounds[1], 20)
        XCTAssertFalse(goResult.hasPrefix("–"), "Show the full range, never a dangling dash")
        // Return from a different part of the book must reach exactly the same range.
        field.tap()
        field.typeText("1\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: field)
        waitForExpectations(timeout: 10)
        field.tap()
        field.typeText("20\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label == %@", goResult), evaluatedWith: range)
        waitForExpectations(timeout: 10)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Whole-book estimated page entry"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeCBZ() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("facing-\(UUID().uuidString).cbz")
        // Four distinct PNG pages in a stored ZIP. A unique ZIP comment keeps
        // this fixture independent of per-book settings from earlier runs.
        var data = try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAAAFQ+XF39BMGKTgAAAE4AAAALAAAAcGFnZTAwMS5wbmeJUE5HDQoaCgAAAA1JSERSAAAADAAAABAIAgAAAK0DCVAAAAAVSURBVHicY3CrOEEQMYwqGlVEnCIA6I8kkDNPmvwAAAAASUVORK5CYIJQSwMEFAAAAAAAVD5cXfZGrYNOAAAATgAAAAsAAABwYWdlMDAyLnBuZ4lQTkcNChoKAAAADUlIRFIAAAAMAAAAEAgCAAAArQMJUAAAABVJREFUeJxjMNrSRBAxjCoaVUScIgAImA4QhZ0wvQAAAABJRU5ErkJgglBLAwQUAAAAAABUPlxdxz0eBk4AAABOAAAACwAAAHBhZ2UwMDMucG5niVBORw0KGgoAAAANSUhEUgAAAAwAAAAQCAIAAACtAwlQAAAAFUlEQVR4nGN4Nk2DIGIYVTSqiDhFAN4kOxC8Zaz/AAAAAElFTkSuQmCCUEsDBBQAAAAAAFQ+XF3djkCQTgAAAE4AAAALAAAAcGFnZTAwNC5wbmeJUE5HDQoaCgAAAA1JSERSAAAADAAAABAIAgAAAK0DCVAAAAAVSURBVHicYzjhVkEQMYwqGlVEnCIAhh4kkM8S1+YAAAAASUVORK5CYIJQSwECFAMUAAAAAABUPlxd/QTBik4AAABOAAAACwAAAAAAAAAAAAAAgAEAAAAAcGFnZTAwMS5wbmdQSwECFAMUAAAAAABUPlxd9katg04AAABOAAAACwAAAAAAAAAAAAAAgAF3AAAAcGFnZTAwMi5wbmdQSwECFAMUAAAAAABUPlxdxz0eBk4AAABOAAAACwAAAAAAAAAAAAAAgAHuAAAAcGFnZTAwMy5wbmdQSwECFAMUAAAAAABUPlxd3Y5AkE4AAABOAAAACwAAAAAAAAAAAAAAgAFlAQAAcGFnZTAwNC5wbmdQSwUGAAAAAAQABADkAAAA3AEAAAAA"))
        let comment = Data(UUID().uuidString.utf8)
        data.replaceSubrange((data.count - 2)..<data.count, with: [UInt8(comment.count), 0])
        data.append(comment)
        try data.write(to: url)
        return url
    }

    private func makePDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("facing-\(UUID().uuidString).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: url) { context in
            for page in 1...4 {
                context.beginPage()
                [UIColor.systemBlue, .systemTeal, .systemOrange, .systemPink][page - 1].withAlphaComponent(0.35).setFill()
                context.cgContext.fill(CGRect(x: 20, y: 20, width: 572, height: 752))
                "\(url.lastPathComponent) — Page \(page)".draw(
                    at: CGPoint(x: 60, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
        return url
    }

}
#endif
