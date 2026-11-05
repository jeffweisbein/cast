# Security policy

Cast connects directly to user-operated OpenClaw gateways and stores gateway credentials in the Apple Keychain. Security reports are treated as private until a fix and disclosure plan are ready.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for this repository. If that is unavailable, email `jeff@hypelab.digital` with the subject `Cast security report`.

Include the affected version or commit, reproduction steps, impact, and any suggested mitigation. Do not include live gateway credentials, setup codes, conversation content, or other people's personal data.

Please do not open a public issue for a suspected vulnerability. We will acknowledge a complete report as quickly as possible and coordinate validation, remediation, and disclosure with the reporter.

## Supported versions

Before Cast has a public release, only the current `main` branch receives security fixes. A supported-version table will be added with the first tagged release.

## Security model

- Cast does not provide or proxy a hosted gateway.
- Remote gateways require `wss://`; plain `ws://` is restricted to loopback and private LAN addresses.
- Gateway tokens and device identity are stored in Keychain with this-device-only accessibility.
- Share Extension handoff uses an App Group for non-secret routing data and queued attachments. Credentials do not enter the App Group container.
- Conversation and media caches are local application data and should be protected by the security of the Apple device and user account.
