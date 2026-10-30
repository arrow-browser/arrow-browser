import Foundation

// The engine boundary (docs/PORTABILITY.md, phase 3): the shared core talks
// to the rendering engine only through these protocols. The macOS app
// implements them with CEF (`CEFBrowser`, `CEFRequestContext`, `CEFRuntime`).

/// One browser of the engine: the page of a tab or of a popup.
@MainActor
public protocol BrowserEngine: AnyObject {
    var delegate: (any BrowserEngineDelegate)? { get set }
    /// Profile the browser belongs to.
    var context: any BrowsingContext { get }
    /// Identifies the browser in engine-wide events (downloads) once created.
    var identifier: Int32? { get }
    /// `close(force:)` was called.
    var isClosing: Bool { get }
    var isClosed: Bool { get }
    var canGoBack: Bool { get }
    /// Address committed in the main frame.
    var currentURL: String? { get }
    var zoomLevel: Double { get set }
    var isAudioMuted: Bool { get set }

    /// Creates the native browser and starts loading `url`.
    func create(url: String)
    /// Closes the browser, running the page's unload handlers unless `force`.
    func close(force: Bool)
    func load(url: String)
    func goBack()
    func goForward()
    func reload()
    func reloadIgnoringCache()
    func stopLoading()
    func executeJavaScript(_ code: String, scriptURL: String)
    /// Evaluates JavaScript in the page and returns its JSON-compatible value.
    func evaluateJavaScript(_ expression: String) async -> Any?
    /// Executes a DevTools protocol method and returns its JSON result.
    func devToolsMethod(_ method: String, params: [String: Any]) async -> [String: Any]?
    func find(_ text: String, forward: Bool, findNext: Bool)
    func stopFinding()
    func setFocus(_ focused: Bool)
    func print()
    func startDownload(url: String)
    /// Opens Developer Tools, inspecting `point` or on `panel` ("console",
    /// "network"…) when given.
    func showDevTools(inspectAt point: CGPoint?, panel: String?)
    func exitFullscreen()
    /// The window hosting the browser started moving or resizing.
    func notifyMoveOrResizeStarted()
    /// Reports the page's preferred size through `browser(_:didAutoResize:)`.
    func enableAutoResize(min: CGSize, max: CGSize)
    /// PNG screenshot of the visible page (or of `clip`, in CSS pixels).
    func captureScreenshot(clip: CGRect?) async -> Data?
    /// PNG of an image (favicon…) downloaded with this browser's profile.
    func downloadImage(url: String, isFavicon: Bool, maxSize: Int) async -> Data?
}

extension BrowserEngine {
    public func close() { close(force: false) }

    public func executeJavaScript(_ code: String) {
        executeJavaScript(code, scriptURL: "arrow://internal")
    }

    public func devToolsMethod(_ method: String) async -> [String: Any]? {
        await devToolsMethod(method, params: [:])
    }

    public func showDevTools(panel: String? = nil) { showDevTools(inspectAt: nil, panel: panel) }
    public func showDevTools(inspectAt point: CGPoint) { showDevTools(inspectAt: point, panel: nil) }

    public func captureScreenshot() async -> Data? { await captureScreenshot(clip: nil) }

    /// A favicon, at most 64 pixels wide.
    public func downloadImage(url: String) async -> Data? {
        await downloadImage(url: url, isFavicon: true, maxSize: 64)
    }
}

/// A browsing profile: cookies, storage and cache isolated from other
/// profiles.
@MainActor
public protocol BrowsingContext: AnyObject {
    /// In-memory profile whose data is discarded when released.
    var isIncognito: Bool { get }
    /// A new browser in this profile, created by `create(url:)`.
    func makeBrowser() -> any BrowserEngine
    /// The profile's media router (Cast), when the engine has one.
    func makeMediaRouter() -> (any MediaRouter)?
    func clearHTTPCache()
    /// Deletes the cookies of `url`'s site, or every cookie when nil.
    func deleteCookies(url: String?)
}

/// The engine as a whole: its profiles and the services shared by every
/// browser.
@MainActor
public protocol EngineRuntime: AnyObject {
    /// Version of the engine's Chromium, e.g. "156.0.7563.0".
    var chromiumVersion: String { get }
    /// Directory holding every profile's data (cookies, cache…).
    var rootCachePath: URL { get }
    /// The default profile.
    func defaultContext() -> any BrowsingContext
    /// A profile stored under `path`, inside `rootCachePath`.
    func persistentContext(path: URL) -> any BrowsingContext
    /// An in-memory profile.
    func incognitoContext() -> any BrowsingContext
    /// Receives every download of the application.
    var downloads: any DownloadCenter { get }
    /// Blocks subresource requests (ad blocker).
    var resourceFilter: any ResourceFilter { get }
}

/// Snapshot of a download reported by the engine.
public struct Download: Sendable, Identifiable {
    public enum State: Sendable { case inProgress, paused, complete, canceled, interrupted }

    public var id: UInt32
    public var url: String
    public var suggestedFileName: String
    public var fullPath: String
    public var mimeType: String
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var percentComplete: Int
    public var currentSpeed: Int64
    public var state: State

    public init(id: UInt32, url: String, suggestedFileName: String, fullPath: String, mimeType: String,
                receivedBytes: Int64, totalBytes: Int64, percentComplete: Int, currentSpeed: Int64, state: State) {
        self.id = id
        self.url = url
        self.suggestedFileName = suggestedFileName
        self.fullPath = fullPath
        self.mimeType = mimeType
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.percentComplete = percentComplete
        self.currentSpeed = currentSpeed
        self.state = state
    }
}

@MainActor
public protocol DownloadCenterDelegate: AnyObject {
    /// Destination of a new download, and whether to ask the user (save panel).
    func downloadCenter(destinationFor suggestedName: String) -> (url: URL, ask: Bool)
    func downloadCenter(didUpdate download: Download)
    /// A navigation of this browser turned into a download.
    func downloadCenter(didStart downloadID: UInt32, inBrowser browserID: Int32)
}

/// The engine's single download handler, shared by every browser.
@MainActor
public protocol DownloadCenter: AnyObject {
    var delegate: (any DownloadCenterDelegate)? { get set }
    func cancel(_ id: UInt32)
    func pause(_ id: UInt32)
    func resume(_ id: UInt32)
}

/// Blocks subresource requests. The engine consults it off the main thread.
public protocol ResourceFilter: AnyObject, Sendable {
    typealias Decision = @Sendable (_ url: String, _ initiator: String?, _ isNavigation: Bool) -> Bool

    /// Installs (or removes, with nil) the blocking decision.
    func setDecision(_ decide: Decision?)
    /// Number of requests blocked since launch.
    var blocked: Int { get }
}
