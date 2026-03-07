# AppRefer iOS SDK

First-party mobile attribution for iOS apps. Captures click IDs, resolves attribution, and forwards conversions to ad networks — without third-party SDKs.

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
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
    .package(url: "https://github.com/AppAgentic/apprefer-ios-sdk", from: "0.1.0")
]
```

## Quick Start

```swift
import AppRefer

@main
struct MyApp: App {
    init() {
        Task {
            let attribution = try await AppRefer.configure(
                backendURL: "https://trk.yourdomain.com",
                appId: "your-app-id"
            )

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

## API

### Configure

Call once at app launch. Resolves attribution on first install, returns cached result on subsequent launches.

```swift
let attribution = try await AppRefer.configure(
    backendURL: "https://trk.yourdomain.com",
    appId: "your-app-id",
    userId: nil,        // optional RevenueCat user ID
    debug: false        // enable verbose logging
)
```

### Link RevenueCat User ID

Connect the device to RevenueCat so purchase webhooks can be attributed.

```swift
try await AppRefer.setUserId(Purchases.shared.appUserID)
```

### Track Events

Track non-purchase events. Purchases are handled automatically via RevenueCat webhooks.

```swift
try await AppRefer.trackEvent("signup")
try await AppRefer.trackEvent("tutorial_complete", properties: ["step": "final"])
```

### Advanced Matching

Improve ad network match rates by sending hashed PII. All data is SHA256-hashed on-device before transmission.

```swift
try await AppRefer.setAdvancedMatching(
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

## Requirements

- iOS 14.0+
- Swift 5.9+
- Zero external dependencies

## License

Proprietary. All rights reserved.
