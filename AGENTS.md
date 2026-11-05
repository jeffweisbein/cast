# Cast verification map

- Release entry point: `Scripts/release.py`; packaging and acceptance: [docs/releases.md](docs/releases.md).
- For release scripts or `Sources/Resources/cast-desktop.py` changes, run `sh Scripts/verify-regressions.sh`. Native source changes still require the appropriate Xcode tests/builds; these Python checks do not replace them.
- Mac delivery must pass `Scripts/verify_mac_package.py` on the exact signed package and staged copy before replacement. Preserve Hex's upstream signature; never use recursive signing to hide a failed component.
- Replay failures before claiming a safeguard works; retain negative and positive receipts. See [docs/verification.md](docs/verification.md).
- Link reports, recurrence and proof to the existing Product Quality Graph occurrence. Do not add a second failure ledger or mark a report user-confirmed based on tests.
- A desktop observation timeout is not proof of a hung app or a failed action. Preserve disposition, invalidate stale controls, observe again, and do not blindly retry mutations.
- Keep source/test/package/install/user-confirmation states distinct. Never reuse a prior release's receipts as proof of a changed artifact.
