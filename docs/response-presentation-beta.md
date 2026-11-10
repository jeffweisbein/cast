# Cast for OpenClaw beta UI changes

Adapted the competitor's information hierarchy, not its artwork or branding:
- Repository-backed commit chips and accent inline code. Bare hashes never invent a repository link.
- Compact existing tool runs; expanded details remain available.
- Diff headers show actual added/deleted line counts and file paths. Entire code remains selectable/copyable and horizontally scrollable; no ellipsis hides changed lines.
- “Ask in side chat” opens a native inspector (adaptive sheet on compact iOS) with quoted response, independent composer, stop and refresh. The gateway conversation is saved, not incognito or deleted when closed. No fork, no main-session send, deliver=false.

Side chat requires advertised sessions.create/chat.send/chat.history/sessions.messages.subscribe. Each pane gets a unique session on the same agent and workspace. Subscription renews on reconnect/foreground; workspace replacement cannot redirect a pending side-chat request to another gateway. Failed/uncertain submission preserves text and idempotency identity. Closing does not erase the gateway transcript. The side panel shows the latest 80 history rows; the saved session can be opened in the ordinary conversation list for older history.

Apple app record created by Jeff: 6832696966, Cast for OpenClaw, iOS + macOS. First delivery is the existing supported iOS TestFlight release path. macOS currently uses direct distribution with helper/Sparkle integration; its App Store sandbox/release path needs separate verification before a Mac TestFlight claim.

castdispatch.com is Jeff's domain; a screenshot-led website was recommended, not published. Launch tweet is draft-only. Push and large uploads retain their existing advertised Gateway requirements; no Gateway deployment is part of this release.
