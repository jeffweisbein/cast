> **Historical binary-readiness record (July 2026).** These are not current source-preview gates or proof for the latest candidate. See [source release checklist](open-source-release-checklist.md) and the exact release receipt.

# Cast public-testing readiness

Updated 2026-07-22. This separates repository evidence from work that still requires a signed archive, physical devices, or App Store Connect. Unchecked items are not claimed complete.

## Completed in code

- [x] Versioned first-run onboarding explains what Cast is, its OpenClaw prerequisites, setup-code/approval workflow, direct-gateway model, Keychain credential storage, and local transcript caching.
- [x] Fresh public installs do not include developer-specific workspaces. Saved user-created profiles remain available and migrate past onboarding without being trapped.
- [x] Existing setup-code/bootstrap and advanced gateway-token paths remain the only pairing implementation. Setup codes validate structure, expiry, and transport safety before Keychain storage.
- [x] Pairing remains visible through connecting, approval, authentication/reachability recovery, and a verified `.connected` success state. Raw gateway errors are not shown in the onboarding UI.
- [x] Setup can be deferred, reopened from the empty state or workspace menu, and used to add another workspace.
- [x] The onboarding UI uses semantic text styles, scrollable/flexible layouts, system controls, VoiceOver labels/headings, and no essential animation; it adapts between compact and regular widths.
- [x] Bundle IDs are `com.besttechie.cast` and `com.besttechie.cast.share`. Both iOS targets declare App Group `group.com.besttechie.cast`; only non-secret share destinations and queued share payloads cross that boundary.
- [x] Credentials/device identity remain in Keychain with this-device-only accessibility. The app and Share Extension versions resolve from the same marketing/build settings.
- [x] iOS declares camera use for QR scanning and local-network use for direct LAN gateway connections. QR setup retains a paste fallback when scanning is unavailable.

## Automated/local evidence

- [x] macOS unit tests: 112 executed, 0 failures.
- [x] Universal unsigned macOS build: arm64 and x86_64 succeeded.
- [x] Generic unsigned iOS Simulator build: arm64 and x86_64 succeeded; `CastShareExtension.appex` was embedded and validated.
- [x] Generated app and Share Extension metadata both report marketing version `0.1.0`, build `2`; the app includes its local-network privacy description.
- [x] A fresh install on an iPhone 17e Simulator launched directly into the first onboarding page with no private workspace names visible.
- [x] `git diff --check`, plist lint, and final diff review completed cleanly.

Unsigned simulator builds prove compilation and embedding only; they do not prove distribution entitlements or TestFlight readiness.

## Remaining manual, device, and App Store Connect gates

### Signing and identifiers

- [ ] Install or access a valid Apple Distribution certificate and Xcode-managed distribution profiles. `security find-identity` currently reports 0 valid code-signing identities and this host has 0 provisioning profiles.
- [ ] In the Apple Developer portal, verify App IDs `com.besttechie.cast` and `com.besttechie.cast.share`, attach both to `group.com.besttechie.cast`, and confirm generated distribution profiles contain the App Group entitlement.
- [ ] Produce a Release archive for a generic iOS device, run Validate App, upload it, and confirm App Store Connect processing succeeds.
- [ ] Confirm the iOS 26.0 minimum is intentional for the external tester pool.

### Physical iPhone acceptance

- [ ] Clean install: onboarding presentation, defer/reopen behavior, setup-code paste, QR scan, invalid/expired code recovery, unreachable gateway recovery, and approval-required flow.
- [ ] Connected use: history load, send/receive/stream, cross-device refresh, background/foreground reconnect, and offline retry.
- [ ] Attachments: PhotosPicker with camera-roll, iCloud-only and HEIC assets; Files; memory pressure; cancellation during import.
- [ ] Share sheet: text/URL/photo/file handoff through the distribution-signed App Group into the selected workspace/session.
- [ ] Accessibility: VoiceOver reading/order/actions, largest Dynamic Type sizes, Reduce Motion, portrait/landscape, and compact/regular size classes.

### Privacy, support, diagnostics, and review

- [ ] Publish working privacy-policy and support URLs, then add them to App Store Connect. The privacy policy must cover direct gateway traffic, local transcript/media caches, Keychain credentials, link metadata fetching, PhotosPicker-selected content, and Share Extension handoff.
- [ ] Audit required-reason API usage and dependencies, add/validate privacy manifests as required, inspect the archive privacy report, and complete App Privacy answers from observed behavior.
- [ ] Provide TestFlight beta description, “What to Test,” feedback email/contact, review notes, and export-compliance answers.
- [ ] Give Beta App Review a reviewer-accessible OpenClaw gateway strategy and reliable fresh setup-code/approval instructions; setup codes can expire.
- [ ] Define the tester feedback path (TestFlight feedback plus visible support contact), verify Organizer/App Store Connect crash collection, and document how testers can export an iOS analytics `.ips` when requested.
- [ ] Submit the build and tester group for external Beta App Review, wait for approval, then verify invitation/install with a non-team Apple ID.

### Known configuration decisions

- [x] Removed the historical host-specific ATS exception. Only Apple's local-network allowance remains for direct LAN gateways.
- [ ] If macOS will also be distributed publicly, enable and validate Hardened Runtime, signing, notarization, and update delivery; the current macOS target is a local-development build.
