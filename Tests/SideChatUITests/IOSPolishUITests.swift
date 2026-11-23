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
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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

    /// A stable identity is required: UIKit omits the placeholder once the field has text.
    private func composerField(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "composer-message-field").firstMatch
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

    /// Acceptance asks for 44-point targets. Height is asserted; both dimensions are recorded
    /// so a narrow control is visible in the attachment even where only height is enforced.
    private func assertTallEnough(_ controls: [(String, XCUIElement)], _ name: String,
                                  file: StaticString = #filePath, line: UInt = #line)
    {
        var report: [String] = []
        for (label, control) in controls {
            guard control.exists else { report.append("\(label): missing"); continue }
            let size = control.frame.size
            report.append(String(format: "%@: %.1f x %.1f", label, size.width, size.height))
            XCTAssertGreaterThanOrEqual(size.height, 43.5, "\(label) must be at least 44 points tall", file: file, line: line)
        }
        self.record(report, name)
    }

    /// Measurements that are reported, not enforced.
    private func record(_ lines: [String], _ name: String) {
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func frames(_ controls: [(String, XCUIElement)]) -> [String] {
        controls.map { label, control in
            control.exists
                ? String(format: "%@: %.1f x %.1f", label, control.frame.width, control.frame.height)
                : "\(label): missing"
        }
    }

    /// On a phone the tab bar sits under the software keyboard, so reaching a tab from a
    /// chat means putting the keyboard away through the production Chat actions menu.
    private func dismissKeyboard(_ app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        func hittableHideButton() -> XCUIElement? {
            app.buttons.matching(identifier: "Hide keyboard").allElementsBoundByIndex.first { $0.isHittable }
        }
        if let hide = hittableHideButton() { hide.tap() } else {
            app.buttons["chat-actions-menu"].tap()
            let available = NSPredicate { _, _ in hittableHideButton() != nil }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: available, object: app)], timeout: 5), .completed)
            guard let hide = hittableHideButton() else { return }
            hide.tap()
        }
        XCTAssertTrue(self.gone(keyboard), "The keyboard must dismiss through the production Hide keyboard action")
    }

    func testCompactTypingAndDirectKeyboardDismissal() throws {
        for arguments in [[String](), ["--large-text"]] {
            let app = self.launch(arguments)
            self.openChat(app, self.cast)
            let field = self.composerField(app)
            field.tap()
            field.typeText("Keep this draft")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            let hide = app.buttons["composer-hide-keyboard"]
            XCTAssertTrue(hide.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(hide.isHittable)
            XCTAssertTrue(hide.isEnabled)
            XCTAssertGreaterThanOrEqual(hide.frame.width, 43.99)
            XCTAssertGreaterThanOrEqual(hide.frame.height, 43.99)
            XCTAssertTrue(self.gone(app.buttons["Jump to"]), "Routine navigation must collapse for the docked keyboard")
            let transcript = app.scrollViews["chat-transcript"]
            self.record(["transcript: \(transcript.frame)", "composer: \(field.frame)", "hide: \(hide.frame)"],
                        arguments.isEmpty ? "bear-standard-geometry" : "bear-large-text-geometry")
            self.attach(app, arguments.isEmpty ? "bear-standard-typing" : "bear-large-text-typing")
            hide.tap()
            XCTAssertTrue(self.gone(app.keyboards.firstMatch))
            XCTAssertTrue(app.buttons["Jump to"].waitForExistence(timeout: 5), "Navigation must return after keyboard dismissal")
            XCTAssertEqual(self.draftText(self.composerField(app)), "Keep this draft")
            self.waitForSelection(app, self.cast, "Dismissal must preserve the selected chat")
            self.attach(app, arguments.isEmpty ? "bear-standard-dismissed" : "bear-large-text-dismissed")
            app.terminate()
        }
    }

    func testConnectionExpansionDoesNotPresentSheetWhenTyping() throws {
        let app = self.launch()
        defer { app.terminate() }
        self.openChat(app, self.cast)
        app.buttons["composer-hide-keyboard"].tap()
        XCTAssertTrue(self.gone(app.keyboards.firstMatch))
        let fieldMidX = self.composerField(app).frame.midX
        let candidates = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Connection status:")).allElementsBoundByIndex
        self.record(candidates.map { "status: \($0.frame)" }, "connection-status-candidates")
        let inChat = candidates.filter { $0.frame.minX < fieldMidX && $0.frame.maxX > fieldMidX }
        XCTAssertEqual(inChat.count, 1, "Select the chat status, not the iPad sidebar status")
        let status = try XCTUnwrap(inChat.first)
        status.tap()
        self.composerField(app).tap()
        self.composerField(app).typeText("Connection draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(self.gone(app.buttons["Jump to"]))
        XCTAssertFalse(app.navigationBars["Connection"].exists, "Keyboard docking must not promote inline state into a modal")
        XCTAssertEqual(self.draftText(self.composerField(app)), "Connection draft")
        // Accessibility order changes when the sidebar relayouts for the keyboard.
        let compactStatus = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Connection status:")).allElementsBoundByIndex.filter {
            $0.frame.minX < fieldMidX && $0.frame.maxX > fieldMidX
        }
        XCTAssertEqual(compactStatus.count, 1)
        try XCTUnwrap(compactStatus.first).tap()
        XCTAssertTrue(app.navigationBars["Connection"].waitForExistence(timeout: 5), "Explicit compact-status tap must still open details")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(self.gone(app.navigationBars["Connection"]))
    }

    func testTypingAttentionRemainsReachable() throws {
        for arguments in [["--typing-attention"], ["--typing-attention", "--large-text"]] {
            let app = self.launch(arguments)
            self.openChat(app, self.cast)
            self.composerField(app).tap()
            self.composerField(app).typeText("Attention draft")
            for (identifier, title) in [("chat-pending-questions", "Questions"),
                                       ("chat-pending-approvals", "Approvals"),
                                       ("chat-pending-secure-entry", "Secure entry")] {
                let menu = app.buttons["chat-pending-attention-menu"]
                XCTAssertTrue(menu.waitForExistence(timeout: 5))
                menu.tap()
                let control = app.buttons[identifier]
                XCTAssertTrue(control.waitForExistence(timeout: 5), app.debugDescription)
                XCTAssertTrue(control.isHittable, app.debugDescription)
                control.tap()
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), app.debugDescription)
                app.buttons["Done"].firstMatch.tap()
                XCTAssertTrue(self.gone(app.navigationBars[title]))
                XCTAssertEqual(self.draftText(self.composerField(app)), "Attention draft")
                self.composerField(app).tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            }
            self.attach(app, arguments.count == 1 ? "bear-attention-standard" : "bear-attention-large-text")
            app.terminate()
        }
    }

    /// The identical measurement can run on the shipped baseline without a new app seam.
    func testTypingViewportMeasurement() throws {
        for arguments in [[String](), ["--large-text"]] {
            let app = self.launch(arguments)
            self.openChat(app, self.cast)
            self.composerField(app).tap()
            self.composerField(app).typeText("Keep this draft")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            let field = self.composerField(app)
            let scrolls = app.scrollViews.allElementsBoundByIndex.filter {
                $0.frame.width > 100 && $0.frame.minY < field.frame.minY && $0.frame.maxY <= field.frame.minY + 1
            }
            self.record(scrolls.map { "scroll: \($0.frame)" } + ["field: \(field.frame)", "keyboard: \(app.keyboards.firstMatch.frame)"],
                        arguments.isEmpty ? "viewport-standard" : "viewport-large-text")
            self.attach(app, arguments.isEmpty ? "viewport-standard" : "viewport-large-text")
            app.terminate()
        }
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
        self.assertTallEnough([
            ("Pinned switcher", app.buttons["pinned-switcher"]),
            ("New chat", app.buttons["personal-new-chat"].firstMatch),
            ("All chats filter", app.buttons["chat-filter-all"]),
            ("Working filter", app.buttons["chat-filter-working"]),
        ], "polish-target-sizes-chats")

        // UIKit reports the toolbar glyph's 36pt visual frame separately from its native
        // hit region. Prove a 44pt vertical target with delivered taps on both outer edges.
        let more = self.any(app, "chats-more-menu")
        self.record(self.frames([("Native More glyph", more)]), "polish-native-toolbar-frame")
        for offset in [-21.0, 21.0] {
            more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 0, dy: offset)).tap()
            XCTAssertTrue(app.buttons["Workspace"].waitForExistence(timeout: 5),
                          "Native toolbar target must receive a tap within its 44pt hit region")
            app.buttons["Workspace"].tap()
            XCTAssertTrue(app.buttons["Pair workspace…"].waitForExistence(timeout: 5),
                          "Workspace actions must remain reachable from More")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.90)).tap()
            XCTAssertTrue(self.gone(app.buttons["Pair workspace…"]))
            XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        }

        // The operator's pinned order holds in the list…
        let order = [self.cast, self.cackles, self.runpr, self.general]
        self.assertTopToBottom(order.map { self.row(app, $0) }, "Pinned chats must keep the user's order in the list")

        // …and in the quick switcher.
        self.openPinnedSwitcher(app)
        self.assertTopToBottom(order.map { app.buttons["pinned-switch-" + $0] },
                               "Pinned chats must keep the user's order in the switcher")
        XCTAssertTrue(app.buttons["pinned-switch-new-chat"].exists)
        self.assertTallEnough([
            ("Switcher row", app.buttons["pinned-switch-" + self.cast]),
            ("Switcher new chat", app.buttons["pinned-switch-new-chat"]),
        ], "polish-target-sizes-switcher")
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

    // MARK: - Tabs stay reachable inside a chat

    /// Phone and iPad: the tabs remain available while a chat is open, and visiting another
    /// tab and coming back leaves the same conversation on screen with its draft.
    func testSelectedChatAndDraftSurviveLeavingAndReturningToChats() throws {
        let app = self.launch()
        defer { app.terminate() }
        self.openChat(app, self.cast)

        let field = self.composerField(app)
        field.tap()
        field.typeText("Draft across tabs")
        XCTAssertEqual(self.draftText(field), "Draft across tabs")
        self.dismissKeyboard(app)

        // The tabs are reachable from inside the chat, without backing out to the list.
        let results = self.tab(app, "Results")
        XCTAssertTrue(results.waitForExistence(timeout: 5), "Results must be reachable from inside a chat\n" + app.debugDescription)
        XCTAssertTrue(results.isHittable, "The Results tab must be tappable while a chat is open")
        XCTAssertTrue(self.composerField(app).exists, "The chat must still be on screen")
        self.attach(app, "polish-tabs-visible-in-chat")

        for destination in ["Results", "Needs You"] {
            // Returning to Chats restores the editor focus as well as its draft.
            self.dismissKeyboard(app)
            self.tab(app, destination).tap()
            let landmark = destination == "Results" ? app.buttons["results-filter-all"] : app.buttons["Open chat"].firstMatch
            XCTAssertTrue(landmark.waitForExistence(timeout: 8), "\(destination) must open\n" + app.debugDescription)
            XCTAssertEqual(app.staticTexts["fixture-selected-chat"].label, self.cast,
                           "Visiting \(destination) must not deselect the open conversation")

            let chats = self.tab(app, "Chats")
            XCTAssertTrue(chats.waitForExistence(timeout: 5), app.debugDescription)
            chats.tap()
            self.waitForSelection(app, self.cast, "Returning from \(destination) must keep the same conversation")
            let restored = self.composerField(app)
            XCTAssertTrue(restored.waitForExistence(timeout: 8),
                          "Returning from \(destination) must show the chat, not the list\n" + app.debugDescription)
            XCTAssertEqual(self.draftText(restored), "Draft across tabs",
                           "Returning from \(destination) must keep the draft")
        }
        self.attach(app, "polish-chat-and-draft-after-tabs")

        // Reported, not enforced: whether the workspace menu (switch, pair, setup, export
        // diagnostics) opens from the Chats title, its only entry point on iOS.
        if self.isPhone, app.navigationBars.buttons.firstMatch.exists {
            app.navigationBars.buttons.firstMatch.tap()
        }
        var probe = ["Chats title bar present: \(app.navigationBars["Chats"].exists)"]
        if self.row(app, self.cast).waitForExistence(timeout: 5) {
            let bar = app.navigationBars["Chats"]
            let title = bar.buttons["Chats"].exists ? bar.buttons["Chats"] : bar.staticTexts["Chats"]
            if title.exists, title.isHittable { title.tap() }
            let reachable = app.buttons["Pair workspace…"].waitForExistence(timeout: 3)
            probe.append("Title tappable: \(title.exists)")
            probe.append("Workspace menu opened from title: \(reachable)")
            self.attach(app, "polish-workspace-title-menu-probe")
        } else {
            probe.append("Chat list not reached; probe skipped")
        }
        self.record(probe, "polish-workspace-title-menu-probe")
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
        self.assertTallEnough([
            ("All results filter", all),
            ("Images filter", app.buttons["results-filter-image"]),
        ], "polish-target-sizes-results")

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
        // Recorded for review rather than enforced here: these are system-styled buttons.
        self.record(self.frames([
            ("Open chat", openChat),
            ("Details", app.buttons["Details"].firstMatch),
            ("Results summary", app.buttons["needs-you-results-link"]),
        ]), "polish-target-sizes-needs-you")

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
            if app.keyboards.firstMatch.exists {
                let assistant = app.otherElements["SystemInputAssistantView"].firstMatch
                let keyboardTop = assistant.exists ? min(assistant.frame.minY, app.keyboards.firstMatch.frame.minY) : app.keyboards.firstMatch.frame.minY
                XCTAssertLessThanOrEqual(add.frame.maxY, keyboardTop + 1, "Composer controls must stay above the keyboard at every text size")
                XCTAssertTrue(add.isHittable, "The add control must remain reachable")
            }
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
