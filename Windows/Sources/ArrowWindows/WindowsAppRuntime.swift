import WinSDK

/// The Windows App SDK runtime, which WinUI runs on: a framework package
/// installed by its redistributable. Unpackaged apps reach it through its
/// bootstrapper DLL, installed next to them (stage.ps1).
enum WindowsAppRuntime {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    // WINDOWSAPPSDK_RELEASE_MAJORMINOR and WINDOWSAPPSDK_RUNTIME_VERSION_UINT64
    // of Microsoft.WindowsAppSDK 2.5.1 (WindowsAppSDK-VersionInfo.h), the
    // version projections.json generates the projections from.
    private static let majorMinorVersion: UInt32 = 0x0002_0005
    private static let minimumVersion: UInt64 = 0x0002_0005_0001_0000

    private typealias Initialize = @convention(c) (
        _ majorMinorVersion: UInt32, _ versionTag: UnsafePointer<WCHAR>?, _ minVersion: UInt64, _ options: Int32
    ) -> HRESULT

    /// Adds the runtime to the process (MddBootstrapInitialize2).
    static func initialize() throws(Failure) {
        let library = "Microsoft.WindowsAppRuntime.Bootstrap.dll"
        guard let module = library.withCString(encodedAs: UTF16.self, { LoadLibraryW($0) }),
              let address = GetProcAddress(module, "MddBootstrapInitialize2") else {
            throw Failure(description: "\(library) is missing next to Arrow.exe")
        }
        let initialize = unsafeBitCast(address, to: Initialize.self)
        let result = "".withCString(encodedAs: UTF16.self) { initialize(majorMinorVersion, $0, minimumVersion, 0) }
        guard result >= 0 else {
            throw Failure(description: "the Windows App SDK 2.5 runtime is not installed "
                + "(MddBootstrapInitialize2: 0x\(String(UInt32(bitPattern: result), radix: 16)))")
        }
    }
}
