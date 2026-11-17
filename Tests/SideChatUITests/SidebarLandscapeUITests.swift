import XCTest

#if os(iOS)
final class SidebarLandscapeUITests: XCTestCase {
    func testSearchAndSwitchChatWithKeyboardAfterRotation() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--reset-fixture", "--project-fixture", "--landscape-sidebar-fixture", "--dark"]
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let search = app.textFields["personal-chat-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.tap()
        search.typeText("Cackles")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app)], timeout: 5), .completed)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Must exercise a visible software keyboard")
        XCTAssertEqual(search.value as? String, "Cackles", "Rotation must retain search text")
        let key = "agent:main:cast-chat-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let chat = app.buttons["personal-chat-" + key]
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "landscape-keyboard-before-selection"; before.lifetime = .keepAlways; add(before)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "landscape-keyboard-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        XCTAssertTrue(chat.waitForExistence(timeout: 5), "Search result must not disappear when keyboard compresses sidebar")
        XCTAssertTrue(chat.isHittable, "The matching chat must be visible without dismissing the keyboard")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let assistant = app.otherElements["SystemInputAssistantView"].firstMatch
        let keyboardTop = assistant.exists
            ? min(assistant.frame.minY, app.keyboards.firstMatch.frame.minY)
            : app.keyboards.firstMatch.frame.minY
        XCTAssertLessThanOrEqual(chat.frame.maxY, keyboardTop + 1,
                                 "The entire row must clear the keyboard prediction/accessory bar")
        chat.tap()
        XCTAssertEqual(app.staticTexts["fixture-selected-chat"].label, key, "A real row tap must select the requested conversation")
        XCUIDevice.shared.orientation = .portrait
        let portrait = NSPredicate { _, _ in app.frame.height > app.frame.width }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: portrait, object: app)], timeout: 5), .completed)
        XCTAssertEqual(app.staticTexts["fixture-selected-chat"].label, key)
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "portrait-selected-chat"; after.lifetime = .keepAlways; add(after)
    }
}
#endif
