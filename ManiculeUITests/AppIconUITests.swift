import XCTest

@MainActor
final class AppIconUITests: XCTestCase {
    func testChangingFromOchreKeepsSettingsAndDoneResponsive() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        let settings = app.buttons["library-settings"]

        func openSettings() {
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.navigationBars["Reading Settings"].waitForExistence(timeout: 5))
        }
        func iconChoice(_ name: String) -> XCUIElement {
            let choice = app.buttons[name]
            for _ in 0..<8 where !choice.exists || !choice.isHittable {
                app.collectionViews.firstMatch.swipeUp()
            }
            XCTAssertTrue(choice.isHittable, app.debugDescription)
            return choice
        }
        func dismissSystemNotice() {
            let alert = app.alerts.firstMatch
            if alert.waitForExistence(timeout: 3) { alert.buttons["OK"].tap() }
            let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            if system.alerts.firstMatch.exists { system.alerts.firstMatch.buttons["OK"].tap() }
        }

        for name in ["Ochre", "Indigo", "Ochre"] {
            openSettings()
            iconChoice(name).tap()
            XCTAssertTrue(app.navigationBars["Reading Settings"].waitForNonExistence(timeout: 5),
                          "Settings must dismiss before the system icon change")
            dismissSystemNotice()
            let ready = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: settings)
            wait(for: [ready], timeout: 10)
            openSettings()
            let choice = iconChoice(name)
            let selected = expectation(
                for: NSPredicate(format: "value CONTAINS %@ AND enabled == true", "Selected"), evaluatedWith: choice)
            wait(for: [selected], timeout: 15)
            app.buttons["Done"].tap()
        }
        app.terminate()
        app.launch()
        openSettings()
        XCTAssertTrue((iconChoice("Ochre").value as? String ?? "").contains("Selected"))
        app.buttons["Done"].tap()
        XCTAssertTrue(settings.isHittable)
    }
}
