# AppRefer iOS SDK

## 0.11.0 (unreleased): lifecycle notifications (engagement)

**Not generally available.** AppRefer turns lifecycle engagement on per app; until then every engagement call answers "disabled" quietly and nothing is stored. The server side is dry-run only in this release: no notification is sent to anyone yet. This version is the client contract (wire schema 1) the live sender will use.

Rules the SDK follows: nothing is registered until your app calls `start`; nothing asks for notification permission or tracking consent; the install secret lives only in secure storage (iOS Keychain / Android Keystore); an account is bound only with an assertion your backend gets from AppRefer (`POST /api/v1/apps/{appId}/engagement/assertions`, `engagement:identity` key), never a plain user id; Support sessions, tokens and `support_reply` pushes never enroll anyone, and Support's handlers ignore engagement pushes; a notification for another install or account, an expired one, or one that fails validation never navigates; each outcome (received, opened, button, snoozed, dismissed) is delivered once, and navigation waits for `setNavigationReady(true)`; a snooze is never a completion; receipts carry the message's own proof and are dropped after any account change; an account change also removes AppRefer's own snoozes and posted notifications for the previous account (on iOS a remote notification already on screen can't be withdrawn, but it never navigates or reports for the next account); queued events and identity changes carry the account epoch they were made under, so the server refuses one made for an account the install has left; destinations are in-app paths your app maps to screens, never URLs the SDK opens.

```swift
await AppRefer.configure(apiKey: "pk_live_…")
await AppRefer.engagement.start(options: .init(
    trackedEvents: ["setup_started", "setup_completed"],     // events journeys react to (nil = all)
    appGroup: "group.com.example.app",                      // shared with the extension (optional)
    notificationServiceExtension: true))                     // you ship the extension below
// didRegisterForRemoteNotificationsWithDeviceToken:
await AppRefer.engagement.setDeviceToken(deviceToken)
// After your own permission prompt:
await AppRefer.engagement.refreshDeviceState()
// After sign-in (assertion from your backend, for `status()`'s install id):
try await AppRefer.engagement.identify(assertion: assertion)
// The person's own choices (your settings screen):
try await AppRefer.engagement.setPreferences(marketing: true)
// Navigation (your router):
AppRefer.engagement.onNotificationEvent = { event in if event.isNavigation { router.open(event.destination) } }
AppRefer.engagement.setNavigationReady(true) // once signed-in state is known
```

Your `UNUserNotificationCenterDelegate` stays yours; forward to AppRefer and keep Support:

```swift
func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
    if await AppRefer.engagement.handle(r) { return }
    _ = AppRefer.support.handleNotification(r.notification.request.content.userInfo)
}
func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
    AppRefer.engagement.presentationOptions(for: n) ?? [.banner, .list, .sound]
}
```

**Images need a Notification Service Extension you add and sign** (File › New › Target › Notification Service Extension; the SDK can't create it). Add only the `AppReferNotifications` product to that target (extension-safe; not the main `AppRefer` product), the same App Group to both targets if you use one, and:

```swift
import AppReferNotifications
final class NotificationService: UNNotificationServiceExtension {
    private let appRefer = AppReferNotificationService(configuration: .init(
        allowedImageHosts: ["assets.example.com"], appGroup: "group.com.example.app"))
    override func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        if appRefer.didReceive(request, withContentHandler: handler) { return }
        handler(request.content)
    }
    override func serviceExtensionTimeWillExpire() { appRefer.serviceExtensionTimeWillExpire() }
}
```

Images: HTTPS, exact allowlisted host names, PNG or JPEG, ≤ 300 KB and 2048 px by default, 8 s; anything else delivers the complete text. Without an App Group the extension can't see the signed-in account, so it fetches only allowlisted generic artwork (it never fetches per-user content). `Samples/EngagementHost` is a working host + extension (`xcodegen generate`). Not supported yet: carousels, video, content extensions, per-notification button titles (labels come from the SDK by kind: Open, View, Start, Remind me later).

## 0.10.0 (unreleased): help centre in the chat; the help chat speaks 35 languages

**Help centre.** When your app has published help articles in AppRefer, the help home
shows a "Help articles" card (search plus the top articles), with a help centre screen
(every article by category, search) and an article reader. "Still need help? Message
us" starts a conversation about the article. Nothing changes for apps without
articles. Read them in code too: `AppRefer.support.articles(query:)`,
`article(slug:)`, and `AppRefer.support.status()` to decide whether to register for
reply notifications. See [Help centre and status](#help-centre-and-status-0100).

**AppRefer Support is localized.** Every label, placeholder, error and accessibility
label in the help chat ships in 35 languages and follows the language your app is
running in, so the chat matches your screens. Override any string or force a language;
see [Support chat → Languages](#languages-and-your-own-wording). Arabic and Hebrew lay
out right to left.

## 0.9.3: reset gate survives relaunch; Support revocation and push fixes

**Billing remembers the reset across launches.** `AppRefer.reset()` saves the Billing
user that was current at that moment. If the app relaunches and Billing still serves
that user (no `AppReferBilling.logIn`/`logOut` yet), its requests still carry no
install device id or device attributes, it is never re-linked, and `/identify` sends
`link: false`. Any explicit `logIn` (even with the same id) or `logOut`, or a
different Billing user, ends this. An anonymous id that `logOut()` has just created
for the next account is never marked, even if `logOut()` runs before `reset()`.
Calling `logIn`/`logOut` after `reset()` is still the recommended flow. The marker
lives in the Keychain with Billing's anonymous id.

**Support.** A revocation queued while another revocation pass is running (for
example by `clearIdentity()`) is processed straight after it, in the same app
session. Registering a push token that a session waiting for revocation still holds
is deferred: the token moves to the current session only once the old session is
revoked. The "cleared" markers now live in the Keychain with the Support session
token, so they survive a reinstall together.

## 0.9.2: Billing follows the collection choice; Support clearIdentity

**Billing sends no device id while it must not.** AppReferBilling uses the same rule
Support has used since 0.9.1: the install device id (`appreferId`) and the device
signals among the customer attributes (`$idfa`, `$idfv`, `$fbAnonId`,
`$attConsentStatus`, `$deviceVersion`, `$ip`, `$gpsAdId`) are sent with
customers/purchases requests only after `configure`/`configureResult` in this
process, never while collection is off (including an "off" that was turned back on
but not yet configured), and never after `reset()` until configure runs again for
the next user. A withheld device attribute is dropped, not sent later. While the
gate is closed Billing also uses `apprefer.com`, never `trk.apprefer.com`.
Purchases, restore, entitlements and offerings work exactly as before without it.
Purchases queued earlier keep their device id only if linking is allowed when they
are resent. A customer registered without the device id is linked once on the next
customer refresh after configure. Billing-only apps (no attribution configure)
never send it.

The device id is also tied to the account: after `reset()` it is sent only for the
Billing user set after that reset, so call `AppReferBilling.logIn`/`logOut` for the
next account. Until then, purchases and queued purchases of the previous Billing user
are recorded without it and that user is never re-linked. `logIn` sends
`link: false` to `/identify` while the gate is closed, so the server merges the
anonymous purchases without copying the install link.

**Remove the account from Support without a full reset**, e.g. when the user
withdraws consent:

```swift
await AppRefer.support.clearIdentity() // @MainActor
```

This forgets the Support name, email and app user id, revokes the current Support
session (through the same durable revocation used by reset) and starts a new
anonymous session that carries no link to the old id: it sends neither the app user
id nor the install device id. A registered reply notification token moves to the new
session once the old session's revocation has succeeded (retried on launch and
foreground if offline), so the two sessions never hold it at once. **Conversations
from the old session are no longer visible in the app**; they stay in your team
inbox. The app user id is not sent to Support again until it changes (another
account is stored with `setUserId`/`configure(userId:)`) or `reset()` runs;
configuring with the same user id on the next launch keeps Support anonymous. When
a different user id is stored later without `reset()`, the anonymous session is
never handed to that account: it is revoked and a fresh session is started. Attribution, Billing and the stored
user id are not changed. Combine it with `setCollectionEnabled(false)` to stop
attribution as well.

## 0.9.1: account switching, independent Support and reliable events

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
After reset, attribution sends nothing (no consent re-report, conversion value or
event delivery; events tracked meanwhile are dropped, never sent later) and Support sends no device id until configure is called again, so
the next account's Support session is never linked to the previous account's
install. Support also omits the device id while collection is off.

Migration: after reset(), call configure again for the next user; until then events, attribution and consent reports are paused.
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
    userId: nil,            // optional — your app's user id (the one you pass to AppReferBilling.logIn)
    debug: false            // optional — enable verbose logging
)
```

### Link your user ID

Tell AppRefer who is signed in, so Support conversations and product events carry the account.
AppRefer Billing links purchases to the ad click on its own (the install device id is sent
automatically), so this isn't needed for purchase attribution.

```swift
await AppRefer.setUserId(currentUser.id)
try await AppReferBilling.logIn(currentUser.id)  // if you use AppRefer Billing
```

### Track Events

Track non-purchase events. Purchases made with AppRefer Billing are recorded and sent to your ad networks automatically.

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
let deviceId = await AppRefer.getDeviceId()     // e.g. for your support tools or backend
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

The AppRefer attribution device id is sent automatically as `appreferId`, so purchases are matched to the ad click without `setUserId` (only after `AppRefer.configure`, and not while collection is off or after `reset()` until configure runs again; see 0.9.2).

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
- **Set the user ID when someone signs in** — call `AppRefer.setUserId()` and `AppReferBilling.logIn()` with the same id, so Support, product events and purchases all belong to that account.
- **Call `setAdvancedMatching()` after login/signup** — this sends hashed PII to improve Meta CAPI match rates. Only needs to be called once per user session.
- **Don't track purchases with `trackEvent()`** — AppRefer Billing records purchases, renewals and refunds and forwards them for you. Use `trackEvent()` only for non-purchase milestones like `signup`, `tutorial_complete`, or `onboarding_finish`.
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
- It checks on launch, when the app becomes active, after trial or revenue events and after AppReferBilling purchases, for the 35 days Apple's postbacks cover. If you take payments outside AppReferBilling, call `await AppRefer.updateConversionValue()` after a purchase to set it sooner.
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

An in-app help chat your team answers from the AppRefer inbox. iOS 15+, SwiftUI, Liquid Glass on iOS 26+. The home screen has a hero in your accent colour (or, with `headerStyle = .plain`, a flat neutral grey) with the team's names and reply time, the conversation to pick up again, quick-help tiles and a floating message bar; conversations show tailed bubbles, screenshots and one-tap quick replies. Light and dark mode.

```swift
// Anywhere (a Help button, Settings row…):
AppRefer.support.open()

// Optional
AppRefer.support.identify(name: "María", email: "maria@example.com") // the app user id from setUserId is sent automatically
let check = try await AppRefer.support.verifyIdentity(tokenFromYourBackend) // 0.12.0: confirms the account (see "Verified identity" below)
AppRefer.support.accentColor = .purple                  // text on a bright accent turns dark automatically
AppRefer.support.headerStyle = .plain                   // 0.11.1: flat neutral grey header, no accent or glow (default .accent); 0.11.2: Continue card avatar too
AppRefer.support.teamNames = ["Jay", "Ana"]             // "Jay and the team · usually under an hour"
AppRefer.support.replyTime = "under an hour"
AppRefer.support.topics = [.billing, .bug, .idea,       // quick-help tiles; [] hides them
    AppReferSupportTopic(title: "Restore purchase", subtitle: "Get your plan back", systemImage: "arrow.clockwise",
                         tint: .blue, prompt: "", action: { Task { try? await myRestore() } })]  // an action runs instead of a message
AppRefer.support.appIcon = UIImage(named: "HelpIcon")   // defaults to the app icon
AppRefer.support.compose("Problem with my subscription") // opens with the message field filled in

// Reply notifications (free push; AppRefer emails only if a reply stays unread for an hour).
// Ask for push only once AppRefer has verified your APNs key (see status() below).
if (try? await AppRefer.support.status())?.pushReady == true {
    UIApplication.shared.registerForRemoteNotifications()
}
func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    AppRefer.support.registerDeviceToken(token)
}
// The APNs environment comes from the app's signing (embedded profile's aps-environment):
// development-signed builds (Debug or Release) and the Simulator use sandbox; App Store,
// TestFlight, Ad Hoc and Enterprise builds use production. To force one:
// AppRefer.support.pushEnvironment = .sandbox
// In your UNUserNotificationCenterDelegate:
if AppRefer.support.handleNotification(response.notification.request.content.userInfo) { return }
```

Customers can attach up to four screenshots per message; they are compressed on the device (about 1600 px, under 700 KB) and uploaded straight to storage. The chat checks for replies only while it's open.

### Verified identity (0.12.0)

The app user id the SDK sends with Support is only a claim from the device. To let your team and
the AI assistant use the account's private details (plan, purchases, orders, credits your backend
shares), confirm it:

1. Your backend, after signing the user in, calls
   `POST https://apprefer.com/api/v1/apps/{appId}/support/identity-tokens` with your **private**
   organisation key (`support:context` scope) and `{ "appUserId": "<the signed-in user>" }`. It
   returns a single-use `identityToken` valid for up to 10 minutes. Never put the private key in
   the app.
2. The app passes that token to ``try await AppRefer.support.verifyIdentity(token)`` after `setUserId` with the same user.

It verifies the current Support session, so conversations already started on it count too; no new
conversation is needed. Network and server failures are retried with the same token and then
thrown (sending the same token again is safe: the server acknowledges a retry from the same session).
A refusal comes back as `verified: false` with a `reason` (`expired`, `already_used`,
`user_mismatch`, `session_replaced`… get a new token), or `account_changed` when a reset,
`clearIdentity()` or another user id happened while it ran. The token is never stored or logged.
`reset()`, `clearIdentity()` and another account signing in end the verification. Until an app
verifies, the AI assistant gets no account data at all, and your team sees the claimed account
marked "Not verified". `identify` is unchanged.

### Option cards (0.12.0)

Your team or AI assistant can attach one of your AppRefer Billing offerings to a reply. Tapping
**See options** on the card calls your code with the offering, so you open **your own** paywall:

```swift
AppRefer.support.onOffer = { offer in
    // offer.offeringId, offer.packageId (optional), offer.cardId, offer.conversationId
    Paywall.present(offeringId: offer.offeringId, packageId: offer.packageId)
}
```

The card reads "Options for you" (never "offer"): it can hold ordinary full-price plans, credit packs
or one-off purchases. Each price shows the store's own billing period ("£29.99/year"), never a
free-trial or introductory price; an owned one-off is tagged "Purchased", a current subscription
"Current plan".

The card lists the offering's packages with the store's own formatted prices (StoreKit `displayPrice` via `AppReferBilling.offerings()`, when Billing is configured; otherwise no prices) and
tags the customer's current plan; switching plans is never blocked. The SDK never shows a paywall,
never starts a purchase and never shows a price, discount or deadline of its own: your paywall does
the buying and AppRefer Billing confirms it from the store as usual. A tap is reported as an
`opened` receipt (never a purchase); receipts made offline are kept on the device for up to 7 days
and sent again with the same id. Before calling you, the SDK asks AppRefer for up to 3 seconds
whether the card can still be opened: a withdrawn, expired or changed card redraws instead, and no
answer calls you anyway (the store is the real gate).

- `closesChatOnOffer` (default `true`) closes the chat sheet opened with `open()`/`compose()` before `onOffer` runs.
- Without `onOffer`, cards say "Update the app to open this".
- Cards refresh when the chat opens, every 30 seconds while it is open, after a purchase, restore or
  sign-in reported by AppRefer Billing, and when the app comes back to the foreground.
- Your team sends cards from the inbox (＋ Offer); the AI assistant can attach one only for a
  verified customer. Offerings that aren't public in your catalogue (current, placement, targeting
  rule, running experiment) also need the customer verified (see Verified identity).
- `reset()` and `clearIdentity()` drop pending receipts with the old session.
- Older SDK versions show your text plus a line asking the customer to update the app.

### Review cards (0.12.0)

Your team can attach an optional **Write a review** card to a reply (inbox: ＋ Review link). The card
says "Share your experience" and opens the app's App Store page with the write-review action (`https://apps.apple.com/app/id<id>?action=write-review`) through the system URL opener. There is nothing to set up: AppRefer builds the link
from the App Store id your app already has in AppRefer (Billing or the store URL in app settings).

- Neutral and optional: no stars, no "do you like the app?" question, no reward, never sent
  automatically and never only to happy customers. The AI assistant can only suggest one in a draft
  for a person to send.
- The SDK opens only `https://apps.apple.com/app/id<digits>?action=write-review`; any other link from the server is shown as "no store page" and never opened.
- The SDK never calls the store's in-app review prompt from the card: that prompt is limited by the
  store and can silently show nothing, so both Apple and Google recommend a link for a button.
- A tap records an `opened` receipt (same queue as offer cards; dropped by `reset()`/`clearIdentity()`).
  It is never a review, a rating or a star count, and the chat never says a review was written.
- A withdrawn, expired or changed card (store page or settings changed) shows "This review link is no
  longer available"; a device with no store page for the app shows "There's no store page for this
  device". AppRefer sends at most one card per customer every 120 days (configurable, 30–365).
- Older SDK versions show your text plus a line asking the customer to update the app.

0.12.0 is unreleased source (not tagged). Once tagged, install it from Git only: Swift Package Manager, `https://github.com/AppAgentic/apprefer-ios-sdk` at the `0.12.0` tag.

### Photo and video testimonials (0.13.0)

Ask a signed-in customer for a photo or a short video and give them the reward your campaign sets,
from your own screens, from your coach/assistant, from a Support reply, or automatically after
real usage. One native capture screen does it everywhere: what's asked, the reward, the system photo
picker (no photo-library permission needed) or the camera, a preview, an optional **Allow public use** switch with your exact permission
text, upload progress, then the result.

1. Your backend registers campaigns (`PUT /api/v1/apps/{appId}/support/testimonials/campaigns`,
   private key with `support:testimonials`). A company admin switches each one on in AppRefer
   Support; nothing reaches customers before that.
2. Your backend asks for one user: `POST /api/v1/apps/{appId}/support/testimonials/requests`
   `{ campaignId, appUserId, idempotencyKey, source: "host" | "coach" }`. It returns `requestId`.
   The reward comes from the campaign; the call can't set one.
3. The app shows it:

```swift
AppRefer.support.testimonials.onRewardUpdate = { update in
    if update.rewardStatus == "fulfilled" { Task { await credits.refresh() } }
}
let open = try await AppRefer.support.testimonials.pending()      // requests waiting for this account
AppRefer.support.testimonials.present(requestId: requestId) { result in
    print(result.outcome, result.rewardStatus ?? "none")          // submitted, declined, cancelled, unavailable
}
// Or embed: AppReferTestimonialView(requestId: requestId) { result in … }
```

4. Your backend applies the reward: `POST …/support/testimonials/rewards/claim` (2-minute leases),
   applies each `fulfillmentId` at most once in your own system (credits, coach usage,
   subscription time, a discount, a gift, or a merch order you collect the address for yourself),
   then `POST …/rewards/{fulfillmentId}/complete` with `status: "fulfilled"` and your own
   `receiptId`. Only then does the SDK report `fulfilled`.

- The customer's Support session must be verified for the same account
  (`verifyIdentity`); otherwise requests read as unavailable. A reset or account switch
  cancels a capture in progress; nothing is shared for another account.
- Taking part earns the reward whatever the customer says and whether or not the media is ever
  used. Public use is a separate, optional yes/no, revocable later
  (`withdrawPublication(requestId)`); the reward is never taken back.
- Photos are re-encoded as JPEG (≤ 2048 px, no location or other metadata); videos are exported as
  MP4 without metadata and refused when longer than the campaign allows. Limits: 15 MB per photo,
  150 MB per video. The server checks the stored bytes and video length again.
- Requests from Support show as a card in the chat ("Share a photo or video"); older SDK versions
  show your text and a line asking the customer to update the app.
- The Support home shows the newest open request for the verified account as a card each time it
  opens (never a pop-up). Requests your backend, coach or automation made appear there by
  themselves; shared, declined, withdrawn or ended ones leave it, and another account's never show.
- Automated asks (a campaign `automation`, switched on separately in Support): the invitation is that
  home card. The SDK declares the `testimonials` engagement capability and opens a tapped
  invitation notification (`/apprefer/testimonials/<requestId>`) as the capture screen itself,
  never through your notification handler. AppRefer only records push invitations as dry runs in
  this release: no notification is sent yet.
- The reward line after sharing is honest about who confirms it: "earned" until your backend
  reports its receipt; then "added to your account" for credits, coach answers and subscription
  time, or "confirmed" for anything else (no shipping or email promise); a failed or late one says
  Support can see it and send it again.
- Camera (optional): offered only when your app declares `NSCameraUsageDescription` (and, for
  video, `NSMicrophoneUsageDescription`) and the device has a camera. The library uses the
  system photo picker, which needs no permission.

0.13.0 is unreleased source (not tagged). Once tagged, install it from Git only: Swift Package Manager, `https://github.com/AppAgentic/apprefer-ios-sdk` at the `0.13.0` tag.

### Languages and your own wording

The chat ships in 35 languages: ar, ca, cs, da, de, el, en, es, es-MX, fi, fr, he, hi, hr, hu, id, it, ja, ko, ms, nb, nl, pl, pt-BR, pt-PT, ro, ru, sk, sv, th, tr, uk, vi, zh-Hans, zh-Hant. Nothing to set up.

- **Which language:** the one your app is running in (`Bundle.main.preferredLocalizations`), so an app that ships fewer languages than the SDK gets a chat that matches its own screens (an English-only app on a German phone shows an English chat). If the SDK has no table for it, the device's preferred languages are tried, then English. Regional variants map sensibly: Latin American Spanish → es-MX, Portuguese outside Brazil → pt-PT, Chinese by script and region, Norwegian → nb.
- **Force a language:** `AppRefer.support.language = "de"` (any shipped code; `nil` follows the app again).
- **Right to left:** in Arabic and Hebrew the chat lays out right to left, bubbles' tails included.
- **Your own wording:** set any key; your text wins over the SDK's translation in every language. Placeholders are written `{name}` and filled in by name, so you can reorder them.

```swift
AppRefer.support.strings = [
    "support.home.subtitle": "What can we fix for you?",
    "support.presence.team": "Real humans · usually {time}",
    "support.a11y.unread#one": "One new reply",   // plural keys: "#one", "#few", … or the bare key for every count
]
// For your own app languages, set the values for the language you're showing:
if Bundle.main.preferredLocalizations.first == "de" { AppRefer.support.strings = ["support.home.subtitle": "Wie können wir helfen?"] }
```

`title`, `replyTime` and topic texts you set are shown as written. The defaults are translated, and `replyTime` is inserted into a translated sentence: in most languages that sentence already carries its own "in", so give the whole phrase (German `"innerhalb weniger Stunden"`, French `"en quelques heures"`). The built-in tiles (`.billing`, `.restore`, `.bug`, `.idea`) translate themselves; their title becomes the conversation subject in the customer's language.

Every key, its English text, a note for translators and all translations are in [`Localization/support-strings.json`](Localization/support-strings.json), the table all four AppRefer SDKs share. Messages your team writes and the AI assistant's answers and hand-over line come from AppRefer, not from this table.

### Help centre and status (0.10.0)

Publish help articles in AppRefer (dashboard, API or MCP) and they appear in the chat with no code: a "Help articles" card on the help home (search and the first three; "See all" with more), a help centre screen (articles by category, search that filters as you type and then asks the server, which also searches article bodies) and a reader. The reader renders markdown (headings, lists, bold and italic, code, quotes, links and https images); HTML is never run and only http(s) and mailto links are kept, opened outside the app. "Still need help? Message us" goes back to the message field with the article's title as the conversation subject. Apps without published articles see no help section at all. Articles come in the chat's language (the best translation the server has); lists are kept in memory for five minutes, and offline the chat shows what it had, never an error screen. Test keys (`pk_test_`) also show drafts, marked "Draft".

```swift
// Open straight on the help centre or one article (any translation's slug works)
AppRefer.support.openHelpCentre()
AppRefer.support.open(article: "restore-purchases")
AppReferSupportView(opening: .article("restore-purchases"))   // or .helpCentre / .conversation(id) / .home

// Your own help screens
let articles = try await AppRefer.support.articles()                 // [AppReferHelpArticle]: slug, title, summary, category, url, updatedAt, isDraft
let results = try await AppRefer.support.articles(query: "refund")   // server search (titles, summaries, bodies), up to 20
do {
    let article = try await AppRefer.support.article(slug: "refunds") // AppReferHelpArticleDetail: + body (markdown)
} catch let error as AppReferSupportError where error.isNotFound { /* removed or unpublished */ }

// Is Support ready?
let status = try await AppRefer.support.status()
status.pushReady            // APNs key configured and accepted by Apple (and not rejected for this build's environment)
status.emailReplies         // customers can answer reply emails
status.helpCentreArticles   // published articles
```

`status()` follows the server's caching (5 minutes once every configured channel is verified, else 30 seconds), so calling it on every launch is cheap. Register for reply notifications only when `pushReady` is true. The line under a customer's last message follows the same status: "we'll notify you" when push is ready and the app registered, "we'll email you" when replies are emailed and the customer gave an email in `identify`, otherwise "the team's reply will appear here".

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

### Collection control (0.9.1)

```swift
await AppRefer.setCollectionEnabled(false)
```

Call this when collection consent is withdrawn. The choice persists across launches. Disabling cancels in-flight attribution, conversion-value, consent and product-event traffic, clears the durable event queue, and blocks activation/background retries. Configure returns cached attribution (or an unavailable/failed result if none exists) while disabled. Support and Billing continue independently. Call `setCollectionEnabled(true)` and then configure again to resume; enabling alone sends nothing. Calling it with `true` while collection is already on changes nothing (no pause, no queue clear). `configure(userId:)` still stores the user id while collection is off, so Support uses that account. Reset does not change this choice.

Product events include `app_user_id` from the identity set via `setUserId` when tracked. The identity is saved in the queued payload, so retries and relaunches retain the original account even after a user switch. Without an identity the field is omitted. Internal events whose names start with `_` retain their existing payloads.
