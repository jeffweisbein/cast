# Cast reliability pass — 2026-11-06

Scope: improve existing single-operator features. Multiplayer, person-specific permissions/cache architecture, gateway configuration, automatic replay and public release remain excluded. Jeff subsequently authorized all four UX improvements below and installation on his devices after verification.

## Feature analysis and changes

| Feature | Failure / existing protection | Action |
|---|---|---|
| Downloads | Short HTTP bodies could pass when artifact size was absent | Validate identity response length; preserve decoded/compressed semantics |
| File cache | Readability alone accepted truncated or modified copies | Atomic data + size/SHA-256 receipt; verify off the UI actor; isolate gateway addresses |
| File names | Character truncation did not bound UTF-8 filename bytes | Portable byte limit while preserving a reasonable extension |
| Inline media | Reappearance must not reset a loaded row's height | Keep loaded state for identical attachment/retry identity; reset revised items |
| Deliverables | A reused row could retain an old revision's cached URL | Tie row identity to revision, size, name and MIME type; ignore cancelled cache lookups |
| Existing local files | Transfer limits must not hide large files already on this Mac | Preserve localhost preview/reveal, with regular-file/expected-size checks |
| Upload sizing | Raw text/base64 estimates ignored JSON escaping | Exact encoded-size counting without constructing base64 on the UI actor; wire encoder avoids optional slash escaping |
| Composer/session switching | Pending files followed selection into another chat | Per-conversation in-memory attachment drafts; delayed preparation bound to original conversation/gateway |
| Send retries | Reusing an outbox ID could overwrite its original session/payload | Permit identical retry only, retaining original bytes and creation time |
| Approval refresh | One successful list erased the failed family's prompts; late lists erased live events | Preserve failed families; revision/generation guards; malformed lists are not successful empty lists |
| Reconnect/sidebar | An old connection's list response could replace the current sidebar | Connection-scoped in-flight ownership and response guards |
| Model/progress controls | Reads/acks could arrive after connection replacement | Reject stale connection results; preserve explicit partial model-change reporting |
| History/streaming | Existing session-open and backfill generations, content reconciliation and retained terminal streams | Reviewed existing protections; retain regression coverage, no redesign |
| Unread/notifications | Existing watermark-checked serialized receipts and delivery-state ledger | Preserve current behavior and tests; no notifications sent during verification |
| Search | Existing query generation and cancellation guards | Preserve current behavior and tests |
| Voice/dictation | Existing bounded recording, cancelled permission handling, generation-bound recognition and session-owned output | Preserve current behavior and tests; hardware capture not exercised in this pass |
| Text drafts | Existing per-session atomic persistence and relaunch tests | Preserve existing persistence; newly isolated attachment drafts are memory-only until sent |

## Verification contract

Regression receipts distinguish original failure, repaired unit/integration tests, platform compilation and independent review. A passing suite does not establish real-device UI acceptance, live delivery or a release.

- Download regressions reproduce short-body acceptance, corrupt cache reuse, filename byte-bound and JSON sizing failures.
- Other-feature regressions reproduce cross-conversation composer files, outbox identity overwrite, partial/live-event approval loss and stale sidebar responses after suspension.
- Real loopback HTTP exercises the actual `ArtifactDownloader` with plain and gzip bodies; it is not a production gateway probe.
- Opus 5.5 reviews immutable source packets. Its first review required repairs to row reappearance and localhost limits; final approval must refer to the repaired candidate.

## Explicit remaining limits

- Downloads remain bounded to 64 MiB in memory, with fresh gateway-issued URLs and no redirects or forwarded gateway credentials. Existing local-file preview is not a transfer and has no such ceiling.
- There is no automatic retry of uncertain sends or approval decisions.
- Cache integrity failures trigger re-fetch. Existing pre-receipt caches are not silently trusted or deleted; older offline cache access/migration needs a separate design. Editing cache files in place is not supported; use Save As to retain edits.
- Cache eviction and unified identity across artifact-list versus transcript ingestion remain follow-up work. No destructive cleanup is added here.
- The RPC layer's existing timeout can delay cancellation while waiting for an artifact link; the result is checked before saving/publishing it. Byte-by-byte HTTP accumulation and resumable transfers remain unchanged.
- This is a bounded reliability pass, not proof that every feature, integration or permission path is defect-free. Live microphone, notification delivery, physical-device scrolling and production gateway side effects require separate acceptance testing.


## Authorized UX expansion

Reuse the existing SwiftUI views, URLSession downloader, verified file cache and request protocols. No library/service dependency is needed. No new server API, scheduler or multiplayer contract is introduced.

| Feature | Lifecycle and UI contract | Verification |
|---|---|---|
| Downloads center | Workspace-owned attempts survive sheet dismissal. At most three active transfers; cancelling is immediate in UI, stale completion/progress cannot replace a retry. Explicit retry gets fresh authorized metadata. Saved files revalidate through existing cache; attempts are memory-only, not auto-resumed after quit. Closing a workspace/endpoint replacement clears transfer state. | Cancellation/retry, duplicate clicks, stale cache callback and workspace reset tests; real HTTP proof retained. |
| Needs you | Waiting, Submitting and Not confirmed are distinct. No duplicate approval submission or automatic resend. Only gateway acknowledgement/resolution produces Confirmed; disappearance from a list is No longer pending, not success. Expired prompts disable decisions. Recent outcomes are session-local and dismissible. Existing question idempotency and memory-only drafts retained. | Lost ack/duplicate submission and refresh-race tests, question-state reducer. |
| Chat navigation | Find searches loaded message groups (first200 matches), preserves a one-hop return bookmark; Jump to latest reply/live work/tail. Older jump renders a bounded neighborhood. Session switch clears bookmarks; missing anchors report no longer loaded. Workspace Search remains the way to search unloaded history. | Pure bounded navigation tests, native scroll layout stress, rendered fixture inspection. |
| Connection status | Persistent compact status on both platforms, expandable explanation. Offline/reconnecting shows local history/draft semantics and no automatic resend. A connected socket never labels unconfirmed messages delivered. Explicit reconnect, no credential or scope changes. | State-copy tests, Mac/iOS compilation and rendered fixture. |

PQG expansion: intake324/occurrence326/finding646. New source, tests, independent review and device installs are separate receipts. No user acceptance claimed from installation.
