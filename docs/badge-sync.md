# Unread badges and reconciliation

The app/icon badge counts **unread conversations**, not locally observed message events. The gateway exposes an authoritative unread boolean per conversation, not a cross-device unread-message count. Hidden sessions/workspaces remain excluded according to each device's existing local visibility settings; mute does not mark read.

The sidebar retains its 60-row page. A separate metadata-only inventory follows all gateway pages (bounded to 64 pages / a 25-second between-request budget). Only a complete inventory with no observed intervening events/reads can retire missing ledger rows. This is best-effort consistency, not an atomic gateway snapshot. Inventory work never blocks the transcript resume path. Live `sessions.changed` rows reconcile conversations outside the sidebar page. Missing unread fields are not read acknowledgments. Cross-device read state uses `lastReadAt` along with activity timestamps, so a read can clear local events without requiring new chat activity.

Only actual assistant text/media counts as new unread activity, excluding tool/system/user events and silent heartbeat/reply sentinels. Foreground activation refreshes the native icon even if the computed count is unchanged; native asynchronous badge writes are serialized/coalesced.

Limits: failed/incomplete inventories preserve cached state and retry through refresh/activation. Counts can remain stale offline or when a changing inventory cannot complete. iOS suspension does not permit continuous WebSocket synchronization; this client patch does not introduce a gateway APNs badge payload or guarantee immediate background clearing. Physical multi-device acceptance remains separate from fixture tests and signed installation. iOS task-completion notification delivery remains APNs-owned; macOS local notification-ledger expectations do not apply to iOS.

Regression coverage includes baseline failures, complete-inventory reconciliation, interrupted refreshes, and native badge delivery. Run the `BadgeSyncTests` suite for these cases; fixture results do not establish physical multi-device behavior.
