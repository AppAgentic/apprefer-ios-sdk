// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppRefer",
    platforms: [.iOS(.v14), .macOS(.v11)],
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
