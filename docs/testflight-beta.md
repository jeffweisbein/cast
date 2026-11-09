# First TestFlight beta

Candidate starts from the Nov8 installed source6148699. Public main d186720 is older; the beta preserves later video, window, upload, notification-gating and compact workspace changes. No Gateway deployment is implied.

The iOS release helper explicitly uses production APNs. Availability still requires compatible Gateway methods and independently configured production APNs; do not promise task alerts from this binary alone. Large attachments also require the advertised Gateway upload protocol; ordinary messages retain the compatible path.

## Privacy manifest reasons

App preferences use UserDefaults CA92.1; app/share-extension destinations use the same App Group1C8F.1. App-owned recording/cache metadata uses FileTimestamp C617.1. The app-owned attachment admission check uses DiskSpace E174.1 to reject writes when space is insufficient; disk-space values are not transmitted. The share extension only declares its shared UserDefaults access.

No advertising tracking or developer-operated analytics collection is added. Conversations and selected attachments are sent to the user-configured gateway; that operator and its model providers have separate handling.

Reasons verified against Apple's NSPrivacyAccessedAPITypeReasons documentation Nov9 2026. Inspect bundled app and extension PrivacyInfo.xcprivacy, versions, sourceSHA, production APNs and app-group entitlements before upload. Upload acceptance, processing, internal testing and external BetaAppReview are distinct; no public availability claim until checked.
