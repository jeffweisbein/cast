import AVFoundation
import Foundation
#if os(iOS)
import UIKit
#endif

/// A finished, not-yet-sent voice capture sitting in the composer's preview state.
public struct VoiceRecording: Equatable, Sendable {
    public let url: URL
    public let duration: TimeInterval
    public let byteCount: Int

    public init(url: URL, duration: TimeInterval, byteCount: Int) {
        self.url = url
        self.duration = duration
        self.byteCount = byteCount
    }
}

public enum VoiceRecordingError: Error, LocalizedError, Sendable {
    case recorderStartFailed
    case nothingToAttach

    public var errorDescription: String? {
        switch self {
        case .recorderStartFailed: return "Voice recording could not start."
        case .nothingToAttach: return "There is no voice recording to attach."
        }
    }
}

/// Abstraction over AVAudioRecorder (permission, capture, metering) so the controller's
/// state machine is testable without a microphone. This is the only seam; the controller
/// owns every transition, file, and timer itself.
@MainActor
public protocol VoiceRecordingBackend: AnyObject {
    func requestPermission() async -> Bool
    func beginRecording(to url: URL) throws
    func stopRecording()
    var currentTime: TimeInterval { get }
    /// Latest metered input level normalized to 0...1.
    func normalizedPowerLevel() -> Float
}

/// Composer voice-message state machine: idle → requestingPermission → recording →
/// preview → (attached | discarded). Owns the temp file for the active capture and
/// guarantees it is deleted on every exit path except a successful attach.
@MainActor
public final class VoiceRecorderController: ObservableObject {
    public enum State: Equatable {
        case idle
        case requestingPermission
        case recording
        case preview(VoiceRecording)
    }

    private enum DeferredBackgroundOutcome {
        case preview(VoiceRecording)
        case discard
    }

    /// Hard ceiling so a forgotten recorder cannot grow an unbounded file. Five minutes of
    /// 32 kbps mono AAC is ~1.2 MB — far under the 16 MB attachment and 24 MB frame caps.
    public static let maximumDuration: TimeInterval = 300
    /// Below this the gesture was a tap, not a message; discard quietly.
    public static let minimumDuration: TimeInterval = 0.3
    /// How long before the ceiling the UI starts counting down. Showing a remaining-time
    /// figure for the whole five minutes reads as a deadline; showing it only at the end
    /// reads as a warning, which is what it is.
    public static let limitWarningThreshold: TimeInterval = 30
    public static let levelHistoryCount = 40
    public static let attachmentFileName = "Voice Message.m4a"
    public static let attachmentMIMEType = "audio/mp4"

    @Published public private(set) var state: State = .idle
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var levels: [Float] = []
    /// User-facing failure (denied mic permission, recorder start failure). The composer
    /// routes this into its existing error alert and then consumes it.
    @Published public private(set) var failureMessage: String?
    /// True when the capture now in preview was ended by the duration ceiling rather than
    /// by the user. The recording is intact either way; this only drives the explanation
    /// so an auto-stop never reads as a crash. Cleared on the next capture or discard.
    @Published public private(set) var stoppedAtLimit = false

    /// Seconds left before the ceiling ends the capture, while recording.
    public var remaining: TimeInterval {
        max(0, Self.maximumDuration - self.elapsed)
    }

    /// Whether the capture is close enough to the ceiling to warrant a countdown.
    public var isNearingLimit: Bool {
        self.state == .recording && self.remaining <= Self.limitWarningThreshold
    }

    private let backend: any VoiceRecordingBackend
    private var meterTask: Task<Void, Never>?
    private var activeURL: URL?
    private var deferredBackgroundOutcome: DeferredBackgroundOutcome?
    private var observers: [any NSObjectProtocol] = []

    public var isCapturing: Bool {
        self.state == .recording || self.state == .requestingPermission
    }

    public init(backend: (any VoiceRecordingBackend)? = nil) {
        self.backend = backend ?? SystemVoiceRecordingBackend()
        #if os(iOS)
        // A phone call/Siri may publish a preview immediately. Backgrounding is different:
        // stop the audio session synchronously but defer the published UI transition until
        // the app is active again, avoiding UIKit/SwiftUI work inside the suspension window.
        let center = NotificationCenter.default
        self.observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main)
        { [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init)
            guard type == .began else { return }
            Task { @MainActor in self?.finishRecordingIfActive() }
        })
        self.observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated { self?.finishRecordingForBackground() }
        })
        self.observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated { self?.publishDeferredBackgroundPreview() }
        })
        #endif
    }

    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func clearFailureMessage() {
        self.failureMessage = nil
    }

    public func beginRecording() async {
        guard self.state == .idle else { return }
        self.deferredBackgroundOutcome = nil
        self.failureMessage = nil
        self.stoppedAtLimit = false
        self.state = .requestingPermission
        let granted = await self.backend.requestPermission()
        // Released mid-prompt (finishRecording/cancel already reset to idle): stay idle.
        guard self.state == .requestingPermission else { return }
        guard granted else {
            self.state = .idle
            self.failureMessage = Self.permissionDeniedMessage
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cast-voice-\(UUID().uuidString).m4a")
        do {
            try self.backend.beginRecording(to: url)
        } catch {
            self.state = .idle
            self.failureMessage = VoiceRecordingError.recorderStartFailed.localizedDescription
            return
        }
        self.activeURL = url
        self.elapsed = 0
        self.levels = Array(repeating: 0, count: Self.levelHistoryCount)
        self.state = .recording
        CastLifecycleDiagnostics.recorderTransition("recording")
        self.startMetering()
    }

    /// Ends the hold gesture: recording becomes a scrubable preview, an unanswered
    /// permission prompt becomes a no-op, and a too-short capture is discarded.
    public func finishRecording(dueToLimit: Bool = false) {
        switch self.state {
        case .requestingPermission:
            self.state = .idle
        case .recording:
            self.stoppedAtLimit = dueToLimit
            self.stopMetering()
            let duration = max(self.elapsed, self.backend.currentTime)
            self.backend.stopRecording()
            CastLifecycleDiagnostics.recorderTransition("stopped")
            guard let url = self.activeURL else {
                self.state = .idle
                return
            }
            self.activeURL = nil
            let byteCount = Self.fileSize(at: url)
            guard duration >= Self.minimumDuration, byteCount > 0 else {
                try? FileManager.default.removeItem(at: url)
                self.stoppedAtLimit = false
                self.state = .idle
                return
            }
            self.state = .preview(VoiceRecording(url: url, duration: duration, byteCount: byteCount))
        case .idle, .preview:
            break
        }
    }

    /// Discards whatever is active — an in-flight recording, an unanswered permission
    /// prompt, or a preview — and deletes its file.
    public func cancel() {
        self.stopMetering()
        if self.state == .recording, self.activeURL != nil {
            self.backend.stopRecording()
        }
        if let url = self.activeURL {
            try? FileManager.default.removeItem(at: url)
            self.activeURL = nil
        }
        if case let .preview(recording) = self.state {
            try? FileManager.default.removeItem(at: recording.url)
        }
        if case let .preview(recording) = self.deferredBackgroundOutcome {
            try? FileManager.default.removeItem(at: recording.url)
        }
        self.deferredBackgroundOutcome = nil
        self.stoppedAtLimit = false
        self.state = .idle
        self.elapsed = 0
        CastLifecycleDiagnostics.recorderTransition("cancelled")
    }

    /// Converts the preview into a `PreparedAttachment` on the same wire shape images use
    /// and removes the temp file. The store's `validateFrame` still runs at send time.
    public func makeAttachment() throws -> PreparedAttachment {
        guard case let .preview(recording) = self.state else {
            throw VoiceRecordingError.nothingToAttach
        }
        let data = try Data(contentsOf: recording.url)
        guard data.count <= AttachmentProcessor.maxFileBytes else {
            try? FileManager.default.removeItem(at: recording.url)
            self.state = .idle
            throw AttachmentError.fileTooLarge(data.count)
        }
        try? FileManager.default.removeItem(at: recording.url)
        self.stoppedAtLimit = false
        self.state = .idle
        self.elapsed = 0
        return PreparedAttachment(
            type: "audio",
            mimeType: Self.attachmentMIMEType,
            fileName: Self.attachmentFileName,
            data: data)
    }

    private func finishRecordingIfActive() {
        guard self.isCapturing else { return }
        self.finishRecording()
    }

    func finishRecordingForBackground() {
        switch self.state {
        case .requestingPermission:
            self.state = .idle
        case .recording:
            guard let url = self.activeURL else { return }
            self.activeURL = nil
            self.stopMetering()
            let duration = max(self.elapsed, self.backend.currentTime)
            self.backend.stopRecording()
            let byteCount = Self.fileSize(at: url)
            if duration >= Self.minimumDuration, byteCount > 0 {
                self.deferredBackgroundOutcome = .preview(VoiceRecording(
                    url: url,
                    duration: duration,
                    byteCount: byteCount))
            } else {
                try? FileManager.default.removeItem(at: url)
                self.deferredBackgroundOutcome = .discard
            }
            CastLifecycleDiagnostics.recorderStoppedForBackground()
        case .idle, .preview:
            break
        }
    }

    func publishDeferredBackgroundPreview() {
        guard let outcome = self.deferredBackgroundOutcome else { return }
        self.deferredBackgroundOutcome = nil
        switch outcome {
        case let .preview(recording): self.state = .preview(recording)
        case .discard:
            self.state = .idle
            self.elapsed = 0
        }
    }

    private func startMetering() {
        self.meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, !Task.isCancelled, self.state == .recording else { return }
                self.elapsed = self.backend.currentTime
                var levels = self.levels
                if !levels.isEmpty { levels.removeFirst() }
                levels.append(self.backend.normalizedPowerLevel())
                self.levels = levels
                if self.elapsed >= Self.maximumDuration {
                    self.finishRecording(dueToLimit: true)
                    return
                }
            }
        }
    }

    private func stopMetering() {
        self.meterTask?.cancel()
        self.meterTask = nil
    }

    private static func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    static var permissionDeniedMessage: String {
        #if os(iOS)
        return "Cast can't access the microphone. Allow it in Settings > Privacy & Security > Microphone."
        #else
        return "Cast can't access the microphone. Allow it in System Settings > Privacy & Security > Microphone."
        #endif
    }
}

/// AVAudioRecorder-backed capture: mono 32 kbps AAC in an .m4a container, which the
/// gateway maps to audio/mp4. Speech quality is fine and five minutes stays around 1 MB.
@MainActor
public final class SystemVoiceRecordingBackend: VoiceRecordingBackend {
    private var recorder: AVAudioRecorder?

    public init() {}

    public func requestPermission() async -> Bool {
        #if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        @unknown default: return false
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default: return false
        }
        #endif
    }

    public func beginRecording(to url: URL) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        #endif
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw VoiceRecordingError.recorderStartFailed
        }
        self.recorder = recorder
    }

    public func stopRecording() {
        self.recorder?.stop()
        self.recorder = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    public var currentTime: TimeInterval {
        self.recorder?.currentTime ?? 0
    }

    public func normalizedPowerLevel() -> Float {
        guard let recorder = self.recorder else { return 0 }
        recorder.updateMeters()
        // Map the useful speech range (-50 dB...0 dB) linearly onto 0...1 so the meter
        // reads as alive at conversational volume instead of hugging the floor.
        let floorDb: Float = -50
        let db = max(floorDb, min(0, recorder.averagePower(forChannel: 0)))
        return (db - floorDb) / -floorDb
    }
}
