import Foundation

/// Where a navigation requested by a page should open.
public enum WindowOpenDisposition: Sendable {
    case currentTab
    case newForegroundTab
    case newBackgroundTab
    case newPopup
    case newWindow
    case other
}

/// Size and position requested by `window.open(…, features)`.
public struct PopupFeatures: Sendable {
    public var frame: CGRect?
    public var isPopup: Bool

    public init(frame: CGRect?, isPopup: Bool) {
        self.frame = frame
        self.isPopup = isPopup
    }
}

/// Context of a right click in web content.
public struct ContextMenuParams: Sendable {
    public var linkURL: String
    public var sourceURL: String
    public var pageURL: String
    public var frameURL: String
    public var selectionText: String
    public var titleText: String
    public var isEditable: Bool
    public var mediaType: MediaType
    public var location: CGPoint

    public enum MediaType: Sendable { case none, image, video, audio, canvas, other }

    public init(linkURL: String, sourceURL: String, pageURL: String, frameURL: String, selectionText: String,
                titleText: String, isEditable: Bool, mediaType: MediaType, location: CGPoint) {
        self.linkURL = linkURL
        self.sourceURL = sourceURL
        self.pageURL = pageURL
        self.frameURL = frameURL
        self.selectionText = selectionText
        self.titleText = titleText
        self.isEditable = isEditable
        self.mediaType = mediaType
        self.location = location
    }

    public var hasLink: Bool { !linkURL.isEmpty }
    public var hasSelection: Bool { !selectionText.isEmpty }
}

/// A custom context menu entry inserted by the delegate.
public enum ContextMenuItem: Sendable {
    case item(id: Int, title: String)
    case separator
}

/// Media/permission request coming from a site.
public struct PermissionRequest: Sendable {
    public enum Kind: Hashable, Sendable {
        case camera, microphone, screenCapture, location, notifications, clipboard, midi, other
    }

    public var origin: String
    public var kinds: Set<Kind>

    public init(origin: String, kinds: Set<Kind>) {
        self.origin = origin
        self.kinds = kinds
    }
}

/// Result of a crashed or killed renderer.
public enum TerminationStatus: Sendable {
    case crashed, killed, outOfMemory, other
}

/// Receives the events of a `BrowserEngine`. All methods run on the main
/// thread.
@MainActor
public protocol BrowserEngineDelegate: AnyObject {
    func browserDidCreate(_ browser: any BrowserEngine)
    func browser(_ browser: any BrowserEngine, didChangeAddress url: String)
    func browser(_ browser: any BrowserEngine, didChangeTitle title: String)
    func browser(_ browser: any BrowserEngine, didChangeFaviconURLs urls: [String])
    func browser(_ browser: any BrowserEngine, didChangeLoadingState isLoading: Bool, canGoBack: Bool, canGoForward: Bool)
    func browser(_ browser: any BrowserEngine, didChangeProgress progress: Double)
    func browser(_ browser: any BrowserEngine, didFinishLoad url: String, httpStatusCode: Int)
    func browser(_ browser: any BrowserEngine, didFailLoad url: String, errorCode: Int, errorText: String)
    func browser(_ browser: any BrowserEngine, didChangeStatusMessage message: String?)
    func browser(_ browser: any BrowserEngine, didChangeFullscreen fullscreen: Bool)
    func browser(_ browser: any BrowserEngine, didChangeMediaAccess camera: Bool, microphone: Bool)
    /// Preferred size of the page when auto-resize is enabled.
    func browser(_ browser: any BrowserEngine, didAutoResize size: CGSize)
    /// A console message of the main frame. Return true to suppress it.
    func browser(_ browser: any BrowserEngine, consoleMessage message: String) -> Bool
    /// A page wants to open `url` in a new browser (target=_blank, window.open…).
    /// Return the browser that will host it, or nil to block it.
    func browser(_ browser: any BrowserEngine, createPopupFor url: String, disposition: WindowOpenDisposition,
                 userGesture: Bool, features: PopupFeatures) -> (any BrowserEngine)?
    /// Cmd+click / middle click on a link. Return true when handled.
    func browser(_ browser: any BrowserEngine, openURL url: String, disposition: WindowOpenDisposition) -> Bool
    /// Return false to cancel the main frame navigation.
    func browser(_ browser: any BrowserEngine, shouldNavigateTo url: String, userGesture: Bool, isRedirect: Bool) -> Bool
    func browser(_ browser: any BrowserEngine, didFindMatches count: Int, activeMatch: Int, finalUpdate: Bool)
    func browser(_ browser: any BrowserEngine, contextMenuItemsFor params: ContextMenuParams) -> [ContextMenuItem]
    func browser(_ browser: any BrowserEngine, didSelectContextMenuItem id: Int, params: ContextMenuParams)
    func browser(_ browser: any BrowserEngine, requestsPermission request: PermissionRequest,
                 decision: @escaping @MainActor (Bool) -> Void) -> Bool
    func browser(_ browser: any BrowserEngine, rendererDidTerminate status: TerminationStatus)
    func browserDidGainFocus(_ browser: any BrowserEngine)
    /// The page called `window.close()` or the close finished unload handlers.
    func browserWillClose(_ browser: any BrowserEngine)
    func browserDidClose(_ browser: any BrowserEngine)
}

extension BrowserEngineDelegate {
    public func browserDidCreate(_ browser: any BrowserEngine) {}
    public func browser(_ browser: any BrowserEngine, didChangeAddress url: String) {}
    public func browser(_ browser: any BrowserEngine, didChangeTitle title: String) {}
    public func browser(_ browser: any BrowserEngine, didChangeFaviconURLs urls: [String]) {}
    public func browser(_ browser: any BrowserEngine, didChangeLoadingState isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {}
    public func browser(_ browser: any BrowserEngine, didChangeProgress progress: Double) {}
    public func browser(_ browser: any BrowserEngine, didFinishLoad url: String, httpStatusCode: Int) {}
    public func browser(_ browser: any BrowserEngine, didFailLoad url: String, errorCode: Int, errorText: String) {}
    public func browser(_ browser: any BrowserEngine, didChangeStatusMessage message: String?) {}
    public func browser(_ browser: any BrowserEngine, didChangeFullscreen fullscreen: Bool) {}
    public func browser(_ browser: any BrowserEngine, didChangeMediaAccess camera: Bool, microphone: Bool) {}
    public func browser(_ browser: any BrowserEngine, consoleMessage message: String) -> Bool { false }
    public func browser(_ browser: any BrowserEngine, didAutoResize size: CGSize) {}
    public func browser(_ browser: any BrowserEngine, createPopupFor url: String, disposition: WindowOpenDisposition,
                        userGesture: Bool, features: PopupFeatures) -> (any BrowserEngine)? { nil }
    public func browser(_ browser: any BrowserEngine, openURL url: String, disposition: WindowOpenDisposition) -> Bool { false }
    public func browser(_ browser: any BrowserEngine, shouldNavigateTo url: String, userGesture: Bool, isRedirect: Bool) -> Bool { true }
    public func browser(_ browser: any BrowserEngine, didFindMatches count: Int, activeMatch: Int, finalUpdate: Bool) {}
    public func browser(_ browser: any BrowserEngine, contextMenuItemsFor params: ContextMenuParams) -> [ContextMenuItem] { [] }
    public func browser(_ browser: any BrowserEngine, didSelectContextMenuItem id: Int, params: ContextMenuParams) {}
    public func browser(_ browser: any BrowserEngine, requestsPermission request: PermissionRequest,
                        decision: @escaping @MainActor (Bool) -> Void) -> Bool { false }
    public func browser(_ browser: any BrowserEngine, rendererDidTerminate status: TerminationStatus) {}
    public func browserDidGainFocus(_ browser: any BrowserEngine) {}
    public func browserWillClose(_ browser: any BrowserEngine) {}
    public func browserDidClose(_ browser: any BrowserEngine) {}
}
