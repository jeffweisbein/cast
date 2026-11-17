# Side-chat archiving

## User contract

Archive removes a side chat from this device's sidebar. The conversation remains saved on its gateway. Archived chats can be restored from the same sidebar; an immediate Undo is also available. Closing a pane is separate from archiving. Archiving never deletes history, aborts a run, clears unread state, sends a message, or changes the main conversation.

Auto-archive is optional and defaults to Off, with 30/60/90-day choices in Side chat options. It runs after a successful complete side-chat refresh while Cast is connected, not on a background schedule. Settings and archived state are local to this device, workspace profile and exact gateway URL.

## Persistence and inactivity

`SideChatArchive` extends the existing owner-only JSON recovery archive with optional presentation metadata, independently of delivery snapshots. Old archive files remain decodable. Explicit Archive/Restore/settings transitions persist before publishing. A failed save leaves the visible transition unapplied and reports an error.

Inactivity uses the later of local use and gateway activity. Opening/restoring, draft or send-state changes, and incoming messages count; unchanged history/list refreshes do not. Newly discovered legacy chats receive a local grace period. Streaming activity updates are coalesced to avoid writing an archive per token.

Automatic archiving excludes:

- Presented or running chats; pinned and unread chats.
- Nonempty drafts or uncertain delivery state.
- Missing, invalid, future, or recent activity timestamps and unknown run status.
- Any session that is not an exact Cast side-chat key.

Only fresh rows from a complete gateway discovery are eligible. If any duplicate observation is protected or recent, that wins over an older eligible row. Absence is never deletion or inactivity. New activity restores automatically archived chats; manually archived chats stay archived until Restore or deliberate open.

## Pagination compatibility

`sessions.list` may report `hasMore`, `nextOffset`, `totalCount` and `truncated`. A short page is not completion proof. Follow valid increasing cursors within the existing 10,000-offset bound. Auto-archive requires all pages to be confirmed and an explicit terminal `hasMore: false`, no next cursor, no truncation, and a consistent advertised total when present. Failures, caps and malformed metadata retain chats. Legacy gateways without completion metadata still support discovery and manual Archive/Restore, but automatic archiving is skipped with a notice when enabled.

## Verification

Use `SideChatRecoveryTests` for old-format decoding, cutoff boundaries, unknown/active/draft exclusions, duplicate-page races, scoped persistence, relaunch/restore, uncertain delivery preservation, complete-page gating, stale-generation rejection and incoming activity.

`Tests/SideChatFixture` runs the production sidebar and inspector against a synthetic local archive with no gateway client or credentials. Its UI test exercises Archive → Undo → Archive → relaunch → Archived chats → Restore → reopen the same saved conversation. `--reset-fixture` resets only this test app's synthetic archive on the first launch of each test; subsequent launches verify persistence. Explicit UI-test bundle identifiers avoid collisions with other runners.

Compile/test both native platforms and inspect the actual phone/tablet/Mac interactions. A test build is not a signed release, device installation or user-confirmed outcome.
