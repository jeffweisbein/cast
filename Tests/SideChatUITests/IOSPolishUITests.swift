import XCTest

#if os(iOS)
/// The full production `ContentView` in the offline fixture app (`--ios-polish-fixture`):
/// bottom tabs, pinned switcher, Results library, Needs You, the composer's + menu and the
/// model sheet, all through delivered taps. Offline by construction: no gateway, credential,
/// pairing or startup call, so connection-dependent controls must present as unavailable
/// rather than as working.
final class IOSPolishUITests: XCTestCase {
    private let cast = "agent:main:cast-chat-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let cackles = "agent:main:cast-chat-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let runpr = "agent:main:cast-chat-cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private let general = "agent:main:main"
    private let placeholder = "Message the fleet…"

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Helpers

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ios-polish-fixture"] + extra
        app.launch()
        XCTAssertTrue(self.row(app, self.cast).waitForExistence(timeout: 15), app.debugDescription)
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func row(_ app: XCUIApplication, _ key: String) -> XCUIElement {
        app.buttons.matching(identifier: "personal-chat-" + key).firstMatch
    }

    /// A labelled tab, wherever the system places the bar on this device.
    private func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let inBar = app.tabBars.buttons[title]
        return inBar.exists ? inBar : app.buttons[title].firstMatch
    }

    /// The composer's message field. It carries no identifier, so it is found by its
    /// placeholder, which stays attached to the element after text is typed.
    private func composerField(_ app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND placeholderValue == %@",
            XCUIElement.ElementType.textView.rawValue, XCUIElement.ElementType.textField.rawValue, self.placeholder)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    private func draftText(_ field: XCUIElement) -> String {
        let value = field.value as? String ?? ""
        return value == self.placeholder ? "" : value
    }

    private func gone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)],
            timeout: timeout) == .completed
    }

    private func waitForSelection(_ app: XCUIApplication, _ key: String, _ message: String,
                                  file: StaticString = #filePath, line: UInt = #line)
    {
        let readout = app.staticTexts["fixture-selected-chat"]
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", key), object: readout)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 8), .completed,
                       "\(message) (selected: \(readout.exists ? readout.label : "missing"))", file: file, line: line)
    }

    /// Opens the pinned switcher from wherever it currently is: the chat's toolbar on a
    /// compact chat detail, otherwise the control under the chat list.
    private func openPinnedSwitcher(_ app: XCUIApplication) {
        let inChat = app.buttons["pinned-switcher-detail"]
        let underList = app.buttons["pinned-switcher"]
        if inChat.exists, inChat.isHittable { inChat.tap() } else {
            XCTAssertTrue(underList.waitForExistence(timeout: 5), app.debugDescription)
            underList.tap()
        }
        XCTAssertTrue(app.buttons["pinned-switch-" + self.cast].waitForExistence(timeout: 5), app.debugDescription)
    }

    private func openChat(_ app: XCUIApplication, _ key: String) {
        self.row(app, key).tap()
        self.waitForSelection(app, key, "A row tap must open that conversation")
        XCTAssertTrue(self.composerField(app).waitForExistence(timeout: 8), app.debugDescription)
    }

    private func assertTopToBottom(_ elements: [XCUIElement], _ message: String,
                                   file: StaticString = #filePath, line: UInt = #line)
    {
        let tops = elements.map(\.frame.minY)
        XCTAssertEqual(tops, tops.sorted(), message + " \(tops)", file: file, line: line)
        XCTAssertEqual(Set(tops).count, tops.count, message + " (overlapping rows) \(tops)", file: file, line: line)
    }

    // MARK: - Tabs, pinned order, switching and drafts

    func testTabsPinnedSwitcherAndDraftRetention() throws {
        let app = self.launch()
        defer { app.terminate() }

        // Labelled tabs, and the chat list — not a greeting — as the landing screen.
        for title in ["Chats", "Needs You", "Results"] {
            XCTAssertTrue(self.tab(app, title).waitForExistence(timeout: 5), "Missing tab \(title)\n" + app.debugDescription)
        }
        XCTAssertTrue(self.tab(app, "Chats").isSelected, "Cast must launch on Chats")
        if self.isPhone {
            XCTAssertEqual(app.staticTexts["fixture-selected-chat"].label, "none",
                           "Launching must not open a conversation or change its read state")
        }
        self.attach(app, "polish-chats-landing")

        // The operator's pinned order holds in the list…
        let order = [self.cast, self.cackles, self.runpr, self.general]
        self.assertTopToBottom(order.map { self.row(app, $0) }, "Pinned chats must keep the user's order in the list")

        // …and in the quick switcher.
        self.openPinnedSwitcher(app)
        self.assertTopToBottom(order.map { app.buttons["pinned-switch-" + $0] },
                               "Pinned chats must keep the user's order in the switcher")
        XCTAssertTrue(app.buttons["pinned-switch-new-chat"].exists)
        self.attach(app, "polish-pinned-switcher")

        app.buttons["pinned-switch-" + self.cackles].tap()
        self.waitForSelection(app, self.cackles, "The switcher must open the chosen pinned chat")

        let field = self.composerField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 8), app.debugDescription)
        field.tap()
        field.typeText("Draft for Cackles")
        XCTAssertEqual(self.draftText(field), "Draft for Cackles")

        // Switch away and back: each conversation keeps its own draft.
        self.openPinnedSwitcher(app)
        app.buttons["pinned-switch-" + self.cast].tap()
        self.waitForSelection(app, self.cast, "The switcher must move between pinned chats")
        XCTAssertTrue(self.composerField(app).waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(self.draftText(self.composerField(app)), "", "Another chat's draft must not leak into this one")

        self.openPinnedSwitcher(app)
        app.buttons["pinned-switch-" + self.cackles].tap()
        self.waitForSelection(app, self.cackles, "Returning to the first chat")
        XCTAssertTrue(self.composerField(app).waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(self.draftText(self.composerField(app)), "Draft for Cackles",
                       "A draft must survive switching chats")
        self.attach(app, "polish-draft-retained")
    }

    // MARK: - Results

    func testResultsFiltersCardAndConversationRoute() throws {
        let app = self.launch()
        defer { app.terminate() }

        self.tab(app, "Results").tap()
        let all = app.buttons["results-filter-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 8), app.debugDescription)
        let image = self.any(app, "result-library-card-fixture-a1")
        let note = self.any(app, "result-library-card-fixture-a2")
        let link = self.any(app, "result-library-card-fixture-link")
        XCTAssertTrue(image.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(note.exists)
        XCTAssertTrue(link.exists)
        // Only kinds that have results offer a filter.
        XCTAssertTrue(app.buttons["results-filter-image"].exists)
        XCTAssertTrue(app.buttons["results-filter-file"].exists)
        XCTAssertFalse(app.buttons["results-filter-pullRequest"].exists, "No pull requests were shared")
        self.attach(app, "polish-results-all")

        app.buttons["results-filter-image"].tap()
        XCTAssertTrue(self.gone(note), "The Images filter must hide files")
        XCTAssertTrue(image.exists)
        self.attach(app, "polish-results-images")

        app.buttons["results-filter-file"].tap()
        XCTAssertTrue(self.gone(image), "The Files filter must hide images")
        XCTAssertTrue(note.waitForExistence(timeout: 5))

        all.tap()
        XCTAssertTrue(image.waitForExistence(timeout: 5))

        // A card opens its detail; the detail routes to the conversation that shared it.
        image.tap()
        let conversation = app.buttons["Conversation"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 8), app.debugDescription)
        self.attach(app, "polish-result-detail")
        conversation.tap()
        self.waitForSelection(app, self.cast, "A result must route to the conversation that shared it")
        XCTAssertTrue(self.composerField(app).waitForExistence(timeout: 8), "The conversation must be on screen\n" + app.debugDescription)
        self.attach(app, "polish-result-routed-to-chat")
    }

    // MARK: - Needs You

    func testNeedsYouRoutesToResultsAndConversation() throws {
        let app = self.launch()
        defer { app.terminate() }

        self.tab(app, "Needs You").tap()
        let openChat = app.buttons["Open chat"].firstMatch
        XCTAssertTrue(openChat.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Pick a headline"].exists, "The agent's own request must be shown")
        self.attach(app, "polish-needs-you")

        // Results are summarised here, owned by the Results tab.
        let resultsLink = app.buttons["needs-you-results-link"]
        XCTAssertTrue(resultsLink.exists, app.debugDescription)
        resultsLink.tap()
        XCTAssertTrue(app.buttons["results-filter-all"].waitForExistence(timeout: 8), "The summary must lead to Results")

        self.tab(app, "Needs You").tap()
        XCTAssertTrue(openChat.waitForExistence(timeout: 8), app.debugDescription)
        openChat.tap()
        self.waitForSelection(app, self.runpr, "Needs You must open the conversation that asked")
        XCTAssertTrue(self.composerField(app).waitForExistence(timeout: 8), app.debugDescription)
        self.attach(app, "polish-needs-you-routed-to-chat")
    }

    // MARK: - Composer + menu and model sheet

    func testPlusMenuAndModelSheetPresentAndDismiss() throws {
        let app = self.launch()
        defer { app.terminate() }
        self.openChat(app, self.cast)

        let field = self.composerField(app)
        field.tap()
        field.typeText("Keep this draft")

        // One + entry, listing only sources this build can really attach.
        let add = app.buttons["composer-add-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        add.tap()
        let photos = app.buttons["Photos & Videos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 5), app.debugDescription)
        for title in ["Files", "Paste Image", "Dictate into Draft", "Deliver Replies Externally"] {
            XCTAssertTrue(app.buttons[title].exists, "Missing menu item \(title)\n" + app.debugDescription)
        }
        XCTAssertFalse(app.buttons["Camera"].exists, "Camera capture is not supported and must not be offered")
        self.attach(app, "polish-plus-menu")

        // Dismiss without choosing.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(self.gone(photos), "Tapping away must dismiss the menu")
        XCTAssertEqual(self.draftText(field), "Keep this draft", "Opening the menu must not disturb the draft")

        // External delivery is off and invisible until chosen, then plainly labelled.
        let chip = app.buttons["composer-external-delivery-chip"]
        XCTAssertFalse(chip.exists, "External delivery must be off by default")
        add.tap()
        XCTAssertTrue(app.buttons["Deliver Replies Externally"].waitForExistence(timeout: 5))
        app.buttons["Deliver Replies Externally"].tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "External delivery must be visible while on\n" + app.debugDescription)
        self.attach(app, "polish-external-delivery-on")
        chip.tap()
        XCTAssertTrue(self.gone(chip), "One tap must turn external delivery back off")

        // Model control shows the gateway-reported model and opens one sheet.
        let model = app.buttons["composer-model-settings"]
        XCTAssertTrue(model.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(model.label.contains("gpt-6-astra"), "The reported model must be named: \(model.label)")
        model.tap()
        let title = app.navigationBars["Model & reasoning"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["In use now"].exists || app.staticTexts["IN USE NOW"].exists, app.debugDescription)
        // Offline fixture: the gateway advertises no model controls, so none may be offered.
        XCTAssertFalse(app.buttons["model-settings-apply"].exists,
                       "A gateway without model controls must not present an apply action")
        self.attach(app, "polish-model-sheet")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(self.gone(title), "Done must dismiss the model sheet")

        self.waitForSelection(app, self.cast, "The sheet must not change the conversation")
        XCTAssertEqual(self.draftText(self.composerField(app)), "Keep this draft", "The sheet must not disturb the draft")
        self.attach(app, "polish-after-model-sheet")
    }

    // MARK: - Phone landscape with the keyboard up

    func testPhoneLandscapeKeyboardKeepsComposerReachable() throws {
        guard self.isPhone else { throw XCTSkip("Phone-only: landscape leaves the least room above the keyboard") }
        let app = self.launch()
        defer { app.terminate() }
        self.openChat(app, self.cast)

        let field = self.composerField(app)
        field.tap()
        field.typeText("Landscape draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Must exercise a visible software keyboard")

        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app)], timeout: 5), .completed)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The keyboard must stay up through rotation")
        self.attach(app, "polish-landscape-keyboard")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "polish-landscape-keyboard-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)

        XCTAssertEqual(self.draftText(self.composerField(app)), "Landscape draft", "Rotation must keep the draft")
        let assistant = app.otherElements["SystemInputAssistantView"].firstMatch
        let keyboardTop = assistant.exists
            ? min(assistant.frame.minY, app.keyboards.firstMatch.frame.minY)
            : app.keyboards.firstMatch.frame.minY
        for (name, control) in [("message field", self.composerField(app)),
                                ("add menu", app.buttons["composer-add-menu"]),
                                ("send", app.buttons["Send message"])]
        {
            XCTAssertTrue(control.exists, "\(name) must exist in landscape\n" + app.debugDescription)
            XCTAssertTrue(control.isHittable, "\(name) must be reachable with the keyboard up")
            XCTAssertLessThanOrEqual(control.frame.maxY, keyboardTop + 1, "\(name) must clear the keyboard")
            XCTAssertGreaterThanOrEqual(control.frame.minY, 0, "\(name) must not be pushed off the top")
        }

        XCUIDevice.shared.orientation = .portrait
        let portrait = NSPredicate { _, _ in app.frame.height > app.frame.width }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: portrait, object: app)], timeout: 5), .completed)
        self.waitForSelection(app, self.cast, "Rotation must not change the conversation")
        XCTAssertEqual(self.draftText(self.composerField(app)), "Landscape draft")
    }

    // MARK: - Screenshots: light, dark, large text

    func testScreenshotsLightDarkAndLargeText() throws {
        for (name, arguments) in [("light", [String]()), ("dark", ["--dark"]), ("large-text", ["--large-text"])] {
            let app = self.launch(arguments)
            self.attach(app, "polish-\(name)-chats")

            self.tab(app, "Needs You").tap()
            XCTAssertTrue(app.buttons["Open chat"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
            self.attach(app, "polish-\(name)-needs-you")

            self.tab(app, "Results").tap()
            XCTAssertTrue(app.buttons["results-filter-all"].waitForExistence(timeout: 8), app.debugDescription)
            self.attach(app, "polish-\(name)-results")

            self.tab(app, "Chats").tap()
            XCTAssertTrue(self.row(app, self.cast).waitForExistence(timeout: 8), app.debugDescription)
            self.openChat(app, self.cast)
            self.attach(app, "polish-\(name)-chat-composer")

            let add = app.buttons["composer-add-menu"]
            XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
            add.tap()
            let photos = app.buttons["Photos & Videos"]
            XCTAssertTrue(photos.waitForExistence(timeout: 5), app.debugDescription)
            self.attach(app, "polish-\(name)-plus-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
            XCTAssertTrue(self.gone(photos))

            app.buttons["composer-model-settings"].tap()
            XCTAssertTrue(app.navigationBars["Model & reasoning"].waitForExistence(timeout: 8), app.debugDescription)
            self.attach(app, "polish-\(name)-model-sheet")
            app.buttons["Done"].firstMatch.tap()
            app.terminate()
        }
    }
}
#endif
