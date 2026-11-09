import XCTest

// MARK: - Menu bar & dashboard UI tests
final class System_MonitorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches without the first-run permission slides.
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--skip-onboarding"]
        app.launch()
        return app
    }

    @MainActor
    func testHoverOpensCompactReadingsAndDashboard() throws {
        let app = launch()
        XCTAssertFalse(app.windows["System Monitor"].exists)

        let icon = app.descendants(matching: .any)["system-monitor-status"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 5), app.debugDescription)
        icon.hover()

        let dashboardButton = app.buttons["Open Dashboard"]
        XCTAssertTrue(dashboardButton.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["CPU"].exists)
        XCTAssertTrue(app.staticTexts["Memory"].exists)
        XCTAssertTrue(app.staticTexts["Storage"].exists)
        XCTAssertTrue(app.staticTexts["Network"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "Clean Up").count, 1)

        // Move into the panel, where hover dismissal must remain suspended.
        dashboardButton.hover()
        dashboardButton.click()
        XCTAssertTrue(app.windows["System Monitor"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your Mac, at a glance"].exists)
    }

    @MainActor
    func testApplicationScanFromSidebar() throws {
        let app = launch()
        let icon = app.descendants(matching: .any)["system-monitor-status"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 5))
        icon.hover()
        let dashboardButton = app.buttons["Open Dashboard"]
        XCTAssertTrue(dashboardButton.waitForExistence(timeout: 5))
        dashboardButton.click()

        let window = app.windows["System Monitor"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.buttons["Applications"].click()
        let scan = window.buttons["scan-installed-apps"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        XCTAssertFalse(window.buttons["check-app-updates"].isEnabled)
        scan.click()
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: window.buttons["check-app-updates"])
        waitForExpectations(timeout: 20)
        XCTAssertEqual(app.sheets.count, 0)
    }
}
