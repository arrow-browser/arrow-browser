import CWinRT
import Foundation
// The projection's initializer from an interface pointer is internal to
// swift-winrt (WinRTInternal): GetForWindow returns such a pointer.
@_spi(WinRTInternal) import UWP
import WinSDK
@_spi(WinRTInternal) import WindowsFoundation

/// Windows' share sheet for a page (Share URL), as Arc opens it: a desktop
/// app reaches it through `IDataTransferManagerInterop`, for its window.
@MainActor
enum ShareSheet {
    private struct Page {
        var title: String
        var url: String
    }

    /// Each window's share manager, and the page it shares next.
    private static var managers: [Int: DataTransferManager] = [:]
    private static var pages: [Int: Page] = [:]

    // {3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8}
    private static var interopID = WinSDK.IID(
        Data1: 0x3A3D_CD6C, Data2: 0x3EAB, Data3: 0x43DC, Data4: (0xBC, 0xDE, 0x45, 0x67, 0x1C, 0xE8, 0x00, 0xC8))
    // {A5CAEE9B-8708-49D1-8D36-67D25A8DA00C}
    private static var managerID = WinSDK.IID(
        Data1: 0xA5CA_EE9B, Data2: 0x8708, Data3: 0x49D1, Data4: (0x8D, 0x36, 0x67, 0xD2, 0x5A, 0x8D, 0xA0, 0x0C))

    private typealias GetForWindow = @convention(c) (UnsafeMutableRawPointer?, HWND?, UnsafePointer<WinSDK.IID>?,
                                                     UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> HRESULT
    private typealias ShowShareUIForWindow = @convention(c) (UnsafeMutableRawPointer?, HWND?) -> HRESULT

    /// Shows the share sheet for `url`, over `window`: whether it opened.
    @discardableResult
    static func share(title: String, url: String, from window: HWND) -> Bool {
        let key = Int(bitPattern: UnsafeRawPointer(window))
        pages[key] = Page(title: title, url: url)
        guard let interop = interopFactory() else { return false }
        let table = interop.assumingMemoryBound(to: UnsafePointer<UnsafeRawPointer?>.self).pointee
        if managers[key] == nil {
            var pointer: UnsafeMutableRawPointer?
            let getForWindow = unsafeBitCast(table[3], to: GetForWindow.self)
            guard getForWindow(interop, window, &managerID, &pointer) >= 0, let pointer else { return false }
            let inspectable = WindowsFoundation.IInspectable(ComPtr(pointer.assumingMemoryBound(to: C_IInspectable.self)))
            let manager = DataTransferManager(fromAbi: inspectable)
            manager.dataRequested.addHandler { _, event in
                guard let data = event?.request?.data, let page = pages[key] else { return }
                data.properties.title = page.title.isEmpty ? page.url : page.title
                try? data.setWebLink(Uri(page.url))
                try? data.setText(page.url)
            }
            managers[key] = manager
        }
        let show = unsafeBitCast(table[4], to: ShowShareUIForWindow.self)
        return show(interop, window) >= 0
    }

    /// The activation factory of DataTransferManager, as its interop
    /// interface.
    private static func interopFactory() -> UnsafeMutableRawPointer? {
        var factory: UnsafeMutableRawPointer?
        "Windows.ApplicationModel.DataTransfer.DataTransferManager".withHStringRef { name in
            _ = RoGetActivationFactory(name, &interopID, &factory)
        }
        return factory
    }
}
