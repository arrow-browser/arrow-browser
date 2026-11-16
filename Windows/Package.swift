// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Arrow for Windows: a WinUI 3 app on ArrowCore and ArrowCEF.
//
// generate-winrt.ps1 generates the WinRT projections (CWinRT,
// WindowsFoundation, UWP, WinAppSDK, WinUI) before the first build, and
// stage.ps1 installs what the app needs next to it (README.md).

// The CEF binary distribution fetched by scripts/fetch-cef.sh, as in
// Packages/ArrowCEF. CEF_ROOT overrides it.
let cefRoot = ProcessInfo.processInfo.environment["CEF_ROOT"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../Vendor/cef").standardizedFileURL
    .withUnsafeFileSystemRepresentation { String(cString: $0!) }
// Every module that imports ArrowCEF loads the CEF module.
let cefHeaders: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I\(cefRoot)"])]
// The generated projections are Swift 5 code.
let projection: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "ArrowWindows",
    products: [
        // Arrow.dll, loaded by CEF's bootstrap.exe renamed Arrow.exe, which
        // sandboxes Chromium's subprocesses.
        .library(name: "Arrow", type: .dynamic, targets: ["ArrowWindows"]),
    ],
    dependencies: [
        .package(path: "../Packages/ArrowKit"),
        .package(path: "../Packages/ArrowCEF"),
    ],
    targets: [
        .target(name: "CWinRT"),
        .target(name: "WindowsFoundation", dependencies: ["CWinRT"], swiftSettings: projection),
        .target(name: "UWP", dependencies: ["CWinRT", "WindowsFoundation"], swiftSettings: projection),
        .target(name: "WinAppSDK", dependencies: ["CWinRT", "WindowsFoundation", "UWP"], swiftSettings: projection),
        .target(name: "WinUI", dependencies: ["CWinRT", "WindowsFoundation", "UWP", "WinAppSDK"],
                swiftSettings: projection),
        .target(
            name: "ArrowWindows",
            dependencies: [
                "WindowsFoundation", "UWP", "WinAppSDK", "WinUI",
                .product(name: "ArrowKit", package: "ArrowKit"),
                .product(name: "ArrowCore", package: "ArrowKit"),
                .product(name: "ArrowCEF", package: "ArrowCEF"),
            ],
            swiftSettings: cefHeaders
        ),
    ]
)
