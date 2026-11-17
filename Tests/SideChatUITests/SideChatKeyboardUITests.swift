import XCTest
final class SideChatKeyboardUITests: XCTestCase {
    #if os(macOS)
    func testReturnSendsAndShiftReturnPreservesMultilineDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-fixture"]
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Side chat question")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        editor.click(); editor.typeText("First line")
        editor.typeKey(.return, modifierFlags: .shift)
        editor.typeText("Second line")
        XCTAssertEqual(text(app.staticTexts["keyboard-send-count"]), "Sends: 0")
        XCTAssertEqual(editor.value as? String, "First line\nSecond line")
        editor.typeKey(.return, modifierFlags: [])
        let sent = NSPredicate(format: "value == %@ OR label == %@", "Sends: 1", "Sends: 1")
        expectation(for: sent, evaluatedWith: app.staticTexts["keyboard-send-count"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(text(app.staticTexts["keyboard-last-message"]).contains("First line\nSecond line"))
        XCTAssertEqual(editor.value as? String, "")
        editor.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(text(app.staticTexts["keyboard-send-count"]), "Sends: 1")
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.lifetime = .keepAlways; add(capture)
    }
    private func text(_ element: XCUIElement) -> String { (element.value as? String) ?? element.label }
    #endif
}
