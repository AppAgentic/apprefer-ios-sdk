# AppRefer iOS SDK

## 0.9.0: account switching, independent Support and reliable events

Support can start independently of attribution. Its configuration does not configure
attribution, collect attribution device signals, initialize product analytics, or
create a device id. Full configuration still enables attribution and analytics as
before. Opening Support before either configuration reports the existing
not-configured error.

Await reset() before signing the next account in. Reset cancels outstanding
attribution, event and Support work, best-effort revokes the old Support session
and unregisters its push token, clears the session/profile and displayed
conversations/unread/drafts, removes the user id and transient matching data,
and drops queued product events. It is idempotent and safe before configuration.
The key remains configured so the next account can use Support; install device id,
attribution result, consent and conversion state are retained. Advanced-matching
hashes are never persisted by this SDK. Billing is separate: also call
AppReferBilling.logOut() when your app uses Billing, then identify its next user
through Billing's existing login API.

```swift
await AppRefer.support.configure(apiKey: "pk_...") // @MainActor; Support only
await AppRefer.setUserId("account-A")
await AppRefer.support.identify(name: "Alex", email: "alex@example.com")
await AppRefer.reset()
await AppRefer.setUserId("account-B")

let result = await AppRefer.configureResult(apiKey: "pk_...")
switch result {
case .attributed(let attribution): print(attribution.network)
case .pending: break // Wait for the server to confirm the ATT decision.
case .organic: break
case .failed(let error): print(error)
}
let delivery = await AppRefer.trackEventResult("workout_finished", properties: ["sets": 4])
await AppRefer.clearPendingEvents()
// If Billing is configured, also: try await AppReferBilling.logOut()
```

The existing configure return value and trackEvent API remain available.
The new configureResult reports attributed, organic, pending, or failed; organic requires
a successful server answer (or its confirmed install cache), never a network
failure or an unclassified empty response. Pending means the server is holding
the ATT decision; its cached copy remains pending until the server confirms a result.
A failed consent re-report preserves any previously confirmed attribution.

trackEventResult returns sent, queued or dropped (uppercase enum cases on
Android). Sent means HTTP 2xx acknowledgement; queued means saved for later
delivery; dropped covers a disabled/unconfigured SDK, a terminal rejection or
unpersistable input. Product events are persisted before sending, bounded to
1,000 events and seven days; expiry and overflow discard the oldest entries.
Each event keeps one stable eventId. Network failures, HTTP 408/429 and 5xx retry
with exponential backoff capped at one hour, or longer when Retry-After requires it.
A retryable failure pauses the drain. HTTP 2xx and other 4xx responses are terminal.
Awaited event calls wait only for their own single request, never the full backlog.
This is **at-least-once delivery**: BigQuery's short insert-id deduplication window
does not provide an exactly-once guarantee.

clearPendingEvents() cancels only product-event requests and erases the queue; call
it when withdrawing product-event consent. Reset calls it too. The existing SDK
kill switch also clears queued events and stops sends. ATT/advertising consent
continues to select the appropriate host; it is not a new product-analytics
consent switch. Discarded events are never replayed. Await reset/clear before
starting work for the next account or resuming event collection.


First-party mobile attribution for iOS apps. Captures click IDs, resolves attribution, and forwards conversions to ad networks — without third-party SDKs.

[![Swift 5.10+](https://img.shields.io/badge/Swift-5.10+-orange.svg)](https://swift.org)
[![iOS 15+](https://img.shields.io/badge/iOS-15+-blue.svg)](https://developer.apple.com/ios/)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)

## Installation

**Xcode:** File → Add Package Dependencies →

```
https://github.com/AppAgentic/apprefer-ios-sdk
```

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/AppAgentic/apprefer-ios-sdk", from: "0.5.0")
]
```

## Quick Start

Get your **API Keys** from the [AppRefer dashboard](https://apprefer.com) → Settings.

```swift
import AppRefer

@main
struct MyApp: App {
    init() {
        Task {
            let attribution = await AppRefer.configure(apiKey: "pk_live_...")
            // Use "pk_test_..." during development — never crashes your app

            if let attr = attribution {
                print("Attributed to: \(attr.network) via \(attr.matchType)")
            }
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

## API Keys

Each app has two SDK keys:

| Key | Prefix | Purpose |
|-----|--------|---------|
| **Live** | `pk_live_` | Production — real attribution, events forwarded to ad networks |
| **Test** | `pk_test_` | Development — sandbox attribution, no ad network forwarding |

Use the test key during development and the live key in production builds. The server determines the environment from the key — no configuration flag needed.

## API

### Configure

Call once at app launch. Resolves attribution on first install, returns cached result on subsequent launches.

```swift
let attribution = await AppRefer.configure(
    apiKey: "pk_live_...",  // or "pk_test_..." for development
    userId: nil,            // optional — link RevenueCat user ID at init
    debug: false            // optional — enable verbose logging
)
```

### Link RevenueCat User ID

Connect the device to RevenueCat so purchase webhooks can be attributed.

```swift
await AppRefer.setUserId(Purchases.shared.appUserID)
```

### Track Events

Track non-purchase events. Purchases are handled automatically via RevenueCat webhooks.

```swift
await AppRefer.trackEvent("signup")
await AppRefer.trackEvent("tutorial_complete", properties: ["step": "final"])
```

### Advanced Matching

Improve ad network match rates by sending hashed PII. All data is SHA256-hashed on-device before transmission.

```swift
await AppRefer.setAdvancedMatching(
    email: "user@example.com",
    phone: "+1234567890",
    firstName: "Jane",
    lastName: "Doe"
)
```

### Get Attribution & Device ID

```swift
let cached = await AppRefer.getAttribution()    // no network call
let deviceId = await AppRefer.getDeviceId()     // for RC subscriber attributes
```

## Attribution Model

```swift
attribution.network       // "meta", "google", "tiktok", "apple_search_ads", "organic"
attribution.matchType     // "click_id", "adservices", "organic"
attribution.campaignName  // campaign name from tracking link
attribution.fbclid        // Meta click ID (if present)
attribution.gclid         // Google click ID (if present)
attribution.ttclid        // TikTok click ID (if present)
```

## Subscriptions (AppRefer Billing)

AppRefer Billing replaces RevenueCat for App Store subscriptions and one-time purchases. StoreKit 2 handles the purchase, AppRefer verifies the signed transaction, keeps the entitlements and sends the conversion to your ad networks from the same attribution data. Requires iOS 15+ (macOS 12+), like the rest of the SDK.

Billing must be enabled for the app in AppRefer (`billing.mode` `shadow` or `primary`, with the bundle id and products configured).

### Set up

```swift
import AppRefer

@main
struct MyApp: App {
    init() {
        Task { await AppRefer.configure(apiKey: "pk_live_...") }
        // Uses the same SDK key. Starts the StoreKit transaction listener right away.
        AppReferBilling.configure(
            appUserId: nil,  // nil = anonymous "$ARAnon:<UUID>", kept in the Keychain
            entitlementsByProduct: [
                "pro_monthly": ["premium"],
                "pro_yearly": ["premium"],
            ]
        )
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

`entitlementsByProduct` is only used when AppRefer can't be reached (see Outage safety). Unlisted products fall back to the mapping the server last returned, then `defaultEntitlement` (default `premium`, the same as the server).

### Products, purchase, restore

```swift
let products = try await AppReferBilling.products(["pro_monthly", "pro_yearly"])  // StoreKit `Product`s, in this order

let result = try await AppReferBilling.purchase(products[1])
switch result.outcome {
case .purchased:     unlock(result.customerInfo)
case .userCancelled: break
case .pending:       showAskToBuyNote()  // arrives later via customerInfoStream
}

let info = try await AppReferBilling.restorePurchases()  // AppStore.sync() + sends every current entitlement
```

`purchase` sets Apple's `appAccountToken` to the customer's AppRefer account token, verifies the transaction, sends it to AppRefer and only then finishes it. Signed promotional offers: `AppReferBilling.purchase(product, promotionalOffer: .init(offerId:keyId:nonce:signature:timestamp:))`.

Before the sheet opens, `purchase` saves who is buying on the device, so a purchase that completes later (Ask to Buy, slow payment, after a restart, logout or user switch) still goes to that customer. If that can't be saved it throws `AppReferBillingError.purchaseIntentNotSaved` and the sheet doesn't open. A purchase delivered without an account token goes to the oldest saved intent for that product (earliest start time); renewals never use or consume intents, even one returned by the purchase sheet. An intent is removed only when the purchase is recorded or the store says no purchase can happen (cancelled, unavailable, not allowed); network and unknown errors keep it. If the saved intents file is partly damaged, the intents that still read are kept and the original is moved aside. If the saved intents are ever unreadable, such purchases are left open and retried for up to 48 hours from when it was made or when the intents were lost, whichever is earlier, then given to the signed-in user with a support note. The marker clears once nothing is waiting on it and it is 48 hours old.

A purchase AppRefer refuses for good (400/413/422), that StoreKit can't verify, or that couldn't be delivered within 50 attempts / 90 days is saved to `await AppReferBilling.rejectedPurchases()` before its transaction is finished (consumables are left unfinished), for support. `restorePurchases()` sends those again. The list has no size limit: an entry leaves only once AppRefer records the purchase.

### Entitlements

```swift
let info = await AppReferBilling.customerInfo()                       // cached for 5 minutes, then fetched
let fresh = await AppReferBilling.customerInfo(fetchPolicy: .fetchCurrent)
if info.entitlements["premium"]?.isActive == true { /* unlocked */ }

for await info in AppReferBilling.customerInfoStream { update(info) }  // or set AppReferBilling.delegate
```

`customerInfo` never throws. `info.source` tells you where the answer came from: `.server`, `.cache` or `.localFallback`.

### Users

```swift
try await AppReferBilling.logIn("user_123")   // moves purchases made while anonymous to this user
try await AppReferBilling.logOut()            // new anonymous id
await AppReferBilling.setAttributes(["$email": "a@b.com", "$displayName": "Alex"])  // sent with the next call
await AppReferBilling.setEmail("a@b.com")     // also setDisplayName / setPhoneNumber
```

The AppRefer attribution device id is sent automatically as `appreferId`, so purchases are matched to the ad click without `setUserId`.

### Outage safety

A paying user is never locked out because AppRefer is down:

- If AppRefer can't be reached at all, entitlements come from StoreKit's verified `Transaction.currentEntitlements` (not revoked, not expired, not upgraded away), mapped through `entitlementsByProduct`, merged with the last server answer for the same user.
- While AppRefer answers, its answer is merged with the customer's own verified StoreKit purchases (untagged, tagged with their account token, or still queued for them), never another app user's.
- A transaction AppRefer can't accept right now is saved to a retry queue on disk and finished only once that copy is saved, so StoreKit doesn't redeliver it forever and never loses it. The queue is resent on the next launch, on foreground and after the next successful call, honouring the server's `Retry-After`. App Store Server Notifications also reach AppRefer on their own.
- Unverified transactions are finished without granting access.

### Migrating from RevenueCat

**No RevenueCat data export is needed.** On first billing configure for each install and user, AppRefer imports the store's active purchases in the background using StoreKit 2's signed current entitlements, including previously finished purchases. Logging in as a new user runs the import for that user. Each purchase is sent without `restore: true`, so it fills unowned purchases and records state without transferring purchases already owned by another user. The completion flag is saved only after every purchase is accepted or durably queued for retry. Migration never finishes, acknowledges or consumes a purchase on device; retry uploads use the same rule. Purchases older than 24 hours update state without an ad conversion. Keep the same app user IDs and configure store notifications for renewals.

| RevenueCat | AppRefer Billing |
|---|---|
| `Purchases.configure(withAPIKey:appUserID:)` | `AppReferBilling.configure(appUserId:entitlementsByProduct:)` (after `AppRefer.configure(apiKey:)`) |
| `Purchases.shared.offerings()` / `StoreProduct` | `AppReferBilling.products(["id", ...])` → StoreKit `Product` |
| `Purchases.shared.purchase(product:)` → `(transaction, customerInfo, userCancelled)` | `AppReferBilling.purchase(product)` → `PurchaseResult` (`.transaction`, `.customerInfo`, `.userCancelled`, `.outcome`) |
| `purchase(product:promotionalOffer:)` | `purchase(product, promotionalOffer: .init(...))` |
| `Purchases.shared.restorePurchases()` | `AppReferBilling.restorePurchases()` |
| `Purchases.shared.customerInfo(fetchPolicy:)` | `AppReferBilling.customerInfo(fetchPolicy: .cachedOrFetched / .fetchCurrent)` |
| `customerInfo.entitlements["premium"]?.isActive` | same |
| `customerInfo.entitlements.active` / `.activeSubscriptions` | same |
| `EntitlementInfo.expirationDate / willRenew / periodType / productIdentifier` | same names |
| `Purchases.shared.customerInfoStream` / `PurchasesDelegate` | `AppReferBilling.customerInfoStream` / `AppReferBilling.delegate` |
| `Purchases.shared.logIn(_:)` / `logOut()` | `AppReferBilling.logIn(_:)` / `logOut()` |
| `Purchases.shared.appUserID` / `isAnonymous` | `await AppReferBilling.appUserId` / `isAnonymous` |
| `$RCAnonymousID:<hex>` | `$ARAnon:<UUID>` |
| `Purchases.shared.attribution.setEmail(_:)` / `setAttributes` | `AppReferBilling.setEmail(_:)` / `setAttributes(_:)` |
| `AppRefer.setUserId(rcUserId)` | not needed: the device id is linked automatically |

If a file imports both SDKs during the switch, use `AppReferCustomerInfo` / `AppReferEntitlementInfo` (or `AppReferBilling.CustomerInfo`) to avoid the name clash with RevenueCat's `CustomerInfo`.

Testing: use a sandbox Apple ID. Transactions from an Xcode StoreKit configuration file are signed with a local certificate that AppRefer's server rejects; the SDK still unlocks them through the local fallback.

## Best Practices

- **Call `configure()` once** — ideally in `App.init()` or `AppDelegate.didFinishLaunching`. The SDK deduplicates automatically; subsequent calls return the cached result with no network overhead.
- **Set the RevenueCat user ID early** — call `AppRefer.setUserId()` right after `Purchases.configure()` so purchase webhooks can be attributed to the correct device.
- **Call `setAdvancedMatching()` after login/signup** — this sends hashed PII to improve Meta CAPI match rates. Only needs to be called once per user session.
- **Don't track purchases with `trackEvent()`** — revenue events are handled automatically via RevenueCat webhooks. Use `trackEvent()` only for non-purchase milestones like `signup`, `tutorial_complete`, or `onboarding_finish`.
- **Use the test key during development** — `pk_test_` keys create sandbox events that are isolated from production data and never forwarded to ad networks. Switch to `pk_live_` for release builds.
- **Use the Debugger** — verify events are flowing correctly in the [AppRefer dashboard](https://apprefer.com) → Debugger before going to production. Toggle the Sandbox switch to see test events.
- **No IDFA required** — the SDK uses Apple's AdServices framework and works without ATT permission. It never shows the ATT prompt; it reads the status your app already has.

## App Tracking Transparency (0.6.0+)

AppRefer keeps first-party work and cross-company tracking apart, per install:

| ATT status | Host | What AppRefer does |
|---|---|---|
| Authorized | `trk.apprefer.com` | Matches the install to its ad click, forwards conversions to your ad networks, sends advanced matching |
| Denied / restricted | `apprefer.com` | Apple AdServices or organic only; analytics, billing and support; nothing forwarded, no advanced matching |
| Not determined | `apprefer.com` | Same as denied until the user answers; conversions are held a few hours in case they allow tracking |

- In your privacy manifest, declare **only `trk.apprefer.com`** in `NSPrivacyTrackingDomains`. `apprefer.com` is never used for tracking, so iOS keeps analytics, billing and support working when the user hasn't allowed tracking.
- After your own ATT prompt, call `await AppRefer.trackingConsentDidChange()`. AppRefer also re-checks on every `configure()` and whenever the app becomes active (the user can change it in Settings).
- `AppRefer.trackingConsent()` returns the status AppRefer applies.

## SKAdNetwork and AdAttributionKit (0.7.0+)

Apple's own ad attribution works for every iOS install, including users who don't allow tracking: the phone ties the install to the ad and Apple sends the ad network an anonymous postback with your app's conversion value. Only the app can set that value, and Apple sends no postback until the app sets it at least once.

AppRefer does this for you:

- On first launch it registers the install (value 0, coarse `low`), as Apple recommends.
- It then sets the value AppRefer computes from what it already knows: **10** (`medium`) once a free trial starts, **20 + whole dollars paid** (`high`, capped at 63) once the user pays, e.g. $9.99 → 30, $39.99 → 60. Values only go up and windows are never locked early.
- It checks on launch, when the app becomes active, after trial or revenue events and after AppReferBilling purchases, for the 35 days Apple's postbacks cover. If you take payments elsewhere (e.g. RevenueCat), call `await AppRefer.updateConversionValue()` after a purchase to set it sooner.
- It updates both AdAttributionKit (iOS 17.4+) and SKAdNetwork (iOS 15.4+), as Apple asks when your ad networks may use either.

To receive copies of the winning postbacks in AppRefer, add to your app's Info.plist:

```xml
<key>NSAdvertisingAttributionReportEndpoint</key>
<string>https://apprefer.com</string>
<key>AdAttributionKit</key>
<dict>
    <key>AttributionCopyEndpoint</key>
    <string>https://apprefer.com</string>
</dict>
```

Also add the `SKAdNetworkItems` identifiers your ad networks publish.

## Requirements

- iOS 15.0+ (macOS 12+, tvOS 15+)
- Swift 5.10+ (Xcode 15.3+)
- Zero external dependencies

## License

Proprietary. All rights reserved.

## Support chat (AppRefer Support)

An in-app help chat your team answers from the AppRefer inbox. iOS 15+, SwiftUI, Liquid Glass on iOS 26+. The home screen has a hero in your accent colour with the team's names and reply time, the conversation to pick up again, quick-help tiles and a floating message bar; conversations show tailed bubbles, screenshots and one-tap quick replies. Light and dark mode.

```swift
// Anywhere (a Help button, Settings row…):
AppRefer.support.open()

// Optional
AppRefer.support.identify(name: "María", email: "maria@example.com") // the app user id from setUserId is sent automatically
AppRefer.support.accentColor = .purple                  // text on a bright accent turns dark automatically
AppRefer.support.teamNames = ["Jay", "Ana"]             // "Jay and the team · usually under an hour"
AppRefer.support.replyTime = "under an hour"
AppRefer.support.topics = [.billing, .bug, .idea,       // quick-help tiles; [] hides them
    AppReferSupportTopic(title: "Restore purchase", subtitle: "Get your plan back", systemImage: "arrow.clockwise",
                         tint: .blue, prompt: "", action: { Task { try? await myRestore() } })]  // an action runs instead of a message
AppRefer.support.appIcon = UIImage(named: "HelpIcon")   // defaults to the app icon
AppRefer.support.compose("Problem with my subscription") // opens with the message field filled in

// Reply notifications (free push; AppRefer emails only if a reply stays unread for an hour)
func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    AppRefer.support.registerDeviceToken(token)
}
// In your UNUserNotificationCenterDelegate:
if AppRefer.support.handleNotification(response.notification.request.content.userInfo) { return }
```

Customers can attach up to four screenshots per message; they are compressed on the device (about 1600 px, under 700 KB) and uploaded straight to storage. The chat checks for replies only while it's open.

## Offerings (0.8.0)

Configure named offerings, packages, placements, targeting and experiments in AppRefer. Your paywall reads the store products without hard-coding product ids.

```swift
let offerings = try await AppReferBilling.offerings()
if let offering = offerings.currentOffering(forPlacement: "onboarding"),
   let annual = offering.annual {
    // Show annual.storeProduct.displayPrice in your paywall.
    let result = try await AppReferBilling.purchase(package: annual)
}
```

`current` is the resolved default, and `all` contains offerings by identifier. Each offering has JSON `metadata`, `availablePackages`, a package lookup, and `weekly`, `monthly`, `twoMonth`, `threeMonth`, `sixMonth`, `annual` and `lifetime` shortcuts. `$rc_*` package identifiers are accepted alongside `$ar_*`; unrecognized types become `custom`. Packages missing a product for this platform or unavailable in the store are omitted.

Unknown placements fall back to current; a configured null placement suppresses the paywall. Placement lookups return a copy carrying placement attribution. Purchase the package to send its offering/package, placement, targeting and experiment context, plus the persistent install bucket. Context survives pending purchases and retry-queue restarts.

Offerings use a five-minute memory and disk cache. Foreground refreshes stale data; login/logout invalidates it and refreshes an already-used catalogue. Network/server failures return the last cached response of any age after resolving store products again. No cache means the SDK billing error is thrown; catch it and use your existing paywall product ids. Offerings never gate configuration or purchases. Concurrent callers share one request.

Google Play `subscription:basePlan` selects that base plan; a bare subscription selects the period matching the package type, otherwise the first base plan. The package exposes the selected offer token. Storefront country uses ISO alpha-2 when available; no device locale is substituted. The install bucket stays stable after login/logout.
