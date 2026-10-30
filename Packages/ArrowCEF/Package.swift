// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The CEF binary distribution fetched by scripts/fetch-cef.sh: the C API
// headers and, on Windows and Linux, libcef. CEF_ROOT overrides it.
let cefRoot = ProcessInfo.processInfo.environment["CEF_ROOT"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Vendor/cef").standardizedFileURL
    .withUnsafeFileSystemRepresentation { String(cString: $0!) }

let package = Package(
    name: "ArrowCEF",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ArrowCEF", targets: ["ArrowCEF"]),
        .executable(name: "cef-shell", targets: ["CEFShell"]),
    ],
    dependencies: [
        .package(path: "../ArrowKit"),
    ],
    targets: [
        // The CEF C API as a Clang module (Sources/CEF/CEF.h).
        .systemLibrary(name: "CEF"),
        // Xlib, to host browsers in X11 windows on Linux.
        .systemLibrary(name: "CX11", pkgConfig: "x11", providers: [.apt(["libx11-dev"])]),
        // Swift bindings of the C API, implementing ArrowEngine's protocols.
        // The macOS app links the CEF framework itself; Windows and Linux
        // link libcef here.
        .target(
            name: "ArrowCEF",
            dependencies: [
                "CEF",
                .target(name: "CX11", condition: .when(platforms: [.linux])),
                .product(name: "ArrowEngine", package: "ArrowKit"),
            ],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(cefRoot)"])],
            linkerSettings: [
                .linkedLibrary("libcef", .when(platforms: [.windows])),
                .linkedLibrary("cef", .when(platforms: [.linux])),
                .unsafeFlags(["-L\(cefRoot)/Release"], .when(platforms: [.windows, .linux])),
                // libcef.so is installed next to the executable.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "$ORIGIN"], .when(platforms: [.linux])),
            ]
        ),
        // The smallest app on ArrowCEF: one window with one browser, to check
        // the bindings on Windows and Linux. macOS runs Arrow itself.
        .executableTarget(
            name: "CEFShell",
            dependencies: [
                .target(name: "ArrowCEF", condition: .when(platforms: [.windows, .linux])),
                .target(name: "CX11", condition: .when(platforms: [.linux])),
                .product(name: "ArrowEngine", package: "ArrowKit"),
            ],
            exclude: ["cef-shell.exe.manifest"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(cefRoot)"])]
        ),
    ]
)
