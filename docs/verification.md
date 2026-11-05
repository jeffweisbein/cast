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
