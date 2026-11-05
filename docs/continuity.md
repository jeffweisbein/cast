# Cast continuity workflows

## Build on your Mac

Pull `main` in a clean checkout, run `Scripts/generate-project.sh`, then build the
Cast-macOS scheme in Xcode with the same signing team used for your existing app.
This release is 0.3.0, build 5. Pairing and existing workspace preferences are unchanged.

## Files you can actually take with you

Open **Deliverables** and refresh gateway attachments. Cast checks the selected
conversation plus at most 12 recent ones, or just the conversation when opened
from a task. Open an older conversation to include its attachments. Discovery uses
`artifacts.list`; downloads use `artifacts.download` with an exact artifact ID and
session key over the existing authenticated connection. No new file-serving plugin
or arbitrary-filesystem HTTP endpoint is required.

Download, cancel, retry, Preview, Save as, and Share are available for supported
artifacts. Completed downloads persist per workspace/device, under a revision-specific
cache key. On iPhone, Save as and the share sheet offer Files destinations. Mac also
offers Reveal. Retry obtains a fresh gateway download URL rather than retaining an
expired signed URL. Download URLs are not logged or persisted by this feature.

The client caps downloads at 64 MB, checks declared size, uses an ephemeral HTTP
session without cookies or credentials, rejects redirects, and never forwards the
gateway token to a file host. A partial/cancelled transfer is not promoted to a cached
file. Downloads are local copies and remain available offline, even if the server
later removes the original; deleting app data is separate from revoking gateway access.

**A Markdown filesystem link is not necessarily a downloadable artifact.** The old
`sessions.files.get` endpoint can preview some small text/image files, but does not
transfer arbitrary PDFs or ZIPs. Ask the agent to attach the actual file to the
conversation if only a path was shared. Public web links and PRs still open in the
browser; Cast does not guess credentials for protected third-party URLs.

## Sending and reconnecting

Before submitting a send, Cast persists the exact text, attachment bytes, delivery
choice, session, and idempotency key in a device-local outbox. A disk failure blocks
that attempt instead of silently giving up restart recovery. The outbox has a 128 MB
aggregate limit and restrictive file permissions; acknowledged requests are removed.

The local bubble distinguishes submitting, accepted by gateway, failed, and
**Delivery unconfirmed**. An uncertain reply is not a final failure: the request may
have arrived while its acknowledgement was lost. Reconnect reloads authoritative
history, which can reconcile the local bubble with the gateway echo. Cast never
automatically replays the uncertain request. Manual retry reuses the original request
ID and exact payload, including non-image files and the external-delivery setting.
Gateway restarts or expiration of its deduplication window can still permit duplicates;
the confirmation explains this. Check history first for consequential requests.

Pre-upgrade cached sends without an exact outbox payload cannot be reconstructed
with missing attachments or changed delivery settings. Cast explains this rather than
silently resending a modified request. Drafts and the existing reconnect/watchdog behavior
remain intact. Request acceptance does not mean the agent finished or a deployment shipped.

## Search this workspace

Use sidebar **Search** or **Cmd-K** on Mac. The default combines locally saved messages,
session names/previews, Needs you entries, and deliverables. Hidden conversations are
excluded unless **Include hidden chats** is enabled; this does not unhide them.

**Search gateway history too** explicitly opts into `sessions.search`. Queries are
scoped to listed conversations, grouped by agent (up to eight agents, 200 session keys
per agent, 25 gateway hits per agent). Recent task search covers the first 100 records.
The UI reports incomplete/indexing/unavailable results. Local results remain usable
when offline. This is search within one workspace, not cross-workspace federation.

Message hits jump to a loaded message. Deep hits use a 200-item neighborhood instead
of expanding the whole eager Mac transcript. **Latest** returns to the normal tail.
If the hit belongs to an older session version or is outside loaded history, its
search excerpt remains visible with that limitation. Deliverable hits open the selected
item; task hits open its real task detail.

## Task details and actions

Sidebar **Tasks** uses `tasks.list` pagination, with `tasks.get` for the full bounded
goal and result. Active detail views refresh every 15 seconds. Needs you also opens
session-level details and related records from the latest task page. Session-only
fallbacks do not invent task IDs or show unsupported controls.

**Stop task** is shown only for running/queued task records when `tasks.cancel` is
advertised. Stopping does not undo completed actions. **Retry result delivery** uses
`tasks.retry` for eligible terminal delivery failures; it does not rerun the task.
Its confirmation warns about possible duplicate delivery. All actions check the
gateway response rather than displaying success optimistically. Use **Open conversation /
answer** to inspect context and respond normally; details do not auto-send answers.

## Verification and limits

- Full Mac unit suite, focused network-transfer fixtures, and iOS Simulator compile.
- Read-only live probes: artifacts.list, scoped sessions.search, tasks.list.
- Automated transfer cases: exact ZIP-like bytes, no Authorization/Cookie headers,
  expired URL, HTTP redirect refusal, oversized and mismatched length, cancellation.
- Automated lifecycle cases: exact file/delivery recovery, workspace/session boundaries,
  disk-write failure, cache restart, authoritative echo reconciliation, deep search bound.
- Physical iPhone/M3 Wi-Fi switching, sleep/wake under real traffic, signed upgrades,
  notarization, Sparkle feed delivery, and TestFlight remain device/operator checks.

No production tasks are stopped or retried by the test suite. No gateway configuration
or private-repository visibility is changed by this release.
