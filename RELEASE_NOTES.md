# Cast 0.4.0 source developer preview

A build-from-source preview for macOS 15+ and iOS 26+, using Xcode 26.3 or newer.

- Native conversations, live progress, approvals and optional secure-entry requests for your own OpenClaw gateways.
- Search, task details, portable attachments, local drafts and recoverable send state.
- Optional local Mac dictation through Hex and explicitly scoped window access through Agent Desktop.
- Apache-2.0 source, pinned dependencies, third-party notices and offline test/build instructions.

This release contains source only: no signed public app, update feed, bundled Hex binary or
model weights. Live features depend on gateway capabilities and permissions. iPhone signing,
microphone permissions, real-device acceptance and notarized binary distribution remain
separate from compiling/testing this source. Existing developer installations are not updated
by publishing this preview. See README.md, PRIVACY.md and docs/local-dictation-and-desktop.md.

# Unreleased

- **Live transcript following:** Keep incoming and streaming replies visible while following Latest, including updates that do not grow the scroll content. On Mac, only actual transcript input pauses following; queued follow work rechecks reading intent before scrolling.

# Cast 0.3.1 (build 6)

- **Actionable failures:** Use structured gateway failure categories to distinguish unavailable models, provider access/billing, rate limits, and temporary service failures. Unknown errors explain how to review before retrying. Raw provider errors are not displayed or shared.
- **Conversation diagnostics:** Status & updates shows last-reported context, history refresh state/time, unconfirmed sends in loaded messages, and recent in-app failure/compaction observations. Stale context is not shown as a current percentage; missing telemetry is not treated as zero.
- **Safer compaction recovery:** Only offer gateway-advertised compaction, prevent duplicate in-flight requests, and distinguish confirmed completion, no-op, and unconfirmed results after a disconnect/stream gap.

No automatic message replay, model/reasoning default changes, API spending, installed-app replacement, or repository publication. Physical-device interaction remains a separate acceptance check.

# Cast 0.3.0 (build 5)

- **Portable deliverables:** Refresh session-scoped gateway attachments, download generated PDFs/ZIPs and other supported artifacts, preview, Save as, and share on Mac/iPhone. Downloads survive restart. Progress, cancel, fresh-link retry, size validation, and a 64 MB cap are built in. Credentials are never forwarded to file hosts. Plain filesystem links remain previews where supported; ask for a real attachment to transfer a binary file.
- **Send continuity:** Exact text, attachments, delivery mode, and request ID persist before submission. Interrupted sends say **Delivery unconfirmed** and never replay automatically. Retry reuses the original payload; older sends without it cannot be reconstructed with missing files. Accepted by gateway is distinct from the agent finishing.
- **Unified search:** Sidebar Search / Cmd-K combines saved messages, conversations, Needs you, and deliverables. Opt in to scoped gateway history and recent task records, with incomplete/unavailable status. Hidden chats are excluded unless requested. Old matches jump into a bounded transcript neighborhood when available, with a preview fallback for historical session versions.
- **Task details:** Browse paginated gateway task records, goal, progress, blocker/error, result, conversation, and related deliverables. Active details refresh every 15 seconds. Stop and retry-result-delivery use real task IDs and advertised methods, with confirmation; retry does not rerun the work.

No gateway changes, public repository publication, update-feed activation, TestFlight upload, or installed-app replacement. Apple signing and a real signed update feed remain separate prerequisites.

# Cast 0.2 development release

- **Model controls:** Click the composer model label to choose a gateway-provided model and reasoning effort for this conversation's next turn. See the last response model when reported.
- **Needs you:** Pending approvals, explicit agent blockers, failed work, failed notifications, and unreviewed deliverables in one view. Hidden chats do not suppress approvals.
- **Deliverables:** Reports, packages, PRs, and releases shared in conversations you open are indexed locally across restarts. Open, preview, reveal on Mac, or share supported files; remote files require gateway support.
- **Status & updates:** Version/source identity, safe connection diagnostics, and signed Sparkle update support on Mac when a release feed is configured.
- **Release tooling:** Signed Mac install with backup, notarized Mac ZIP, and explicit iOS/TestFlight export/upload paths. No unsigned install fallback.

No new server storage, hosted service, or public repository is introduced. Sidebar, review, and deliverable preferences are local to each workspace/device. Model changes use the gateway's existing session settings and permission checks.
