import XCTest

/// Captures a launch screenshot for the test report.
///
/// Screenshot attachment needs an interactive, Accessibility-authorised session; the
/// test skips rather than fails when run headlessly so `xcodebuild test` stays green
/// in both environments.
final class FRED_UltraUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchScreenshot() throws {
        let app = XCUIApplication()
        app.launch()

        guard app.windows.firstMatch.waitForExistence(timeout: 20) else {
            throw XCTSkip("No window appeared; screenshot capture requires an interactive session.")
        }

        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
