# Failure-to-regression workflow

Use existing test runners, release tooling and Product Quality Graph (PQG), not a new orchestrator or duplicate failure ledger. Only add checks supported by a real failure or a concrete reproduced boundary case.

1. Record the observed failure, expected behavior, exact candidate/artifact and existing intake/occurrence ID. Scope each remedy to the owning repository or tool; a one-off workaround is not a universal rule.
2. Reproduce the original case. Prefer the smallest deterministic test or existing release check over more prompt text. If replay is unsafe or unavailable, explicitly record **cannot replay**, not proven.
3. Watch the regression test fail on the old behavior, then pass after the fix. A rejection gate must also accept a known-valid case. Preserve both outputs and artifact hashes; a mocked integration test is not a physical desktop or signature check.
4. Run relevant existing checks. Store bounded evidence under the exact PQG occurrence with `intake-verify`; this proves reproduction, not user confirmation or a shipped fix. Use `intake-resolve` only for an actual named confirmation on that occurrence.
5. Keep the final source, tested, packaged, installed and user-confirmed states separate. Do not infer one from another. When a failure recurs, first reconcile installed version and source before judging the safeguard ineffective.
6. Review false positives and obsolete checks when the relevant tool/model changes. Don't automatically remove permission boundaries, alter budgets, add approval stops or create scheduled jobs.

## Commands

```sh
# Fast offline contract/regression suite; required by the Mac release entry point.
sh Scripts/verify-regressions.sh

# Read-only package check; expected values come from the intended release, not the package itself.
python3 Scripts/verify_mac_package.py /path/to/Cast.app \
  --version 0.4.0 --build 8 --source 743502253ab8 --team YOURTEAMID \
  --receipt /path/to/new-package-receipt.json
```

The package gate checks metadata, required bundled components, Sparkle's resource seal, Hex's original Apple-anchored vendor identity, Cast's expected team/identifier, and executable/adapter hashes. It cannot notarize, install, record microphone audio, or grant Accessibility permission. Receipt files refuse overwrite. The release runner preserves failed package receipts, checks staged hashes before replacing an app, verifies the destination and rolls back on destination failure.

## Proven cases — 2026-11-01

PQG intake **284**, occurrence **286**, finding **598** tracks this improvement; original integration intake **283** / occurrence **285** remains separate and unconfirmed. These references link to the existing ledger; this document is the test map, not a recurrence counter.

| Case | Executable check | Evidence and limits |
| --- | --- | --- |
| Original unsigned-build Sparkle seal mismatch | `verify_mac_package.py` | Actual retained Oct31 package rejected for Sparkle's missing sealed resources; actual signed M3 0.4.0(8) package accepted, Hex hash unchanged. No package was modified by replay. |
| Failed reinspection left old controls usable | `test_failed_reinspection_cannot_reuse_previous_refs` | New deterministic reproduction failed against the previous adapter; passes after clearing refs before reinspection. This is a reproduced code defect, not a claim the previous UI timeout delivered an unintended click. |
| Mutation times out after uncertain delivery | `test_uncertain_action_preserves_disposition_and_forces_observation` | Preserves `delivered_unverified`/`retry: unsafe`; a repeated mutation is refused until observation. CLI behavior is a fixture, not a live app action. |
| Access revoked during inventory or an owned subprocess | Desktop bridge race/process tests | No subsequent mutation; actual task-owned subprocess terminates. Does not claim already delivered actions are undone. |
| Invalid candidate/staged/destination package | Release preflight integration tests | Mocked package verifier rejects before replacement, or restores previous app on destination failure. Valid fixture install writes a distinct installation receipt without claiming user acceptance. |

Full receipts: operator task evidence directory `cast-guard-replays-20261101`. Native Swift tests, real audio, UI-created session revocation and microphone hardware acceptance remain separately scoped checks in [local-dictation-and-desktop.md](local-dictation-and-desktop.md).


## Video attachments

The iOS **Photos & Videos** picker imports movies through a file representation, not an image preview. Files and the Photos share extension use the same preparation path. Videos at or below 16 MiB retain their original bytes; larger clips are exported to MP4 at 720p, then 480p if necessary, without modifying the source. The final per-file and aggregate frame limits still apply. A clip that cannot fit asks the user to trim it. Cancelled imports and imports whose workspace/conversation changed do not enter the current draft.

`VideoAttachmentTests` uses a synthetic one-second MP4 with audio to verify byte-preserving RPC payloads, a playable bounded export with audio, source preservation, corrupt media rejection and cancellation. The large-input test pads the valid movie beyond the transport limit; it exercises export and limits, not real-world long-video quality. Physical Photos/iCloud selection and end-to-end agent interpretation remain separate acceptance checks.

## Chat switching

`ChatSwitchPerformanceTests` exercises the production `ChatStore` selection path with
synthetic offline transcripts. Warm text-only opens reuse the existing five-session MRU's
prepared display rows and do not reload/reconcile the older disk snapshot. Live gateway
refreshes and subscription ordering are unchanged. Media-bearing snapshots still strip
image bytes and rehydrate from disk; render state is not retained for those snapshots.

The tests cover immediate prepared-row reuse, zero redundant disk publication, rapid
A/B/A selection, local image recovery, display-mode changes, invalidation after a transcript
rewrite, and eviction of render/media metadata. The warm-open fixture has 1,000 messages;
its elapsed measurement includes the test's settling poll and compares app-model behavior,
not physical click-to-paint latency. Native macOS/iOS builds and installed-device acceptance
remain separate evidence. PQG intake 400 / occurrence 402 tracks the original report.

### macOS render stall on switch

The warm model path above did not change what the reader saw. The installed build's
always-on main-thread watchdog recorded 1.5–2.2 s stalls on nearly every switch, with no
`ChatStore` work inside the stall, and an external sample placed the time in
`NSHostingView.layout`. macOS renders the transcript as an eager stack, so each switch
instantiated and laid out the whole 200-row window, cached or not.

`ChatSwitchRenderLatencyTests` hosts the production `ChatView` in a window and rotates
through seven synthetic 1,500-message conversations (more than the five-entry snapshot
cache, so warm and evicted opens are both covered), then flips between two warm chats. It
measures main-thread unavailability after each programmatic selection with the same
technique as the watchdog. The eager transcript now opens on a 16-row tail window and grows
back to the normal 200 rows in bounded steps, only while the reader follows the tail and is
not using the keyboard or pointer; another selection, scrolling away or a search cancels
growth. The window is keyed to the selected conversation so a cached chat never inherits
the previous chat's full-size window for its first frame. iOS keeps its lazy transcript and
full initial window.

Regressions cover first-frame-before-full-window for warm and evicted opens, growth back to
the normal window with the newest row still in view, growth waiting for reader input,
selection during growth, and the window arithmetic (`TranscriptWindowTests`). These are
hosted-view timings of a Debug build with synthetic content: not a physical click, not a
display refresh, and not installed-device acceptance. PQG intake 405 / occurrence 407
tracks this report.
