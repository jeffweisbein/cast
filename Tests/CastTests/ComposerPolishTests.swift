import Foundation
import XCTest
@testable import Cast

/// What the model sheet is allowed to claim, and when it lets a request through.
final class SessionModelSheetStateTests: XCTestCase {
    private let levels = [
        ThinkingOption(id: "low", label: "Low"),
        ThinkingOption(id: "high", label: "High"),
    ]

    private func choice(
        _ id: String,
        provider: String = "openai",
        available: Bool? = true,
        levels: [ThinkingOption]? = nil,
        thinkingDefault: String? = nil) -> GatewayModelChoice
    {
        GatewayModelChoice(
            id: id, name: id.uppercased(), provider: provider, available: available,
            thinkingLevels: levels, thinkingDefault: thinkingDefault)
    }

    func testCurrentModelMatchesBareIdOrReferenceAndRespectsProvider() {
        let choices = [choice("astra", provider: "other"), choice("astra")]
        XCTAssertEqual(
            SessionModelSheetState.choice(matching: "astra", provider: "openai", in: choices)?.reference,
            "openai/astra")
        XCTAssertEqual(
            SessionModelSheetState.choice(matching: "openai/astra", provider: nil, in: choices)?.reference,
            "openai/astra")
        XCTAssertNil(SessionModelSheetState.choice(matching: nil, provider: nil, in: choices))
        XCTAssertNil(SessionModelSheetState.choice(matching: "", provider: nil, in: choices))
    }

    func testUnreportedValuesAreLabelledNotGuessed() {
        let state = SessionModelSheetState()
        XCTAssertEqual(state.currentModelLabel, "Not reported")
        XCTAssertEqual(state.currentReasoningLabel, "Not reported")
        XCTAssertNil(state.lastReplyLabel)
        XCTAssertNil(state.requestedLabel)
        XCTAssertFalse(state.lastReplyDiffers)
    }

    func testReasoningShowsOverrideBeforeDefault() {
        var state = SessionModelSheetState(
            sessionModel: "astra", thinkingOverride: "high", thinkingDefault: "low",
            choices: [choice("astra", levels: levels)])
        XCTAssertEqual(state.currentReasoningLabel, "High")
        state.thinkingOverride = nil
        XCTAssertEqual(state.currentReasoningLabel, "Model default · Low")
    }

    func testLastReplyIsReportedSeparatelyAndFlaggedOnlyWhenDifferent() {
        var state = SessionModelSheetState(
            sessionModel: "openai/astra", lastResponseModel: "astra", lastResponseProvider: "openai")
        XCTAssertEqual(state.lastReplyLabel, "openai/astra")
        XCTAssertFalse(state.lastReplyDiffers)
        XCTAssertEqual(state.summaryFootnote, "Cast shows only what the gateway reports.")

        state.lastResponseModel = "fallback-mini"
        XCTAssertTrue(state.lastReplyDiffers)
        XCTAssertTrue(state.summaryFootnote.contains("gateway fallback"))

        state.isConnected = false
        XCTAssertTrue(state.summaryFootnote.hasPrefix("Offline"))
    }

    func testRequestedModelIsNamedFromTheCatalogWhenKnown() {
        var state = SessionModelSheetState(pendingReference: "openai/astra", choices: [choice("astra")])
        XCTAssertEqual(state.requestedLabel, "ASTRA")
        state.choices = []
        XCTAssertEqual(state.requestedLabel, "openai/astra")
    }

    func testChangingModelCarriesEffortOnlyWhenSupported() {
        let withLevels = choice("astra", levels: levels)
        XCTAssertEqual(SessionModelSheetState.carriedEffort("high", to: withLevels), "high")
        XCTAssertEqual(SessionModelSheetState.carriedEffort("max", to: withLevels), "")
        XCTAssertEqual(SessionModelSheetState.carriedEffort("high", to: choice("plain")), "")
        XCTAssertEqual(SessionModelSheetState.carriedEffort(nil, to: withLevels), "")
        XCTAssertEqual(SessionModelSheetState.carriedEffort("high", to: nil), "")
    }

    func testModelWithoutLevelsExplainsTheMissingControl() {
        let state = SessionModelSheetState(
            choices: [choice("plain")], selectedReference: "openai/plain")
        XCTAssertTrue(state.effortOptions.isEmpty)
        XCTAssertEqual(state.reasoningUnavailableNote, "PLAIN does not report adjustable reasoning levels.")
        XCTAssertNil(SessionModelSheetState().reasoningUnavailableNote)
    }

    func testDefaultEffortLabelNamesTheDefaultLevelWhenReported() {
        var state = SessionModelSheetState(
            choices: [choice("astra", levels: levels, thinkingDefault: "low")],
            selectedReference: "openai/astra")
        XCTAssertEqual(state.defaultEffortLabel, "Default (Low)")
        state.choices = [choice("astra", levels: levels)]
        XCTAssertEqual(state.defaultEffortLabel, "Default")
    }

    func testApplyIsBlockedWithOneStatedReason() {
        let astra = choice("astra", levels: levels)
        let down = choice("down", available: false)
        var state = SessionModelSheetState(
            sessionModel: "astra", sessionProvider: "openai",
            choices: [astra, down, choice("nova")],
            selectedReference: "openai/astra")

        XCTAssertEqual(state.applyBlocker, "Already set for this conversation.")
        XCTAssertFalse(state.canApply)

        state.selectedReference = ""
        XCTAssertEqual(state.applyBlocker, "Choose a model.")

        state.selectedReference = "openai/down"
        XCTAssertEqual(state.applyBlocker, "DOWN is unavailable right now.")

        state.selectedReference = "openai/astra"
        state.selectedEffort = "max"
        XCTAssertEqual(state.applyBlocker, "Choose a reasoning level this model supports.")

        state.selectedEffort = "high"
        XCTAssertNil(state.applyBlocker)
        XCTAssertTrue(state.canApply)

        state.isSaving = true
        XCTAssertFalse(state.canApply)
        XCTAssertEqual(state.applyTitle, "Saving…")
        state.isSaving = false

        state.isConnected = false
        XCTAssertEqual(state.applyBlocker, "Reconnect to change this conversation’s model.")
        state.isConnected = true
        state.supportsControls = false
        XCTAssertTrue(state.applyBlocker?.contains("does not advertise model controls") == true)
    }

    func testChangeDetectionCoversModelAndReasoning() {
        let astra = choice("astra", levels: levels)
        var state = SessionModelSheetState(
            sessionModel: "astra", sessionProvider: "openai", thinkingOverride: "high",
            choices: [astra, choice("nova")],
            selectedReference: "openai/astra", selectedEffort: "high")
        XCTAssertFalse(state.hasChanges)

        // Returning to the model default clears an override, which is a real change.
        state.selectedEffort = ""
        XCTAssertTrue(state.hasChanges)

        state.selectedEffort = "high"
        state.selectedReference = "openai/nova"
        XCTAssertTrue(state.hasChanges)
    }

    func testChipLabelDropsProviderAndNeverInventsAModel() {
        XCTAssertEqual(ComposerModelStatus(model: "openai/gpt-6-astra", isConnected: true).chipLabel, "gpt-6-astra")
        XCTAssertEqual(ComposerModelStatus(model: " claude-opus-5 ", isConnected: false).chipLabel, "claude-opus-5")
        XCTAssertEqual(ComposerModelStatus(model: nil, isConnected: true).chipLabel, "Model")
        XCTAssertEqual(ComposerModelStatus(model: "  ", isConnected: true).chipLabel, "Model")
        // The descriptive label used for accessibility is unchanged.
        XCTAssertEqual(ComposerModelStatus(model: "openai/gpt-6-astra", isConnected: true).label,
                       "Model: openai/gpt-6-astra")
    }
}

/// An import is attached only after it really succeeded, in the draft it was started for.
@MainActor
final class ComposerImportQueueTests: XCTestCase {
    /// Reference-typed so the delivery closures record outcomes without capturing a `var`.
    private final class Outcomes {
        var delivered: [String] = []
        var discarded = 0
    }

    private struct Failure: LocalizedError {
        var errorDescription: String? { "Cast could not read that file." }
    }

    private let sessionA = ChatStore.AttachmentDraftTarget(
        workspaceID: "w", gatewayURL: URL(string: "wss://example.invalid")!, sessionKey: "agent:main:a")
    private let sessionB = ChatStore.AttachmentDraftTarget(
        workspaceID: "w", gatewayURL: URL(string: "wss://example.invalid")!, sessionKey: "agent:main:b")

    private func attachment(_ name: String = "note.txt") -> PreparedAttachment {
        PreparedAttachment(type: "file", mimeType: "text/plain", fileName: name, data: Data("x".utf8))
    }

    private func settle(_ queue: ComposerImportQueue, until done: @MainActor () -> Bool) async {
        for _ in 0 ..< 400 where !done() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        _ = queue
    }

    func testSuccessDeliversOnceAndRemovesTheTile() async {
        let queue = ComposerImportQueue()
        let outcomes = Outcomes()
        let expected = self.attachment()
        let id = queue.enqueue(
            title: "note.txt", symbol: "doc", target: self.sessionA,
            work: { expected },
            deliver: { outcomes.delivered.append($0.fileName) })
        XCTAssertTrue(queue.isPreparing(id))
        XCTAssertEqual(queue.items(for: self.sessionA).map(\.title), ["note.txt"])

        await self.settle(queue) { queue.items.isEmpty }
        XCTAssertEqual(outcomes.delivered, ["note.txt"])
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testFailureStaysVisibleWithItsReasonUntilDismissed() async {
        let queue = ComposerImportQueue()
        let outcomes = Outcomes()
        let id = queue.enqueue(
            title: "broken.bin", symbol: "doc", target: self.sessionA,
            work: { throw Failure() },
            deliver: { outcomes.delivered.append($0.fileName) })

        await self.settle(queue) { !queue.isPreparing(id) }
        XCTAssertTrue(outcomes.delivered.isEmpty)
        XCTAssertEqual(queue.items.first?.phase, .failed("Cast could not read that file."))

        queue.cancel(id)
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testCancelledImportIsDiscardedAndNeverAttached() async {
        let queue = ComposerImportQueue()
        let outcomes = Outcomes()
        let expected = self.attachment()
        let id = queue.enqueue(
            title: "slow.mov", symbol: "doc", target: self.sessionA,
            work: {
                // Finishes despite cancellation, as a copy that is already on disk would.
                try? await Task.sleep(for: .milliseconds(40))
                return expected
            },
            deliver: { outcomes.delivered.append($0.fileName) },
            discard: { _ in outcomes.discarded += 1 })

        queue.cancel(id)
        XCTAssertTrue(queue.items.isEmpty, "Cancel removes the tile immediately")

        await self.settle(queue) { outcomes.discarded > 0 }
        XCTAssertTrue(outcomes.delivered.isEmpty)
        XCTAssertEqual(outcomes.discarded, 1)
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testTilesAreScopedToTheDraftTheyWereStartedFor() {
        let queue = ComposerImportQueue()
        let a = queue.begin(title: "for A", symbol: "doc", target: self.sessionA)
        queue.report("The clipboard has no image.", title: "Paste Image", symbol: "doc.on.clipboard", target: self.sessionB)

        XCTAssertEqual(queue.items(for: self.sessionA).map(\.title), ["for A"])
        XCTAssertEqual(queue.items(for: self.sessionB).map(\.title), ["Paste Image"])

        // Clearing failures never removes work that is still running, in any conversation.
        queue.clearFailures(for: self.sessionA)
        queue.clearFailures(for: self.sessionB)
        XCTAssertTrue(queue.isPreparing(a))
        XCTAssertTrue(queue.items(for: self.sessionB).isEmpty)
    }

    func testProgressTitleAppliesOnlyWhilePreparing() {
        let queue = ComposerImportQueue()
        let id = queue.begin(title: "3 photos and videos", symbol: "photo", target: self.sessionA)
        queue.retitle(id, "Preparing 2 of 3")
        XCTAssertEqual(queue.items.first?.title, "Preparing 2 of 3")

        queue.fail(id, message: "That image format could not be decoded.")
        queue.retitle(id, "Preparing 3 of 3")
        XCTAssertEqual(queue.items.first?.title, "Preparing 2 of 3")
        XCTAssertFalse(queue.isPreparing(id))
    }

    func testWorkAttachedAfterCancellationIsCancelled() async {
        let queue = ComposerImportQueue()
        let id = queue.begin(title: "photo", symbol: "photo", target: self.sessionA)
        queue.cancel(id)
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        queue.attach(task, to: id)
        XCTAssertTrue(task.isCancelled)
    }

    func testThumbnailDecoderRejectsNonImages() {
        XCTAssertNil(ComposerThumbnailDecoder.thumbnail(from: Data(), maxPixelSize: 224))
        XCTAssertNil(ComposerThumbnailDecoder.thumbnail(from: Data("not an image".utf8), maxPixelSize: 224))
    }
}

/// The suite is macOS-hosted and cannot instantiate the iOS composer, so these keep a narrow
/// source guard on the properties of it that protect the operator.
final class IOSComposerStructureTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testComposerHasOneAddEntryAndOnlySupportedSources() throws {
        let chat = try self.source("Sources/App/ChatView.swift")
        XCTAssertEqual(chat.components(separatedBy: "accessibilityIdentifier(\"composer-add-menu\")").count, 2)
        let start = try XCTUnwrap(chat.range(of: "private var addMenu: some View"))
        let end = try XCTUnwrap(chat[start.upperBound...].range(of: "accessibilityIdentifier(\"composer-add-menu\")"))
        let menu = String(chat[start.upperBound ..< end.lowerBound])
        for supported in ["Photos & Videos", "Files", "Paste Image", "Deliver Replies Externally"] {
            XCTAssertTrue(menu.contains(supported), supported)
        }
        for unsupported in ["Camera", "Connector", "Skill", "Project"] {
            XCTAssertFalse(menu.contains(unsupported), "\(unsupported) has no implementation behind it")
        }
    }

    func testExternalDeliveryStillRequiresConfirmationAndIsVisibleWhenOn() throws {
        let chat = try self.source("Sources/App/ChatView.swift")
        XCTAssertTrue(chat.contains("if self.model.deliverExternally {\n            self.confirmingDelivery = true"))
        XCTAssertTrue(chat.contains("Button(\"Deliver externally\", role: .destructive) { self.performSend(deliver: true) }"))
        XCTAssertTrue(chat.contains("deliversExternally: self.model.deliverExternally"))
        let tray = try self.source("Sources/App/ComposerAttachmentTray.swift")
        XCTAssertTrue(tray.contains("if self.deliversExternally {"))
        XCTAssertTrue(tray.contains("External delivery on"))
    }

    func testImportsBindToTheDraftCapturedBeforeThePickerOpens() throws {
        let chat = try self.source("Sources/App/ChatView.swift")
        XCTAssertTrue(chat.contains("self.photoTarget = self.store.attachmentDraftTarget\n                    self.showingPhotos = true"))
        XCTAssertTrue(chat.contains("self.importTarget = self.store.attachmentDraftTarget\n                    self.importing = true"))
        XCTAssertTrue(chat.contains("let target = self.photoTarget ?? self.store.attachmentDraftTarget"))
    }

    func testModelSheetUsesTheSessionKeyItWasOpenedWith() throws {
        let sheet = try self.source("Sources/App/SessionModelSettingsView.swift")
        XCTAssertTrue(sheet.contains("changeSessionModel(key: self.sessionKey, reference: reference, effort: effort)"))
        XCTAssertTrue(sheet.contains("loadModelChoices(for: self.sessionKey)"))
        XCTAssertFalse(sheet.contains("changeSessionModel(key: self.store.selectedSessionKey"))
    }
}
