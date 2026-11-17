# Project-first sidebar

Historical design for project grouping. The current personal chat sidebar is documented in [sidebar-layout.md](../sidebar-layout.md); this plan does not describe the current default navigation.

## Contract

- Projects are organizational Gateway `category`/group metadata, **not** execution `projectId`, cwd or permissions. Use the existing `sessions.groups.list`, `sessions.create`, and identity-guarded `sessions.patch` RPCs. No new dependency or backend service.
- Existing groups plus offered Cackles/RunPR/Cast are shown; offered groups are not persisted until an explicit chat creation or move. General means no category. Existing conversations are not classified by title or silently moved.
- Select a project to see an overview without losing the open conversation/draft. New chat creates an empty, distinct gateway conversation in that category; creation does not start an agent turn.
- Needs you uses actual questions, approvals and attention items, not unread replies. Working uses running/queued state. Recent shows activity within seven days. Views reference original session identities.
- Side chats retain inspector presentation, original context, drafts, archive/restore and exact session keys. Archived/background sessions do not become ordinary project conversations.
- Moves persist before appearing successful; errors remain visible. No public distribution, device installation or migration is part of source implementation.

## Acceptance

Check project identity through decoding/unread changes, first-page/full-inventory reconciliation, failed/late moves, replaced session incarnations, uncertain create retry identity, independent unread/work filters, project overview draft retention, native navigation and existing side-chat archive/restore. Unit boundary fixtures do not prove live cross-device acceptance.

Smart-chat suggestions with editable context, automatic chat creation, arbitrary nested folders and full dashboard authoring remain deferred. No automatic chat creation is introduced.
