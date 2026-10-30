// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArrowKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ArrowKit", targets: ["ArrowKit"]),
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
        .testTarget(name: "ArrowKitTests", dependencies: [
            "ArrowKit",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "CryptoExtras", package: "swift-crypto"),
        ]),
    ]
)
