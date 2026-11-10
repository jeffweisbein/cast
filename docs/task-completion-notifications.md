# Task completion notifications

## Behavior

- Only live `chat` events with `state: final`, a run ID and session key, and neither `yielded` nor `transcriptOnly` notify. Message/progress events only update unread accounting.
- The persistent notification ledger deduplicates each workspace/run. Muted and hidden chats suppress alerts. The visible conversation suppresses foreground alerts.
- macOS uses local notifications while Cast remains running and connected, including when another app is active.
- iOS uses only Apple remote notifications (never a local fallback while remote setup is pending or fails), so it does not keep its socket alive while suspended. Enable **Notify me when tasks finish** in the workspace Notification Center. Apple permission alone does not mean delivery is configured.
- Lock-screen copy is generic. A tap can navigate only to a configured workspace. Remote payloads must match a gateway identity learned from an authenticated status response for that exact workspace URL. Session access is still checked by the gateway.

## Gateway contract

Only use methods advertised by the connection: `push.native.register`, `push.native.status`, `push.native.unregister`. Register includes APNs token, topic, environment, local workspace ID, enabled state and the full mute/hidden exclusion list. No token or signing credential is logged or included in diagnostics.

Preference updates run serially; reconnect retries pending changes. An offline opt-out or mute cannot recall a push already sent by the gateway. The UI reports pending connection/sync status instead of claiming the remote setting took effect.

A successful status must report `registered`, `enabled`, and `configured` before Cast calls remote alerts ready. This is configuration readiness, not end-to-end delivery evidence. Apple outages, revoked permission and connectivity can still prevent delivery.

## Signing

The iOS entitlement `aps-environment` and Info key `CastAPNSEnvironment` use the same `CAST_APNS_ENVIRONMENT` build setting. The development default maps to APNs sandbox; distribution builds must explicitly set `CAST_APNS_ENVIRONMENT=production` with a compatible provisioning profile. Do not infer APNs environment from Debug/Release. Existing profiles without the entitlement cannot sign this capability.

## Verification boundary

Focused unit tests cover terminal filtering, visible-chat suppression, per-run replay/remote echo dedupe, mute/hidden behavior, unknown-workspace rejection, authenticated gateway URL binding, and explicit environment mapping. macOS app-host tests and an iOS Simulator build do not prove visible delivery to a locked physical phone. That requires a signed push-enabled build, configured gateway APNs credentials, permission on the target, and one real completion/tap test.

## Workspace aliases

One workspace owns task alerts for each Gateway on this device. Other aliases show that alerts are managed elsewhere and cannot replace mutes or unregister the owner during reconnect. Choose **Use this workspace for task alerts** to explicitly transfer ownership, including reclaiming a removed/stale workspace. The request compares the observed owner atomically; a concurrent owner change fails and requires another explicit action. Per-workspace opt-in flags do not claim that all aliases independently own delivery.
