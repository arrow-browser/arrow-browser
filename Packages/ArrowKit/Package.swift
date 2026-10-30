// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArrowKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ArrowKit", targets: ["ArrowKit"]),
        .library(name: "ArrowCore", targets: ["ArrowCore"]),
    ],
    dependencies: [
        // CryptoKit's API on Linux and Windows (CryptoKit itself on Apple
        // platforms), plus RSA in CryptoExtras.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.3"),
    ],
    targets: [
        .target(name: "ArrowKit", dependencies: [
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "CryptoExtras", package: "swift-crypto"),
        ]),
        // The app's state and services shared by every platform, on top of
        // ArrowKit (docs/PORTABILITY.md).
        .target(name: "ArrowCore", dependencies: ["ArrowKit"]),
        .testTarget(name: "ArrowKitTests", dependencies: [
            "ArrowKit",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "CryptoExtras", package: "swift-crypto"),
        ]),
        .testTarget(name: "ArrowCoreTests", dependencies: ["ArrowCore"]),
    ]
)
