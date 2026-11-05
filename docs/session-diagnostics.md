# Session diagnostics — Cast 0.3.1 / build 6

Open **Status & updates** from the sidebar with a conversation selected.

## What the fields mean

- **Context · last reported:** Gateway `sessions.list` usage/window counts, not billing or remaining subscription quota. The count can lag during an active run or while offline. An explicit `totalTokensFresh: false` is shown as stale, never as a current percentage. Missing/invalid fields show “not reported.”
- **History:** The current refresh state. Saved messages remain readable if refresh fails. **Refresh conversation** only reloads history/session metadata; it does not rerun the agent or resend a message.
- **Unconfirmed sends:** Counts uncertain-delivery messages in the currently loaded transcript, not all gateway history. Review the conversation and Needs you before retrying: completed side effects cannot be undone by a retry. Existing exact-payload/manual-retry behavior is unchanged.
- **Compaction:** Operations observed during this app session. Confirmed completion, no-op/non-completion, and unconfirmed results are distinct. Disconnects, background suspension and sequence gaps invalidate an in-progress observation. No recorded operation does not mean compaction has never happened.
- **Most recent observed failure:** A timestamped past event, not proof the conversation is still failing. Dismissing an error does not erase this diagnostic. Records are in-memory and bounded to 100 sessions per store; restarting the app clears them.

## Failure handling

The existing `errorKind` remains authoritative when recognized. If missing/unknown, Cast uses the gateway's structured `errorDetail.providerRuntimeFailureKind`, `failoverReason`, and selected HTTP statuses. Unknown or malformed detail falls back safely without dropping the terminal event. Provider error previews and raw error messages are never included in the new diagnostic output. A late failure for an already-answered run stays suppressed.

Model-access/version problems direct you to the conversation model picker or gateway administrator. Provider authentication is explicitly different from Cast device pairing. Cast does not change provider billing or replay requests automatically.

Compaction is offered only if `sessions.compact` is advertised. Its RPC is bounded at 120 seconds and cannot be duplicated locally while in flight. A timeout does not prove the server stopped compacting, so the outcome is shown as unconfirmed. An RPC that reports `compacted:false` is not labeled successful compaction. No session reset/history deletion is used for recovery.

## Compatibility and privacy

Uses existing gateway payloads: `sessions.list`, `chat.errorDetail`, and `session.operation` (`operationId`, `operation:compact`, `phase:start|end`, `sessionKey`, `completed`, `ts`). Gateways that do not emit operation events simply have less observational detail; Cast does not infer unobserved events. Unknown fields remain compatible.

The shareable connection summary includes counts and fixed failure/operation labels, not session titles, prompts, file paths, credentials, or provider error previews. It is sent only when the user chooses a share destination.

Verified with decoding/reducer/store regressions and Mac/iOS simulator builds. Physical Mac/iPhone interaction and real network-transition acceptance are not certified by these checks.
