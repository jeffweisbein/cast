# Cast privacy

This describes the source-first developer preview, not a hosted service.

- Cast connects directly to gateways you configure. Messages, attachments, approvals and
  explicit secret submissions go to that gateway. Its operator and configured providers
  determine processing and retention outside your Apple device.
- Tokens and device identity are stored in Apple Keychain. Conversations, drafts, attachment
  caches and workspace preferences can be stored locally. Protect your device and backups.
- The iOS Share Extension uses an App Group for destination metadata and queued attachments,
  not gateway credentials. Shared content is sent only through the selected gateway route.
- Optional link previews may request public websites. Explicit links and remote media can
  contact their hosts. Update checks contact the configured feed when enabled; the default
  source build has no update feed. Cast does not operate an analytics collection backend.
- Voice messages send recorded audio when you choose to send. Optional Mac dictation uses
  local Hex and downloaded model files; upstream Hex may write its own local diagnostic logs.
  iOS dictation requires on-device speech recognition. See the local-tools guide for limits.
- Optional desktop access shares selected-window accessibility information with the chosen
  agent. It requires explicit setup and OS permission; stopping access does not undo actions
  already delivered or delete content already sent to a gateway.

Removing a workspace or uninstalling the app is not a request to delete gateway history.
Keychain entries and local backups may survive uninstalling. Ask your gateway operator about
server-side deletion and review device storage/Keychain separately when retiring a device.
Reports sent voluntarily through GitHub or email are handled by those services and the project
maintainer. Send only the minimum diagnostic information; see [support](SUPPORT.md).
