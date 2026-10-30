// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The CEF binary distribution fetched by scripts/fetch-cef.sh, for the C API
// headers. CEF_ROOT overrides it.
let cefRoot = ProcessInfo.processInfo.environment["CEF_ROOT"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Vendor/cef").standardizedFileURL.path

let package = Package(
    name: "ArrowCEF",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ArrowCEF", targets: ["ArrowCEF"]),
    ],
    dependencies: [
        .package(path: "../ArrowKit"),
    ],
    targets: [
        // The CEF C API as a Clang module (Sources/CEF/CEF.h).
        .systemLibrary(name: "CEF"),
        // Swift bindings of the C API, implementing ArrowEngine's protocols.
        .target(
            name: "ArrowCEF",
            dependencies: [
                "CEF",
                .product(name: "ArrowEngine", package: "ArrowKit"),
            ],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(cefRoot)"])]
        ),
    ]
)
