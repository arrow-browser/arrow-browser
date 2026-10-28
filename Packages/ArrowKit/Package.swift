// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArrowKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ArrowKit", targets: ["ArrowKit"]),
    ],
    targets: [
        .target(name: "ArrowKit"),
        .testTarget(name: "ArrowKitTests", dependencies: ["ArrowKit"]),
    ]
)
