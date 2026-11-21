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

The packaged app comes from `3715813059a17f997c2c580e3fd24936b1fd9161`. Its final native
suite passed **676 tests, with no failures or skips**, on Xcode 27.1. macOS and iOS Simulator
Release builds passed. The publication commit adds documentation only; product source,
resources, dependencies, and build settings match that verified app revision.

The signed Mac package is checked independently for source/version metadata, nested
signatures, and its preserved vendor-signed Hex helper. Apple notarization, a stapled ticket,
Gatekeeper acceptance, and the published ZIP checksum are separate release checks.
Hosted CI results are available on the release pull request; the local suite is not a claim
about hosted CI or physical responsiveness on every Mac.

The native suite retained an existing SwiftUI test-fixture warning. An earlier attempt did
not finalize its result bundle; the completed serial run supplies the passing count above.
Physical feature acceptance and live gateway compatibility remain environment-dependent.
