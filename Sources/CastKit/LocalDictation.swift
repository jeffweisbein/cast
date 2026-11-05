import AVFoundation
import Combine
import Foundation
import Speech

struct DictationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Final-only insertion is deliberate: partial recognition must never overwrite an edited draft.
enum DictationDraft {
    static let defaultCorrections = "run pr=RunPR\nopen claw=OpenClaw\ncackles=Cackles"
    static func corrected(_ text: String, rules: String) -> String {
        var result = text
        for line in rules.split(separator: "\n").prefix(100) {
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty,
                  let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: pair[0]) + "(?![\\p{L}\\p{N}_])", options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: NSRegularExpression.escapedTemplate(for: pair[1]))
        }
        return result
    }
    static func inserting(_ transcript: String, into draft: String) -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return draft }
        return draft + (draft.isEmpty || draft.last?.isWhitespace == true ? "" : " ") + text
    }
}

struct DictationOutput: Equatable { let text: String; let conversation: String }

@MainActor
final class LocalDictation: ObservableObject {
    enum Phase: Equatable { case idle, preparing, recording, transcribing }
    @Published private(set) var phase: Phase = .idle
    @Published var status = ""
    @Published var failure: String?
    @Published var output: DictationOutput?
    private var conversation = ""
    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var work: Task<Void, Never>?
    private var limit: Task<Void, Never>?
    private var generation = UUID()
    #if os(macOS)
    private var hex: HexService?
    #else
    private var recognition: SFSpeechRecognitionTask?
    private var recognitionContinuation: CheckedContinuation<String, Error>?
    private var recognitionDeadline: Task<Void, Never>?
    #endif

    func start(context: String) {
        guard phase == .idle else { return }
        generation = UUID()
        let operation = generation
        failure = nil
        output = nil
        conversation = context
        phase = .preparing
        status = "Preparing local dictation…"
        work = Task {
            do {
                #if os(macOS)
                let hex = HexService()
                self.hex = hex
                try await hex.start()
                let models = try await hex.models()
                guard models.contains(where: { $0.id == HexService.model && $0.installed && $0.verified }) else {
                    throw DictationFailure(message: "Download the dictation model first using Dictation Setup.")
                }
                try await hex.prepare { [weak self] in self?.status = $0 }
                #else
                let auth = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                }
                guard auth == .authorized else { throw DictationFailure(message: "Allow Speech Recognition for Cast in Settings.") }
                guard SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.supportsOnDeviceRecognition == true else {
                    throw DictationFailure(message: "On-device English speech recognition is unavailable on this device. Cast will not send audio to a cloud recognizer.")
                }
                #endif
                let allowed = await SystemVoiceRecordingBackend().requestPermission()
                try Task.checkCancellation()
                guard operation == generation else { return }
                guard allowed else { throw DictationFailure(message: VoiceRecorderController.permissionDeniedMessage) }
                #if os(iOS)
                try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
                try AVAudioSession.sharedInstance().setActive(true)
                #endif
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("cast-dictation-\(UUID()).wav")
                audioURL = url
                let capture = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                ])
                guard capture.record() else { throw DictationFailure(message: "The microphone could not start.") }
                recorder = capture
                phase = .recording
                status = "Listening · audio stays on this device"
                limit = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled else { return }
                    self?.finish()
                }
            } catch {
                guard operation == generation else { return }
                cancel()
                failure = error.localizedDescription
            }
        }
    }

    func finish() {
        guard phase == .recording, let url = audioURL else { return }
        recorder?.stop()
        recorder = nil
        limit?.cancel()
        phase = .transcribing
        status = "Transcribing on this device…"
        let operation = generation
        let owner = conversation
        work = Task {
            do {
                #if os(macOS)
                guard let hex else { throw DictationFailure(message: "Hex is no longer running.") }
                let text = try await hex.transcribe(Data(contentsOf: url))
                #else
                let text = try await recognize(url)
                #endif
                try Task.checkCancellation()
                guard operation == generation else { return }
                cancel()
                output = DictationOutput(text: text, conversation: owner)
            } catch {
                guard operation == generation else { return }
                cancel()
                failure = error.localizedDescription
            }
        }
    }

    func cancel() {
        generation = UUID()
        output = nil
        work?.cancel(); work = nil
        limit?.cancel(); limit = nil
        recorder?.stop(); recorder = nil
        #if os(macOS)
        hex?.close(); hex = nil
        #else
        recognitionContinuation?.resume(throwing: CancellationError()); recognitionContinuation = nil
        recognitionDeadline?.cancel(); recognitionDeadline = nil
        recognition?.cancel(); recognition = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
        phase = .idle
        status = ""
    }

    #if os(iOS)
    private func recognize(_ url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.supportsOnDeviceRecognition else {
            throw DictationFailure(message: "On-device recognition is unavailable.")
        }
        let recognitionGeneration = generation
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.contextualStrings = ["Cackles", "RunPR", "OpenClaw", "Cast"]
        return try await withCheckedThrowingContinuation { continuation in
            recognitionContinuation = continuation
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.generation == recognitionGeneration, let pending = self.recognitionContinuation else { return }
                    if let result, result.isFinal {
                        self.recognitionContinuation = nil
                        pending.resume(returning: result.bestTranscription.formattedString)
                    } else if let error {
                        self.recognitionContinuation = nil
                        pending.resume(throwing: error)
                    }
                }
            }
            recognitionDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, let pending = self.recognitionContinuation else { return }
                self.recognitionContinuation = nil
                pending.resume(throwing: DictationFailure(message: "On-device recognition timed out. Please try a shorter recording."))
                self.recognition?.cancel()
            }
        }
    }
    #endif
}
