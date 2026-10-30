import ArrowCEF
import ArrowEngine
import ArrowKit
import Foundation
import UWP
import WinAppSDK
import WinSDK
import WindowsFoundation
import WinUI

/// A WinUI window with one browser under a toolbar: back, forward, reload
/// and the address field. The browser is a child window of the WinUI
/// window's, kept over the area the layout leaves it.
@MainActor
final class BrowserWindow: BrowserEngineDelegate {
    let browser: CEFBrowser
    /// Called once the window has closed.
    var onClose: (() -> Void)?
    /// Called when a page finishes loading, with its address and HTTP status.
    var onLoad: ((_ url: String, _ httpStatusCode: Int) -> Void)?

    private let window: Window
    private let handle: HWND
    private let backButton = BrowserWindow.toolbarButton(glyph: "\u{E72B}", name: "Back")
    private let forwardButton = BrowserWindow.toolbarButton(glyph: "\u{E72A}", name: "Forward")
    private let reloadButton = BrowserWindow.toolbarButton(glyph: "\u{E72C}", name: "Reload")
    private let addressField = TextBox()
    /// Where the browser goes in the layout.
    private let browserArea = Border()

    init(url: String) throws {
        browser = CEFBrowser(requestContext: .global())
        window = Window()
        handle = try window.handle()
        window.title = "Arrow"
        window.content = try layout()
        try window.appWindow.resize(SizeInt32(width: 1280, height: 800))
        try window.activate()
        browser.delegate = self
        browser.hostWindow.attach(to: handle, frame: .zero)
        // Over WinUI's own child window, which draws the toolbar.
        SetWindowPos(browser.hostWindow.handle, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE))
        browser.create(url: url)
        observe()
        layoutBrowser()
    }

    /// Whether the browser is a child of this window (smoke test).
    var isBrowserHosted: Bool {
        GetAncestor(browser.hostWindow.handle, UINT(GA_ROOT)) == handle
    }

    /// Closes the browser, then the window (`browserDidClose`).
    func close() {
        browser.close(force: false)
    }

    // MARK: - Layout

    private func layout() throws -> UIElement {
        let toolbar = Grid()
        toolbar.padding = Thickness(left: 8, top: 6, right: 8, bottom: 6)
        toolbar.columnSpacing = 4
        let items: [FrameworkElement] = [backButton, forwardButton, reloadButton, addressField]
        for (column, item) in items.enumerated() {
            let definition = ColumnDefinition()
            definition.width = item === addressField ? .star : .auto
            toolbar.columnDefinitions.append(definition)
            try Grid.setColumn(item, Int32(column))
            toolbar.children.append(item)
        }
        addressField.placeholderText = "Search or enter address"
        addressField.verticalAlignment = .center
        backButton.isEnabled = false
        forwardButton.isEnabled = false

        let root = Grid()
        for height in [GridLength.auto, .star] {
            let definition = RowDefinition()
            definition.height = height
            root.rowDefinitions.append(definition)
        }
        try Grid.setRow(browserArea, 1)
        root.children.append(toolbar)
        root.children.append(browserArea)
        return root
    }

    private static func toolbarButton(glyph: String, name: String) -> Button {
        let button = Button()
        button.content = glyph
        button.fontFamily = FontFamily("Segoe Fluent Icons")
        try? AutomationProperties.setName(button, name)
        return button
    }

    private func observe() {
        backButton.click.addHandler { [weak self] _, _ in self?.browser.goBack() }
        forwardButton.click.addHandler { [weak self] _, _ in self?.browser.goForward() }
        reloadButton.click.addHandler { [weak self] _, _ in self?.browser.reload() }
        addressField.keyDown.addHandler { [weak self] _, event in
            guard let self, let event, event.key == .enter else { return }
            event.handled = true
            browser.load(url: URLInput.resolve(addressField.text, engine: .google))
            browser.setFocus(true)
        }
        browserArea.sizeChanged.addHandler { [weak self] _, _ in self?.layoutBrowser() }
        window.closed.addHandler { [weak self] _, event in
            // The window closes once the browser has (browserDidClose).
            guard let self, !browser.isClosed else { return }
            event?.handled = true
            close()
        }
    }

    /// Puts the browser over `browserArea`, in physical pixels.
    private func layoutBrowser() {
        guard let root = browserArea.xamlRoot,
              let origin = try? browserArea.transformToVisual(nil).transformPoint(Point(x: 0, y: 0)) else { return }
        let scale = root.rasterizationScale
        browser.hostWindow.setFrame(CGRect(x: Double(origin.x) * scale, y: Double(origin.y) * scale,
                                           width: browserArea.actualWidth * scale,
                                           height: browserArea.actualHeight * scale).integral)
    }

    // MARK: - BrowserEngineDelegate

    func browser(_ engine: any BrowserEngine, didChangeAddress url: String) {
        addressField.text = url == ArrowApp.startPage ? "" : url
    }

    func browser(_ engine: any BrowserEngine, didChangeTitle title: String) {
        window.title = title.isEmpty ? "Arrow" : "\(title) - Arrow"
    }

    func browser(_ engine: any BrowserEngine, didChangeLoadingState isLoading: Bool, canGoBack: Bool,
                 canGoForward: Bool) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
    }

    func browser(_ engine: any BrowserEngine, didFinishLoad url: String, httpStatusCode: Int) {
        onLoad?(url, httpStatusCode)
    }

    func browserDidClose(_ engine: any BrowserEngine) {
        try? window.close()
        onClose?()
    }
}

private extension GridLength {
    static let auto = GridLength(value: 1, gridUnitType: .auto)
    static let star = GridLength(value: 1, gridUnitType: .star)
}

extension Window {
    /// The window's Win32 handle, as Microsoft.UI.Interop.h's
    /// GetWindowFromWindowId gets it.
    func handle() throws(WindowsAppRuntime.Failure) -> HWND {
        typealias GetWindowFromWindowId = @convention(c) (UInt64, UnsafeMutablePointer<HWND?>) -> HRESULT
        guard let module = "Microsoft.Internal.FrameworkUdk.dll".withCString(encodedAs: UTF16.self, { LoadLibraryW($0) }),
              let address = GetProcAddress(module, "Windowing_GetWindowFromWindowId") else {
            throw WindowsAppRuntime.Failure(description: "Windowing_GetWindowFromWindowId is missing")
        }
        var handle: HWND?
        let result = unsafeBitCast(address, to: GetWindowFromWindowId.self)(appWindow.id.value, &handle)
        guard result >= 0, let handle else {
            throw WindowsAppRuntime.Failure(description: "no window for \(appWindow.id.value)")
        }
        return handle
    }
}
