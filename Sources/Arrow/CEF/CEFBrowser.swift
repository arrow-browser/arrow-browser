import AppKit
import ArrowCore
import CEF

/// NSView hosting a Chromium browser view. Keeps CEF's child view sized to
/// its bounds and clips it (rounded corners of the content panel).
final class CEFHostView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        for subview in subviews where subview.frame != bounds {
            subview.frame = bounds
        }
    }
}

/// Invisible window holding browser views that are not displayed.
///
/// Chromium needs its view to belong to a window when the browser is created
/// and while it renders in the background (tabs opened in the background,
/// switched-away tabs). Views are parked here instead of being orphaned.
@MainActor
enum CEFParkingLot {
    private static let window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        return window
    }()

    static func park(_ view: NSView) {
        guard let contentView = window.contentView, view.superview !== contentView else { return }
        let size = view.frame.size == .zero ? contentView.bounds.size : view.frame.size
        view.removeFromSuperview()
        view.frame = NSRect(origin: .zero, size: size)
        contentView.addSubview(view)
    }

    static func isParked(_ view: NSView) -> Bool {
        view.superview === window.contentView
    }
}

/// A Chromium browser (one web page) and its CEF handlers.
///
/// Created lazily: `create(url:)` instantiates the native browser inside
/// `hostView`. All public API must be used on the main thread.
final class CEFBrowser: @unchecked Sendable {
    let hostView: CEFHostView
    let requestContext: CEFRequestContext
    @MainActor weak var delegate: (any BrowserEngineDelegate)?

    @MainActor private(set) var browser: CefRef<cef_browser_t>?
    @MainActor private(set) var isClosing = false
    @MainActor private(set) var isClosed = false
    /// True between `on_before_popup` and `on_after_created`.
    @MainActor private var isPendingPopup = false

    private var client: CefHandler<cef_client_t>!
    private var lifeSpanHandler: CefHandler<cef_life_span_handler_t>!
    private var loadHandler: CefHandler<cef_load_handler_t>!
    private var displayHandler: CefHandler<cef_display_handler_t>!
    private var requestHandler: CefHandler<cef_request_handler_t>!
    private var contextMenuHandler: CefHandler<cef_context_menu_handler_t>!
    private var findHandler: CefHandler<cef_find_handler_t>!
    private var focusHandler: CefHandler<cef_focus_handler_t>!
    private var permissionHandler: CefHandler<cef_permission_handler_t>!
    private var devToolsObserver: CefHandler<cef_dev_tools_message_observer_t>!

    @MainActor private var devToolsRegistration: CefRef<cef_registration_t>?
    @MainActor private var nextMessageID: Int32 = 1
    @MainActor private var pendingDevToolsResults: [Int32: (Bool, Data) -> Void] = [:]
    @MainActor private var pendingImageRequests: [ObjectIdentifier: CEFImageRequest] = [:]
    @MainActor private var lastContextMenuParams: ContextMenuParams?

    @MainActor
    init(requestContext: CEFRequestContext, frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)) {
        self.requestContext = requestContext
        hostView = CEFHostView(frame: frame)
        buildHandlers()
    }

    // MARK: - Lifecycle

    @MainActor var isCreated: Bool { browser != nil }

    /// Creates the native browser and starts loading `url`.
    @MainActor
    func create(url: String) {
        guard browser == nil, !isPendingPopup, !isClosed else { return }
        var windowInfo = makeWindowInfo()
        var settings = cef_browser_settings_t()
        settings.size = MemoryLayout<cef_browser_settings_t>.size
        let created = withCefString(url) { url in
            cef_browser_host_create_browser_sync(&windowInfo, client.retained(), url, &settings, nil,
                                                 requestContext.ref.retained())
        }
        if browser == nil {
            browser = CefRef(adopting: created)
            didCreateBrowser()
        } else {
            cefRelease(created)
        }
    }

    @MainActor
    private func makeWindowInfo() -> cef_window_info_t {
        if hostView.window == nil { CEFParkingLot.park(hostView) }
        var windowInfo = cef_window_info_t()
        windowInfo.size = MemoryLayout<cef_window_info_t>.size
        windowInfo.parent_view = Unmanaged.passUnretained(hostView).toOpaque()
        windowInfo.bounds = cef_rect_t(x: 0, y: 0, width: Int32(hostView.bounds.width), height: Int32(hostView.bounds.height))
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY
        return windowInfo
    }

    @MainActor
    private func didCreateBrowser() {
        if let host {
            devToolsRegistration = CefRef(adopting: host.pointer.pointee.add_dev_tools_message_observer?(host.pointer, devToolsObserver.retained()))
        }
        delegate?.browserDidCreate(self)
    }

    /// Browsers kept alive until Chromium confirms they are destroyed, so
    /// close callbacks always find their owner.
    @MainActor private static var closing: [ObjectIdentifier: CEFBrowser] = [:]

    /// Closes the browser, running the page's unload handlers unless `force`.
    @MainActor
    func close(force: Bool) {
        guard !isClosed, !(isClosing && !force) else { return }
        isClosing = true
        Self.closing[ObjectIdentifier(self)] = self
        guard let host else {
            finishClose()
            return
        }
        host.pointer.pointee.close_browser?(host.pointer, force ? 1 : 0)
    }

    @MainActor
    private func tearDownView() {
        for subview in hostView.subviews {
            subview.removeFromSuperview()
        }
    }

    @MainActor
    private func finishClose() {
        defer { Self.closing[ObjectIdentifier(self)] = nil }
        guard !isClosed else { return }
        isClosed = true
        if CEFParkingLot.isParked(hostView) { hostView.removeFromSuperview() }
        devToolsRegistration = nil
        browser = nil
        pendingDevToolsResults.removeAll()
        pendingImageRequests.removeAll()
        delegate?.browserDidClose(self)
    }

    // MARK: - Navigation

    @MainActor var host: CefRef<cef_browser_host_t>? {
        guard let browser else { return nil }
        return CefRef(adopting: browser.pointer.pointee.get_host?(browser.pointer))
    }

    @MainActor var mainFrame: CefRef<cef_frame_t>? {
        guard let browser else { return nil }
        return CefRef(adopting: browser.pointer.pointee.get_main_frame?(browser.pointer))
    }

    @MainActor var identifier: Int32? {
        guard let browser else { return nil }
        return browser.pointer.pointee.get_identifier?(browser.pointer)
    }

    @MainActor
    func load(url: String) {
        guard let frame = mainFrame else {
            create(url: url)
            return
        }
        withCefString(url) { frame.pointer.pointee.load_url?(frame.pointer, $0) }
    }

    @MainActor func goBack() { browser.map { $0.pointer.pointee.go_back?($0.pointer) } }
    @MainActor func goForward() { browser.map { $0.pointer.pointee.go_forward?($0.pointer) } }
    @MainActor func reload() { browser.map { $0.pointer.pointee.reload?($0.pointer) } }
    @MainActor func reloadIgnoringCache() { browser.map { $0.pointer.pointee.reload_ignore_cache?($0.pointer) } }
    @MainActor func stopLoading() { browser.map { $0.pointer.pointee.stop_load?($0.pointer) } }

    @MainActor var canGoBack: Bool { browser.map { $0.pointer.pointee.can_go_back?($0.pointer) != 0 } ?? false }
    @MainActor var canGoForward: Bool { browser.map { $0.pointer.pointee.can_go_forward?($0.pointer) != 0 } ?? false }

    @MainActor
    var currentURL: String? {
        guard let frame = mainFrame else { return nil }
        return String(cefUserFree: frame.pointer.pointee.get_url?(frame.pointer))
    }

    @MainActor
    func executeJavaScript(_ code: String, scriptURL: String) {
        guard let frame = mainFrame else { return }
        withCefString(code) { code in
            withCefString(scriptURL) { url in
                frame.pointer.pointee.execute_java_script?(frame.pointer, code, url, 0)
            }
        }
    }

    @MainActor func viewSource() { mainFrame.map { $0.pointer.pointee.view_source?($0.pointer) } }

    // MARK: - Host operations

    @MainActor
    func setFocus(_ focused: Bool) {
        host.map { $0.pointer.pointee.set_focus?($0.pointer, focused ? 1 : 0) }
    }

    @MainActor
    var zoomLevel: Double {
        get { host.map { $0.pointer.pointee.get_zoom_level?($0.pointer) ?? 0 } ?? 0 }
        set { host.map { $0.pointer.pointee.set_zoom_level?($0.pointer, newValue) } }
    }

    @MainActor
    var isAudioMuted: Bool {
        get { host.map { $0.pointer.pointee.is_audio_muted?($0.pointer) != 0 } ?? false }
        set { host.map { $0.pointer.pointee.set_audio_muted?($0.pointer, newValue ? 1 : 0) } }
    }

    @MainActor
    func find(_ text: String, forward: Bool, findNext: Bool) {
        guard let host else { return }
        withCefString(text) { text in
            host.pointer.pointee.find?(host.pointer, text, forward ? 1 : 0, 0, findNext ? 1 : 0)
        }
    }

    @MainActor
    func stopFinding() {
        host.map { $0.pointer.pointee.stop_finding?($0.pointer, 1) }
    }

    @MainActor
    /// Opens Developer Tools, on `panel` ("console", "network"…) when given.
    func showDevTools(inspectAt point: CGPoint?, panel: String?) {
        guard let host else { return }
        let client = panel.map { CEFDevToolsPanel.client(showing: $0) }
        var windowInfo = cef_window_info_t()
        windowInfo.size = MemoryLayout<cef_window_info_t>.size
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY
        windowInfo.bounds = cef_rect_t(x: 120, y: 120, width: 1000, height: 720)
        var settings = cef_browser_settings_t()
        settings.size = MemoryLayout<cef_browser_settings_t>.size
        if let point {
            var cefPoint = cef_point_t(x: Int32(point.x), y: Int32(point.y))
            host.pointer.pointee.show_dev_tools?(host.pointer, &windowInfo, client, &settings, &cefPoint)
        } else {
            host.pointer.pointee.show_dev_tools?(host.pointer, &windowInfo, client, &settings, nil)
        }
    }

    @MainActor
    var hasDevTools: Bool { host.map { $0.pointer.pointee.has_dev_tools?($0.pointer) != 0 } ?? false }

    @MainActor
    func closeDevTools() { host.map { $0.pointer.pointee.close_dev_tools?($0.pointer) } }

    @MainActor
    func print() { host.map { $0.pointer.pointee.print?($0.pointer) } }

    @MainActor
    func startDownload(url: String) {
        guard let host else { return }
        withCefString(url) { host.pointer.pointee.start_download?(host.pointer, $0) }
    }

    /// Reports the page's preferred size through `didAutoResize`.
    @MainActor
    func enableAutoResize(min: CGSize, max: CGSize) {
        guard let host else { return }
        var minimum = cef_size_t(width: Int32(min.width), height: Int32(min.height))
        var maximum = cef_size_t(width: Int32(max.width), height: Int32(max.height))
        host.pointer.pointee.set_auto_resize_enabled?(host.pointer, 1, &minimum, &maximum)
    }

    @MainActor
    func exitFullscreen() {
        host.map { $0.pointer.pointee.exit_fullscreen?($0.pointer, 1) }
    }

    @MainActor
    func notifyMoveOrResizeStarted() {
        host.map { $0.pointer.pointee.notify_move_or_resize_started?($0.pointer) }
    }

    // MARK: - DevTools protocol

    /// Executes a DevTools protocol method and returns its JSON result.
    @MainActor
    func devToolsMethod(_ method: String, params: [String: Any]) async -> [String: Any]? {
        guard let host else { return nil }
        let messageID = nextMessageID
        nextMessageID += 1
        let dictionary = CEFValue.dictionary(from: params)
        return await withCheckedContinuation { continuation in
            pendingDevToolsResults[messageID] = { success, data in
                let object = success ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] : nil
                continuation.resume(returning: object)
            }
            let accepted = withCefString(method) { method in
                host.pointer.pointee.execute_dev_tools_method?(host.pointer, messageID, method, dictionary?.retained()) ?? 0
            }
            if accepted == 0, let callback = pendingDevToolsResults.removeValue(forKey: messageID) {
                callback(false, Data())
            }
        }
    }

    /// Evaluates JavaScript in the page and returns its JSON-compatible value.
    @MainActor
    func evaluateJavaScript(_ expression: String) async -> Any? {
        let result = await devToolsMethod("Runtime.evaluate", params: [
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": true,
        ])
        return (result?["result"] as? [String: Any])?["value"]
    }

    /// PNG screenshot of the visible page (or of `clip`, in CSS pixels).
    @MainActor
    func captureScreenshot(clip: CGRect?) async -> Data? {
        var params: [String: Any] = ["format": "png", "captureBeyondViewport": false]
        if let clip {
            params["clip"] = ["x": clip.minX, "y": clip.minY, "width": clip.width, "height": clip.height, "scale": 1]
        }
        guard let base64 = await devToolsMethod("Page.captureScreenshot", params: params)?["data"] as? String,
              let data = Data(base64Encoded: base64) else { return nil }
        return data
    }

    // MARK: - Images

    /// Downloads an image (favicon…) using this browser's profile.
    @MainActor
    func downloadImage(url: String, isFavicon: Bool, maxSize: Int) async -> Data? {
        guard let host else { return nil }
        return await withCheckedContinuation { continuation in
            let request = CEFImageRequest()
            let key = ObjectIdentifier(request)
            pendingImageRequests[key] = request
            request.completion = { [weak self] image in
                self?.pendingImageRequests[key] = nil
                continuation.resume(returning: image)
            }
            withCefString(url) { url in
                host.pointer.pointee.download_image?(host.pointer, url, isFavicon ? 1 : 0, UInt32(maxSize), 0,
                                                     request.callback.retained())
            }
        }
    }

    // MARK: - Handlers

    @inline(__always)
    private static func owner<T>(_ pointer: UnsafeMutablePointer<T>?) -> CEFBrowser? {
        CefHandler<T>.owner(of: pointer, as: CEFBrowser.self)
    }

    private static func isMainFrame(_ frame: UnsafeMutablePointer<cef_frame_t>?) -> Bool {
        guard let frame else { return false }
        return frame.pointee.is_main?(frame) != 0
    }

    // swiftlint:disable:next function_body_length
    private func buildHandlers() {
        client = CefHandler(owner: self) { client in
            client.get_life_span_handler = { CEFBrowser.owner($0)?.lifeSpanHandler.retained() }
            client.get_load_handler = { CEFBrowser.owner($0)?.loadHandler.retained() }
            client.get_display_handler = { CEFBrowser.owner($0)?.displayHandler.retained() }
            client.get_request_handler = { CEFBrowser.owner($0)?.requestHandler.retained() }
            client.get_context_menu_handler = { CEFBrowser.owner($0)?.contextMenuHandler.retained() }
            client.get_find_handler = { CEFBrowser.owner($0)?.findHandler.retained() }
            client.get_focus_handler = { CEFBrowser.owner($0)?.focusHandler.retained() }
            client.get_permission_handler = { CEFBrowser.owner($0)?.permissionHandler.retained() }
            client.get_download_handler = { _ in CEFDownloadCenter.shared.handler.retained() }
        }

        lifeSpanHandler = CefHandler(owner: self) { handler in
            handler.on_before_popup = { handler, browser, frame, _, targetURL, _, disposition, userGesture, features,
                                        windowInfo, client, _, _, _ in
                defer {
                    cefRelease(browser)
                    cefRelease(frame)
                }
                guard let owner = CEFBrowser.owner(handler), let windowInfo, let client else { return 1 }
                let url = String(cef: targetURL)
                let popupFeatures = PopupFeatures(features?.pointee)
                // CEF calls this on its UI thread, which is the main thread.
                nonisolated(unsafe) let popupWindowInfo = windowInfo
                nonisolated(unsafe) let popupClient = client
                return MainActor.assumeIsolated {
                    guard let popup = owner.delegate?.browser(owner, createPopupFor: url,
                                                              disposition: WindowOpenDisposition(disposition),
                                                              userGesture: userGesture != 0,
                                                              features: popupFeatures) as? CEFBrowser
                    else { return 1 }
                    let info = popup.makeWindowInfo()
                    popupWindowInfo.pointee.parent_view = info.parent_view
                    popupWindowInfo.pointee.bounds = info.bounds
                    popupWindowInfo.pointee.runtime_style = CEF_RUNTIME_STYLE_ALLOY
                    popupClient.pointee = popup.client.retained()
                    popup.isPendingPopup = true
                    return 0
                }
            }
            handler.on_after_created = { handler, browser in
                guard let owner = CEFBrowser.owner(handler) else {
                    cefRelease(browser)
                    return
                }
                nonisolated(unsafe) let browser = browser
                MainActor.assumeIsolated {
                    owner.isPendingPopup = false
                    if owner.browser == nil {
                        owner.browser = CefRef(adopting: browser)
                        owner.didCreateBrowser()
                    } else {
                        cefRelease(browser)
                    }
                }
            }
            handler.do_close = { handler, browser in
                defer { cefRelease(browser) }
                // Never let CEF close the window hosting the browser (returning
                // 0 sends performClose: to it).
                guard let owner = CEFBrowser.owner(handler) else { return 1 }
                MainActor.assumeIsolated {
                    owner.delegate?.browserWillClose(owner)
                    // The browser is embedded in our own window: never let CEF
                    // close it. Destroying the browser view completes the close.
                    DispatchQueue.main.async { owner.tearDownView() }
                }
                return 1
            }
            handler.on_before_close = { handler, browser in
                defer { cefRelease(browser) }
                guard let owner = CEFBrowser.owner(handler) else { return }
                MainActor.assumeIsolated { owner.finishClose() }
            }
        }

        loadHandler = CefHandler(owner: self) { handler in
            handler.on_loading_state_change = { handler, browser, isLoading, canGoBack, canGoForward in
                defer { cefRelease(browser) }
                guard let owner = CEFBrowser.owner(handler) else { return }
                MainActor.assumeIsolated {
                    owner.delegate?.browser(owner, didChangeLoadingState: isLoading != 0,
                                            canGoBack: canGoBack != 0, canGoForward: canGoForward != 0)
                }
            }
            handler.on_load_end = { handler, browser, frame, status in
                defer {
                    cefRelease(browser)
                    cefRelease(frame)
                }
                guard let owner = CEFBrowser.owner(handler), CEFBrowser.isMainFrame(frame), let frame else { return }
                let url = String(cefUserFree: frame.pointee.get_url?(frame))
                MainActor.assumeIsolated {
                    owner.delegate?.browser(owner, didFinishLoad: url, httpStatusCode: Int(status))
                }
            }
            handler.on_load_error = { handler, browser, frame, errorCode, errorText, failedURL in
                defer {
                    cefRelease(browser)
                    cefRelease(frame)
                }
                guard let owner = CEFBrowser.owner(handler), CEFBrowser.isMainFrame(frame) else { return }
                let url = String(cef: failedURL)
                let text = String(cef: errorText)
                MainActor.assumeIsolated {
                    owner.delegate?.browser(owner, didFailLoad: url, errorCode: Int(errorCode.rawValue), errorText: text)
                }
            }
        }

        displayHandler = CefHandler(owner: self) { handler in
            handler.on_address_change = { handler, browser, frame, url in
                defer {
                    cefRelease(browser)
                    cefRelease(frame)
                }
                guard let owner = CEFBrowser.owner(handler), CEFBrowser.isMainFrame(frame) else { return }
                let address = String(cef: url)
                MainActor.assumeIsolated { owner.delegate?.browser(owner, didChangeAddress: address) }
            }
            handler.on_title_change = { handler, browser, title in
                defer { cefRelease(browser) }
                guard let owner = CEFBrowser.owner(handler) else { return }
                let value = String(cef: title)
                MainActor.assumeIsolated { owner.delegate?.browser(owner, didChangeTitle: value) }
            }
            handler.on_favicon_urlchange = { handler, browser, urls in
                defer { cefRelease(browser) }
                guard let owner = CEFBrowser.owner(handler) else { return }
                let list = cefStringList(urls)
                MainActor.assumeIsolated { owner.delegate?.browser(owner, didChangeFaviconURLs: list) }
            }
            handler.on_fullscreen_mode_change = { handler, browser, fullscreen in
                defer { cefRelease(browser) }
                guard let owner = CEFBrowser.owner(handler) else { return }
                MainActor.assumeIsolated { owner.delegate?.browser(owner, didChangeFullscreen: fullscreen != 0) }
            }
            handler.on_status_message = { handler, browser, value in
                defer { cefRelease(browser) }
                guard let owner = CEFBrowser.owner(handler) else { return }
                let message = String(cef: value)
                MainActor.assumeIsolated {
                    owner.delegate?.browser(owner, didChangeStatusMessage: message.isEmpty ? nil : message)
                }
            }
            handler.on_loading_progress_change = { handler, browser, progress in
                defer { cefRelease(browser) }
                guard let owner = CEFBrowser.owner(handler) else { return }
                MainActor.assumeIsolated { owner.delegate?.browser(owner, didChangeProgress: progress) }
            }
            handler.on_console_message = { handler, browser, _, message, _, _ in
                defer { cefRelease(browser) }
                guard let owner = CEFBrowser.owner(handler) else { return 0 }
                let text = String(cef: message)
                return MainActor.assumeIsolated {
                    owner.delegate?.browser(owner, consoleMessage: text) == true ? 1 : 0
                }
            }
            handler.on_auto_resize = { handler, browser, size in
                defer { cefRelease(browser) }
                guard let owner = CEFBrowser.owner(handler), let size = size?.pointee else { return 0 }
                let newSize = CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
                MainActor.assumeIsolated { owner.delegate?.browser(owner, didAutoResize: newSize) }
                return 1
            }
            handler.on_media_access_change = { handler, browser, video, audio in
                defer { cefRelease(browser) }
                guard let owner = CEFBrowser.owner(handler) else { return }
                MainActor.assumeIsolated {
                    owner.delegate?.browser(owner, didChangeMediaAccess: video != 0, microphone: audio != 0)
                }
            }
        }

        requestHandler = CefHandler(owner: self) { handler in
            handler.on_before_browse = { handler, browser, frame, request, userGesture, isRedirect in
                defer {
                    cefRelease(browser)
                    cefRelease(frame)
                    cefRelease(request)
                }
                guard let owner = CEFBrowser.owner(handler), CEFBrowser.isMainFrame(frame), let request else { return 0 }
                let url = String(cefUserFree: request.pointee.get_url?(request))
                return MainActor.assumeIsolated {
                    let allowed = owner.delegate?.browser(owner, shouldNavigateTo: url, userGesture: userGesture != 0,
                                                          isRedirect: isRedirect != 0) ?? true
                    return allowed ? 0 : 1
                }
            }
            handler.get_resource_request_handler = { _, browser, frame, request, isNavigation, _, initiator, _ in
                // IO thread: only reads the thread-safe filter.
                defer {
                    cefRelease(browser)
                    cefRelease(frame)
                    cefRelease(request)
                }
                guard let request else { return nil }
                let url = String(cefUserFree: request.pointee.get_url?(request))
                return CEFResourceFilter.shared.resourceRequestHandler(url: url, initiator: String(cef: initiator),
                                                                       isNavigation: isNavigation != 0)
            }
            handler.on_open_urlfrom_tab = { handler, browser, frame, targetURL, disposition, _ in
                defer {
                    cefRelease(browser)
                    cefRelease(frame)
                }
                guard let owner = CEFBrowser.owner(handler) else { return 0 }
                let url = String(cef: targetURL)
                return MainActor.assumeIsolated {
                    owner.delegate?.browser(owner, openURL: url, disposition: WindowOpenDisposition(disposition)) == true ? 1 : 0
                }
            }
            handler.on_render_process_terminated = { handler, browser, status, _, _ in
                defer { cefRelease(browser) }
                guard let owner = CEFBrowser.owner(handler) else { return }
                let termination: TerminationStatus = switch status {
                case TS_PROCESS_CRASHED: .crashed
                case TS_PROCESS_WAS_KILLED: .killed
                case TS_PROCESS_OOM: .outOfMemory
                default: .other
                }
                MainActor.assumeIsolated { owner.delegate?.browser(owner, rendererDidTerminate: termination) }
            }
        }

        contextMenuHandler = CefHandler(owner: self) { handler in
            handler.on_before_context_menu = { handler, browser, frame, params, model in
                defer {
                    cefRelease(browser)
                    cefRelease(frame)
                    cefRelease(params)
                    cefRelease(model)
                }
                guard let owner = CEFBrowser.owner(handler), let params, let model else { return }
                let contextParams = CEFBrowser.contextMenuParams(params)
                nonisolated(unsafe) let menuModel = model
                MainActor.assumeIsolated {
                    let model = menuModel
                    owner.lastContextMenuParams = contextParams
                    guard let items = owner.delegate?.browser(owner, contextMenuItemsFor: contextParams), !items.isEmpty else { return }
                    _ = model.pointee.clear?(model)
                    for item in items {
                        switch item {
                        case .separator:
                            _ = model.pointee.add_separator?(model)
                        case let .item(id, title):
                            withCefString(title) { _ = model.pointee.add_item?(model, Int32(id), $0) }
                        }
                    }
                }
            }
            handler.on_context_menu_command = { handler, browser, frame, params, commandID, _ in
                defer {
                    cefRelease(browser)
                    cefRelease(frame)
                    cefRelease(params)
                }
                guard let owner = CEFBrowser.owner(handler),
                      commandID >= Int32(MENU_ID_USER_FIRST.rawValue), commandID <= Int32(MENU_ID_USER_LAST.rawValue)
                else { return 0 }
                return MainActor.assumeIsolated {
                    guard let params = owner.lastContextMenuParams else { return 0 }
                    owner.delegate?.browser(owner, didSelectContextMenuItem: Int(commandID), params: params)
                    return 1
                }
            }
        }

        findHandler = CefHandler(owner: self) { handler in
            handler.on_find_result = { handler, browser, _, count, _, activeMatch, finalUpdate in
                defer { cefRelease(browser) }
                guard let owner = CEFBrowser.owner(handler) else { return }
                MainActor.assumeIsolated {
                    owner.delegate?.browser(owner, didFindMatches: Int(count), activeMatch: Int(activeMatch),
                                            finalUpdate: finalUpdate != 0)
                }
            }
        }

        focusHandler = CefHandler(owner: self) { handler in
            handler.on_got_focus = { handler, browser in
                defer { cefRelease(browser) }
                guard let owner = CEFBrowser.owner(handler) else { return }
                MainActor.assumeIsolated { owner.delegate?.browserDidGainFocus(owner) }
            }
        }

        permissionHandler = CefHandler(owner: self) { handler in
            handler.on_request_media_access_permission = { handler, browser, frame, origin, requested, callback in
                defer {
                    cefRelease(browser)
                    cefRelease(frame)
                }
                guard let owner = CEFBrowser.owner(handler), let callback = CefRef(adopting: callback) else { return 0 }
                var kinds = Set<PermissionRequest.Kind>()
                if requested & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE.rawValue != 0 { kinds.insert(.microphone) }
                if requested & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE.rawValue != 0 { kinds.insert(.camera) }
                if requested & (CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE.rawValue | CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE.rawValue) != 0 {
                    kinds.insert(.screenCapture)
                }
                let request = PermissionRequest(origin: String(cef: origin), kinds: kinds)
                return MainActor.assumeIsolated {
                    let handled = owner.delegate?.browser(owner, requestsPermission: request) { allowed in
                        callback.pointer.pointee.cont?(callback.pointer, allowed ? requested : 0)
                    } ?? false
                    return handled ? 1 : 0
                }
            }
            handler.on_show_permission_prompt = { handler, browser, _, origin, requested, callback in
                defer { cefRelease(browser) }
                guard let owner = CEFBrowser.owner(handler), let callback = CefRef(adopting: callback) else { return 0 }
                let request = PermissionRequest(origin: String(cef: origin), kinds: CEFBrowser.permissionKinds(requested))
                return MainActor.assumeIsolated {
                    let handled = owner.delegate?.browser(owner, requestsPermission: request) { allowed in
                        callback.pointer.pointee.cont?(callback.pointer, allowed ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY)
                    } ?? false
                    return handled ? 1 : 0
                }
            }
        }

        devToolsObserver = CefHandler(owner: self) { observer in
            observer.on_dev_tools_method_result = { observer, browser, messageID, success, result, size in
                defer { cefRelease(browser) }
                guard let owner = CEFBrowser.owner(observer) else { return }
                let data = result.map { Data(bytes: $0, count: size) } ?? Data()
                MainActor.assumeIsolated {
                    owner.pendingDevToolsResults.removeValue(forKey: messageID)?(success != 0, data)
                }
            }
        }
    }

    private static func contextMenuParams(_ params: UnsafeMutablePointer<cef_context_menu_params_t>) -> ContextMenuParams {
        let p = params.pointee
        let mediaType: ContextMenuParams.MediaType = switch p.get_media_type?(params) {
        case CM_MEDIATYPE_IMAGE: .image
        case CM_MEDIATYPE_VIDEO: .video
        case CM_MEDIATYPE_AUDIO: .audio
        case CM_MEDIATYPE_CANVAS: .canvas
        case CM_MEDIATYPE_NONE, nil: .none
        default: .other
        }
        return ContextMenuParams(
            linkURL: String(cefUserFree: p.get_link_url?(params)),
            sourceURL: String(cefUserFree: p.get_source_url?(params)),
            pageURL: String(cefUserFree: p.get_page_url?(params)),
            frameURL: String(cefUserFree: p.get_frame_url?(params)),
            selectionText: String(cefUserFree: p.get_selection_text?(params)),
            titleText: String(cefUserFree: p.get_title_text?(params)),
            isEditable: p.is_editable?(params) != 0,
            mediaType: mediaType,
            location: CGPoint(x: Int(p.get_xcoord?(params) ?? 0), y: Int(p.get_ycoord?(params) ?? 0))
        )
    }

    private static func permissionKinds(_ mask: UInt32) -> Set<PermissionRequest.Kind> {
        var kinds = Set<PermissionRequest.Kind>()
        if mask & CEF_PERMISSION_TYPE_GEOLOCATION.rawValue != 0 { kinds.insert(.location) }
        if mask & CEF_PERMISSION_TYPE_NOTIFICATIONS.rawValue != 0 { kinds.insert(.notifications) }
        if mask & CEF_PERMISSION_TYPE_CLIPBOARD.rawValue != 0 { kinds.insert(.clipboard) }
        if mask & CEF_PERMISSION_TYPE_CAMERA_STREAM.rawValue != 0 { kinds.insert(.camera) }
        if mask & CEF_PERMISSION_TYPE_MIC_STREAM.rawValue != 0 { kinds.insert(.microphone) }
        if mask & CEF_PERMISSION_TYPE_MIDI_SYSEX.rawValue != 0 { kinds.insert(.midi) }
        if kinds.isEmpty { kinds.insert(.other) }
        return kinds
    }
}

/// One-shot `cef_download_image_callback_t`.
private final class CEFImageRequest: @unchecked Sendable {
    @MainActor var completion: ((Data?) -> Void)?
    private(set) var callback: CefHandler<cef_download_image_callback_t>!

    init() {
        callback = CefHandler(owner: self) { callback in
            callback.on_download_image_finished = { callback, _, _, image in
                let request = CefHandler.owner(of: callback, as: CEFImageRequest.self)
                let png = CEFImageRequest.pngData(image)
                cefRelease(image)
                MainActor.assumeIsolated {
                    request?.completion?(png)
                    request?.completion = nil
                }
            }
        }
    }

    private static func pngData(_ image: UnsafeMutablePointer<cef_image_t>?) -> Data? {
        guard let image, image.pointee.is_empty?(image) == 0 else { return nil }
        var width: Int32 = 0
        var height: Int32 = 0
        let scale = Float(NSScreen.main?.backingScaleFactor ?? 2)
        guard let binary = CefRef(adopting: image.pointee.get_as_png?(image, scale, 1, &width, &height)) else { return nil }
        let size = binary.pointer.pointee.get_size?(binary.pointer) ?? 0
        guard size > 0, let bytes = binary.pointer.pointee.get_raw_data?(binary.pointer) else { return nil }
        return Data(bytes: bytes, count: size)
    }
}
