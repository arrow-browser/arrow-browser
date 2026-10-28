import CEF
import Foundation

/// A browsing profile: cookies, storage and cache isolated from other
/// profiles (backed by a CEF request context).
final class CEFRequestContext: @unchecked Sendable {
    let ref: CefRef<cef_request_context_t>
    let isIncognito: Bool

    private init(ref: CefRef<cef_request_context_t>, isIncognito: Bool) {
        self.ref = ref
        self.isIncognito = isIncognito
    }

    /// The default profile (CEF global context).
    static func global() -> CEFRequestContext {
        CEFRequestContext(ref: CefRef(adopting: cef_request_context_get_global_context())!, isIncognito: false)
    }

    /// A persistent profile stored under `path` (must live inside the root
    /// cache path).
    static func persistent(path: URL) -> CEFRequestContext {
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return make(cachePath: path.path, incognito: false)
    }

    /// An in-memory profile whose data is discarded when released.
    static func incognito() -> CEFRequestContext {
        make(cachePath: nil, incognito: true)
    }

    private static func make(cachePath: String?, incognito: Bool) -> CEFRequestContext {
        var settings = cef_request_context_settings_t()
        settings.size = MemoryLayout<cef_request_context_settings_t>.size
        settings.persist_session_cookies = incognito ? 0 : 1
        settings.accept_language_list.set(CEFRuntime.acceptLanguages)
        if let cachePath {
            settings.cache_path.set(cachePath)
        }
        defer {
            settings.cache_path.clear()
            settings.accept_language_list.clear()
        }
        let context = cef_request_context_create_context(&settings, nil)
        return CEFRequestContext(ref: CefRef(adopting: context)!, isIncognito: incognito)
    }

    /// Clears the HTTP cache of this profile.
    func clearHTTPCache() {
        ref.pointer.pointee.clear_http_cache?(ref.pointer, nil)
    }

    /// Deletes the cookies of `url`'s site (or every cookie when nil).
    func deleteCookies(url: String? = nil) {
        guard let manager = CefRef(adopting: ref.pointer.pointee.get_cookie_manager?(ref.pointer, nil)) else { return }
        withOptionalCefString(url) { url in
            _ = manager.pointer.pointee.delete_cookies?(manager.pointer, url, nil, nil)
        }
    }

    /// Reads a content setting (camera, location…) for `url`.
    func contentSetting(url: String, type: cef_content_setting_types_t) -> cef_content_setting_values_t {
        withCefString(url) { url in
            ref.pointer.pointee.get_content_setting?(ref.pointer, url, url, type) ?? CEF_CONTENT_SETTING_VALUE_DEFAULT
        }
    }

    func setContentSetting(url: String, type: cef_content_setting_types_t, value: cef_content_setting_values_t) {
        withCefString(url) { url in
            ref.pointer.pointee.set_content_setting?(ref.pointer, url, url, type, value)
        }
    }
}
