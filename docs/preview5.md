# Cast 0.4.0 preview 5

Preview 5 brings the current chat-switching improvements and results interface to the
public Mac download. The app reports **0.4.0 (20)**; the preview tag identifies this public
release separately from the app's build number.

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

## Download and update

Download the signed, Apple-notarized [Mac ZIP](https://github.com/jeffweisbein/cast/releases/download/v0.4.0-preview.5/Cast-0.4.0-preview.5-macOS-arm64.zip),
quit Cast, unzip it, and replace Cast.app in Applications. Keep your previous app if you
want a rollback copy. Do not delete Cast's settings or app data. Manual downloads remain
the update route; an automatic-update feed is not configured.

This download targets Apple Silicon Macs running macOS 15 or newer. A reachable OpenClaw
gateway is still required. This release does not add a public iPhone/iPad download or
change TestFlight availability.

## Verification and source mapping

The Mac package includes the results design and a compatibility fix for macOS 15: staged
transcript expansion explicitly reapplies the latest-message position while following is
active. It stops doing so when the reader scrolls away or starts a search. The same native
regression failed on the unchanged source and passed with the fix on macOS 15.6.1; no
assertions or timing thresholds were removed.

The release notes record the exact embedded source revision and final native test/build
results. Publication also refreshes XcodeGen 2.47's project/scheme upgrade metadata and
explicit default architecture selection; target build settings are unchanged.

The signed Mac package is checked independently for source/version metadata, nested
signatures, and its preserved vendor-signed Hex helper. Apple notarization, a stapled ticket,
Gatekeeper acceptance, and the published ZIP checksum are separate release checks.
Hosted CI results are available on the release pull request; the local suite is not a claim
about hosted CI or physical responsiveness on every Mac.

Native warnings remain documented separately from successful checks. Physical feature
acceptance and live gateway compatibility remain environment-dependent.
