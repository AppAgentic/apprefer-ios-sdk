## 0.12.0 (unreleased)

- Support review cards: an optional "Write a review" card the team can attach to a reply. It opens the app's App Store write-review page (`https://apps.apple.com/app/id<id>?action=write-review`) with the system URL opener, after the same ≤ 3 s `opened` receipt check as offer cards (`POST …/reviews/{cardId}/events`; refresh `GET …/conversations/{id}/reviews`). The SDK opens only that exact URL shape, never calls `requestReview` from a button, shows no stars and never claims a review was written. Requests announce `reviews` in `X-AppRefer-Support-Features`. Neutral copy in 35 languages (8 new `support.review.*` keys, 130-key table). No new dependency.
- Support offer cards: a team member or the AI assistant can attach one of the app's AppRefer Billing offerings to a reply. The chat draws a card (title, packages with the store's own formatted prices when AppRefer Billing is configured, "Current plan" tag, "View offer") in the Concierge style, light and dark, and calls the new `onOffer` callback with `{ cardId, conversationId, offeringId, packageId }` so the app opens its own paywall (`closesChatOnOffer`, default true, closes the chat first). No paywall, purchase, price, discount or deadline of the SDK's own; a tap is an `opened` receipt, never a purchase. Disabled states: owned, no longer available, and "can't be opened in this version" when the app sets no `onOffer`. Requests send `X-AppRefer-Support-Features: offers[, offer-handler]` and the thread asks for `?platform=`; cards refresh on open, every 30 s, after Billing changes and on foreground (`GET …/conversations/{id}/offers`). `shown`/`opened` receipts (`POST …/offers/{cardId}/events`) are queued on the device (7 days, 8 attempts, same id on every retry) and dropped by `reset()`/`clearIdentity()`; an `opened` tap waits at most 3 s for the server and redraws a withdrawn card instead of opening the paywall. 15 new `support.offer.*` strings in all 35 languages (122-key table).
- Support: `verifyIdentity(identityToken)` confirms who the customer is with a short-lived, single-use token your backend gets from AppRefer (`POST /api/v1/apps/{appId}/support/identity-tokens`, private key, never in the app). It verifies the current Support session (`POST /api/support/v1/session/identity`), so existing conversations on it count; returns `{ verified, reason, appUserId }`. Network and server failures are retried with the same token (the server acknowledges a retry from the same session), then thrown. A reset, `clearIdentity()` or a different user id while it runs answers `account_changed`; the token is never stored or logged. After `clearIdentity()` nothing is sent (`identity_cleared`). `identify(name, email)` is unchanged.
- Version 0.12.0 (prerelease source for the actionable Support roadmap; not tagged or released).

## 0.11.2 (unreleased)

- Support: `.plain` header style now also draws the avatar on the home's Continue card (the chat icon, or the first team member's initial) in the header's neutral greys (`#6B6B6B` to `#3A3A3A`, white glyph ≥ 5:1) instead of the accent's neighbours, which were pale mint for a white accent. The AI persona's portrait still covers it. No new API; the default accent style is unchanged, and the help tiles, conversation list and chat are untouched.
- Version 0.11.2. No other change.

## 0.11.1 (unreleased)

- Support: `AppRefer.support.headerStyle` (`AppReferSupportHeaderStyle.accent` default, `.plain`). `.plain` draws the help home's header as one flat neutral grey (dark `#1C1C1C`, light `#EBEBEB`) with white / near-black text: no accent fill, no radial glows, neutral presence pill, close button, initials tile and presence avatars (the AI portrait still shows). For apps whose design has no colour accents, where even a white `accentColor` gave the hero tinted glows. `.accent` is unchanged; bubbles, buttons and the rest of the chat keep `accentColor` in both.
- Version 0.11.1. No other change: lifecycle engagement stays off / dry run, Billing and attribution are untouched.

## 0.11.0 (unreleased)

- Lifecycle engagement client: `AppRefer.engagement` (`start`, `setDeviceToken`, `refreshDeviceState`, `notificationPermission`, `preferences`/`setPreferences` for marketing, reminders and service, `identify(assertion:)`, `logout`, `deleteInstall`, `onNotificationEvent`, `setNavigationReady`, `handle(_:)`, `presentationOptions(for:)`, `registerNotificationCategories`). Off unless the app starts it and AppRefer enabled it for the app (dry run on the server in this release).
- New extension-safe library product `AppReferNotifications` for the host's Notification Service Extension: `AppReferNotificationService` adds an allowlisted HTTPS PNG/JPEG image (bounded size, time and pixels, redirects refused, ephemeral session, exactly one content-handler call including expiry races) and otherwise delivers the text unchanged; `AppReferEngagementPayload` parser; App Group shared identity and "received" markers. The main `AppRefer` product depends on it.
- Notification buttons: 16 categories `apprefer.eng.<kind>[.<kind>]` merged with the app's own, labelled from the 35-language table (new keys `engagement.action.open|view|start|snooze`, `engagement.channel.*`).
- `AppRefer.trackEvent` carries the engagement install credential (`X-AppRefer-Install`) only for events the app chose, only to AppRefer, only while the same install and identity are current; queued events keep a stamp, never the credential. `AppRefer.reset()` also logs engagement out; `setCollectionEnabled` and `configure` keep it in step.
- Push tokens use the 0.10.1 signing-environment detection (`AppRefer.support.pushEnvironment` override).
- Sample host with a Notification Service Extension: `Samples/EngagementHost` (xcodegen).
- Review fixes (before release): queued events carry the account epoch they were queued under (in their stamp, and as `X-AppRefer-Install-Epoch` with the credential), and the last confirmed epoch is persisted per install, so an event queued under one account never goes out for another after a cold restart, a backend bind or a logout; preference changes, sign-in and logout send the epoch they were made for (`expectedEpoch`, required by the server) and a stale one is refused (`identityChanged`; a stale saved logout is settled, never applied to the next account); reading preferences learns their epoch; an expired notification never navigates, even when its tap waited for `setNavigationReady`; sources shared by copy with the other SDKs are hash-checked by this repo's tests (`shared-sources.json`).
- Any identity change (sign-in, logout, reset, deletion, key switch, an epoch the server moved, also one learned at a cold start) removes AppRefer's own pending and delivered local snoozes (`apprefer.eng.snooze.*`); a snooze whose system add was still in flight is removed when it lands. The app's and Support's notifications are untouched.
- Version 0.11.0.

## 0.10.1 (unreleased)

- Support push: the APNs environment for `registerDeviceToken` and `status().pushReady` is now read from the app's signing instead of the DEBUG flag. The embedded provisioning profile's `aps-environment` decides (`development` = sandbox, `production` = production); with no profile (App Store, TestFlight) or an unreadable one, production; the Simulator uses sandbox. A development-signed Release build (internal testers) now registers sandbox tokens, and a distribution-signed Debug build production ones. Parsing uses only Foundation (`PropertyListSerialization` on the profile's embedded XML plist, files over 2 MB ignored).
- New `AppRefer.support.pushEnvironment` (`AppReferPushEnvironment?`, nil = detect) to force an environment, and `effectivePushEnvironment` to read the one in use.
- Version 0.10.1.

## 0.10.0 (unreleased)

- Help centre in the Support chat. With published articles, the help home shows a "Help articles" card (search entry, top three, "See all"); a help centre screen lists every article by category with search (instant local filter, then the server's search 300 ms after the last keystroke); an article reader renders markdown with a small safe parser (headings, setext headings, ordered/unordered/nested/task lists, quotes, fenced code, rules, https images; inline bold, italic, code, strikethrough, links via `AttributedString(markdown:)`). HTML is stripped (script/style with their content) and links keep only http(s) and mailto, opened outside the app. "Still need help? Message us" returns to the message field with the article's title as the subject. No articles: no section. Concierge design, Liquid Glass header, 35 languages.
- New `AppRefer.support.articles(query:)`, `article(slug:)` (throws `AppReferSupportError` with `isNotFound` on 404) and `status()` (`AppReferSupportStatus`: `pushReady`, `emailReplies`, `helpCentreArticles`, raw push/email fields). Help requests need only the SDK key (no support session); lists and articles are cached in memory for five minutes, with the last copy used offline; the status honours the server's Cache-Control (5 min / 30 s).
- New `AppRefer.support.open(article:)`, `openHelpCentre()` and `AppReferSupportView(opening:)` (`.home`, `.helpCentre`, `.article(slug)`, `.conversation(id)`); Back always leads to the help home.
- The line under the customer's last message says how the reply will reach them: notification (push ready and registered), email (replies emailed and an email was given), or "the team's reply will appear here".
- 22 new strings (`support.help.*`, `support.status.*`) in all 35 languages; the shared table now has 100 keys.
- Version 0.10.0.
- Support chat localized into 35 languages (ar, ca, cs, da, de, el, en, es, es-MX, fi, fr, he, hi, hr, hu, id, it, ja, ko, ms, nb, nl, pl, pt-BR, pt-PT, ro, ru, sk, sv, th, tr, uk, vi, zh-Hans, zh-Hant): every title, button, placeholder, quick-help tile, status line, error and accessibility label. Strings ship as `.lproj/Localizable.strings` package resources (`defaultLocalization: "en"`), generated by `scripts/generate-support-strings.py` from `Localization/support-strings.json`, the 78-key table shared with the Android, Flutter and React Native SDKs. Plural labels follow CLDR rules per language.
- The chat follows the language the host app is running in (`Bundle.main.preferredLocalizations`), then the device's languages, then English, so an app that ships fewer languages gets a chat that matches it. `AppRefer.support.language` forces one.
- New `AppRefer.support.strings: [String: String]`: your text for any key, used before the bundled translations in every language (`{placeholders}` filled by name; plural keys as `key#one` etc. or the bare key).
- `replyTime`, `title` and the built-in topics (`.billing`, `.restore`, `.bug`, `.idea`) default to the chat's language; values you set are shown as written. `replyTime` is still a `String` property. Built-in topic ids are now `billing`, `restore`, `bug`, `idea` (were their English titles).
- Errors in the chat are shown in the customer's language (offline, rate limit, message too long, upload failed, device locked) instead of the server's English message. `AppReferSupportError.message` still carries the raw message for logs.
- Right-to-left: Arabic and Hebrew lay the chat out right to left, including the bubble tails, the back chevron and the screenshot remove buttons; dates and times use the chat's language.
- Support's revocation queue now uses the same injectable Keychain as the session token (production still uses the real Keychain). Tests that touch the Keychain use an in-memory one, so they also pass in a hostless iOS-simulator test bundle, where the real Keychain returns errSecMissingEntitlement (-34018).
- README: RevenueCat examples replaced with AppRefer Billing ones.

## 0.9.3

- Support: a revocation queued while a revocation pass is running (by clearIdentity() or by retiring a cleared session) is now processed in the same app session: the running pass runs again when it finishes, instead of waiting for the next launch or foreground.
- Billing: reset() now saves the Billing user that was current at that moment (anonymous or signed in) as `apprefer_billing_reset_user`, so the account gate survives a relaunch. While that user is still the current Billing user, customers/purchases requests carry no install device id or device attributes, the customer is never re-linked, and `/identify` sends `link: false`. The marker is cleared by any explicit logIn (even with the same id) or logOut, and when the Billing user changes to a different id. Nothing is saved if Billing never had a user. reset() does not mark the fresh anonymous id that logOut() minted in this app session (for apps that call logOut() before reset()); that exemption is used once, so a later reset() while the same anonymous user is current marks them. A marker write from reset() is skipped only when a logIn/logOut called after reset() has been applied (validated and the new user stored); a logIn that throws never cancels it. Billing configured while reset() runs cancels it only when configured with a different appUserId. The marker is kept in the Keychain next to Billing's anonymous id, so a reinstall that keeps that identity keeps the marker; if it can't be read, the gate stays closed.
- Support: registering a push token that a session waiting for revocation still holds (after reset() or clearIdentity(), including tokens saved by older versions) no longer posts it at once. The pending revocation is marked to move the token with the environment just registered, and the token is posted to the current session only after the old session is revoked.
- The "session started while identity was cleared" marker and the identity-cleared flag are now kept in the Keychain next to the Support session token, so a reinstall that keeps the session also keeps them. Values saved in UserDefaults by 0.9.2 are moved on first read. If the Keychain can't be read (before first unlock, or failing), both read as cleared, and Support starts or adopts no session until it can be read (a retryable error); the marker is never recorded for a session token that couldn't be saved, and a stored session token is deleted only when it is the one being retired, never because of a locked read.

## 0.9.2

- Billing sends no install device id (`appreferId`) or device attribute (`$idfa`, `$idfv`, `$fbAnonId`, `$attConsentStatus`, `$deviceVersion`, `$ip`, `$gpsAdId`) with customers/purchases requests while collection is off (including a pause waiting for configure), after reset() until configure/configureResult runs again, or in Billing-only apps. It reuses the Support device id gate; queued purchases are resent without it while the gate is closed, and Billing then uses apprefer.com rather than trk.apprefer.com. Purchases, restore, entitlements and offerings are unchanged. A customer registered without the device id is linked once after configure.
- Billing's device id and that re-link are tied to the account: after reset() they are sent only for the Billing user set after the reset (logIn/logOut); purchases and queued purchases of the previous Billing user never get it. `/identify` sends `link: false` while the gate is closed, so the server merges anonymous purchases without copying the install link.
- setCollectionEnabled(false) pauses at once, before any await, so Billing and Support see it immediately.
- Add `AppRefer.support.clearIdentity()`: forgets the Support name, email and app user id, revokes the current Support session through the durable revocation path and starts a new anonymous session that sends neither the app user id nor the install device id. The push token moves to the new session only after the old session's revocation succeeds. Conversations from the old session are no longer visible in the app; they stay in the team inbox. Support stays anonymous until the user id changes or reset() runs; a different user id stored later without reset() gets a fresh session (the anonymous one is revoked, never handed over).

## 0.9.1

- Migration: after reset(), call configure again for the next user; until then events, attribution and consent reports are paused.
- Product events capture `app_user_id` at track time and persist it with the queued payload, preserving identity across retries, restarts, and account switches. Internal `_` events are unchanged.
- Add persistent `setCollectionEnabled` control. Disabling cancels attribution, consent, conversion-value and event requests and clears queued events; Support and Billing remain available. Enable, then call configure to resume.
- Support sends no device id after reset() or while collection is off. reset() also stops attribution (consent re-reports, conversion values, event sends) until configure is called again; events tracked meanwhile are dropped, never queued or sent later.
- setCollectionEnabled(true) while collection is already on is a no-op: it no longer pauses collection or clears the saved event queue. Only a saved "off" or the server kill switch clears queued events.
- configure(userId:) stores the user id even while collection is off, so Support uses the new account.

## 0.9.0 — 2026-10-16

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
