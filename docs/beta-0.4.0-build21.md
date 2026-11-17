# Cast 0.4.0 — beta build 21

This beta brings the latest chat-management and download improvements to TestFlight.

- Keep chats reachable in landscape while the iPhone keyboard and prediction bar are open.
- Archive, restore, pin, rename and reopen chats without silently switching conversations or marking another chat read.
- Recover saved side chats and retain their drafts and delivery state.
- Reconcile unread conversation badges across the gateway inventory.
- Save downloaded documents through the native export interface, and explain when a gateway file needs to be attached before it can be downloaded.

## What to test

Open a chat, rotate to landscape with the keyboard visible, and select another chat from the sidebar. Try archive/restore and reopening a saved side chat. Download an attached document and use Save as to export it. Check that your existing pairing, chats and settings remain intact.

Gateway capabilities still determine synchronization, attachment delivery and push-notification availability. TestFlight upload, Apple processing, tester availability and physical-device acceptance are separate release stages.
