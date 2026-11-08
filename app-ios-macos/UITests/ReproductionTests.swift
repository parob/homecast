import XCTest

/// Issue-specific simulator replays. Account/relay data is synthetic.
final class ReproductionTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let origin = try XCTUnwrap(ProcessInfo.processInfo.environment["HOMECAST_TEST_WEB_ORIGIN"])
        let route = name.contains("257") ? "/native/header" : name.contains("228") ? "/native/status" : name.contains("227") ? "/native/room" : ""
        app.launchArguments = [
            "-com.homecast.modeSelected", "YES",
            "-com.homecast.communityMode", "NO",
            "-com.homecast.nativeHeaderPreview", "YES",
            "-com.homecast.devWebOrigin", origin + route,
        ]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.alerts.buttons.matching(
            NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])
        ).firstMatch
        if deny.waitForExistence(timeout: 5) { deny.tap() }
    }

    override func tearDownWithError() throws {
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

    func testIssue222NativeNewCollectionOpensRealDialog() {
        let title = app.buttons["Switch home"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 45), "Real dashboard must publish its native title menu")
        title.tap()
        capture("222-native-menu-no-collections")
        let create = app.buttons["New Collection"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5), "Native UIKit menu must offer New Collection when none exist")
        create.tap()
        XCTAssertTrue(app.webViews.staticTexts["Create Collection"].firstMatch.waitForExistence(timeout: 10),
                      "The actual native menu callback must open the real React dialog")
        capture("222-real-create-collection-dialog")
    }

    func testIssue227ColdRoomBackHasVisibleDestination() {
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.staticTexts["Room fixture ready"].waitForExistence(timeout: 30))
        capture("227-cold-restored-room")
        let back = app.navigationBars.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        capture("227-native-back-transition")
        let placeholder = app.descendants(matching: .any)["home-swipe-placeholder"].firstMatch
        let hadDestination = placeholder.exists
        XCTAssertTrue(web.staticTexts["Home content ready"].waitForExistence(timeout: 10), "Back must eventually restore Home")
        capture("227-home-restored")
        XCTAssertTrue(hadDestination, "Cold-start native Back must show a named destination while the web home loads")
    }

    func testIssue228StatusBarOverLightCover() {
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.staticTexts["Status fixture ready"].waitForExistence(timeout: 30))
        capture("228-dark-home-status-bar")
        web.buttons["Open light Analytics cover"].tap()
        XCTAssertTrue(web.staticTexts["Analytics fixture"].waitForExistence(timeout: 5))
        capture("228-light-analytics-status-bar")
        // System-clock contrast needs screenshot review; a pass only means
        // the cover state reached the real shell and returned successfully.
        web.buttons["Close Analytics cover"].tap()
        XCTAssertTrue(app.buttons["Search"].firstMatch.waitForExistence(timeout: 5))
        capture("228-returned-dark-home-status-bar")
    }

    func testIssue257ScrollEdgeAppearance() {
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.staticTexts["Fixture ready"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Search"].firstMatch.waitForExistence(timeout: 5))
        capture("257-header-at-rest")
        web.swipeUp()
        XCTAssertTrue(web.staticTexts["Scroll received"].waitForExistence(timeout: 5))
        capture("257-header-scrolled")
        // Visual comparison, not an assertion that iOS 27 is fixed.
        XCUIDevice.shared.orientation = .landscapeLeft
        capture("257-header-landscape")
    }
}
