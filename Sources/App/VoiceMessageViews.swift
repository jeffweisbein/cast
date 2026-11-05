import AVFoundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Mic button that starts a voice capture. iOS keeps the messaging idiom — hold to
/// record, release to preview, slide left to cancel — and the button node stays
/// structurally stable across the idle → recording transition so the in-flight drag
/// gesture is never torn down. macOS is a plain click-to-start / click-to-stop toggle:
/// press-and-hold is a touch gesture, and a mouse hold is awkward while a keyboard
/// cannot perform it at all.
struct VoiceRecordButton: View {
    @ObservedObject var controller: VoiceRecorderController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @State private var holding = false

    private static let cancelDragDistance: CGFloat = 70
    #endif

    private var isRecording: Bool { self.controller.state == .recording }

    var body: some View {
        #if os(macOS)
        Button {
            if self.isRecording {
                self.controller.finishRecording()
            } else {
                Task { await self.controller.beginRecording() }
            }
        } label: {
            self.micImage
        }
        .buttonStyle(.plain)
        .help(self.isRecording ? "Stop and preview" : "Record a voice message")
        .accessibilityLabel(self.isRecording ? "Stop recording" : "Record voice message")
        #else
        self.micImage
            .gesture(
                LongPressGesture(minimumDuration: 0.2)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        switch value {
                        case .second(true, let drag):
                            if !self.holding {
                                self.holding = true
                                Task { await self.controller.beginRecording() }
                            }
                            if let drag, drag.translation.width < -Self.cancelDragDistance {
                                self.holding = false
                                self.controller.cancel()
                            }
                        default:
                            break
                        }
                    }
                    .onEnded { _ in
                        guard self.holding else { return }
                        self.holding = false
                        self.controller.finishRecording()
                    })
            .accessibilityLabel(self.isRecording ? "Recording voice message" : "Record voice message")
            .accessibilityHint("Hold to record, release to preview, slide left to cancel")
            // VoiceOver users cannot hold-and-drag; expose start/stop as discrete actions.
            .accessibilityAction(named: self.isRecording ? "Stop recording" : "Start recording") {
                if self.isRecording {
                    self.controller.finishRecording()
                } else {
                    Task { await self.controller.beginRecording() }
                }
            }
        #endif
    }

    private var micImage: some View {
        Image(systemName: self.isRecording ? "mic.fill" : "mic")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(self.isRecording ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .frame(width: 28, height: 28)
            .scaleEffect(self.isRecording && !self.reduceMotion ? 1.2 : 1)
            .animation(self.reduceMotion ? nil : .spring(duration: 0.25), value: self.isRecording)
            .contentShape(Circle())
    }
}

/// Live capture strip shown in place of the text field: pulsing dot, elapsed time,
/// scrolling level waveform, and the cancel affordance.
struct VoiceRecordingIndicator: View {
    @ObservedObject var controller: VoiceRecorderController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(self.pulsing && !self.reduceMotion ? 0.3 : 1)
                .animation(
                    self.reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                    value: self.pulsing)
            Text(Self.timestamp(self.controller.elapsed))
                .font(.callout.monospacedDigit())
                .foregroundStyle(self.controller.isNearingLimit ? .orange : .primary)
            // Only appears for the last stretch. A five-minute countdown running the whole
            // time reads as pressure; one that shows up at 0:30 reads as a heads-up.
            if self.controller.isNearingLimit {
                Text("\(Self.timestamp(self.controller.remaining)) left")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
            VoiceWaveformView(levels: self.controller.levels)
                .frame(height: 22)
                .frame(maxWidth: .infinity)
            #if os(iOS)
            Label("Slide to cancel", systemImage: "chevron.left")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            #else
            // The mic button stays visible to its right for stop-and-preview; this is
            // the explicit discard path, reachable by click or Escape.
            Button {
                self.controller.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Cancel recording")
            .accessibilityLabel("Cancel recording")
            #endif
        }
        .padding(.vertical, 8)
        .onAppear { self.pulsing = true }
        .animation(.easeInOut(duration: 0.2), value: self.controller.isNearingLimit)
        #if os(iOS)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.controller.isNearingLimit
            ? "Recording voice message, \(Int(self.controller.remaining)) seconds remaining before the limit"
            : "Recording voice message, \(Int(self.controller.elapsed)) seconds")
        #else
        // Keep the cancel button reachable as its own element; the strip itself still
        // reads as one labelled group.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording voice message")
        #endif
    }

    static func timestamp(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct VoiceWaveformView: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(self.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.tint)
                    .frame(width: 2.5, height: 3 + CGFloat(min(max(level, 0), 1)) * 19)
            }
        }
        .animation(.linear(duration: 0.05), value: self.levels)
        .accessibilityHidden(true)
    }
}

/// Shown above the preview when the duration ceiling ended the capture instead of the
/// user. An auto-stop is otherwise indistinguishable from a crash, so this states what
/// happened, confirms the audio survived, and names the next step. It fires a haptic on
/// appear because the stop usually happens while the phone is away from the user's face.
struct VoiceLimitNotice: View {
    var body: some View {
        Label {
            Text("Maximum length reached. Your recording is saved — send it, then record another if you have more.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "clock.badge.checkmark")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .onAppear {
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            #endif
        }
    }
}

/// Scrubable playback preview of a finished recording, with discard and send.
/// Send routes through the composer's normal draft path so voice messages share the
/// exact validation and delivery flow images use.
struct VoicePreviewRow: View {
    let recording: VoiceRecording
    let onDelete: () -> Void
    let onSend: () -> Void
    @StateObject private var player = VoicePreviewPlayer()

    var body: some View {
        HStack(spacing: 8) {
            Button {
                self.player.togglePlayback()
            } label: {
                Image(systemName: self.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(self.player.isPlaying ? "Pause preview" : "Play preview")
            Slider(
                value: Binding(
                    get: { self.player.fraction },
                    set: { self.player.scrub(to: $0) }),
                in: 0...1,
                onEditingChanged: { self.player.setScrubbing($0) })
                .controlSize(.small)
                .accessibilityLabel("Playback position")
            Text(VoiceRecordingIndicator.timestamp(
                self.player.isPlaying || self.player.fraction > 0
                    ? self.player.position
                    : self.recording.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                self.player.stop()
                self.onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard voice message")
            Button {
                self.player.stop()
                self.onSend()
            } label: {
                ZStack {
                    Circle().fill(.tint)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send voice message")
        }
        .padding(.vertical, 4)
        .task(id: self.recording.url) {
            self.player.load(url: self.recording.url, fallbackDuration: self.recording.duration)
        }
        .onDisappear { self.player.stop() }
    }
}

/// Playable voice-message bubble for transcript audio attachments whose file is readable
/// on this machine (gateway echo of a sent message, or any inbound audio media path).
/// Unreadable/remote paths never reach this view — `InlineMediaThumbnail` falls back to
/// the chip instead.
struct VoicePlaybackBubble: View {
    let url: URL
    @StateObject private var player = VoicePreviewPlayer()

    var body: some View {
        HStack(spacing: 8) {
            Button {
                self.player.togglePlayback()
            } label: {
                Image(systemName: self.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(self.player.isPlaying ? "Pause voice message" : "Play voice message")
            Slider(
                value: Binding(
                    get: { self.player.fraction },
                    set: { self.player.scrub(to: $0) }),
                in: 0...1,
                onEditingChanged: { self.player.setScrubbing($0) })
                .controlSize(.small)
                .accessibilityLabel("Playback position")
            Text(VoiceRecordingIndicator.timestamp(
                self.player.isPlaying || self.player.fraction > 0
                    ? self.player.position
                    : self.player.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 240)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.5)))
        .task(id: self.url) {
            self.player.load(url: self.url, fallbackDuration: 0)
        }
        .onDisappear { self.player.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice message")
    }
}

/// Thin AVAudioPlayer wrapper for the preview row: play/pause, polling progress, scrub.
@MainActor
final class VoicePreviewPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    // Published so a view showing the duration before first playback (the transcript
    // bubble) refreshes once async `load` resolves it.
    @Published private(set) var duration: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var tickTask: Task<Void, Never>?
    private var isScrubbing = false
    private var otherPlayerObserver: (any NSObjectProtocol)?

    /// Every live player listens; whichever one starts pauses the rest so two voice
    /// messages never talk over each other.
    private static let didStartPlayback = Notification.Name("CastVoicePreviewPlayerDidStartPlayback")

    init() {
        self.otherPlayerObserver = NotificationCenter.default.addObserver(
            forName: Self.didStartPlayback,
            object: nil,
            queue: .main)
        { [weak self] notification in
            guard let self, (notification.object as? VoicePreviewPlayer) !== self else { return }
            Task { @MainActor in self.pauseBecauseAnotherPlayerStarted() }
        }
    }

    deinit {
        if let observer = self.otherPlayerObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var fraction: Double {
        guard self.duration > 0 else { return 0 }
        return min(1, self.position / self.duration)
    }

    func load(url: URL, fallbackDuration: TimeInterval) {
        self.player = try? AVAudioPlayer(contentsOf: url)
        self.player?.prepareToPlay()
        self.duration = self.player.map(\.duration) ?? fallbackDuration
    }

    func togglePlayback() {
        guard let player = self.player else { return }
        if self.isPlaying {
            player.pause()
            self.isPlaying = false
            self.stopTicking()
            return
        }
        #if os(iOS)
        // The recorder deactivated the shared session; without an active playback
        // category the preview can route through the receiver or respect silent mode.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        if self.fraction >= 1 { player.currentTime = 0 }
        NotificationCenter.default.post(name: Self.didStartPlayback, object: self)
        player.play()
        self.isPlaying = true
        self.startTicking()
    }

    func scrub(to fraction: Double) {
        guard let player = self.player, self.duration > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        player.currentTime = clamped * self.duration
        self.position = player.currentTime
    }

    /// While the user drags the slider, the 50 ms progress poll stops writing
    /// `position` so the thumb tracks the drag instead of fighting it.
    func setScrubbing(_ scrubbing: Bool) {
        self.isScrubbing = scrubbing
    }

    func stop() {
        self.player?.stop()
        self.isPlaying = false
        self.position = 0
        self.stopTicking()
    }

    private func pauseBecauseAnotherPlayerStarted() {
        guard self.isPlaying else { return }
        self.player?.pause()
        self.isPlaying = false
        self.stopTicking()
    }

    private func startTicking() {
        self.tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, !Task.isCancelled else { return }
                guard let player = self.player else { return }
                if !self.isScrubbing { self.position = player.currentTime }
                if !player.isPlaying {
                    self.isPlaying = false
                    if self.position >= self.duration - 0.05 { self.position = 0 }
                    return
                }
            }
        }
    }

    private func stopTicking() {
        self.tickTask?.cancel()
        self.tickTask = nil
    }
}
