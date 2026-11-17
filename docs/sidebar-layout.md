# iOS sidebar height contract

The sidebar must keep chat navigation reachable with the software keyboard open,
including after rotation and in regular-width/short-height split layouts.

- Use one scrolling `List` for the iOS sidebar, including search, management,
  workspace/tools and connection/status controls. Do not nest a flexible chat List
  between fixed-height stacks: the keyboard can reduce that List to zero height.
- Prefer chat controls and rows when the *available sidebar height* is below 420pt.
  Combine search/New Chat in one row and omit section headings at that height.
  Secondary navigation remains available below the chats. Width or device name
  alone does not identify this case.
- Preserve the `SessionListView` identity and its search/sheet state across height
  changes. Do not disable keyboard avoidance globally or erase drafts to reveal
  navigation. macOS retains its existing fixed-header/footer layout.

## Regression check

`Tests/SideChatUITests/SidebarLandscapeUITests.swift` mounts the production
`WorkspaceContentView` through the existing offline fixture. Credentials and
production startup are disabled. It enters search in portrait, verifies the
software keyboard, rotates, checks the actual viewport and retained query, asserts the whole row clears the keyboard and its prediction bar, taps
the matched chat, verifies its selected identity, and rotates back.

Run with the fixture project/scheme and a disposable iOS simulator:

```sh
xcodegen generate --spec Tests/SideChatFixture/project.yml
xcodebuild test -project Tests/SideChatFixture/CastSideChatFixture.xcodeproj \
  -scheme Fixture -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -only-testing:FixtureUITests/SidebarLandscapeUITests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

The test fails against installed-source baseline `fd4e488` because the matching
chat row disappears after keyboard-open rotation. Simulator results do not prove
physical Duo behavior or authorize installation. Keep original failure, candidate
results and device acceptance separate.
