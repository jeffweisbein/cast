# Human question cards

Cast renders OpenClaw `question.requested` records as native cards, separate from
execution approvals and secure credential entry. Answers are sent through
`question.resolve`, never as chat messages.

## Enabling

Open **Questions** in the conversation toolbar (or **Needs you → Questions and
question-card settings**) and enable question cards for this workspace. Existing
paired devices may require Gateway approval for the additional
`operator.questions` scope. Cast does not approve its own permission or request
operator.admin. Setup-code bootstrap scopes are unchanged. Secure entry retains
its separate opt-in; enabling questions does not enable secret entry.

## Behavior

- Pending questions appear inline in the owning conversation and in the workspace
  Questions inbox / Needs you. Requests without a session key remain in the inbox.
- Single-select, multi-select, free-text-only and optional Other answers follow
  the canonical question schema. No default is selected, including recommended
  options. Every required question must have an answer before explicit submit.
- Drafts survive view/session changes and socket reconnects in memory for the
  same workspace. They are not saved to disk or included in chat history. Quitting
  the app or replacing the workspace discards them.
- While submitting, controls are locked against double submits. A lost response
  keeps the draft and the original resolutionId. An explicit retry sends the same
  answer with the same correlation identifier; this is not a server-side
  idempotency guarantee. The Gateway rejects resolution of a terminal question,
  and Cast refreshes its status instead of claiming this client supplied the
  recorded answer. Reconnect does not submit anything.
- `question.list` recovers currently pending requests after reconnect;
  `question.get` reconciles known missing requests and uncertain acknowledgements.
  A confirmed pending
  state unlocks editing. Changed answers receive a fresh resolutionId.
- Answered (including another client), cancelled, expired and unavailable records
  stop accepting input. Expiry also updates Needs you without opening a card.
  An authoritative terminal record can correct local clock expiry after reconnect
  without reviving a pending replay or a dismissed card.
- Secret or store-bound records never enter ordinary cards, even in mixed batches.
  The metadata decoder never retains returned answers. URLs are displayed only
  as explicit http/https reference links.

## Verification

`QuestionRequestTests` and `QuestionEventTests` exercise schema handling, selection,
custom text, deduplication, session routing, secret separation, expiry, replay,
reconnect draft retention and uncertain acknowledgement retries. Full macOS tests
and both platform builds remain separate from live Gateway/physical-device
acceptance. UI snapshots render production cards with fictional offline data;
they do not establish delivered keyboard/VoiceOver or live submission acceptance.
