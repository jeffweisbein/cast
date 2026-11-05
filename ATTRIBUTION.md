# Attribution and dependency inventory

Cast-owned source is Apache-2.0; dependencies keep their own licenses. Full license texts
are in `Sources/Resources/ThirdParty` and are included as app resources by XcodeGen.
This inventory corresponds to `Package.resolved`, not arbitrary future dependency versions.

| Component | Version | Terms / notice |
| --- | --- | --- |
| OpenClawKit-derived gateway connection code | adapted source | MIT; OpenClawKit-LICENSE.txt; Copyright (c) 2025 Peter Steinberger |
| Sparkle | 2.9.6 | MIT plus bundled external notices; Sparkle-LICENSE.txt |
| MarkdownUI | 2.4.1 | MIT; swift-markdown-ui-LICENSE.txt |
| NetworkImage | 6.0.1 (transitive) | MIT; NetworkImage-LICENSE.txt |
| swift-cmark | 0.8.0 (transitive) | BSD/MIT and included component notices; swift-cmark-LICENSE.txt |
| HighlightSwift | 1.1.0 | MIT; HighlightSwift-LICENSE.txt |
| Highlight.js | 11.9.0 (inside HighlightSwift) | BSD-3-Clause; HighlightJS-LICENSE.txt |

Upstream sources and exact revisions are recorded in
`Cast.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
OpenClawKit originates at https://github.com/openclaw/openclaw/tree/main/apps/shared/OpenClawKit.
Highlight.js license source: https://github.com/highlightjs/highlight.js/blob/11.9.0/LICENSE.

## Optional local tools — not shipped in the source snapshot

- [Hex](https://github.com/anomalyco/hex): independently installed, vendor-signed helper.
  The integration was verified with 3.1.0; its MIT license and supplied icon notices are
  retained as Hex-LICENSE.txt and Hex-NOTICES.md. Signed binary packaging must preserve the
  complete helper and its upstream notices/signature; source publication does not distribute it.
- Parakeet Unified English: downloaded only when the user prepares dictation. No model weights
  are included here. NVIDIA Open Model License is **not** Cast's Apache license; the full terms
  and conversion attribution are Parakeet-LICENSE.txt and Parakeet-NOTICE.txt. Review them before
  using or redistributing model weights. No claim that these model terms are OSI-approved.
- Agent Desktop and Python are user-installed prerequisites for optional window access.
  They are not vendored by Cast. Their own licenses and installation requirements apply.

The Cast name and icon identify this project; Apache-2.0 does not grant trademark rights.
This inventory is a technical attribution review, not legal trademark clearance.
