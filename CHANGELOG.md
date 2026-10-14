## Unreleased

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
