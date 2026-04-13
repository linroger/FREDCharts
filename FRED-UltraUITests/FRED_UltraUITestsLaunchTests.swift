//
//  FRED_UltraUITestsLaunchTests.swift
//  FRED-UltraUITests
//
//  Created by Roger Lin on 12/11/24.
//

import XCTest

final class FRED_UltraUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        throw XCTSkip("Launch screenshot capture requires AX authorization that is not consistently available in automated macOS runs.")
    }
}
