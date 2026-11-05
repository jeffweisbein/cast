# Cast operations console: architecture and append-only status

This file is an append-only decision and delivery log for phases 1–6. New entries may clarify
older entries, but existing entries are not rewritten or removed.

## 2026-07-25 — Baseline audit and product decisions

### Invariants

- The macOS transcript remains eager (`VStack`) by default. The existing `LazyVStack`
  session-switch placement livelock fix is preserved. Windowing must bound the eager render
  set; it must not restore lazy layout on macOS. iOS keeps its existing lazy transcript.
- Gateway state is authoritative where the protocol exposes it. Local ledgers add durable
  precision and delivery history; they do not claim the gateway's boolean `unread` field is an
  exact message count.
- A mutating gateway control is unavailable until the gateway explicitly advertises the
  corresponding capability. Cast will not guess RPC method names from session labels.
- All operations records are workspace-scoped, deterministic, Codable, and persisted through
  atomic replacement. Tests use isolated temporary roots and never deliver native notifications.

### Information architecture

- Human direct and group channel conversations are **Chats**.
- `agent:main:main` is labeled **Agent Inbox**, not “Main Session.” It is not a human chat and
  heartbeat activity makes recency misleading.
- Agent Inbox appears in **Needs Attention** while unread or actively running. When quiet it is
  available under **All Sessions**, so the raw operational session remains reachable without
  dominating the normal chat list.
- Identifiable subagent sessions are first-class **Tasks** with derived activity/attention
  status. Cron and dreaming sessions are **Automation** with health derived only from facts Cast
  has (active, unread/failure evidence, last activity/staleness); run/pause controls remain
  capability-gated.
- **Needs Attention** is an aggregate view over unread conversations, pending approvals, task or
  automation failures, and notification-delivery failures. Entries need stable dedupe identities
  so one incident is counted once even when represented by multiple inputs.

### Delivery order

1. Bound macOS eager transcript rendering with deterministic, testable window expansion.
2. Add persistent numeric unread and notification-delivery ledgers.
3. Wire aggregate numeric badge state across workspaces and both Apple platforms.
4. Ship the operations sidebar taxonomy and first-class task/automation summaries.
5. Add notification authorization/delivery parity and a searchable in-app notification center.
6. Add gateway controls only as capabilities are confirmed by the connect handshake.

### Baseline evidence

- Starting branch point: `78ddd92` (`fix(chat): scope eager transcript default to macOS`).
- Work branch: `feature/operations-console-phases-1-6`.
- Baseline worktree was clean.
- Existing tests already cover transcript projection, session classification/search, history
  reconciliation, and boolean unread clearing.

## 2026-07-25 — Build checkpoint: strongest cross-platform vertical slice

### Delivered

- macOS retains the eager transcript freeze fix and now renders a bounded 200-item suffix.
  **Show Earlier** expands by 200 items while the streaming tail, approvals, and follow anchor
  remain outside the window. iOS remains lazy and unwindowed.
- `UnreadLedger` persists numeric counts per workspace and session, distinguishes exact counts
  from lower bounds, deduplicates message IDs, rejects stale watermarks, reconciles gateway
  boolean unread state without claiming false precision, and clears in the chat-open
  transaction.
- `WorkspaceManager` aggregates the durable counts for the macOS Dock badge and iOS app-icon
  badge. Sidebar rows and section headers show numbers rather than boolean dots.
- `NotificationDeliveryLedger` stores append-only
  observed → eligible/suppressed → delivered/failed → read transitions with stable dedupe IDs
  and workspace/session/event/message/run linkage. Writes are atomic and serialized.
- A shared native notification boundary delivers only after explicit user authorization. The
  in-app Notification Center contains the same durable records, exposes authorization, supports
  record search, and routes a selected record to its chat. Tests always suppress native
  delivery.
- Recovered gateway snapshots create a lower-bound unread record but suppress stale native
  alerts. Newly observed assistant `session.message` events drive exact local increments.
- The sidebar now promotes unread sessions, narrow failure/action-required signals, and native
  notification failures into **Needs Attention** without duplicating rows. Quiet work remains in
  Chats, Tasks, Automation, or All Sessions.
- `agent:main:main` is implemented as **Agent Inbox**: actionable/running goes to Needs
  Attention; quiet goes to the collapsed All Sessions disclosure.
- Subagent sessions are first-class Tasks with running/complete/attention state. Cron/dreaming
  sessions are Automation with running/healthy/attention summaries. No speculative task or
  automation RPC is present.

### Checkpoint commits

- `475a9e0` — architecture and append-only status baseline
- `0f86be6` — bounded eager macOS transcript rendering
- `a39455f` — operations sidebar taxonomy and Agent Inbox decision
- `851e262` — durable unread and notification ledger domain/persistence
- `5de1604` — runtime integration, numeric badges, Needs Attention, and Notification Center

### Validation

- Focused operations ledger/integration tests: 10 passed.
- Full macOS test suite: 130 passed, 0 failed.
- macOS app compiled and linked as the test host with signing disabled.
- Universal iOS Simulator build: succeeded for arm64 and x86_64; the Share Extension embedded
  and validated.
- `git diff --check`: clean at each checkpoint.
- No push, publication, release, or external message was performed.

### Known gaps and exact continuation

1. **Offline exactness:** when Cast missed events while stopped, `sessions.list` can recover only
   the gateway's boolean unread lower bound of one. Add a gateway unread-count/message cursor
   only if the protocol exposes one; never infer a larger exact count from timestamps.
2. **Native delivery parity:** the current “delivered” transition means
   `UNUserNotificationCenter.add` accepted the request. Add a notification-center delegate and
   presentation/response callbacks in the app lifecycle to distinguish scheduled, presented,
   and tapped; route tap `workspaceID` + `sessionKey` through `WorkspaceManager`.
3. **Unified attention:** unread/failure sessions are deduplicated in Needs Attention, while
   pending exec approvals retain their existing global count and transcript cards. Introduce a
   typed `AttentionItem` reducer that merges approvals, tasks, automation, unread, and delivery
   failures by stable incident ID, then render approvals in the same section.
4. **Tasks:** current Tasks are typed read-only projections of subagent sessions. Add a task
   detail surface and task-native fields when the gateway provides a task endpoint/status
   schema; keep session heuristics as compatibility fallback.
5. **Automation controls:** no run/pause/edit controls are shown because the connect snapshot
   has no confirmed capability mapping in this repo. Parse an explicit server capability set
   from `cast.hello`, add fixture tests, and expose controls only for exact advertised
   capabilities and confirmed RPC shapes.
6. **Search:** session/message search and notification-ledger search both work, but are separate
   surfaces. Add an `OperationsSearchResult` merger that ranks transcript, session, task,
   automation, attention, and notification hits under one query.
7. **Transcript storage:** rendering is bounded on macOS, but history synchronization and the
   in-memory transcript remain complete. Profile very large histories, then add paged cache
   loading independently of the render window without changing the eager macOS layout.
