# Source-first release checklist

This preview publishes buildable source, not signed app downloads. Do not change visibility
on the existing private development repository: its history, PRs and attachments are not the
public snapshot. Preserve that repository and publish only the audited clean-root candidate.

## Required source-preview gates

- [x] Apache-2.0 license, NOTICE, dependency inventory and bundled license texts.
- [x] No personal signing team; pinned package versions and documented prerequisites.
- [x] Privacy, support, security reporting, contribution and community-conduct documents.
- [x] Active source-scan, macOS test/Release and iOS Simulator Release CI workflow.
- [x] Personal connection details removed; captured fixture identifiers anonymized.
- [x] Internal diagnostics, historical investigation screenshots and marketing mockup excluded
  from the source export through `.gitattributes`; original private records preserved.
- [ ] Exact clean-root candidate passes fresh-clone build/test and source/metadata scan.
- [ ] Candidate archive/bundle hashes and verification receipt recorded privately.
- [ ] Jeff authorizes public publication of the exact verified candidate.

The operator's release packet records actual check results and source IDs. An installed older
build or checked box is not proof that a newly changed artifact passed.

## Publication procedure (only after authorization)

1. Preserve the private development repository. Import **only** the verified clean-root bundle
   into an empty public repository. Never push `--mirror` from the private development repo.
2. If retaining `jeffweisbein/cast` as the public URL, first rename the private repository to
   an agreed private archive name, then create the new repository at the existing URL. Keep
   its issues, PRs, artifacts and old branches private. Re-check permissions and integrations.
3. Push only the audited main branch and explicit preview tag. Enable free public private-
   vulnerability reporting, secret scanning/push protection where available, and required CI
   checks after the first successful run. The SECURITY.md email remains the reporting fallback.
4. Verify anonymous source/docs access, run CI on the imported commit, and compare its tree and
   archive hashes with the release receipt before announcing. Publish source-only release notes.

## Later binary launch (not source-preview blockers)

Notarization/Gatekeeper, signed Sparkle feed and real update testing; physical iPhone/iPad
acceptance and TestFlight/App Store review; public binary privacy disclosures and support
website; fresh screenshots and marketing; legal review of name/logo as appropriate.
See [release guide](releases.md). These are not implicitly verified by source checks.
