import Foundation
import XCTest
@testable import Cast

@MainActor
private final class FakeVoiceBackend: VoiceRecordingBackend {
    var permissionGranted = true
    var permissionDelayNanoseconds: UInt64 = 0
    var permissionRequests = 0
    var startError: Error?
    var recordedURL: URL?
    var stopCount = 0
    var currentTime: TimeInterval = 0
    var level: Float = 0.5
    var payload = Data("fake-aac-bytes".utf8)

    func requestPermission() async -> Bool {
        self.permissionRequests += 1
        if self.permissionDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: self.permissionDelayNanoseconds)
        }
        return self.permissionGranted
    }

    func beginRecording(to url: URL) throws {
        if let startError = self.startError { throw startError }
        try self.payload.write(to: url)
        self.recordedURL = url
    }

    func stopRecording() {
        self.stopCount += 1
    }

    func normalizedPowerLevel() -> Float {
        self.level
    }
}

final class VoiceRecorderTests: XCTestCase {
    @MainActor
    func testRecordFinishPreviewAndAttachmentConstruction() async throws {
        let backend = FakeVoiceBackend()
        let controller = VoiceRecorderController(backend: backend)

        await controller.beginRecording()
        XCTAssertEqual(controller.state, .recording)
        let url = try XCTUnwrap(backend.recordedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // A second begin while already recording is a no-op, not a second file.
        await controller.beginRecording()
        XCTAssertEqual(backend.permissionRequests, 1)

        backend.currentTime = 2.4
        controller.finishRecording()
        guard case let .preview(recording) = controller.state else {
            return XCTFail("Expected preview state, got \(controller.state)")
        }
        XCTAssertEqual(recording.url, url)
        XCTAssertEqual(recording.duration, 2.4, accuracy: 0.01)
        XCTAssertEqual(recording.byteCount, backend.payload.count)
        XCTAssertEqual(backend.stopCount, 1)

        let attachment = try controller.makeAttachment()
        XCTAssertEqual(attachment.type, "audio")
        XCTAssertEqual(attachment.mimeType, "audio/mp4")
        XCTAssertTrue(attachment.fileName.hasSuffix(".m4a"))
        XCTAssertEqual(attachment.data, backend.payload)
        XCTAssertEqual(controller.state, .idle)
        // Attaching hands the bytes over and removes the temp file.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        XCTAssertNoThrow(try AttachmentProcessor.validateFrame(message: "", attachments: [attachment]))
    }

    @MainActor
    func testDeniedPermissionFailsGracefullyWithoutRecording() async {
        let backend = FakeVoiceBackend()
        backend.permissionGranted = false
        let controller = VoiceRecorderController(backend: backend)

        await controller.beginRecording()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNotNil(controller.failureMessage)
        XCTAssertNil(backend.recordedURL)
    }

    @MainActor
    func testCancelWhileRecordingStopsBackendAndDeletesFile() async throws {
        let backend = FakeVoiceBackend()
        let controller = VoiceRecorderController(backend: backend)

        await controller.beginRecording()
        backend.currentTime = 3
        let url = try XCTUnwrap(backend.recordedURL)
        controller.cancel()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testDiscardingPreviewDeletesFile() async throws {
        let backend = FakeVoiceBackend()
        let controller = VoiceRecorderController(backend: backend)

        await controller.beginRecording()
        backend.currentTime = 1.5
        controller.finishRecording()
        let url = try XCTUnwrap(backend.recordedURL)
        guard case .preview = controller.state else {
            return XCTFail("Expected preview state, got \(controller.state)")
        }

        controller.cancel()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testTooShortRecordingIsDiscardedQuietly() async throws {
        let backend = FakeVoiceBackend()
        let controller = VoiceRecorderController(backend: backend)

        await controller.beginRecording()
        backend.currentTime = 0.1
        controller.finishRecording()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.failureMessage)
        let url = try XCTUnwrap(backend.recordedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testReleasingDuringPermissionPromptNeverStartsRecording() async throws {
        let backend = FakeVoiceBackend()
        backend.permissionDelayNanoseconds = 100_000_000
        let controller = VoiceRecorderController(backend: backend)

        let begin = Task { await controller.beginRecording() }
        // Let beginRecording reach the suspended permission request.
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(controller.state, .requestingPermission)

        controller.finishRecording()
        XCTAssertEqual(controller.state, .idle)

        await begin.value
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(backend.recordedURL)
    }

    @MainActor
    func testAutoStopAtMaximumDurationEndsInPreview() async throws {
        let backend = FakeVoiceBackend()
        let controller = VoiceRecorderController(backend: backend)

        await controller.beginRecording()
        backend.currentTime = VoiceRecorderController.maximumDuration + 5

        // The metering loop polls every 50 ms; give it a bounded window to trip the cap.
        for _ in 0..<40 {
            if case .preview = controller.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case let .preview(recording) = controller.state else {
            return XCTFail("Recorder did not auto-stop at the duration cap")
        }
        XCTAssertGreaterThanOrEqual(recording.duration, VoiceRecorderController.maximumDuration)
        XCTAssertEqual(backend.stopCount, 1)
        // The cap stop must be attributable, otherwise the UI cannot explain it and the
        // capture just appears to end on its own.
        XCTAssertTrue(controller.stoppedAtLimit)
        try? FileManager.default.removeItem(at: recording.url)
    }

    @MainActor
    func testManualFinishIsNotAttributedToTheDurationLimit() async throws {
        let backend = FakeVoiceBackend()
        let controller = VoiceRecorderController(backend: backend)

        await controller.beginRecording()
        backend.currentTime = 2
        controller.finishRecording()

        guard case let .preview(recording) = controller.state else {
            return XCTFail("Expected a preview after a manual stop")
        }
        XCTAssertFalse(controller.stoppedAtLimit)
        try? FileManager.default.removeItem(at: recording.url)
    }

    @MainActor
    func testLimitAttributionClearsOnTheNextRecording() async throws {
        let backend = FakeVoiceBackend()
        let controller = VoiceRecorderController(backend: backend)

        await controller.beginRecording()
        backend.currentTime = VoiceRecorderController.maximumDuration + 5
        for _ in 0..<40 {
            if case .preview = controller.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(controller.stoppedAtLimit)
        if case let .preview(recording) = controller.state {
            try? FileManager.default.removeItem(at: recording.url)
        }

        // Discarding and recording again must not carry the previous notice forward.
        controller.cancel()
        XCTAssertFalse(controller.stoppedAtLimit)
    }

    @MainActor
    func testCountdownOnlyEngagesNearTheCeiling() async throws {
        let backend = FakeVoiceBackend()
        let controller = VoiceRecorderController(backend: backend)

        await controller.beginRecording()
        XCTAssertFalse(controller.isNearingLimit, "Countdown must stay hidden at the start")

        let nearly = VoiceRecorderController.maximumDuration
            - VoiceRecorderController.limitWarningThreshold + 1
        backend.currentTime = nearly
        for _ in 0..<40 {
            if controller.isNearingLimit { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(controller.isNearingLimit)
        XCTAssertLessThanOrEqual(
            controller.remaining,
            VoiceRecorderController.limitWarningThreshold)

        controller.cancel()
    }

    @MainActor
    func testSecondMakeAttachmentThrowsNothingToAttach() async throws {
        let backend = FakeVoiceBackend()
        let controller = VoiceRecorderController(backend: backend)

        await controller.beginRecording()
        backend.currentTime = 2
        controller.finishRecording()
        _ = try controller.makeAttachment()

        // The composer's Send action can fire twice on a rapid double-tap; the second
        // call must fail with a recognizable error rather than produce a duplicate.
        XCTAssertThrowsError(try controller.makeAttachment()) { error in
            guard case VoiceRecordingError.nothingToAttach = error else {
                return XCTFail("Expected nothingToAttach, got \(error)")
            }
        }
        XCTAssertEqual(controller.state, .idle)
    }

    @MainActor
    func testCancelDuringPermissionPromptNeverStartsRecording() async throws {
        let backend = FakeVoiceBackend()
        backend.permissionDelayNanoseconds = 100_000_000
        let controller = VoiceRecorderController(backend: backend)

        let begin = Task { await controller.beginRecording() }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(controller.state, .requestingPermission)

        controller.cancel()
        XCTAssertEqual(controller.state, .idle)

        await begin.value
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(backend.recordedURL)
    }

    @MainActor
    func testOversizedRecordingFailsAttachAndResets() async throws {
        let backend = FakeVoiceBackend()
        backend.payload = Data(count: AttachmentProcessor.maxFileBytes + 1)
        let controller = VoiceRecorderController(backend: backend)

        await controller.beginRecording()
        backend.currentTime = 5
        controller.finishRecording()
        let url = try XCTUnwrap(backend.recordedURL)
        guard case .preview = controller.state else {
            return XCTFail("Expected preview state, got \(controller.state)")
        }

        XCTAssertThrowsError(try controller.makeAttachment()) { error in
            guard case AttachmentError.fileTooLarge = error else {
                return XCTFail("Expected fileTooLarge, got \(error)")
            }
        }
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFrameValidationRoutesOversizedAudioThroughStaging() {
        let oversized = PreparedAttachment(
            type: "audio",
            mimeType: "audio/mp4",
            fileName: "Voice Message.m4a",
            data: Data(count: AttachmentProcessor.maxFrameBytes))
        XCTAssertTrue(try AttachmentProcessor.requiresUpload(message: "", attachments: [oversized]))
        XCTAssertNoThrow(try AttachmentProcessor.validateFrame(message: "", attachments: [oversized]))

        let reasonable = PreparedAttachment(
            type: "audio",
            mimeType: "audio/mp4",
            fileName: "Voice Message.m4a",
            data: Data(count: 1_200_000))
        XCTAssertNoThrow(
            try AttachmentProcessor.validateFrame(message: "caption", attachments: [reasonable]))
    }

    @MainActor
    func testBackgroundStopIsIdempotentAndDefersPreviewUntilActive() async throws {
        let backend = FakeVoiceBackend()
        let controller = VoiceRecorderController(backend: backend)
        await controller.beginRecording()
        backend.currentTime = 2
        controller.finishRecordingForBackground()
        controller.finishRecordingForBackground()
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(controller.state, .recording, "preview publication must wait for activation")

        controller.publishDeferredBackgroundPreview()
        if case let .preview(recording) = controller.state {
            try? FileManager.default.removeItem(at: recording.url)
        } else {
            XCTFail("Expected the deferred preview after activation")
        }
    }

    @MainActor
    func testShortBackgroundRecordingReturnsToIdleOnActivation() async throws {
        let backend = FakeVoiceBackend()
        let controller = VoiceRecorderController(backend: backend)
        await controller.beginRecording()
        backend.currentTime = 0.1

        controller.finishRecordingForBackground()
        controller.publishDeferredBackgroundPreview()

        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(controller.state, .idle)
        let url = try XCTUnwrap(backend.recordedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
