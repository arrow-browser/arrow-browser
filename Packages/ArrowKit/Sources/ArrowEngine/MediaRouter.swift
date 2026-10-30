/// A device found by the engine's media router (Chromecast, Google TV, Cast
/// speaker…).
public struct MediaSink: Identifiable, Sendable {
    public enum Kind: Sendable { case tv, speaker, speakerGroup, other }

    public let id: String
    public let name: String
    public let kind: Kind
    public let isCast: Bool

    public init(id: String, name: String, kind: Kind, isCast: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isCast = isCast
    }
}

public enum MediaRouteState: Sendable { case connecting, connected, closed, terminated }

public struct MediaRouteError: Error {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

/// A connection to an app launched on a device.
@MainActor
public protocol MediaRoute: AnyObject {
    var id: String { get }
    var sinkID: String { get }
    /// Sends a message to the app (JSON for Cast apps).
    func send(_ message: String)
    /// Stops the app on the device.
    func terminate()
}

/// The media router of a profile (View ▸ Cast). Device discovery runs only
/// while `startDiscovery()` is in effect, as in Chrome, where it starts when
/// the Cast dialog opens.
@MainActor
public protocol MediaRouter: AnyObject {
    var onSinks: (([MediaSink]) -> Void)? { get set }
    var onRouteState: ((_ routeID: String, MediaRouteState) -> Void)? { get set }
    var onRouteMessage: ((_ routeID: String, String) -> Void)? { get set }
    var isDiscovering: Bool { get }

    func startDiscovery()
    /// Stops discovery and the observer callbacks (routes stay up).
    func stopDiscovery()
    /// Launches the app of `sourceURN` ("cast:<appId>?clientId=…") on `sink`.
    func createRoute(sourceURN: String, sink: MediaSink) async throws(MediaRouteError) -> any MediaRoute
}
