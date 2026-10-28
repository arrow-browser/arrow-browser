import CEF
import Foundation

/// A device found by Chromium's Media Router (Chromecast, Google TV, Cast
/// speaker…).
struct CEFMediaSink: Identifiable, Sendable {
    enum Kind { case tv, speaker, speakerGroup, other }

    let id: String
    let name: String
    let kind: Kind
    let isCast: Bool
    fileprivate let ref: CefRef<cef_media_sink_t>

    fileprivate init(adopting pointer: UnsafeMutablePointer<cef_media_sink_t>?) {
        let ref = CefRef(adopting: pointer)!
        self.ref = ref
        id = String(cefUserFree: ref.pointee.get_id?(ref.pointer))
        name = String(cefUserFree: ref.pointee.get_name?(ref.pointer))
        isCast = ref.pointee.is_cast_sink?(ref.pointer) == 1
        kind = switch ref.pointee.get_icon_type?(ref.pointer) {
        case CEF_MSIT_CAST: .tv
        case CEF_MSIT_CAST_AUDIO: .speaker
        case CEF_MSIT_CAST_AUDIO_GROUP: .speakerGroup
        default: .other
        }
    }
}

/// A connection to an app launched on a device.
final class CEFMediaRoute: @unchecked Sendable {
    let id: String
    let sinkID: String
    private let ref: CefRef<cef_media_route_t>

    fileprivate init(_ ref: CefRef<cef_media_route_t>) {
        self.ref = ref
        id = String(cefUserFree: ref.pointee.get_id?(ref.pointer))
        let sink = CefRef(adopting: ref.pointee.get_sink?(ref.pointer))
        sinkID = sink.map { String(cefUserFree: $0.pointee.get_id?($0.pointer)) } ?? ""
    }

    /// Sends a message to the app (JSON for Cast apps).
    func send(_ message: String) {
        var bytes = Array(message.utf8)
        ref.pointee.send_route_message?(ref.pointer, &bytes, bytes.count)
    }

    /// Stops the app on the device.
    func terminate() {
        ref.pointee.terminate?(ref.pointer)
    }
}

/// Chromium's Media Router for a profile (View ▸ Cast). Device discovery
/// runs only while `startDiscovery()` is in effect, as in Chrome, where it
/// starts when the Cast dialog opens.
@MainActor
final class CEFMediaRouter {
    enum RouteState { case connecting, connected, closed, terminated }

    struct RouteError: Error {
        let description: String
    }

    var onSinks: (([CEFMediaSink]) -> Void)?
    var onRouteState: ((_ routeID: String, RouteState) -> Void)?
    var onRouteMessage: ((_ routeID: String, String) -> Void)?

    private let ref: CefRef<cef_media_router_t>
    private var observer: CefHandler<cef_media_observer_t>?
    private var registration: CefRef<cef_registration_t>?
    private var pendingRoutes: [ObjectIdentifier: RouteRequest] = [:]

    init?(context: CEFRequestContext) {
        let context = context.ref.pointer
        guard let router = CefRef(adopting: context.pointee.get_media_router?(context, nil)) else { return nil }
        ref = router
    }

    var isDiscovering: Bool { registration != nil }

    func startDiscovery() {
        if registration == nil {
            let observer = observer ?? makeObserver()
            self.observer = observer
            registration = CefRef(adopting: ref.pointee.add_observer?(ref.pointer, observer.retained()))
        }
        ref.pointee.notify_current_sinks?(ref.pointer)
    }

    /// Stops discovery and the observer callbacks (routes stay up).
    func stopDiscovery() {
        registration = nil
    }

    /// Launches the app of `sourceURN` ("cast:<appId>?clientId=…") on `sink`.
    func createRoute(sourceURN: String, sink: CEFMediaSink) async throws(RouteError) -> CEFMediaRoute {
        guard let source = CefRef(adopting: withCefString(sourceURN, { ref.pointee.get_source?(ref.pointer, $0) })) else {
            throw RouteError(description: "Invalid media source.")
        }
        guard sink.ref.pointee.is_compatible_with?(sink.ref.pointer, source.retained()) == 1 else {
            throw RouteError(description: "\(sink.name) can't play this media.")
        }
        let result: Result<CEFMediaRoute, RouteError> = await withCheckedContinuation { continuation in
            let request = RouteRequest()
            let key = ObjectIdentifier(request)
            pendingRoutes[key] = request
            request.completion = { [weak self] result in
                self?.pendingRoutes[key] = nil
                continuation.resume(returning: result)
            }
            ref.pointee.create_route?(ref.pointer, source.retained(), sink.ref.retained(), request.handler.retained())
        }
        return try result.get()
    }

    private func makeObserver() -> CefHandler<cef_media_observer_t> {
        CefHandler(owner: self) { observer in
            observer.on_sinks = { observer, count, sinks in
                let sinks = (0..<count).map { CEFMediaSink(adopting: sinks?[$0]) }
                guard let router = CefHandler.owner(of: observer, as: CEFMediaRouter.self) else { return }
                MainActor.assumeIsolated { router.onSinks?(sinks) }
            }
            observer.on_routes = { _, count, routes in
                for index in 0..<count { cefRelease(routes?[index]) }
            }
            observer.on_route_state_changed = { observer, route, state in
                let route = CefRef(adopting: route).map(CEFMediaRoute.init)
                guard let router = CefHandler.owner(of: observer, as: CEFMediaRouter.self), let route else { return }
                let routeState: RouteState = switch state {
                case CEF_MRCS_CONNECTED: .connected
                case CEF_MRCS_CLOSED: .closed
                case CEF_MRCS_TERMINATED: .terminated
                default: .connecting
                }
                MainActor.assumeIsolated { router.onRouteState?(route.id, routeState) }
            }
            observer.on_route_message_received = { observer, route, message, size in
                let route = CefRef(adopting: route).map(CEFMediaRoute.init)
                let text = message.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: size), as: UTF8.self) } ?? ""
                guard let router = CefHandler.owner(of: observer, as: CEFMediaRouter.self), let route else { return }
                MainActor.assumeIsolated { router.onRouteMessage?(route.id, text) }
            }
        }
    }
}

/// Completion of `create_route`.
@MainActor
private final class RouteRequest {
    var completion: ((Result<CEFMediaRoute, CEFMediaRouter.RouteError>) -> Void)?
    private(set) var handler: CefHandler<cef_media_route_create_callback_t>!

    init() {
        handler = CefHandler(owner: self) { callback in
            callback.on_media_route_create_finished = { callback, result, error, route in
                let route = CefRef(adopting: route).map(CEFMediaRoute.init)
                let message = String(cef: error)
                guard let request = CefHandler.owner(of: callback, as: RouteRequest.self) else { return }
                MainActor.assumeIsolated {
                    if result == CEF_MRCR_OK, let route {
                        request.completion?(.success(route))
                    } else {
                        request.completion?(.failure(.init(description: message.isEmpty ? RouteRequest.describe(result) : message)))
                    }
                    request.completion = nil
                }
            }
        }
    }

    private static func describe(_ result: cef_media_route_create_result_t) -> String {
        switch result {
        case CEF_MRCR_TIMED_OUT: "The device didn't answer."
        case CEF_MRCR_SINK_NOT_FOUND: "The device is no longer available."
        case CEF_MRCR_CANCELLED: "Casting was canceled."
        case CEF_MRCR_ROUTE_ALREADY_EXISTS: "This device is already casting this media."
        default: "Couldn't connect to the device."
        }
    }
}
