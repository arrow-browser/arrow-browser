import ArrowEngine
import CEF
import Foundation

// CEF behind ArrowEngine's protocols, and CEF's types converted to the
// engine-neutral ones.

extension WindowOpenDisposition {
    public init(_ disposition: cef_window_open_disposition_t) {
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

extension PopupFeatures {
    public init(_ features: cef_popup_features_t?) {
        guard let features else {
            self.init(frame: nil, isPopup: false)
            return
        }
        var frame: CGRect?
        if features.widthSet != 0, features.heightSet != 0 {
            frame = CGRect(x: CGFloat(features.x), y: CGFloat(features.y),
                           width: CGFloat(features.width), height: CGFloat(features.height))
        }
        self.init(frame: frame, isPopup: features.isPopup != 0)
    }
}

extension CEFBrowser: BrowserEngine {
    public var context: any BrowsingContext { requestContext }
}

extension CEFRequestContext: BrowsingContext {
    public func makeBrowser() -> any BrowserEngine {
        CEFBrowser(requestContext: self)
    }

    public func makeMediaRouter() -> (any MediaRouter)? {
        CEFMediaRouter(context: self)
    }
}

extension CEFRuntime: EngineRuntime {
    public var chromiumVersion: String { CEFVersion.chromium }
    public func defaultContext() -> any BrowsingContext { CEFRequestContext.global() }
    public func persistentContext(path: URL) -> any BrowsingContext { CEFRequestContext.persistent(path: path) }
    public func incognitoContext() -> any BrowsingContext { CEFRequestContext.incognito() }
    public var downloads: any DownloadCenter { CEFDownloadCenter.shared }
    public var resourceFilter: any ResourceFilter { CEFResourceFilter.shared }
}

extension CEFDownloadCenter: DownloadCenter {}

extension CEFResourceFilter: ResourceFilter {}

extension CEFMediaRoute: MediaRoute {}

extension CEFMediaRouter: MediaRouter {}
