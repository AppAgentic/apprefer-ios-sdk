# AppRefer iOS SDK

First-party mobile attribution for iOS apps. Captures click IDs, resolves attribution, and forwards conversions to ad networks — without third-party SDKs.

[![Swift 5.10+](https://img.shields.io/badge/Swift-5.10+-orange.svg)](https://swift.org)
[![iOS 14+](https://img.shields.io/badge/iOS-14+-blue.svg)](https://developer.apple.com/ios/)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)

## Installation

**Xcode:** File → Add Package Dependencies →

```
https://github.com/AppAgentic/apprefer-ios-sdk
```

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/AppAgentic/apprefer-ios-sdk", from: "0.2.0")
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

AppRefer Billing replaces RevenueCat for App Store subscriptions and one-time purchases. StoreKit 2 handles the purchase, AppRefer verifies the signed transaction, keeps the entitlements and sends the conversion to your ad networks from the same attribution data. Requires iOS 15+ (macOS 12+); the attribution API still works on iOS 14.

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

Before the sheet opens, `purchase` saves who is buying on the device, so a purchase that completes later (Ask to Buy, slow payment, after a restart, logout or user switch) still goes to that customer. If that can't be saved it throws `AppReferBillingError.purchaseIntentNotSaved` and the sheet doesn't open.

A purchase AppRefer refuses for good (400/413/422), that StoreKit can't verify, or that couldn't be delivered within 50 attempts / 90 days is saved to `await AppReferBilling.rejectedPurchases()` before its transaction is finished (consumables are left unfinished), for support. `restorePurchases()` sends those again.

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
- **No IDFA required** — the SDK uses Apple's AdServices framework and does not require ATT permission or the `AdSupport` framework.

## Requirements

- iOS 14.0+ (AppRefer Billing: iOS 15.0+)
- Swift 5.10+ (Xcode 15.3+)
- Zero external dependencies

## License

Proprietary. All rights reserved.
