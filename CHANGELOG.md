## 0.9.0 — 2026-10-16

## 0.9.1

- Product events capture `app_user_id` at track time and persist it with the queued payload, preserving identity across retries, restarts, and account switches. Internal `_` events are unchanged.
- Add persistent `setCollectionEnabled` control. Disabling cancels attribution, consent, conversion-value and event requests and clears queued events; Support and Billing remain available. Enable, then call configure to resume.
- Support sends no device id after reset() or while collection is off. reset() also stops attribution (consent re-reports, conversion values, event sends) until configure is called again; events tracked meanwhile are dropped, never queued or sent later.

- Add async reset for account switching: cancel old work, revoke Support sessions and push registrations, clear account/profile/UI state and pending product events, retain install attribution and device id. Billing logout stays explicit.
- Add Support-only configuration with no attribution initialization or analytics.
- Persist a bounded 1,000-event / seven-day product queue with stable eventId, network/5xx backoff and launch/foreground retries; remove successful and terminal rejected events. Delivery is at least once.
- Add trackEventResult acknowledgements and clearPendingEvents; retain the existing tracking signature and respect the existing SDK kill switch.
- Add typed configureResult distinguishing attributed, confirmed organic and failure, while preserving configure.
- Add account isolation, persistence, expiry, retry, terminal rejection, cancellation and attribution-status regressions.

## 0.7.0 - 2026-10-16

## 0.8.0 — 2026-10-16

- Add RevenueCat-style Offerings, packages, placements, metadata and experiment context, with native store product resolution.
- Add five-minute memory/disk caching, shared in-flight requests, foreground refresh, identity invalidation and offline catalogue fallback.
- Add package purchases with durable offering attribution and a stable anonymous install bucket.
- Include the 0.7.1 offline fallback fix: explicitly empty entitlement mappings unlock nothing; only unmapped products use the default.
- Add paywall examples and Offerings regression tests.

- SKAdNetwork and AdAttributionKit conversion values: the SDK registers each install on first launch and raises its conversion value from AppRefer's first-party data (trial started = 10, paid = 20 + whole dollars, capped at 63; coarse low/medium/high), on launch, activation, trial/revenue events and AppReferBilling purchases, for 35 days. Works for every install whatever its ATT status.
- New `AppRefer.updateConversionValue()` to refresh right after a purchase made outside AppReferBilling; such checks look once more 90 seconds later. The first-run date is sent so a reinstall starts fresh. iOS 15.0–15.3 use SKAdNetwork 3.
- README: Info.plist keys to receive postback copies in AppRefer (`NSAdvertisingAttributionReportEndpoint`, `AdAttributionKit.AttributionCopyEndpoint`).

## 0.6.0 - 2026-10-15

- **Tracking consent split (App Tracking Transparency).** The SDK reads the ATT status (never prompts) and sends it as `tracking_consent`. Requests from ATT-authorized installs go to `trk.apprefer.com` only; everything else goes to `apprefer.com` only. The two hosts no longer fall back to each other, so apps declare only `trk.apprefer.com` in `NSPrivacyTrackingDomains`.
- The server matches, forwards and keeps advanced matching only for authorized installs; denied and undetermined installs get Apple AdServices or organic attribution, first-party analytics, billing and support.
- New `AppRefer.trackingConsentDidChange()` (call after your ATT prompt) and `AppRefer.trackingConsent()`. Status changes are also reported on `configure()` and when the app becomes active.
- `setAdvancedMatching` is skipped unless ATT is authorized. IDFA is only read when authorized (unchanged).
- AppRefer Billing picks its host per request the same way.

## 0.5.0 - 2026-10-15

- Add AppRefer Support: native home and conversations, screenshot uploads, secure sessions, unread counts and notification routing.
- Concierge chat design with configurable accent, team presence, quick-help topics and a floating composer.
- AI personas show their approved name and portrait, an explicit AI tag, and a hand-over pill when a person is needed.


- **Breaking:** the whole package now requires iOS 15 / macOS 12 / tvOS 15 (was iOS 14 / macOS 11), matching the Flutter SDK; old availability branches removed.
- Add AppRefer Billing (`AppReferBilling`), a StoreKit 2 purchases and entitlements module that replaces RevenueCat (iOS 15+ / macOS 12+):
  - `configure(apiKey:appUserId:entitlementsByProduct:defaultEntitlement:)` with an anonymous `$ARAnon:<UUID>` id kept in the Keychain, and a `Transaction.updates` listener started at configure
  - `products(_:)`, `purchase(_:promotionalOffer:options:)` (sets `appAccountToken`), `restorePurchases()`
  - `customerInfo(fetchPolicy:)`, `customerInfoStream`, `delegate`; `entitlements["premium"]?.isActive`
  - `logIn(_:)` (merges anonymous purchases via `/identify`), `logOut()`, `setAttributes(_:)`, `setEmail`/`setDisplayName`/`setPhoneNumber`
  - Outage safety: falls back to verified `Transaction.currentEntitlements` merged with the cached server answer; transactions AppRefer can't accept are queued on disk, finished, and resent later
  - Sends the AppRefer attribution device id as `appreferId` automatically
  - Uses the attribution SDK key and the `trk.apprefer.com` → `apprefer.com` fallback
- `AppRefer.getDeviceId()` returns nil (and first-launch attribution waits for the next launch) while the Keychain can't read or save the device id, instead of a random id that was never saved

## 0.4.0

- Use `trk.apprefer.com` as primary tracking endpoint for lower latency
- Fallback to `apprefer.com` if the tracking endpoint is unreachable
- HTTPClient now supports primary + fallback URL with automatic failover

## 0.3.0

- Harden SDK to never crash host app
- Remove throws from all public API methods — silently no-op if called before configure()
- Fix force unwrap crash in DeviceInfo utsname pointer
- Fix potential double-resume crash in URLSession continuation
- Fix simulator crash: skip AdServices (throws uncatchable NSException)
- Use proper AdServices import instead of unsafe objc_msgSend bridge

## 0.2.1

- Fix kill switch response key (`sdk_enabled` → `sdkEnabled`)

## 0.2.0

- Fix EXC_BAD_ACCESS: thread-safe actor isolation with lock-protected static state
- Fix ARC ownership mismatch in AdServices ObjC bridge
- Fix unsafe memory access in DeviceInfo utsname
- Add deep-copy for cross-actor dictionary parameters
- Add concurrency tests
- Use SDK key as sole credential — `configure(apiKey:)` replaces `configure(appId:)`
- Centralize version string via `AppReferVersion.current`

## 0.1.0

- Initial release
