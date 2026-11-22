import Foundation
import XCTest
@testable import Cast

/// Regressions for the rev100 combined review: import results must settle the tile that
/// started them (even after a chat switch), sending must wait for preparing imports, and the
/// model sheet must never propose or perform a reasoning reset by itself.
@MainActor
final class ComposerImportDeliveryTests: XCTestCase {
    private final class Counts {
        var delivered = 0
        var discarded = 0
    }

    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    private func file(_ name: String = "a.txt") -> PreparedAttachment {
        PreparedAttachment(type: "file", mimeType: "text/plain", fileName: name, data: Data("x".utf8))
    }

    private func settle(until done: @MainActor () -> Bool) async {
        for _ in 0 ..< 400 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testDeliveryAfterSwitchLandsInOriginalDraftOnly() {
        let store = ChatStore(transcriptCacheRoot: self.root(), operationsLedgerRoot: self.root())
        store.selectedSessionKey = "a"
        let targetA = store.attachmentDraftTarget
        store.selectedSessionKey = "b"
        let outcome = store.deliverPreparedAttachments([self.file()], target: targetA)
        XCTAssertEqual(outcome, .accepted)
        XCTAssertTrue(store.pendingAttachments.isEmpty, "The chat on screen must not receive another chat's file")
        store.selectedSessionKey = "a"
        XCTAssertEqual(store.pendingAttachments.map(\.fileName), ["a.txt"])
    }

    func testRejectedBatchIsReportedToCallerNotSilentlyDroppedOrGlobal() {
        let store = ChatStore(transcriptCacheRoot: self.root(), operationsLedgerRoot: self.root())
        store.selectedSessionKey = "a"
        let targetA = store.attachmentDraftTarget
        store.addAttachments((0 ..< AttachmentLimits.maxFiles).map { self.file("f\($0).txt") })
        store.selectedSessionKey = "b"
        let outcome = store.deliverPreparedAttachments([self.file("extra.txt")], target: targetA)
        guard case let .rejected(message) = outcome else { return XCTFail("Over-limit batch must be rejected, got \(outcome)") }
        XCTAssertEqual(message, AttachmentLimits.LimitError.count.errorDescription)
        XCTAssertNil(store.lastError, "The caller's tile reports the rejection; no unrelated global alert")
        store.selectedSessionKey = "a"
        XCTAssertEqual(store.pendingAttachments.count, AttachmentLimits.maxFiles, "The existing draft is untouched")
    }

    func testBatchIsAllOrNothing() {
        let store = ChatStore(transcriptCacheRoot: self.root(), operationsLedgerRoot: self.root())
        store.selectedSessionKey = "a"
        store.addAttachments((0 ..< AttachmentLimits.maxFiles - 1).map { self.file("f\($0).txt") })
        let outcome = store.deliverPreparedAttachments([self.file("x1"), self.file("x2")], target: store.attachmentDraftTarget)
        XCTAssertNotEqual(outcome, .accepted)
        XCTAssertEqual(store.pendingAttachments.count, AttachmentLimits.maxFiles - 1)
    }

    func testUnselectedTargetIsDiscardedOnceAChatIsOpen() {
        let store = ChatStore(transcriptCacheRoot: self.root(), operationsLedgerRoot: self.root())
        let unselected = store.attachmentDraftTarget
        store.selectedSessionKey = "a"
        let outcome = store.deliverPreparedAttachments([self.file()], target: unselected)
        XCTAssertEqual(outcome, .discarded)
        XCTAssertNotNil(outcome.failureMessage)
        XCTAssertTrue(store.pendingAttachments.isEmpty)
    }

    func testLegacyFinishPreparationKeepsItsSelectedChatAlert() {
        let store = ChatStore(transcriptCacheRoot: self.root(), operationsLedgerRoot: self.root())
        store.selectedSessionKey = "a"
        store.addAttachments((0 ..< AttachmentLimits.maxFiles).map { self.file("f\($0).txt") })
        let outcome = store.finishAttachmentPreparation(.success(self.file("extra")), target: store.attachmentDraftTarget)
        XCTAssertNotEqual(outcome, .accepted)
        XCTAssertNotNil(store.lastError, "Existing callers keep their visible error")
    }

    func testRejectedDeliveryKeepsTileWithReason() async {
        let queue = ComposerImportQueue()
        let target = ChatStore.AttachmentDraftTarget(workspaceID: "w", gatewayURL: URL(string: "wss://example.invalid")!, sessionKey: "a")
        let attachment = self.file()
        let id = queue.enqueue(
            title: "a.txt", symbol: "doc", target: target,
            work: { attachment },
            deliver: { (_: PreparedAttachment) -> ChatStore.AttachmentDeliveryOutcome in .rejected("Attach up to 20 files per message.") })
        await self.settle { !queue.isPreparing(id) }
        XCTAssertEqual(queue.items.first?.phase, .failed("Attach up to 20 files per message."))
        XCTAssertFalse(queue.hasPreparing(for: target))
    }

    func testDiscardedDeliveryKeepsTileWithReason() async {
        let queue = ComposerImportQueue()
        let target = ChatStore.AttachmentDraftTarget(workspaceID: "w", gatewayURL: URL(string: "wss://example.invalid")!, sessionKey: "a")
        let attachment = self.file()
        let id = queue.enqueue(
            title: "a.txt", symbol: "doc", target: target,
            work: { attachment },
            deliver: { (_: PreparedAttachment) -> ChatStore.AttachmentDeliveryOutcome in .discarded })
        await self.settle { !queue.isPreparing(id) }
        if case .failed = queue.items.first?.phase {} else { XCTFail("Discarded delivery must stay visible") }
    }

    func testCancelledImportNeverReachesDelivery() async {
        let queue = ComposerImportQueue()
        let target = ChatStore.AttachmentDraftTarget(workspaceID: "w", gatewayURL: URL(string: "wss://example.invalid")!, sessionKey: "a")
        let attachment = self.file()
        let counts = Counts()
        let id = queue.enqueue(
            title: "slow", symbol: "doc", target: target,
            work: { try? await Task.sleep(for: .milliseconds(40)); return attachment },
            deliver: { (_: PreparedAttachment) -> ChatStore.AttachmentDeliveryOutcome in counts.delivered += 1; return .accepted },
            discard: { _ in counts.discarded += 1 })
        XCTAssertTrue(queue.hasPreparing(for: target))
        queue.cancel(id)
        await self.settle { counts.discarded > 0 }
        XCTAssertEqual(counts.delivered, 0)
        XCTAssertEqual(counts.discarded, 1)
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testSendGateIsScopedToTheDraftWithPreparingImports() {
        let queue = ComposerImportQueue()
        let a = ChatStore.AttachmentDraftTarget(workspaceID: "w", gatewayURL: URL(string: "wss://example.invalid")!, sessionKey: "a")
        let b = ChatStore.AttachmentDraftTarget(workspaceID: "w", gatewayURL: URL(string: "wss://example.invalid")!, sessionKey: "b")
        let first = queue.begin(title: "one", symbol: "doc", target: a)
        _ = queue.begin(title: "two", symbol: "doc", target: a)
        queue.report("No image", title: "Paste", symbol: "doc", target: a)
        XCTAssertTrue(queue.hasPreparing(for: a))
        XCTAssertEqual(queue.preparingCount(for: a), 2, "Failed tiles do not hold Send")
        XCTAssertFalse(queue.hasPreparing(for: b), "Another chat's import never blocks this chat")
        queue.fail(first, message: "x")
        XCTAssertEqual(queue.preparingCount(for: a), 1)
        XCTAssertTrue(ComposerSendGate.waitingLabel(count: 1).contains("1 attachment"))
        XCTAssertTrue(ComposerSendGate.waitingLabel(count: 2).contains("2 attachments"))
    }
}

/// Opening the sheet proposes nothing; only deliberate choices change reasoning.
final class SessionModelReasoningPreservationTests: XCTestCase {
    private let levels = [ThinkingOption(id: "low", label: "Low"), ThinkingOption(id: "high", label: "High")]

    private func choice(_ id: String, levels: [ThinkingOption]? = nil) -> GatewayModelChoice {
        GatewayModelChoice(id: id, name: id.uppercased(), provider: "openai", available: true,
                           thinkingLevels: levels, thinkingDefault: nil)
    }

    func testOverrideNotListedByCatalogDoesNotEnableApplyOnOpen() {
        // The catalog reports no levels for the current model, but the gateway reports an override.
        let astra = self.choice("astra")
        let state = SessionModelSheetState(
            sessionModel: "astra", sessionProvider: "openai", thinkingOverride: "xhigh",
            choices: [astra], selectedReference: astra.reference,
            selectedEffort: SessionModelSheetState.initialEffort(override: "xhigh"))
        XCTAssertEqual(state.selectedEffort, "xhigh", "The raw override is the starting point")
        XCTAssertFalse(state.hasChanges)
        XCTAssertEqual(state.applyBlocker, "Already set for this conversation.")
        XCTAssertFalse(state.canApply, "Apply must not be offered just because the sheet opened")
        XCTAssertTrue(state.reasoningUnavailableNote?.contains("left as it is") == true)
    }

    func testOverrideMissingFromListedLevelsAlsoStaysUntouchedOnOpen() {
        let astra = self.choice("astra", levels: self.levels)
        let state = SessionModelSheetState(
            sessionModel: "astra", sessionProvider: "openai", thinkingOverride: "max",
            choices: [astra], selectedReference: astra.reference,
            selectedEffort: SessionModelSheetState.initialEffort(override: "max"))
        XCTAssertFalse(state.canApply)
        XCTAssertEqual(state.applyBlocker, "Already set for this conversation.")
    }

    func testModelOnlyChangeKeepsOverrideWhenDestinationSupportIsUnknown() {
        let astra = self.choice("astra"), nova = self.choice("nova")
        var state = SessionModelSheetState(
            sessionModel: "astra", sessionProvider: "openai", thinkingOverride: "xhigh",
            choices: [astra, nova], selectedReference: astra.reference, selectedEffort: "xhigh")
        state.selectedReference = nova.reference
        state.selectedEffort = SessionModelSheetState.effortAfterSelecting(nova, currentEffort: "xhigh", override: "xhigh")
        XCTAssertEqual(state.selectedEffort, "xhigh")
        XCTAssertNil(state.applyBlocker, "A model change is allowed and keeps the override")
        XCTAssertNil(state.overrideResetNote)
        XCTAssertFalse(SessionModelMutation.needsThinkingCommand(effort: "xhigh", currentOverride: "xhigh"),
                       "An unchanged override sends no /think command, so nothing is reset")
    }

    func testDestinationWithoutTheLevelSaysItWillUseTheDefault() {
        let astra = self.choice("astra"), nova = self.choice("nova", levels: self.levels)
        var state = SessionModelSheetState(
            sessionModel: "astra", sessionProvider: "openai", thinkingOverride: "xhigh",
            choices: [astra, nova], selectedReference: astra.reference, selectedEffort: "xhigh")
        state.selectedReference = nova.reference
        state.selectedEffort = SessionModelSheetState.effortAfterSelecting(nova, currentEffort: "xhigh", override: "xhigh")
        XCTAssertEqual(state.selectedEffort, "")
        XCTAssertTrue(state.overrideResetNote?.contains("model default") == true, "The reset is stated before Apply")
        XCTAssertNil(state.applyBlocker)
    }

    func testReturningToOriginalModelRestoresItsOverrideWithoutAChange() {
        let original = self.choice("astra"), other = self.choice("nova", levels: self.levels)
        let away = SessionModelSheetState.effortAfterSelecting(
            other, currentEffort: "xhigh", override: "xhigh", currentModelReference: original.reference)
        XCTAssertEqual(away, "")
        let restored = SessionModelSheetState.effortAfterSelecting(
            original, currentEffort: away, override: "xhigh", currentModelReference: original.reference)
        let state = SessionModelSheetState(
            sessionModel: "astra", sessionProvider: "openai", thinkingOverride: "xhigh",
            choices: [original, other], selectedReference: original.reference, selectedEffort: restored)
        XCTAssertEqual(restored, "xhigh")
        XCTAssertFalse(state.hasChanges)
        XCTAssertFalse(state.canApply)
        XCTAssertFalse(SessionModelMutation.needsThinkingCommand(effort: restored, currentOverride: "xhigh"))
    }

    func testSupportedLevelsCarryAndDeliberateChoicesApply() {
        let astra = self.choice("astra", levels: self.levels), nova = self.choice("nova", levels: self.levels)
        XCTAssertEqual(SessionModelSheetState.effortAfterSelecting(nova, currentEffort: "high", override: "high"), "high")
        XCTAssertEqual(SessionModelSheetState.effortAfterSelecting(nova, currentEffort: "", override: "high"), "")
        XCTAssertEqual(SessionModelSheetState.effortAfterSelecting(nil, currentEffort: "high", override: "high"), "")
        // A level the operator picked (not the reported override) is never smuggled to a model without it.
        XCTAssertEqual(SessionModelSheetState.effortAfterSelecting(self.choice("plain"), currentEffort: "low", override: "high"), "")

        var state = SessionModelSheetState(
            sessionModel: "astra", sessionProvider: "openai", thinkingOverride: "high",
            choices: [astra], selectedReference: astra.reference, selectedEffort: "high")
        state.selectedEffort = "low"
        XCTAssertTrue(state.canApply)
        state.selectedEffort = ""
        XCTAssertTrue(state.canApply, "Returning to the default is a deliberate change")
        XCTAssertTrue(SessionModelMutation.needsThinkingCommand(effort: nil, currentOverride: "high"))
        XCTAssertTrue(SessionModelMutation.needsThinkingCommand(effort: "low", currentOverride: "high"))
    }

    func testInitialEffortTrimsButNeverInvents() {
        XCTAssertEqual(SessionModelSheetState.initialEffort(override: nil), "")
        XCTAssertEqual(SessionModelSheetState.initialEffort(override: " high "), "high")
    }
}

/// The suite is macOS-hosted, so these source guards pin the iOS send gate and hit targets.
final class IOSComposerReviewGuardTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testEverySendPathWaitsForPreparingImports() throws {
        let chat = try self.source("Sources/App/ChatView.swift")
        XCTAssertTrue(chat.contains("guard self.allowsSending, self.dictation.phase == .idle, !self.waitingForImports else { return }"),
                      "Button, Return and shortcuts all go through sendDraft")
        XCTAssertTrue(chat.contains("!self.allowsSending || self.dictation.phase != .idle || self.waitingForImports"))
        let voice = try XCTUnwrap(chat.range(of: "private func sendVoiceMessage()"))
        XCTAssertTrue(chat[voice.upperBound...].prefix(300).contains("guard !self.waitingForImports"))
        XCTAssertTrue(chat.contains(".accessibilityHint(self.waitingForImports ? ComposerSendGate.waitingMessage"))
        XCTAssertFalse(chat.contains("store.finishAttachmentPreparation(.success($0), target: target)"),
                       "Composer imports must settle their tile from the delivery outcome")
    }

    func testComposerHitTargetsMeetMinimum() throws {
        XCTAssertGreaterThanOrEqual(ComposerSendGate.minimumHitTarget, 44)
        let chat = try self.source("Sources/App/ChatView.swift")
        XCTAssertGreaterThanOrEqual(chat.components(separatedBy: "ComposerSendGate.minimumHitTarget").count - 1, 4, "+ and send")
        let tray = try self.source("Sources/App/ComposerAttachmentTray.swift")
        XCTAssertFalse(tray.contains(".frame(height: ComposerAttachmentTray.tileSide)"), "Tiles grow with Dynamic Type")
        XCTAssertFalse(tray.contains("width: 32, height: 32"))
        XCTAssertGreaterThanOrEqual(tray.components(separatedBy: "ComposerSendGate.minimumHitTarget").count - 1, 2)
        let chip = try self.source("Sources/App/ComposerModelControls.swift")
        XCTAssertTrue(chip.contains(".frame(minHeight: ComposerSendGate.minimumHitTarget)"))
        let sheet = try self.source("Sources/App/SessionModelSettingsView.swift")
        XCTAssertTrue(sheet.contains(".frame(minHeight: ComposerSendGate.minimumHitTarget)"))
        XCTAssertTrue(sheet.contains("SessionModelSheetState.initialEffort(override:"))
        XCTAssertFalse(sheet.contains("carriedEffort(self.session?.modelInfo?.thinkingLevel"))
    }
}
