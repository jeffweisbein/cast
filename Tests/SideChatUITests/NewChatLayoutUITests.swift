import XCTest

#if os(iOS)
final class NewChatLayoutUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }

    func testNameAndMessageStayEditableAboveKeyboard() throws { try exercise([]) }
    func testLargeTextNameAndMessageStayEditable() throws { try exercise(["--large-text"]) }

    private func exercise(_ extra: [String]) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-fixture", "--project-fixture"] + extra
        // A SwiftUI size override on the presenting view does not reach every sheet.
        // Set UIKit's launch preference too, and prove the presented form is enlarged.
        if extra.contains("--large-text") {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        }
        app.launch()
        let newChat = app.buttons["personal-new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 10), app.debugDescription)
        newChat.tap()
        let name = app.textFields["new-chat-name"]
        let editor = app.textViews["new-chat-message"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription)
        if extra.contains("--large-text") {
            XCTAssertGreaterThan(app.staticTexts["First message"].frame.height, 30, "Large text must reach the actual sheet")
        }
        name.tap(); name.typeText("A clear title")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let title = app.navigationBars["New Chat"].staticTexts["New Chat"]
        XCTAssertTrue(title.exists, app.debugDescription)
        capture(app, "name-keyboard")
        XCTAssertGreaterThanOrEqual(name.frame.minY, title.frame.maxY, "The heading must not overlap the editable name")
        XCTAssertTrue(name.isHittable)
        if !editor.isHittable { app.swipeUp() }
        XCTAssertTrue(editor.isHittable, app.debugDescription)
        editor.tap(); editor.typeText("Hi")
        capture(app, "message-keyboard")
        XCTAssertEqual(editor.value as? String, "Hi")
        if !name.isHittable { app.swipeDown() }
        XCTAssertTrue(name.isHittable, app.debugDescription)
        name.tap(); name.typeText(" edited")
        XCTAssertEqual(name.value as? String, "A clear title edited")
        XCTAssertGreaterThanOrEqual(name.frame.minY, title.frame.maxY)
        XCTAssertFalse(app.buttons["Send"].isEnabled, "Offline verification must not create a real chat")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "personal-chat-")).count, 4)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-tree"; tree.lifetime = .keepAlways; add(tree)
    }
}
#endif
