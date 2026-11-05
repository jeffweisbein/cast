# Building, installing, and releasing Cast

Source publication and signed binary distribution are separate. These tools do not publish source or releases, configure a hosting provider, or store credentials. The signed update feed is deliberately unset until an operator chooses its hosting and signing key. A successful unsigned CI build is **not** an installable release.

## Daily Mac install

Install Xcode and XcodeGen; add your Apple account in Xcode Settings and create an **Apple Development** certificate for your team. Pull main, keep the checkout clean, and quit Cast. Then:

```sh
python3 Scripts/release.py install-mac --version 0.4.0 --build 8 --team YOURTEAMID --hex-app /Applications/Hex.app
```

Use your actual 10-character team ID and increment the build for subsequent releases. The script verifies a valid identity before building, verifies the signature and version/source metadata, preserves the previous app under `~/Applications/Cast-backup-<timestamp>.app`, and installs to `~/Applications/Cast.app`. It does not modify pairing data. It will not replace a running app or fall back to ad-hoc signing. Restore a previous app by quitting Cast and moving the preserved copy back in Finder. Use the same team consistently to retain Keychain access.

## Notarized Mac ZIP

Configure a **Developer ID Application** signing identity and a `notarytool` Keychain profile through Apple's secure setup, outside chat. Generate a Sparkle Ed25519 key with the dependency's `generate_keys` tool; its private key stays in Keychain. Supply only its **public** key to builds.

```sh
python3 Scripts/release.py mac --version 0.4.0 --build 8 --team YOURTEAMID --hex-app /Applications/Hex.app --notary-profile cast-notary
```

This archives with hardened runtime, exports a signed app, submits it to Apple, staples and validates the ticket, checks Gatekeeper, and creates the final ZIP in `build/`. Omitting `--notary-profile` creates a signed review archive explicitly marked **not ready for distribution**. Release artifacts are never uploaded automatically.

### Sparkle updates

Build with `--feed-url` (a public HTTPS appcast URL without authentication parameters) and `--update-public-key` (the public Ed25519 key). Both must be present. The app enables **Check for Updates** only for a valid configuration. Automatic checks/downloads default off. Sparkle verifies update signatures; keep the private key in Keychain and preserve it for future releases.

Sparkle's binaries live under the build's `DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`. Put notarized ZIPs and same-basename `.md` release notes in a dedicated feed directory. Run `generate_appcast` against that directory, with its documented `--download-url-prefix` option pointing at your chosen HTTPS artifact location. Inspect the generated URLs, signatures, minimum OS requirements, and release notes before publishing. Preserve existing feed entries; never replace a stable feed with an empty one. Verify a real update from the previous signed version to the new one before enabling background checks.

A private GitHub repository does not by itself provide a public Sparkle feed. Feed hosting and distribution audience are separate decisions from open-sourcing Cast. No feed or signing keys are provisioned by this change.

## iPhone / TestFlight

Configure an **Apple Distribution** identity, matching provisioning, and the Cast app record in App Store Connect. Confirm both app and share-extension bundle IDs and their shared App Group belong to the team. Xcode uses its own signed-in account; never pass account passwords, pairing tokens, or signing secrets to these scripts.

```sh
python3 Scripts/release.py ios --version 0.3.0 --build 5 --team YOURTEAMID
```

Inspect the exported archive first. On a new build number, add `--upload-testflight` to explicitly upload through Xcode's stored account. Upload completion is **not** proof that Apple processing or beta review passed. Check processing, compliance, tester group assignment, and installation in App Store Connect/TestFlight. No new tester invitations are sent by this script.

## Release acceptance

Mac release commands require a vendor-signed Hex.app, run the focused regression suite, embed Hex without changing its signature, then re-seal only the outer app. The mandatory package verifier checks Sparkle, Hex's vendor identity, Cast's team and candidate metadata. An invalid component stops delivery; it is not silently repaired or recursively re-signed. The staged and installed packages are independently checked, and destination failure restores the old app. Separate JSON receipts distinguish artifact validation from installation; neither implies user confirmation, live microphone acceptance or notarization. See [verification.md](verification.md) for replay commands and existing quality-tracker links.

- Mac unit tests and iOS Simulator build pass.
- Both platforms show version, build, gateway capability status, and accurate model labels.
- A real device connects, streams, resumes, and retains pairing after a signed update.
- Needs you approvals preserve exact gateway decisions; hiding a chat cannot suppress an approval.
- Model changes affect only their selected session and do not interrupt an existing run.
- Deliverables opens a local file, downloads a generated artifact through artifacts.download, validates size, and reports plain filesystem links separately from downloadable attachments.
- Transcript filesystem links use the session-scoped document sheet, never macOS/iOS's raw file-URL opener. Verify a text link downloads on a remote client, an attached PDF previews locally, and a plain gateway PDF link explains that an attachment is required. The gateway's text/image preview API is not a general binary download API.
- Mac ZIP passes signature, notarization and Gatekeeper checks; test Sparkle from a prior signed version.
- TestFlight processing and physical iPhone smoke test pass before declaring iOS shipped.

Signed installation, notarization, real Sparkle updates, and TestFlight are separate, artifact-specific gates. An earlier signed developer installation does not prove a new public binary is ready.
