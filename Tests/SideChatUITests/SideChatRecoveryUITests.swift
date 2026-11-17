import XCTest
final class SideChatRecoveryUITests: XCTestCase {
    let keys = ["agent:main:cast-chat-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "agent:main:cast-chat-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "agent:main:cast-chat-cccccccc-cccc-4ccc-8ccc-cccccccccccc", "agent:main:main"]
    func testFlatPersonalListWithRealisticInventoryInLightDarkAndNarrowWindow() throws {
        let app = XCUIApplication()
        for theme in ["light", "dark"] {
            app.launchArguments = ["--reset-fixture", "--project-fixture", "--" + theme] + (theme == "dark" ? ["--narrow"] : [])
            app.launch(); revealSidebar(app)
            var previous: CGRect?
            for key in keys {
                let button = app.buttons["personal-chat-" + key]
                XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
                XCTAssertEqual(app.buttons.matching(identifier: button.identifier).count, 1)
                XCTAssertTrue(button.isHittable)
                if let previous { XCTAssertGreaterThanOrEqual(button.frame.minY, previous.maxY - 1, "Chat rows must not overlap") }
                previous = button.frame
            }
            XCTAssertFalse(app.buttons["personal-chat-agent:main:probe-0"].exists)
            XCTAssertFalse(app.buttons["sidebar-filter-working"].exists)
            XCTAssertFalse(app.buttons["project-Cast"].exists)
            capture("flat-sidebar-" + theme, app)
            press(app.buttons["personal-chat-" + keys[1]])
            XCTAssertFalse(app.buttons["overview-new-chat"].exists)
            capture("direct-chat-" + theme, app)
            revealSidebar(app)
            press(app.buttons["personal-chat-" + keys[1]])
            XCTAssertFalse(app.staticTexts["main-unchanged"].exists, "Reopening must select the same chat detail, not an empty overview")
            capture("same-chat-reopened-" + theme, app)
            app.terminate()
        }
    }
    func testArchiveUndoColdRelaunchRestoreAndPin() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-fixture", "--project-fixture"]
        app.launch(); revealSidebar(app)
        let key = keys[1], entry = app.buttons["personal-chat-" + keys[1]]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        openActions(app, key); press(menuItem(app, "Archive"))
        XCTAssertFalse(entry.exists)
        press(app.buttons["chat-cleanup-undo"])
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        openActions(app, key); press(menuItem(app, "Hide"))
        XCTAssertFalse(entry.exists)
        press(app.buttons["chat-cleanup-undo"])
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        openActions(app, key); press(menuItem(app, "Move up"))
        XCTAssertLessThan(entry.frame.minY, app.buttons["personal-chat-" + keys[0]].frame.minY)
        openActions(app, key); press(menuItem(app, "Archive"))
        app.terminate(); app.launchArguments = ["--project-fixture"]; app.launch(); revealSidebar(app)
        XCTAssertFalse(entry.exists, "Archive must survive relaunch")
        press(app.buttons["manage-chats"])
        #if os(macOS)
        press(app.radioButtons["Archived"])
        #else
        press(app.buttons["Archived"])
        #endif
        let restore = app.buttons["keep-chat-" + key]
        XCTAssertTrue(restore.waitForExistence(timeout: 3), app.debugDescription)
        capture("archive-restore", app)
        press(restore); press(app.buttons["Done"])
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        XCTAssertLessThan(entry.frame.minY, app.buttons["personal-chat-" + keys[0]].frame.minY)
        press(entry)
        capture("restored-same-chat", app)
    }
    func testCancelNewChatLeavesNoGhostAndKeepingOldChatIsExplicit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-fixture", "--project-fixture"]
        app.launch(); revealSidebar(app)
        press(app.buttons["personal-new-chat"])
        XCTAssertTrue(app.textFields["new-chat-name"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["Send"].isEnabled, "Offline fixture cannot send/create")
        capture("new-chat-explicit-first-message", app)
        press(app.buttons["Cancel"])
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "personal-chat-")).count, 4)
        press(app.buttons["manage-chats"])
        let search = app.textFields["Find an existing chat"]
        XCTAssertTrue(search.waitForExistence(timeout: 3), app.debugDescription)
        press(search); search.typeText("Unrelated diagnostic probe 0")
        let keep = app.buttons["keep-chat-agent:main:probe-0"]
        XCTAssertTrue(keep.waitForExistence(timeout: 3), app.debugDescription)
        press(keep); press(app.buttons["Done"])
        XCTAssertTrue(app.buttons["personal-chat-agent:main:probe-0"].waitForExistence(timeout: 3))
    }
    func testSavedSideChatCanBeKeptReopenedAndSurviveColdRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-fixture", "--project-fixture"]
        app.launch(); revealSidebar(app)
        let key = "agent:main:cast-side-11111111-1111-4111-8111-111111111111"
        press(app.buttons["manage-chats"])
        let search = app.textFields["Find an existing chat"]
        press(search); search.typeText("Also can you")
        let keep = app.buttons["keep-chat-" + key]
        XCTAssertTrue(keep.waitForExistence(timeout: 3), app.debugDescription)
        press(keep); press(app.buttons["Done"])
        press(app.buttons["personal-chat-" + key])
        let close = app.buttons["Close side chat"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        capture("saved-side-chat-reopened", app)
        press(close)
        app.terminate(); app.launchArguments = ["--project-fixture"]; app.launch(); revealSidebar(app)
        XCTAssertFalse(close.exists)
        XCTAssertTrue(app.buttons["personal-chat-" + key].waitForExistence(timeout: 5))
        press(app.buttons["personal-chat-" + key])
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        press(close)
    }
    func openActions(_ app: XCUIApplication, _ key: String) {
        let action = app.descendants(matching: .any).matching(identifier: "personal-actions-" + key).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 3), app.debugDescription); press(action)
    }
    func menuItem(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        #if os(macOS)
        return app.menuItems[title]
        #else
        return app.buttons[title]
        #endif
    }
    func revealSidebar(_ app: XCUIApplication) {
        let toggle = app.buttons["Show Sidebar"]
        if toggle.exists && toggle.isHittable { press(toggle) }
        #if os(iOS)
        if !app.buttons["personal-new-chat"].exists {
            let back = app.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
            let hittable = NSPredicate(format: "hittable == true")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hittable, object: back)], timeout: 5), .completed)
            press(back)
            XCTAssertTrue(app.buttons["personal-new-chat"].waitForExistence(timeout: 5), app.debugDescription)
        }
        #endif
    }
    func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }
    func capture(_ name: String, _ app: XCUIApplication) {
        #if os(macOS)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
