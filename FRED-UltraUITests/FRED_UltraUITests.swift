import XCTest

/// Smoke coverage for the surfaces a user meets first.
///
/// These tests only assert on state the app can reach without network access or a saved
/// API key, so they stay deterministic in CI. Anything requiring live FRED data is
/// covered by the unit tests against injected loaders instead.
final class FRED_UltraUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesAndShowsAWindow() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 20),
            "The app should present a window on launch."
        )
    }

    /// Either surface is valid depending on whether this machine already has a saved
    /// key: onboarding when it does not, the search sidebar when it does.
    @MainActor
    func testLaunchPresentsOnboardingOrWorkspace() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))

        let onboardingField = app.secureTextFields["welcome.apiKeyField"]
        let sidebar = app.outlines["sidebar.list"]
        let searchField = app.searchFields.firstMatch

        let deadline = Date().addingTimeInterval(20)
        var found = false
        while Date() < deadline {
            if onboardingField.exists || sidebar.exists || searchField.exists {
                found = true
                break
            }
            usleep(250_000)
        }

        XCTAssertTrue(found, "Expected either the onboarding key field or the workspace sidebar.")
    }

    /// The validate button must stay disabled until a key is typed, so an empty
    /// submission can never reach the network.
    @MainActor
    func testValidateButtonRequiresAKey() throws {
        let app = XCUIApplication()
        app.launch()

        let keyField = app.secureTextFields["welcome.apiKeyField"]
        guard keyField.waitForExistence(timeout: 10) else {
            throw XCTSkip("This machine already has a saved API key, so onboarding is not shown.")
        }

        let validateButton = app.buttons["welcome.validateButton"]
        XCTAssertTrue(validateButton.exists)
        XCTAssertFalse(validateButton.isEnabled, "Validation should require a non-empty key.")

        keyField.click()
        keyField.typeText("not-a-real-key")

        XCTAssertTrue(validateButton.isEnabled, "Typing a key should enable validation.")
    }
}
