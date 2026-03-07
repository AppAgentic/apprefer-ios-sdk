// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppRefer",
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [
        .library(name: "AppRefer", targets: ["AppRefer"]),
    ],
    targets: [
        .target(name: "AppRefer"),
        .testTarget(name: "AppReferTests", dependencies: ["AppRefer"]),
    ]
)
