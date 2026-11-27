# Reminders and task notifications

## Behavior

- Only live `chat` events with `state: final`, a run ID and session key, and neither `yielded` nor `transcriptOnly` notify. Message/progress events only update unread accounting.
- The persistent notification ledger deduplicates each workspace/run. Muted and hidden chats suppress alerts. The visible conversation suppresses foreground alerts.
- macOS uses local notifications while Cast remains running and connected, including when another app is active.
- A compatible Gateway emits `notification.reminder` only after committing a scheduled result to its originating conversation. Raw cron run status, silent runs and replayed history do not become reminder alerts. Scheduled jobs still run on the Gateway; this does not schedule an offline alarm on the phone or guarantee delivery at an exact second.
- iOS uses only Apple remote notifications (never a local fallback while remote setup is pending or fails), so it does not keep its socket alive while suspended. Enable **Notify me about reminders and finished tasks** in the workspace Notification Center. Apple permission alone does not mean delivery is configured.
- Lock-screen copy is generic. A tap can navigate only to a configured workspace. Remote payloads must match a gateway identity learned from an authenticated status response for that exact workspace URL. Session access is still checked by the gateway.

## Gateway contract

Only use methods advertised by the connection: `push.native.register`, `push.native.status`, `push.native.unregister`. Register includes APNs token, topic, environment, local workspace ID, enabled state and the full mute/hidden exclusion list. No token or signing credential is logged or included in diagnostics.

Preference updates run serially; reconnect retries pending changes. An offline opt-out or mute cannot recall a push already sent by the gateway. The UI reports pending connection/sync status instead of claiming the remote setting took effect.

A successful status must report `registered`, `enabled`, and `configured` before Cast calls remote alerts ready. This is configuration readiness, not end-to-end delivery evidence. Apple outages, revoked permission and connectivity can still prevent delivery.

`push.native.status` additionally advertises `supportedKinds`. Cast reports reminder
readiness only when that list includes `reminder.due`. A missing list is compatible
with older task-only gateways, but does not imply reminder support.

Remote reminders preserve `openclaw.kind: task.completed` for older clients, add
`notificationKind: reminder.due`, and namespace the wire `runId` as
`reminder:<canonicalRunId>`. The same `gatewayDeviceId`, `workspaceId` and
`sessionKey` route the tap. Remote ledger identity remains
`completion:reminder:<canonicalRunId>` across app upgrades, so reminders neither
collide with ordinary tasks nor duplicate retained notifications. Local macOS
reminders use `reminder:<canonicalRunId>`. Reading the conversation removes
the exact matching reminder and completion notifications, including APNs-assigned
identifiers. macOS consumes the authenticated `notification.reminder` event locally
while running; iOS keeps APNs as its sole notification sender.

The supported reminder route is the agent tool's default `agentTurn` job in the
current conversation, plus isolated jobs that announce back to that source without
an explicit external destination. Explicit `main`/`systemEvent` and named-session
jobs are not converted into reminder notifications by this integration. An isolated
job with an explicit external destination and no source-conversation commit does
not also create a Cast reminder alert. A current-conversation job can commit its
result here and additionally deliver to an external channel.

## Public distribution prerequisite

The direct Gateway implementation requires a trusted operator to configure Apple
credentials authorized for Cast's bundle identifier and the app's APNs environment.
Do not distribute Cast's private Apple key to users or include it in this repository.
The production environment used by TestFlight cannot use a sandbox-only key.

A public, zero-credential-setup experience needs a Cast-operated relay with
installation verification and grants bound to the paired Gateway. OpenClaw's
official hosted relay accepts its own app, not Cast. The client routing support in
this repository does not constitute a deployed Cast relay or a working public push
service. Self-hosted source builds also need their own valid signing and delivery
configuration.

## Signing

The iOS entitlement `aps-environment` and Info key `CastAPNSEnvironment` use the same `CAST_APNS_ENVIRONMENT` build setting. The development default maps to APNs sandbox; distribution builds must explicitly set `CAST_APNS_ENVIRONMENT=production` with a compatible provisioning profile. Do not infer APNs environment from Debug/Release. Existing profiles without the entitlement cannot sign this capability.

## Verification boundary

Focused unit tests cover terminal filtering, visible-chat suppression, per-run replay/remote echo dedupe, mute/hidden behavior, unknown-workspace rejection, authenticated gateway URL binding, and explicit environment mapping. macOS app-host tests and an iOS Simulator build do not prove visible delivery to a locked physical phone. That requires a signed push-enabled build, configured gateway APNs credentials, permission on the target, and one real completion/tap test.

## Workspace aliases

One workspace owns task alerts for each Gateway on this device. Other aliases show that alerts are managed elsewhere and cannot replace mutes or unregister the owner during reconnect. Choose **Use this workspace for task alerts** to explicitly transfer ownership, including reclaiming a removed/stale workspace. The request compares the observed owner atomically; a concurrent owner change fails and requires another explicit action. Per-workspace opt-in flags do not claim that all aliases independently own delivery.
