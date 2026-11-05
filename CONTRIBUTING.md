# Contributing to Cast

Cast is a source-first developer preview. Focused bug reports, documentation improvements and tested fixes are welcome.

## Development setup

You need a Mac with the Xcode 26.3 or newer, XcodeGen, and an OpenClaw gateway for live integration testing.

```sh
brew install xcodegen
Scripts/generate-project.sh
xcodebuild -project Cast.xcodeproj -scheme Cast-macOS build CODE_SIGNING_ALLOWED=NO
```

The iOS app can be compiled without a personal signing team:

```sh
xcodebuild -project Cast.xcodeproj -scheme Cast-iOS \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

Run the macOS-hosted test suite with:

```sh
xcodebuild -project Cast.xcodeproj -scheme Cast-macOS \
  -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

## Pull requests

- Keep changes focused and match the existing Swift and SwiftUI conventions.
- Regenerate `Cast.xcodeproj` after changing `project.yml`: `GIT_COMMIT_SHA=development Scripts/generate-project.sh`. Commit the generated project with that neutral marker; the build wrapper embeds the actual clone revision.
- Add the smallest useful regression test for behavior changes.
- Run `git diff --check`, the relevant tests, and both platform builds when practical.
- Describe user-visible behavior, verification evidence, and any untested device-specific path.
- Never commit gateway credentials, setup codes, transcripts, personal hostnames, provisioning profiles, or screenshots containing private conversations.

## Security issues

Do not open a public issue for a suspected vulnerability. Follow [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contribution is licensed under the Apache License 2.0.

## Your own iOS signing configuration

No signing team is committed. To install on your iPhone, choose your team and register unique
bundle IDs for the app and share extension. Update `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`
for both targets), both `Support/*.entitlements` App Group entries, and
`CastAppGroup.identifier` in `Sources/ShareSupport/ShareBridge.swift` to the **same registered
App Group**. Regenerate the project. Keep that local signing customization out of unrelated PRs.
The default identifiers belong to the upstream app; an unrelated team cannot provision them.

## Checks

Run `sh Scripts/verify-regressions.sh`, macOS tests and the generic iOS Simulator build.
CI uses a fresh package checkout and does not need a live gateway, signing secrets, Hex or
Agent Desktop. Never run destructive integration checks against other people's workspaces.
