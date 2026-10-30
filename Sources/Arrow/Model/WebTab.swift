import AppKit
import ArrowCore
import ArrowKit
import Observation

/// Window-side services a tab needs (opening tabs, popups, Peek…).
@MainActor
protocol TabHost: AnyObject {
    func tab(_ tab: WebTab, openURL url: String, inBackground: Bool)
    func tab(_ tab: WebTab, createPopupFor url: String, features: PopupFeatures) -> (any BrowserEngine)?
    /// Return true when the navigation was diverted (Peek).
    func tab(_ tab: WebTab, shouldDivertNavigationTo url: String) -> Bool
    func tab(_ tab: WebTab, openInSplitView url: String)
    func tab(_ tab: WebTab, openInLittleArrow url: String)
    func tab(_ tab: WebTab, openInPeek url: String)
    func tabDidRequestClose(_ tab: WebTab)
    func tabDidGainFocus(_ tab: WebTab)
    func tab(_ tab: WebTab, didChangeFullscreen fullscreen: Bool)
    func tabRequestsBoostEditor(_ tab: WebTab)
    func tabRequestsCapture(_ tab: WebTab)
    /// Whether the tab is currently shown in the window.
    func isDisplaying(_ tab: WebTab) -> Bool
}

/// Find-in-page state of a tab.
struct FindState: Equatable {
    var text = ""
    var matchCount = 0
    var activeMatch = 0
}

/// A site permission waiting for the user's decision.
struct PendingPermission: Identifiable {
    let id = UUID()
    let request: PermissionRequest
    let decide: @MainActor (Bool) -> Void
}

/// Load failure shown instead of the page.
struct LoadFailure: Equatable {
    var url: String
    var code: Int
    var description: String
}

/// Runtime of one tab: its Chromium browser and observable page state.
@MainActor
@Observable
final class WebTab: Identifiable {
    let id: UUID
    let profileID: UUID
    let isIncognito: Bool
    @ObservationIgnored weak var store: BrowserStore?
    @ObservationIgnored weak var host: TabHost?

    private(set) var engine: (any BrowserEngine)?
    @ObservationIgnored var lastVisibleAt = Date()
    @ObservationIgnored private var closeCompletions: [@MainActor () -> Void] = []
    @ObservationIgnored private var faviconTask: Task<Void, Never>?

    var url: String
    var title: String
    var faviconURL: String?
    var favicon: NSImage?
    var isLoading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    var statusMessage: String?
    var isFullscreen = false
    var isMuted = false {
        didSet { engine?.isAudioMuted = isMuted }
    }

    var isPlayingMedia = false
    var isCameraActive = false
    var isMicrophoneActive = false
    var crash: TerminationStatus?
    var loadFailure: LoadFailure?
    var find: FindState?
    var permissionRequest: PendingPermission?
    /// Save or fill a password or a card, or translate the page.
    var offer: PageOffer?
    var zoomLevel = 0.0
    /// Boost "Zap": clicked elements are hidden and saved to the site's boost.
    var isZapping = false
    /// Last rendering of the page, shown when hovering a favorite.
    var snapshot: NSImage?

    init(model: Tab, profileID: UUID, store: BrowserStore?, isIncognito: Bool = false) {
        id = model.id
        self.profileID = profileID
        self.store = store
        self.isIncognito = isIncognito
        url = model.url
        title = model.title
        faviconURL = model.faviconURL
        isMuted = model.isMuted
        favicon = FaviconCache.shared.image(for: model.url)
    }

    var displayTitle: String {
        switch internalPage {
        case let .note(id): return store?.note(id)?.title ?? "Untitled"
        case let .easel(id): return store?.easel(id)?.title ?? "Untitled Easel"
        case .shortcuts: return "Keyboard Shortcuts"
        default: break
        }
        if !title.isEmpty { return title }
        return URLDisplay.host(of: url) ?? url
    }

    var internalPage: InternalPage? { InternalPage(url: url) }
    var isEngineLoaded: Bool { engine != nil }
    /// `prefers-color-scheme` emulated in the current engine ("" for the system's).
    @ObservationIgnored private var appliedColorScheme: String?

    // MARK: - Engine lifecycle

    /// Creates the Chromium browser when the tab is first shown.
    @discardableResult
    func ensureEngine(context: any BrowsingContext) -> (any BrowserEngine)? {
        guard internalPage == nil else { return nil }
        if let engine { return engine }
        let engine = context.makeBrowser()
        engine.delegate = self
        self.engine = engine
        appliedColorScheme = nil
        crash = nil
        engine.create(url: url.isEmpty ? "about:blank" : url)
        return engine
    }

    /// Adopts a browser created by Chromium for a popup.
    func adopt(_ engine: any BrowserEngine) {
        engine.delegate = self
        self.engine = engine
        appliedColorScheme = nil
    }

    /// Destroys the browser, keeping the tab (reloaded when shown again).
    func closeEngine(completion: (@MainActor () -> Void)? = nil) {
        guard let engine, !engine.isClosed else {
            self.engine = nil
            completion?()
            return
        }
        if let completion { closeCompletions.append(completion) }
        engine.close(force: true)
    }

    // MARK: - Navigation

    func load(_ address: String) {
        url = address
        loadFailure = nil
        if let engine {
            engine.load(url: address)
        } else if let store, internalPage == nil {
            ensureEngine(context: store.requestContext(for: profileID))
        }
    }

    func goBack() { engine?.goBack() }
    func goForward() { engine?.goForward() }

    func reload(ignoringCache: Bool = false) {
        loadFailure = nil
        if crash != nil, let store {
            closeEngine()
            engine = nil
            crash = nil
            ensureEngine(context: store.requestContext(for: profileID))
            return
        }
        ignoringCache ? engine?.reloadIgnoringCache() : engine?.reload()
    }

    func stopLoading() { engine?.stopLoading() }

    func zoomIn() { setZoom(zoomLevel + 0.5) }
    func zoomOut() { setZoom(zoomLevel - 0.5) }
    func resetZoom() { setZoom(0) }

    private func setZoom(_ level: Double) {
        zoomLevel = min(max(level, -4), 6)
        engine?.zoomLevel = zoomLevel
    }

    // MARK: - Find

    func find(_ text: String, forward: Bool = true) {
        let isNext = find?.text == text && !text.isEmpty
        find = FindState(text: text, matchCount: find?.matchCount ?? 0, activeMatch: find?.activeMatch ?? 0)
        guard !text.isEmpty else {
            engine?.stopFinding()
            find?.matchCount = 0
            return
        }
        engine?.find(text, forward: forward, findNext: isNext)
    }

    func endFind() {
        engine?.stopFinding()
        find = nil
    }

    // MARK: - Page features

    /// View ▸ Appearance: the `prefers-color-scheme` the page sees. Chromium's
    /// own color scheme does not reach browsers embedded in a view, so it is
    /// emulated per browser.
    func applyContentAppearance() {
        guard let store, let engine else { return }
        let value = switch store.settings.contentAppearance {
        case .automatic: ""
        case .light: "light"
        case .dark: "dark"
        }
        guard appliedColorScheme != value else { return }
        appliedColorScheme = value
        Task {
            _ = await engine.devToolsMethod("Emulation.setEmulatedMedia", params: [
                "features": [["name": "prefers-color-scheme", "value": value]],
            ])
        }
    }

    func applyBoosts() {
        guard let store, store.settings.boostsEnabled, let engine else { return }
        for boost in store.boosts(for: url) {
            engine.executeJavaScript(boost.injectionScript, scriptURL: "arrow://boost")
        }
    }

    /// Enters Picture in Picture for the playing video (automatic PiP).
    func enterPictureInPicture() {
        guard let engine, isPlayingMedia else { return }
        Task {
            _ = await engine.devToolsMethod("Runtime.evaluate", params: [
                "expression": Self.pictureInPictureScript,
                "userGesture": true,
                "awaitPromise": true,
            ])
        }
    }

    func exitPictureInPicture() {
        engine?.executeJavaScript("document.pictureInPictureElement && document.exitPictureInPicture()")
    }

    private static let pictureInPictureScript = """
    (async () => {
      const video = [...document.querySelectorAll('video')].find(v => !v.paused && v.readyState > 2 && !v.disablePictureInPicture);
      if (video && document.pictureInPictureElement !== video) { await video.requestPictureInPicture(); }
    })()
    """

    /// Reports media playback through the console (see `browser(_:consoleMessage:)`).
    private static let mediaObserverScript = """
    (() => {
      if (window.__arrowMediaObserver) return;
      window.__arrowMediaObserver = true;
      let last = null;
      const report = () => {
        const playing = [...document.querySelectorAll('video, audio')]
          .some(m => !m.paused && !m.ended && !m.muted && m.volume > 0 && m.readyState > 2);
        if (playing !== last) { last = playing; console.debug('__arrow_media__:' + (playing ? '1' : '0')); }
      };
      for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied']) {
        document.addEventListener(type, report, true);
      }
      report();
    })();
    """

    /// Starts Zap: hovered elements are outlined, a click hides them.
    func startZapping() {
        guard let engine else { return }
        isZapping = true
        engine.executeJavaScript(Self.zapScript, scriptURL: "arrow://zap")
    }

    func stopZapping() {
        isZapping = false
        engine?.executeJavaScript("window.__arrowZapStop && window.__arrowZapStop()")
    }

    private static let zapScript = """
    (() => {
      if (window.__arrowZapStop) return;
      const box = document.createElement('div');
      box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #ff3b6b;background:rgba(255,59,107,.15);border-radius:4px;transition:all .06s';
      document.documentElement.appendChild(box);
      const selectorFor = (el) => {
        if (el.id && /^[A-Za-z][\\w-]*$/.test(el.id)) return '#' + el.id;
        const parts = [];
        while (el && el.nodeType === 1 && el !== document.body && parts.length < 5) {
          let part = el.tagName.toLowerCase();
          const classes = [...el.classList].filter(c => /^[A-Za-z][\\w-]*$/.test(c)).slice(0, 2);
          if (classes.length) part += '.' + classes.join('.');
          const parent = el.parentElement;
          if (parent) {
            const same = [...parent.children].filter(c => c.tagName === el.tagName);
            if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
          }
          parts.unshift(part);
          if (el.id) break;
          el = parent;
        }
        return parts.join(' > ');
      };
      const over = (e) => {
        const r = e.target.getBoundingClientRect();
        Object.assign(box.style, {left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px'});
      };
      const click = (e) => {
        e.preventDefault(); e.stopPropagation();
        const selector = selectorFor(e.target);
        e.target.style.setProperty('display', 'none', 'important');
        console.debug('__arrow_zap__:' + selector);
      };
      const key = (e) => { if (e.key === 'Escape') { stop(); console.debug('__arrow_zap__:__done__'); } };
      const stop = () => {
        document.removeEventListener('mouseover', over, true);
        document.removeEventListener('click', click, true);
        document.removeEventListener('keydown', key, true);
        box.remove();
        delete window.__arrowZapStop;
      };
      document.addEventListener('mouseover', over, true);
      document.addEventListener('click', click, true);
      document.addEventListener('keydown', key, true);
      window.__arrowZapStop = stop;
    })();
    """

    func playPauseMedia() {
        engine?.executeJavaScript("""
        (() => { const m = [...document.querySelectorAll('video, audio')].find(m => !m.paused) \
        || document.querySelector('video, audio'); if (m) { m.paused ? m.play() : m.pause(); } })();
        """)
    }

    private func loadFavicon(from urls: [String]) {
        let preferred = urls.first { $0.hasSuffix(".svg") == false } ?? urls.first
        guard let preferred else { return }
        faviconURL = preferred
        faviconTask?.cancel()
        let pageURL = url
        faviconTask = Task { [weak self] in
            guard let engine = self?.engine, let data = await engine.downloadImage(url: preferred),
                  let image = NSImage(data: data) else { return }
            guard let self, !Task.isCancelled else { return }
            favicon = image
            FaviconCache.shared.store(image, for: pageURL)
        }
    }
}

// MARK: - BrowserEngineDelegate

extension WebTab: BrowserEngineDelegate {
    private enum MenuID {
        static let openLinkInNewTab = 26500
        static let openLinkInSplitView = 26501
        static let openLinkInLittleArrow = 26502
        static let copyLink = 26503
        static let saveLinkAs = 26504
        static let openImageInNewTab = 26505
        static let copyImageAddress = 26506
        static let saveImageAs = 26507
        static let searchSelection = 26508
        static let copySelection = 26509
        static let back = 26510
        static let forward = 26511
        static let reload = 26512
        static let copyPageURL = 26513
        static let viewSource = 26514
        static let inspect = 26515
        static let print = 26516
        static let capture = 26517
        static let boost = 26518
    }

    func browser(_ browser: any BrowserEngine, didChangeAddress url: String) {
        self.url = url
        loadFailure = nil
        store?.syncTabModel(self)
    }

    func browser(_ browser: any BrowserEngine, didChangeTitle title: String) {
        self.title = title
        store?.updateHistoryTitle(url: url, title: title, incognito: isIncognito)
        store?.syncTabModel(self)
    }

    func browser(_ browser: any BrowserEngine, didChangeFaviconURLs urls: [String]) {
        loadFavicon(from: urls)
    }

    func browser(_ browser: any BrowserEngine, didChangeLoadingState isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        if isLoading { applyContentAppearance() }
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        if isLoading { progress = max(progress, 0.1) }
    }

    func browser(_ browser: any BrowserEngine, didChangeProgress progress: Double) {
        self.progress = progress
    }

    func browser(_ browser: any BrowserEngine, didFinishLoad url: String, httpStatusCode: Int) {
        store?.recordVisit(url: url, title: title, incognito: isIncognito)
        applyBoosts()
        applyPageFeatures(browser)
        runAutofill(browser)
        browser.executeJavaScript(Self.mediaObserverScript)
        if zoomLevel != 0 { browser.zoomLevel = zoomLevel }
        refreshSnapshot(after: .seconds(1.5))
    }

    /// Captures the page for hover previews (only while it is displayed:
    /// Chromium does not render hidden pages).
    func refreshSnapshot(after delay: Duration = .zero) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, let engine, host?.isDisplaying(self) == true,
                  let data = await engine.captureScreenshot(), let image = NSImage(data: data) else { return }
            snapshot = image
        }
    }

    func browser(_ browser: any BrowserEngine, didFailLoad url: String, errorCode: Int, errorText: String) {
        // ERR_ABORTED (-3) happens on user-cancelled or replaced navigations.
        guard errorCode != -3 else { return }
        loadFailure = LoadFailure(url: url, code: errorCode, description: errorText)
    }

    func browser(_ browser: any BrowserEngine, didChangeStatusMessage message: String?) {
        statusMessage = message
    }

    func browser(_ browser: any BrowserEngine, didChangeFullscreen fullscreen: Bool) {
        isFullscreen = fullscreen
        host?.tab(self, didChangeFullscreen: fullscreen)
    }

    func browser(_ browser: any BrowserEngine, didChangeMediaAccess camera: Bool, microphone: Bool) {
        isCameraActive = camera
        isMicrophoneActive = microphone
    }

    func browser(_ browser: any BrowserEngine, consoleMessage message: String) -> Bool {
        if handleAutofillMessage(message) { return true }
        if message.hasPrefix("__arrow_quote__:") {
            copyQuote(String(message.dropFirst("__arrow_quote__:".count)))
            return true
        }
        if message.hasPrefix("__arrow_media__:") {
            isPlayingMedia = message.hasSuffix("1")
            return true
        }
        if isZapping, message.hasPrefix("__arrow_zap__:") {
            let selector = String(message.dropFirst("__arrow_zap__:".count))
            if selector == "__done__" {
                isZapping = false
            } else {
                store?.zap(selector, on: url)
            }
            return true
        }
        return false
    }

    func browser(_ browser: any BrowserEngine, createPopupFor url: String, disposition: WindowOpenDisposition,
                 userGesture: Bool, features: PopupFeatures) -> (any BrowserEngine)? {
        host?.tab(self, createPopupFor: url, features: features)
    }

    func browser(_ browser: any BrowserEngine, openURL url: String, disposition: WindowOpenDisposition) -> Bool {
        // Preferences ▸ Links: ⌥⌘-click opens Little Arrow, Shift-click opens Peek.
        let modifiers = store?.platform.heldModifiers ?? []
        if let settings = store?.settings, disposition != .currentTab, disposition != .other {
            if modifiers.isSuperset(of: [.command, .option]), settings.littleArrowOnOptionCommandClick {
                host?.tab(self, openInLittleArrow: url)
                return true
            }
            if modifiers.contains(.shift), !modifiers.contains(.command), settings.peekOnShiftClick {
                host?.tab(self, openInPeek: url)
                return true
            }
        }
        switch disposition {
        case .newBackgroundTab:
            host?.tab(self, openURL: url, inBackground: true)
            return true
        case .newForegroundTab, .newWindow, .newPopup:
            host?.tab(self, openURL: url, inBackground: false)
            return true
        case .currentTab, .other:
            return false
        }
    }

    func browser(_ browser: any BrowserEngine, shouldNavigateTo url: String, userGesture: Bool, isRedirect: Bool) -> Bool {
        guard userGesture, !isRedirect else { return true }
        return !(host?.tab(self, shouldDivertNavigationTo: url) ?? false)
    }

    func browser(_ browser: any BrowserEngine, didFindMatches count: Int, activeMatch: Int, finalUpdate: Bool) {
        guard find != nil else { return }
        find?.matchCount = count
        find?.activeMatch = activeMatch
    }

    func browser(_ browser: any BrowserEngine, contextMenuItemsFor params: ContextMenuParams) -> [ContextMenuItem] {
        if params.isEditable { return [] }
        var items: [ContextMenuItem] = []
        if params.hasLink {
            items += [
                .item(id: MenuID.openLinkInNewTab, title: "Open Link in New Tab"),
                .item(id: MenuID.openLinkInSplitView, title: "Open Link in Split View"),
                .item(id: MenuID.openLinkInLittleArrow, title: "Open Link in Little Arrow"),
                .separator,
                .item(id: MenuID.copyLink, title: "Copy Link"),
                .item(id: MenuID.saveLinkAs, title: "Download Linked File"),
                .separator,
            ]
        }
        if params.mediaType == .image {
            items += [
                .item(id: MenuID.openImageInNewTab, title: "Open Image in New Tab"),
                .item(id: MenuID.copyImageAddress, title: "Copy Image Address"),
                .item(id: MenuID.saveImageAs, title: "Download Image"),
                .separator,
            ]
        }
        if params.hasSelection {
            let excerpt = params.selectionText.count > 24 ? String(params.selectionText.prefix(24)) + "…" : params.selectionText
            let engine = store?.settings.searchEngine.name ?? "Google"
            items += [
                .item(id: MenuID.copySelection, title: "Copy"),
                .item(id: MenuID.searchSelection, title: "Search \(engine) for “\(excerpt)”"),
                .separator,
            ]
        }
        if !params.hasLink && params.mediaType == .none && !params.hasSelection {
            items += [
                .item(id: MenuID.back, title: "Back"),
                .item(id: MenuID.forward, title: "Forward"),
                .item(id: MenuID.reload, title: "Reload"),
                .separator,
                .item(id: MenuID.copyPageURL, title: "Copy URL"),
                .item(id: MenuID.capture, title: "Capture Page"),
                .item(id: MenuID.boost, title: "Boost This Site…"),
                .item(id: MenuID.print, title: "Print…"),
                .separator,
                .item(id: MenuID.viewSource, title: "View Page Source"),
            ]
        }
        items.append(.item(id: MenuID.inspect, title: "Inspect"))
        return items
    }

    func browser(_ browser: any BrowserEngine, didSelectContextMenuItem id: Int, params: ContextMenuParams) {
        let platform = store?.platform
        switch id {
        case MenuID.openLinkInNewTab: host?.tab(self, openURL: params.linkURL, inBackground: true)
        case MenuID.openLinkInSplitView: host?.tab(self, openInSplitView: params.linkURL)
        case MenuID.openLinkInLittleArrow: host?.tab(self, openInLittleArrow: params.linkURL)
        case MenuID.copyLink: platform?.copyToClipboard(params.linkURL)
        case MenuID.saveLinkAs: browser.startDownload(url: params.linkURL)
        case MenuID.openImageInNewTab: host?.tab(self, openURL: params.sourceURL, inBackground: true)
        case MenuID.copyImageAddress: platform?.copyToClipboard(params.sourceURL)
        case MenuID.saveImageAs: browser.startDownload(url: params.sourceURL)
        case MenuID.copySelection: platform?.copyToClipboard(params.selectionText)
        case MenuID.searchSelection:
            let engine = store?.settings.searchEngine ?? .google
            host?.tab(self, openURL: engine.searchURL(for: params.selectionText), inBackground: false)
        case MenuID.back: goBack()
        case MenuID.forward: goForward()
        case MenuID.reload: reload()
        case MenuID.copyPageURL: platform?.copyToClipboard(url)
        case MenuID.capture: host?.tabRequestsCapture(self)
        case MenuID.boost: host?.tabRequestsBoostEditor(self)
        case MenuID.print: browser.print()
        case MenuID.viewSource: host?.tab(self, openURL: "view-source:\(url)", inBackground: false)
        case MenuID.inspect: browser.showDevTools(inspectAt: params.location)
        default: break
        }
    }

    func browser(_ browser: any BrowserEngine, requestsPermission request: PermissionRequest,
                 decision: @escaping @MainActor (Bool) -> Void) -> Bool {
        permissionRequest?.decide(false)
        permissionRequest = PendingPermission(request: request) { [weak self] allowed in
            decision(allowed)
            self?.permissionRequest = nil
        }
        return true
    }

    func browser(_ browser: any BrowserEngine, rendererDidTerminate status: TerminationStatus) {
        crash = status
        isLoading = false
        isPlayingMedia = false
    }

    func browserDidGainFocus(_ browser: any BrowserEngine) {
        host?.tabDidGainFocus(self)
    }

    func browserWillClose(_ browser: any BrowserEngine) {
        // window.close() from the page: close the tab unless we initiated it.
        // Deferred so the tab is not torn down inside Chromium's callback.
        if !browser.isClosing, engine === browser {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.host?.tabDidRequestClose(self)
            }
        }
    }

    func browserDidClose(_ browser: any BrowserEngine) {
        if engine === browser { engine = nil }
        isLoading = false
        isPlayingMedia = false
        let completions = closeCompletions
        closeCompletions.removeAll()
        for completion in completions { completion() }
    }
}

// MARK: - Theme data and Shared Quotes (Preferences ▸ Advanced)

extension WebTab {
    /// Theme variables and the quote button, as the preferences allow.
    func applyPageFeatures(_ browser: any BrowserEngine) {
        guard let store, url.hasPrefix("http") else { return }
        if store.settings.shareThemeWithWebsites, !isIncognito, let script = themeScript(store) {
            browser.executeJavaScript(script, scriptURL: "arrow://theme")
        }
        if store.settings.sharedQuotes {
            browser.executeJavaScript(Self.quoteScript, scriptURL: "arrow://quote")
        }
    }

    /// Arc's `--arc-palette-*` CSS variables, read by sites that adapt to the browser theme.
    private func themeScript(_ store: BrowserStore) -> String? {
        guard let spaceID = store.state.location(of: id)?.spaceID, let space = store.state.space(spaceID) else { return nil }
        let isDark = space.theme.isDark(systemIsDark: store.platform.isDarkAppearance)
        let palette = space.theme.palette(isDark: isDark)
        let variables: [(String, RGBColor)] = [
            ("background", palette.backgroundStops.first ?? palette.accent),
            ("backgroundExtra", palette.backgroundStops.last ?? palette.accent),
            ("focus", palette.accent),
            ("title", palette.title),
            ("subtitle", palette.subtitle),
            ("foregroundPrimary", palette.title),
            ("foregroundSecondary", palette.subtitle),
            ("maxContrastColor", isDark ? .white : .black),
            ("minContrastColor", isDark ? .black : .white),
        ]
        let assignments = variables.map { "s.setProperty('--arc-palette-\($0.0)', '\($0.1.hexString)');" }.joined()
        return "(() => { const s = document.documentElement.style; \(assignments) })();"
    }

    /// Copies "> quote — [title](link to the highlight)".
    fileprivate func copyQuote(_ payload: String) {
        guard let data = payload.data(using: .utf8),
              let quote = try? JSONDecoder().decode([String: String].self, from: data),
              let text = quote["text"], let link = quote["url"] else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        store?.platform.copyToClipboard("\(lines)\n\n— [\(displayTitle)](\(link))")
        store?.playSound(.event)
    }

    /// A "Copy Quote" button over highlighted text; the link scrolls to the
    /// highlight (text fragment).
    fileprivate static let quoteScript = """
    (() => {
      if (window.__arrowQuote) return;
      window.__arrowQuote = true;
      const host = document.createElement('div');
      const root = host.attachShadow({ mode: 'closed' });
      root.innerHTML = '<button style="all:initial;position:fixed;z-index:2147483647;display:none;padding:5px 10px;'
        + 'border-radius:8px;background:#1c1c1e;color:#fff;font:600 12px -apple-system,system-ui;cursor:default;'
        + 'box-shadow:0 4px 14px rgba(0,0,0,.25)">Copy Quote</button>';
      const button = root.querySelector('button');
      let quote = '';
      document.documentElement.appendChild(host);
      document.addEventListener('mouseup', (event) => {
        if (event.composedPath().includes(host)) return;
        setTimeout(() => {
          const selection = window.getSelection();
          quote = selection ? selection.toString().trim() : '';
          if (quote.length < 4 || selection.rangeCount === 0) { button.style.display = 'none'; return; }
          const rect = selection.getRangeAt(0).getBoundingClientRect();
          button.style.left = Math.max(8, rect.left + rect.width / 2 - 45) + 'px';
          button.style.top = Math.max(8, rect.top - 36) + 'px';
          button.style.display = 'block';
        }, 0);
      }, true);
      document.addEventListener('scroll', () => { button.style.display = 'none'; }, true);
      button.addEventListener('mousedown', (event) => event.preventDefault());
      button.addEventListener('click', () => {
        const words = quote.split(/\\s+/);
        const fragment = words.length > 8
          ? encodeURIComponent(words.slice(0, 4).join(' ')) + ',' + encodeURIComponent(words.slice(-4).join(' '))
          : encodeURIComponent(quote);
        const url = location.href.split('#')[0] + '#:~:text=' + fragment;
        console.debug('__arrow_quote__:' + JSON.stringify({ text: quote, url }));
        button.textContent = 'Copied';
        setTimeout(() => { button.style.display = 'none'; button.textContent = 'Copy Quote'; }, 900);
      });
    })();
    """
}
