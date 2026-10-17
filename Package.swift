// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AppRefer",
    // The Support help chat ships its text in 35 languages (Sources/AppRefer/Resources/*.lproj).
    defaultLocalization: "en",
    // Billing (StoreKit 2) needs iOS 15 / macOS 12 and is gated with @available; tvOS starts at 15
    // so it is always available there. watchOS is not supported (the attribution core uses UIDevice).
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15)],
    products: [
        .library(name: "AppRefer", targets: ["AppRefer"]),
        // For the host app's Notification Service Extension target: extension-safe (Foundation,
        // ImageIO, UserNotifications only; no UIApplication) and independent of AppRefer.
        .library(name: "AppReferNotifications", targets: ["AppReferNotifications"]),
    ],
    targets: [
        .target(name: "AppReferNotifications"),
        .target(
            name: "AppRefer",
            dependencies: ["AppReferNotifications"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AdServices", .when(platforms: [.iOS])),
                .linkedFramework("AdSupport", .when(platforms: [.iOS])),
                .linkedFramework("AppTrackingTransparency", .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(name: "AppReferTests", dependencies: ["AppRefer"]),
        .testTarget(name: "AppReferNotificationsTests", dependencies: ["AppReferNotifications"]),
    ]
)
