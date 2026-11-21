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
        let shot = XCTAttachment(screenshot: app.screenshot())
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
        working.tap()
        XCTAssertTrue(gone(row(app, cast)), "Working filter must hide the review-only chat")
        XCTAssertTrue(row(app, cackles).exists)
        XCTAssertFalse(row(app, runpr).exists)
        attach(app, "results-sidebar-working")

        app.buttons["chat-filter-needsYou"].tap()
        XCTAssertTrue(row(app, runpr).waitForExistence(timeout: 5))
        XCTAssertTrue(gone(row(app, cackles)))

        app.buttons["chat-filter-review"].tap()
        XCTAssertTrue(row(app, cast).waitForExistence(timeout: 5))
        XCTAssertTrue(gone(row(app, runpr)))
        XCTAssertFalse(row(app, general).exists)

        row(app, cast).tap()
        let reviewButton = app.buttons["result-card-review"]
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "results-chat-card")
        reviewButton.tap()
        let markAll = app.buttons["result-mark-all-reviewed"]
        XCTAssertTrue(markAll.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["result-not-reported"].exists || app.descendants(matching: .any)["result-not-reported"].exists)
        attach(app, "results-review-panel")
        markAll.tap()
        XCTAssertTrue(gone(markAll), "Marking all reviewed must clear the bulk action")
        attach(app, "results-review-marked")
    }
}
