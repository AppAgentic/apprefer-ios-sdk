# AppRefer iOS SDK

First-party mobile attribution for iOS apps. Zero external dependencies.

## Installation

Add to your Xcode project via Swift Package Manager:

```
https://github.com/AppAgentic/apprefer-ios-sdk
```

Or add to `Package.swift`:

```swift
.package(url: "https://github.com/AppAgentic/apprefer-ios-sdk", from: "0.1.0")
```

**Requirements:** iOS 14+, Swift 5.9+

## Usage

```swift
import AppRefer

// In your App init or AppDelegate
let attribution = try await AppRefer.configure(
    backendURL: "https://trk.yourdomain.com",
    appId: "your-app-id"
)

// Link RevenueCat user ID
try await AppRefer.setUserId(Purchases.shared.appUserID)

// Track events
try await AppRefer.trackEvent("signup")

// Advanced matching (hashed on-device)
try await AppRefer.setAdvancedMatching(email: "user@example.com")
```

## License

Proprietary. All rights reserved.
