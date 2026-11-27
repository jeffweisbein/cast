# Cast push relay

A small Cast-owned APNs relay for public Cast clients. Apple signing credentials remain on the operator's host, never on end-user OpenClaw gateways. Node 24+ with native HTTP2, crypto and SQLite; `node-app-attest` is pinned to 2.2.0. No framework, hosted database or paid service is required.

This service is a source candidate until deployed and tested with an actual production-signed Cast app. Local tests do not prove Apple attestation, APNs authorization, on-device display or cold-launch routing.

## Security / delivery model

- Only production App Attest for team `2Q694P9U2Y` and bundle `com.besttechie.cast`. No development/simulator bypass. App Attest proves a genuine team-signed app instance, not App Store purchase or distribution by itself.
- Random single-use 5-minute challenges; assertion covers exact decoded UTF8 bytes. Key counter, challenge consume and registration mutation are one SQLite transaction.
- Each 90-day registration is bound to installation+attested key+gateway Ed25519 identity. The relay stores the raw APNs token; gateway gets only an opaque handle and send grant. Only the hash of the grant is stored. A replacement revokes the old handle atomically.
- Gateway authenticates with the capability **and** a signature over exact body/timestamp/device ID. Timestamp skew limited to 5 minutes. No client-supplied APNs topic/credential/custom text. Only fixed generic task/reminder alerts are permitted.
- Explicit app-authenticated revocation persists across restart; APNs 410, `BadDeviceToken`, and `DeviceTokenNotForTopic` also disable registration. Already-dispatched/accepted Apple notifications cannot be recalled.
- Unique durable `(handle,idempotencyKey)` is claimed before provider I/O. Duplicate same-body sends return stored result; changed body returns 409. Pending/crashed/timeout sends remain unknown and are not retried. This is **at-most-once dispatch**, not guaranteed/exactly-once delivery. There is no retry outbox.
- Reminder expiration is original event + 24h; task alerts use APNs expiration 0. The relay refuses expired or >24h reminder windows. Deterministic APNs ID/collapse ID supports provider correlation; Apple acceptance is not display.
- Bounds: request 32KiB (send 8KiB/challenge 256B), APNs payload 4KiB, 128 inbound requests/connections, 8 provider requests, per-source/challenge/key/gateway/registration rate limits, capped persistent tables. Expired registrations/ledger and stale challenges/rate counters are pruned. Ledger entries persist until their registration expires; no replay window is reopened by truncating live entries.
- No request/proof/device-token/grant logging. Startup fails unless key and state are owner-only, owned by process UID and not symlinks. A LaunchAgent running as the operator is **not** an OS isolation boundary.

## Local verification

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm test
```

Tests use temporary SQLite files, generated ephemeral gateway/provider keys, synthetic AppAttest boundary proofs, and local HTTP/HTTP2 servers. One test exercises real AppAttest rejection of a forged attestation. Happy-path real Apple attestation remains a device acceptance step. Tests never contact Apple or send a real notification.

## Runtime configuration

Only these environment settings are needed:

| Name | Meaning |
| --- | --- |
| `CAST_RELAY_STATE_DIR` | Absolute dedicated 0700 persistent directory |
| `CAST_APNS_KEY_PATH` | Absolute owner-only 0600 production-capable `.p8` file |
| `CAST_APNS_KEY_ID` | Apple 10-character key identifier (not its value) |

Team, topic, production app-attestation policy and loopback port 19890 are fixed in source. Do not point production at the older sandbox-only Cast key. The `.p8` must stay outside the repository. Never put its content in shell arguments, logs, source or plist.

Start with `npm start` once configuration is supplied. `GET /healthz` proves the local HTTP process initialized its DB/key; it does not probe APNs or prove push delivery. `SIGTERM` stops accepting traffic and drains up to 15 seconds. Provider requests timeout after 10 seconds and retain an unknown delivery result.

`cast-push-relay.plist.example` is an operator template, not an installed job. Substitute absolute paths, create owner-only state/log directories, preserve existing LaunchAgents, run `plutil -lint`, then bootstrap only this job. A user LaunchAgent starts on user login; after-reboot unattended recovery is unverified until tested. Do not claim a dedicated-user boundary unless separately provisioned.

## HTTPS exposure on the existing host

Planned host: fubz. Existing private Tailscale 443→gateway 18789 must remain unchanged. Proposed separate route (not installed by this source):

```sh
/usr/local/bin/tailscale serve status --json
/usr/local/bin/tailscale funnel --bg --https=10000 http://127.0.0.1:19890
/usr/local/bin/tailscale serve status --json
```

Public relay origin: `https://jeffs-mac-studio-3.tail5db72b.ts.net:10000`. Verify Funnel policy authorization and external HTTPS reachability after applying the exact route. Never use `funnel reset`, repoint 443, or touch Forge's Banana 8443 service. Tailscale Funnel uses `.ts.net` names and bandwidth limits; no SLA/availability claim is made.

The service binds **only loopback** and ignores forwarded-address headers. Its socket-address abuse bucket is intentionally shared behind Funnel: all users together can obtain30 challenges/minute per proxy address. This conservative beta limit cannot be bypassed with forged `X-Forwarded-For`; authenticated-key, gateway and registration limits still apply independently. Public callers can exhaust this shared enrollment challenge quota, including fresh challenges needed for revocation; already-registered authenticated gateway sends have independent quotas and are not charged against it. This is a known low-volume beta availability limitation, not an internet-scale abuse-resistance claim. Higher-volume operation needs a separately verified trusted-proxy identity design and explicit capacity review. The endpoints do not use browser cookies or permissive CORS.

## API v1

`POST /v1/push/challenge {}` returns `{challengeId,challenge,expiresAtMs}`.

Register/revoke share outer `{keyId,attestationObject?,assertion,signedPayloadBase64}`; base64 proof encodings are standard padded base64. App assertion hashes the exact decoded signed payload bytes. First registration attestation hashes the UTF8 challenge string; subsequent operations reuse the stored attested key and require a higher assertion counter.

Register signed JSON:

```json
{"challengeId":"...","installationId":"UUID","bundleId":"com.besttechie.cast","environment":"production","apnsToken":"hex","gateway":{"deviceId":"SHA256-hex","publicKey":"Ed25519-base64url"}}
```

Reply `{status:"registered",relayHandle,sendGrant,expiresAtMs,tokenSuffix}`. Renew before expiry or token/gateway changes. Revoke signed JSON `{challengeId,relayHandle,action:"revoke"}`; only the owning attested key may revoke an existing handle. For an already-pruned handle, an existing attested key may acknowledge its absence with a fresh challenge/assertion; this consumes the assertion counter and challenge without granting ownership or creating a registration.

Send body is `{relayHandle,pushType:"alert",priority:10,payload,idempotencyKey,expiresAt}`. Payload:

```json
{"aps":{"alert":{"title":"Cast reminder","body":"Your reminder is ready. Tap to view."},"sound":"default"},"openclaw":{"kind":"task.completed","notificationKind":"reminder.due","gatewayDeviceId":"...","workspaceId":"...","sessionKey":"...","runId":"reminder:..."}}
```

Task variant omits `notificationKind`, title `Cast task complete`, body `Your task is ready. Tap to return.`; expiration 0. Reminder expiration epoch seconds original commit+86400. Routing fields disallow control characters (workspace 128/session 1024/run 512 characters).

Idempotency SHA256 of `[gatewayDeviceId,relayHandle,workspaceId,sessionKey,runId].join("\n")`. Required headers:

- `authorization: Bearer <sendGrant>`
- `x-openclaw-gateway-device-id`
- `x-openclaw-gateway-signed-at-ms` (epoch milliseconds)
- `x-openclaw-gateway-signature` (Ed25519 base64url)

Signature covers UTF8 `openclaw-relay-send-v1\n<deviceId>\n<signedAtMs>\n<exact raw JSON body>`.

Response `{ok,status,reason?,apnsId?,environment:"production"}` uses Apple status, with status 0 for pending/unknown. HTTP 200 with `ok:false,status:0` is **not** provider acceptance. Send protocol/auth errors use their own HTTP 4xx/5xx with `{ok:false,status,reason,environment:"production"}`. Registration/challenge/revocation errors use HTTP 4xx/5xx and short secret-free `{error}` codes. An explicit send 401/`RegistrationUnavailable` means renew the registration; an unrecognized/malformed response is not definitive invalidation.

## Deployment acceptance still required

Verify immutable source/version and dependency lock; run tests; review security boundaries; inspect/backup existing routing/service state; use the production Apple credential only on the relay host; verify health/external TLS and independent auth rejection. Then a signed Cast iPhone must attest/register, the compatible gateway must report a valid relay binding, and a user-requested reminder must produce a background notification whose cold tap returns to the original workspace/session. Record provider acceptance, display and user confirmation separately. Revoke and retry must stop new sends. No source test substitutes for these checks.
