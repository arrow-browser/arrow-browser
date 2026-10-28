import AppKit
import CEF

/// Where a navigation requested by a page should open.
enum CEFWindowOpenDisposition: Sendable {
    case currentTab
    case newForegroundTab
    case newBackgroundTab
    case newPopup
    case newWindow
    case other

    init(_ disposition: cef_window_open_disposition_t) {
        switch disposition {
        case CEF_WOD_CURRENT_TAB, CEF_WOD_SINGLETON_TAB, CEF_WOD_SWITCH_TO_TAB: self = .currentTab
        case CEF_WOD_NEW_FOREGROUND_TAB: self = .newForegroundTab
        case CEF_WOD_NEW_BACKGROUND_TAB: self = .newBackgroundTab
        case CEF_WOD_NEW_POPUP: self = .newPopup
        case CEF_WOD_NEW_WINDOW, CEF_WOD_OFF_THE_RECORD: self = .newWindow
        default: self = .other
        }
    }
}

/// Size and position requested by `window.open(…, features)`.
struct CEFPopupFeatures: Sendable {
    var frame: CGRect?
    var isPopup: Bool

    init(_ features: cef_popup_features_t?) {
        guard let features else {
            frame = nil
            isPopup = false
            return
        }
        isPopup = features.isPopup != 0
        if features.widthSet != 0, features.heightSet != 0 {
            frame = CGRect(x: CGFloat(features.x), y: CGFloat(features.y),
                           width: CGFloat(features.width), height: CGFloat(features.height))
        } else {
            frame = nil
        }
    }
}

/// Context of a right click in web content.
struct CEFContextMenuParams: Sendable {
    var linkURL: String
    var sourceURL: String
    var pageURL: String
    var frameURL: String
    var selectionText: String
    var titleText: String
    var isEditable: Bool
    var mediaType: MediaType
    var location: CGPoint

    enum MediaType: Sendable { case none, image, video, audio, canvas, other }

    var hasLink: Bool { !linkURL.isEmpty }
    var hasSelection: Bool { !selectionText.isEmpty }
}

/// A custom context menu entry inserted by the delegate.
enum CEFContextMenuItem {
    case item(id: Int, title: String)
    case separator
}

/// Media/permission request coming from a site.
struct CEFPermissionRequest: Sendable {
    enum Kind: Hashable, Sendable {
        case camera, microphone, screenCapture, location, notifications, clipboard, midi, other
    }

    var origin: String
    var kinds: Set<Kind>
}

/// Result of a crashed or killed renderer.
enum CEFTerminationStatus: Sendable {
    case crashed, killed, outOfMemory, other
}

/// Receives the events of a `CEFBrowser`. All methods run on the main thread.
@MainActor
protocol CEFBrowserDelegate: AnyObject {
    func browserDidCreate(_ browser: CEFBrowser)
    func browser(_ browser: CEFBrowser, didChangeAddress url: String)
    func browser(_ browser: CEFBrowser, didChangeTitle title: String)
    func browser(_ browser: CEFBrowser, didChangeFaviconURLs urls: [String])
    func browser(_ browser: CEFBrowser, didChangeLoadingState isLoading: Bool, canGoBack: Bool, canGoForward: Bool)
    func browser(_ browser: CEFBrowser, didChangeProgress progress: Double)
    func browser(_ browser: CEFBrowser, didFinishLoad url: String, httpStatusCode: Int)
    func browser(_ browser: CEFBrowser, didFailLoad url: String, errorCode: Int, errorText: String)
    func browser(_ browser: CEFBrowser, didChangeStatusMessage message: String?)
    func browser(_ browser: CEFBrowser, didChangeFullscreen fullscreen: Bool)
    func browser(_ browser: CEFBrowser, didChangeMediaAccess camera: Bool, microphone: Bool)
    /// Preferred size of the page when auto-resize is enabled.
    func browser(_ browser: CEFBrowser, didAutoResize size: CGSize)
    /// A console message of the main frame. Return true to suppress it.
    func browser(_ browser: CEFBrowser, consoleMessage message: String) -> Bool
    /// A page wants to open `url` in a new browser (target=_blank, window.open…).
    /// Return the browser that will host it, or nil to block it.
    func browser(_ browser: CEFBrowser, createPopupFor url: String, disposition: CEFWindowOpenDisposition,
                 userGesture: Bool, features: CEFPopupFeatures) -> CEFBrowser?
    /// Cmd+click / middle click on a link. Return true when handled.
    func browser(_ browser: CEFBrowser, openURL url: String, disposition: CEFWindowOpenDisposition) -> Bool
    /// Return false to cancel the main frame navigation.
    func browser(_ browser: CEFBrowser, shouldNavigateTo url: String, userGesture: Bool, isRedirect: Bool) -> Bool
    /// Key event before it reaches the page. Return true when consumed.
    func browser(_ browser: CEFBrowser, handlePreKeyEvent event: NSEvent) -> Bool
    func browser(_ browser: CEFBrowser, didFindMatches count: Int, activeMatch: Int, finalUpdate: Bool)
    func browser(_ browser: CEFBrowser, contextMenuItemsFor params: CEFContextMenuParams) -> [CEFContextMenuItem]
    func browser(_ browser: CEFBrowser, didSelectContextMenuItem id: Int, params: CEFContextMenuParams)
    func browser(_ browser: CEFBrowser, requestsPermission request: CEFPermissionRequest,
                 decision: @escaping @MainActor (Bool) -> Void) -> Bool
    func browser(_ browser: CEFBrowser, rendererDidTerminate status: CEFTerminationStatus)
    func browserDidGainFocus(_ browser: CEFBrowser)
    /// The page called `window.close()` or the close finished unload handlers.
    func browserWillClose(_ browser: CEFBrowser)
    func browserDidClose(_ browser: CEFBrowser)
}

extension CEFBrowserDelegate {
    func browserDidCreate(_ browser: CEFBrowser) {}
    func browser(_ browser: CEFBrowser, didChangeAddress url: String) {}
    func browser(_ browser: CEFBrowser, didChangeTitle title: String) {}
    func browser(_ browser: CEFBrowser, didChangeFaviconURLs urls: [String]) {}
    func browser(_ browser: CEFBrowser, didChangeLoadingState isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {}
    func browser(_ browser: CEFBrowser, didChangeProgress progress: Double) {}
    func browser(_ browser: CEFBrowser, didFinishLoad url: String, httpStatusCode: Int) {}
    func browser(_ browser: CEFBrowser, didFailLoad url: String, errorCode: Int, errorText: String) {}
    func browser(_ browser: CEFBrowser, didChangeStatusMessage message: String?) {}
    func browser(_ browser: CEFBrowser, didChangeFullscreen fullscreen: Bool) {}
    func browser(_ browser: CEFBrowser, didChangeMediaAccess camera: Bool, microphone: Bool) {}
    func browser(_ browser: CEFBrowser, consoleMessage message: String) -> Bool { false }
    func browser(_ browser: CEFBrowser, didAutoResize size: CGSize) {}
    func browser(_ browser: CEFBrowser, createPopupFor url: String, disposition: CEFWindowOpenDisposition,
                 userGesture: Bool, features: CEFPopupFeatures) -> CEFBrowser? { nil }
    func browser(_ browser: CEFBrowser, openURL url: String, disposition: CEFWindowOpenDisposition) -> Bool { false }
    func browser(_ browser: CEFBrowser, shouldNavigateTo url: String, userGesture: Bool, isRedirect: Bool) -> Bool { true }
    func browser(_ browser: CEFBrowser, handlePreKeyEvent event: NSEvent) -> Bool { false }
    func browser(_ browser: CEFBrowser, didFindMatches count: Int, activeMatch: Int, finalUpdate: Bool) {}
    func browser(_ browser: CEFBrowser, contextMenuItemsFor params: CEFContextMenuParams) -> [CEFContextMenuItem] { [] }
    func browser(_ browser: CEFBrowser, didSelectContextMenuItem id: Int, params: CEFContextMenuParams) {}
    func browser(_ browser: CEFBrowser, requestsPermission request: CEFPermissionRequest,
                 decision: @escaping @MainActor (Bool) -> Void) -> Bool { false }
    func browser(_ browser: CEFBrowser, rendererDidTerminate status: CEFTerminationStatus) {}
    func browserDidGainFocus(_ browser: CEFBrowser) {}
    func browserWillClose(_ browser: CEFBrowser) {}
    func browserDidClose(_ browser: CEFBrowser) {}
}
