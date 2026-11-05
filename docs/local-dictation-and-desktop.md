# Local dictation and desktop agents

## Dictate into a Cast conversation

1. On Mac, open the local-tools menu beside the composer → **Dictation Setup**. Source builds do not bundle Hex. For optional Mac dictation, install the vendor-signed [Hex app](https://github.com/AnomalyCo/hex) at `/Applications/Hex.app`. Hex does not need to be running.
2. Download/prepare **Parakeet Unified English** once (731.4 MB, plus a small VAD model). Model files are shared with Hex. Setup shows download progress, model readiness, preferred spellings, the model license and a confirmed remove-model action.
3. Click **Dictate into draft** (waveform/microphone), or press **⌘⇧D**. Allow microphone access when macOS asks.
4. Speak, then click **Finish** or press **⌘⇧D** again. The final text is appended to the current draft, preserving existing edits. Review/edit and send normally.
5. **Cancel** discards the recording and pending transcription. Changing conversations or leaving the composer also cancels it. Recording ends automatically at five minutes. Nothing auto-sends.

The microphone button for **voice messages** still sends audio attachments. Dictation is separate. On iPhone/iPad, the new dictation button uses Apple's on-device English speech recognition, never a cloud fallback; it requires Microphone and Speech Recognition permission and an available local recognizer. The Rust Hex helper is Mac-only. Mac preferred spellings are editable under Setup and local to that client.

Audio is sent only to the owned authenticated loopback helper and the temporary WAV is removed after completion/cancellation. The text is sent to your configured agent/provider only when you press Send. Hex can maintain its own local diagnostic logs; Cast does not promise those upstream logs contain no text. Downloads require internet; ordinary transcription does not. Model licenses and Hex notices are included in app resources. No subscription/API key is required.

## Give an agent one window

1. In the Mac composer, open the local-tools menu → **Attach a Window**.
2. Select the app/window. **Inspect only** is the default. Turn on **Allow interaction with this window** if the task needs clicks/field changes.
3. Click **Attach window**. Review the resulting context attachment, add or dictate your request, then send.
4. Examples: “Check this window for clipped controls”; “Use this test app to reproduce the draft-loss issue”; “Change this fixture field and verify the displayed result.”
5. A visible composer row identifies the app and access mode. **Stop access** revokes the adapter session and stops the current agent turn. Access also expires after 15 minutes, on switching conversations, or after Cast stops refreshing its heartbeat. Removing the unsent context attachment revokes access.

Only accessibility text/controls from the chosen window are attached. This feature does **not** include pixels, full-screen recording, drawing/annotation, system-wide hotkeys or always-on listening. Screenshot permission is not needed. Use existing attachment controls when a screenshot is necessary.

### Desktop prerequisites and operation

- Agent Desktop 1.0.2 installed (`/opt/homebrew/bin/agent-desktop` or `/usr/local/bin/agent-desktop`). macOS Accessibility permission must cover the launching context (Cast) and Agent Desktop as required by macOS. Use System Settings → Privacy & Security → Accessibility / Device Control and Data Access. Permissions cannot be granted by Cast itself.
- `/usr/bin/python3` available (Apple Command Line Tools on the tested Macs).
- The agent must have an existing authorized execution route to the selected Mac: paired node or SSH. Cast includes machine identity, the installed adapter path and a scoped session ID in the attachment. It does not install a new remote-control daemon, open a network port or silently grant gateway shell access.

The bundled `cast-desktop.py` reads a bounded JSON object from stdin. Examples:

```json
{"session":"<id from the attachment>","action":"snapshot"}
{"session":"<id>","action":"click","ref":"@<fresh-snapshot>:e3"}
{"session":"<id>","action":"set-value","ref":"@<fresh-snapshot>:e5","value":"New text"}
{"session":"<id>","action":"scroll","ref":"@<fresh-snapshot>:e7","direction":"down","amount":3}
```

Allowed actions: snapshot, click, toggle, check, uncheck, expand, collapse, set-value, select, scroll. All are headless. Each action invalidates its refs; observe again to verify the effect. Unsupported controls fail visibly. Menus/new windows outside the selected window require a new selection; no automatic scope expansion. Same-app operations are serialized across sessions. Parallel agents do not have independent desktops.

The adapter constrains its own calls, not arbitrary code running as your macOS user. Existing shell permissions remain unchanged. Do not bypass it by calling raw desktop commands for a scoped task. Revocation prevents new calls and terminates adapter-owned in-flight processes; already delivered GUI actions cannot be undone. Sending, purchasing, publishing or deleting still needs the user's instruction. A failed/uncertain delivery must be observed before retrying.

## Build and package

```sh
Scripts/generate-project.sh
xcodebuild -project Cast.xcodeproj -scheme Cast-macOS -configuration Release CODE_SIGNING_ALLOWED=NO build
Scripts/embed-hex.sh /path/to/Cast.app /path/to/signed/Hex.app
# Sign the outer Cast app using the normal Cast signing identity, preserving Hex's nested signature.
# Then run Scripts/verify_mac_package.py with expected version/build/source/team before delivery.
```

Prefer `Scripts/release.py ... --hex-app /path/to/Hex.app` for signed builds: it embeds the helper, runs the regression suite and enforces the package/staging checks. An unsigned Xcode build can leave Sparkle's old resource seal invalid after stripping headers. Diagnose the named framework; sign that framework and then outer Cast with the intended identity/options. Never use recursive signing to overwrite Hex. See [verification.md](verification.md).

`embed-hex.sh` checks Hex's signature and Anomaly team identity before copying the complete 59 MB helper app into `Contents/Resources/Helpers/Hex.app`. The model is not bundled. Runtime also validates the helper signature and API2 localhost handshake; bearer credentials remain in memory and redirects are refused. The helper is launched directly with a scrubbed environment and stdin lifetime lease. Cancellation closes its owned process, never a global Hex process. Upstream helper updates are explicit packaging updates, not silent downloads at launch.

Verification: `python3 Tests/desktop_bridge_test.py`; Xcode `Cast-macOS` tests; macOS and iOS Simulator Release builds; a real audio fixture through the Swift Hex adapter; a separate M3 fixture observed before/action/after and rejected after revocation. Microphone hardware, first-run permission prompts and iPhone/iPad runtime acceptance are separate from these checks.
