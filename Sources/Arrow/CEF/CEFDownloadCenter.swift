import ArrowCore
import CEF
import Foundation

/// Single download handler shared by every browser.
final class CEFDownloadCenter: @unchecked Sendable {
    static let shared = CEFDownloadCenter()

    @MainActor weak var delegate: (any DownloadCenterDelegate)?
    private(set) var handler: CefHandler<cef_download_handler_t>!
    @MainActor private var callbacks: [UInt32: CefRef<cef_download_item_callback_t>] = [:]

    private init() {
        handler = CefHandler(owner: self) { handler in
            handler.can_download = { _, browser, _, _ in
                cefRelease(browser)
                return 1
            }
            handler.on_before_download = { handler, browser, item, suggestedName, callback in
                defer {
                    cefRelease(browser)
                    cefRelease(item)
                }
                guard let center = CefHandler.owner(of: handler, as: CEFDownloadCenter.self),
                      let callback = CefRef(adopting: callback) else { return 0 }
                let name = String(cef: suggestedName)
                let browserID = browser.flatMap { $0.pointee.get_identifier?($0) }
                let downloadID = item.flatMap { $0.pointee.get_id?($0) }
                MainActor.assumeIsolated {
                    if let browserID, let downloadID {
                        center.delegate?.downloadCenter(didStart: downloadID, inBrowser: browserID)
                    }
                    let destination = center.delegate?.downloadCenter(destinationFor: name)
                        ?? (url: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(name), ask: false)
                    withCefString(destination.url.path) { path in
                        callback.pointer.pointee.cont?(callback.pointer, path, destination.ask ? 1 : 0)
                    }
                }
                return 1
            }
            handler.on_download_updated = { handler, browser, item, callback in
                defer {
                    cefRelease(browser)
                    cefRelease(item)
                }
                guard let center = CefHandler.owner(of: handler, as: CEFDownloadCenter.self), let item else {
                    cefRelease(callback)
                    return
                }
                let download = CEFDownloadCenter.snapshot(item)
                let callbackRef = CefRef(adopting: callback)
                MainActor.assumeIsolated {
                    if download.state == .inProgress || download.state == .paused {
                        center.callbacks[download.id] = callbackRef
                    } else {
                        center.callbacks[download.id] = nil
                    }
                    center.delegate?.downloadCenter(didUpdate: download)
                }
            }
        }
    }

    private static func snapshot(_ item: UnsafeMutablePointer<cef_download_item_t>) -> Download {
        let i = item.pointee
        let state: Download.State = if i.is_complete?(item) != 0 {
            .complete
        } else if i.is_canceled?(item) != 0 {
            .canceled
        } else if i.is_interrupted?(item) != 0 {
            .interrupted
        } else if i.is_paused?(item) != 0 {
            .paused
        } else {
            .inProgress
        }
        return Download(
            id: i.get_id?(item) ?? 0,
            url: String(cefUserFree: i.get_url?(item)),
            suggestedFileName: String(cefUserFree: i.get_suggested_file_name?(item)),
            fullPath: String(cefUserFree: i.get_full_path?(item)),
            mimeType: String(cefUserFree: i.get_mime_type?(item)),
            receivedBytes: i.get_received_bytes?(item) ?? 0,
            totalBytes: i.get_total_bytes?(item) ?? 0,
            percentComplete: Int(i.get_percent_complete?(item) ?? -1),
            currentSpeed: i.get_current_speed?(item) ?? 0,
            state: state
        )
    }

    @MainActor func cancel(_ id: UInt32) { callbacks[id].map { $0.pointer.pointee.cancel?($0.pointer) } }
    @MainActor func pause(_ id: UInt32) { callbacks[id].map { $0.pointer.pointee.pause?($0.pointer) } }
    @MainActor func resume(_ id: UInt32) { callbacks[id].map { $0.pointer.pointee.resume?($0.pointer) } }
}
