# Current source updates

The source now includes chat-switching, results-review, iOS navigation and compact typing
improvements. The validated native build reports **0.4.0 (21)**. This source update does
not publish preview 5 or a new downloadable app.

## Changes

- Reuse prepared transcript rows when returning to a conversation, while preserving live
  refreshes, image recovery, and the bounded conversation cache.
- Show the newest messages first on Mac, then grow the transcript window in bounded steps
  when the reader is not scrolling or typing.
- Read conversation work states in the sidebar and review available results in the chat.
- Open a result-review inspector without losing the conversation; stable artifact identities
  keep the selected result attached to the correct gateway artifact.
- Keep the shared Mac inspector width stable after its initial expansion, including when
  switching between main and side chats.

- Navigate between Chats, Needs You and Results on iOS, with pinned-chat switching and
  attachment/model controls that preserve the selected conversation and draft.
- Use the compact composer and direct Hide Keyboard action; routine chat chrome collapses
  for a docked software keyboard while pending actions and connection problems stay reachable.

## Downloads

The published Mac binary remains [preview 4](https://github.com/jeffweisbein/cast/releases/tag/v0.4.0-preview.4),
**0.4.0 (17)**, for Apple Silicon Macs running macOS 15 or newer. It does not include all
of these source updates. [Build current source](../CONTRIBUTING.md) to use the newer code.
A reachable OpenClaw gateway is required for live use. No public iPhone/iPad download or
TestFlight availability is introduced by this source update.

## Verification

The installed-source revision `5ec9308b70eaf5f70707d08b80bfc3bb0a42de8f` passed 729 native
macOS tests with no failures or skips. Final targeted simulator UI runs passed five checks
on the Duo cover layout, five on iPad and three on Air. Source reviews and signed private
build verification are separate from hosted CI, public binary distribution and physical
folding, hardware-keyboard or voice-gesture acceptance.

The macOS transcript-growth regression reproduced on unchanged source and passed after the
native scroll-frame fix on macOS 15.6.1. Synthetic fixtures and simulator checks do not
establish responsiveness or hardware behavior on every device. The public pull request
records hosted checks for the published source revision.
