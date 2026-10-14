// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AppRefer",
    // Billing (StoreKit 2) needs iOS 15 / macOS 12 and is gated with @available; tvOS starts at 15
    // so it is always available there. watchOS is not supported (the attribution core uses UIDevice).
    platforms: [.iOS(.v14), .macOS(.v11), .tvOS(.v15)],
    products: [
        .library(name: "AppRefer", targets: ["AppRefer"]),
    ],
    targets: [
        .target(
            name: "AppRefer",
            linkerSettings: [
                .linkedFramework("AdServices", .when(platforms: [.iOS])),
                .linkedFramework("AdSupport", .when(platforms: [.iOS])),
                .linkedFramework("AppTrackingTransparency", .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(name: "AppReferTests", dependencies: ["AppRefer"]),
    ]
)
