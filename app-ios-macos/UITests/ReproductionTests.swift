import XCTest

/// Runs the real Homecast binary and UIKit/WKWebView bridge against a local,
/// synthetic page. Add issue-specific steps and assertions here before fixing
/// the product. A passing smoke test is not proof that another issue is fixed.
final class ReproductionTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let origin = try XCTUnwrap(ProcessInfo.processInfo.environment["HOMECAST_TEST_WEB_ORIGIN"],
                                   "Run scripts/reproduce-ios.py to start the local fixture server")
        app.launchArguments = [
            "-com.homecast.modeSelected", "YES",
            "-com.homecast.communityMode", "NO",
            "-com.homecast.nativeHeaderPreview", "YES",
            "-com.homecast.devWebOrigin", origin,
        ]
        app.launch()
        // A fresh simulator asks for HomeKit access. The synthetic fixture
        // needs none; dismiss the system permission sheet before taking proof.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.alerts.buttons.matching(
            NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])
        ).firstMatch
        if deny.waitForExistence(timeout: 5) { deny.tap() }
    }

    override func tearDownWithError() throws {
        // Keep evidence on failures too, including a failed launch/bridge load.
        capture("final-screen")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "accessibility-tree"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        app.terminate()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNativeHeaderRoundTripAndScroll() {
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.staticTexts["Fixture ready"].waitForExistence(timeout: 30),
                      "The local fixture must load inside Homecast's WKWebView")
        let search = app.buttons["Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10),
                      "The real native header must receive the page's state")
        capture("01-native-header-at-rest")
        search.tap()
        XCTAssertTrue(web.staticTexts["Native search received"].waitForExistence(timeout: 5),
                      "A native tap must cross the bridge back into the page")
        web.swipeUp()
        XCTAssertTrue(web.staticTexts["Scroll received"].waitForExistence(timeout: 5))
        capture("02-native-header-scrolled")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        capture("03-native-header-landscape")
    }
}
