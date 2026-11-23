import XCTest

/// Production SessionListView + ChatView + shared inspector in the offline fixture app with
/// fictional signals (`--results-fixture`). Exercises the real filter chips and review
/// controls through delivered taps. Offline: no gateway, so "working" is last-known.
final class ResultsDesignUITests: XCTestCase {
    private let cast = "agent:main:cast-chat-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let cackles = "agent:main:cast-chat-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let runpr = "agent:main:cast-chat-cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private let general = "agent:main:main"

    private func attach(_ app: XCUIApplication, _ name: String) {
        #if os(macOS)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #else
        let shot = XCTAttachment(screenshot: app.screenshot())
        #endif
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func row(_ app: XCUIApplication, _ key: String) -> XCUIElement {
        app.buttons.matching(identifier: "personal-chat-" + key).firstMatch
    }

    private func gone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)],
                       timeout: timeout) == .completed
    }

    func testFilterChipsAndReviewControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--reset-fixture", "--project-fixture", "--results-fixture", "--dark"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(row(app, cast).waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "results-sidebar-all")
        // States come from real signals; the link-only chat and quiet chats get none.
        XCTAssertTrue(row(app, cast).label.contains("Ready to review"), row(app, cast).label)
        XCTAssertTrue(row(app, cackles).label.contains("Working when last connected"), row(app, cackles).label)
        XCTAssertTrue(row(app, runpr).label.contains("Needs you"), row(app, runpr).label)
        XCTAssertFalse(row(app, general).label.contains("review"), "An ordinary link must not create a review state")

        let working = app.buttons["chat-filter-working"]
        XCTAssertTrue(working.waitForExistence(timeout: 5))
        press(working)
        XCTAssertTrue(gone(row(app, cast)), "Working filter must hide the review-only chat")
        XCTAssertTrue(row(app, cackles).exists)
        XCTAssertFalse(row(app, runpr).exists)
        attach(app, "results-sidebar-working")

        press(app.buttons["chat-filter-needsYou"])
        XCTAssertTrue(row(app, runpr).waitForExistence(timeout: 5))
        XCTAssertTrue(gone(row(app, cackles)))

        press(app.buttons["chat-filter-review"])
        XCTAssertTrue(row(app, cast).waitForExistence(timeout: 5))
        XCTAssertTrue(gone(row(app, runpr)))
        XCTAssertFalse(row(app, general).exists)

        press(row(app, cast))
        let reviewButton = app.buttons["result-card-review"]
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "results-chat-card")
        press(reviewButton)
        let markAll = app.buttons["result-mark-all-reviewed"]
        XCTAssertTrue(markAll.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["result-not-reported"].exists || app.descendants(matching: .any)["result-not-reported"].exists)
        attach(app, "results-review-panel")
        press(markAll)
        XCTAssertTrue(gone(markAll), "Marking all reviewed must clear the bulk action")
        attach(app, "results-review-marked")
        #if os(iOS)
        if app.buttons["Done"].exists { press(app.buttons["Done"]) }
        #endif
        XCTAssertTrue(gone(app.descendants(matching: .any)["chat-result-card"]),
                      "A reviewed result must not leave a permanent card in the transcript")
        attach(app, "results-card-gone-after-review")
    }

    /// Real navigation composition: Result review and Side chat share one inspector and are
    /// mutually exclusive in both directions.
    func testResultReviewAndSideChatAreMutuallyExclusive() throws {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            throw XCTSkip("Compact width presents both as sheets; run on iPad or Mac for the shared column")
        }
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--reset-fixture", "--project-fixture", "--results-fixture"]
        app.launch()
        defer { app.terminate() }
        let side = "agent:main:cast-side-11111111-1111-4111-8111-111111111111"
        XCTAssertTrue(row(app, cast).waitForExistence(timeout: 10), app.debugDescription)
        press(app.buttons["manage-chats"])
        let search = app.textFields["Find an existing chat"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        press(search); search.typeText("Also can you")
        let keep = app.buttons["keep-chat-" + side]
        XCTAssertTrue(keep.waitForExistence(timeout: 5), app.debugDescription)
        press(keep); press(app.buttons["Done"])

        let panel = app.descendants(matching: .any)["result-review-panel"]
        let closeSide = app.buttons["Close side chat"]
        press(row(app, cast))
        let review = app.buttons["result-card-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 10), app.debugDescription)
        press(review)
        XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(closeSide.exists)
        attach(app, "inspector-result-open")

        press(row(app, side))
        XCTAssertTrue(closeSide.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(gone(panel), "Opening Side chat must close Result review")
        attach(app, "inspector-side-chat-replaces-result")

        press(row(app, cast))
        #if os(iOS)
        press(app.buttons["chat-actions-menu"])
        #endif
        let toggle = app.buttons["result-review-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        press(toggle)
        XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(gone(closeSide), "Opening Result review must close Side chat")
        attach(app, "inspector-result-replaces-side-chat")
    }

    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }
}
