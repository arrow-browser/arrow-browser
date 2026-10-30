import ArrowKit
import Foundation
import Observation

/// View ▸ Cast: plays the video or audio of the current tab on a Cast
/// device (Chromecast, Google TV, Cast speakers) with Google's Default Media
/// Receiver. CEF has no tab mirroring, so what is cast is the media URL of
/// the page: the device fetches it itself.
@MainActor
@Observable
public final class CastController {
    public static let shared = CastController()

    public enum Status: Equatable {
        case idle
        case connecting(sinkID: String)
        case casting(sinkID: String)
    }

    public private(set) var sinks: [MediaSink] = []
    public private(set) var status: Status = .idle
    /// "PLAYING", "PAUSED", "BUFFERING" or "IDLE", as the device reports it.
    public private(set) var playerState: String?
    public private(set) var media: CastMedia?
    public var errorMessage: String?
    /// Device lists reported by Chromium since launch (Debug diagnostics).
    @ObservationIgnored public private(set) var sinkReports = 0

    @ObservationIgnored private var router: (any MediaRouter)?
    @ObservationIgnored private var routerContext: (any BrowsingContext)?
    @ObservationIgnored private var route: (any MediaRoute)?
    /// Paused once its media plays on the device.
    @ObservationIgnored private weak var sourceTab: WebTab?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var mediaSessionID: Int?
    @ObservationIgnored private var sequenceNumber = 0
    /// Identifies Arrow as a sender, as the Cast SDK does with a random number.
    @ObservationIgnored private let clientID = String(UInt32.random(in: 100_000...UInt32.max))

    private init() {}

    public var castingSinkID: String? {
        if case let .casting(id) = status { return id }
        return nil
    }

    /// Looks for devices while the Cast popover is open (or while casting).
    public func startDiscovery(context: any BrowsingContext) {
        if router == nil || routerContext !== context, route == nil {
            router?.stopDiscovery()
            router = context.makeMediaRouter()
            routerContext = context
            sinks = []
            router?.onSinks = { [weak self] sinks in
                self?.sinkReports += 1
                self?.sinks = sinks.filter(\.isCast)
            }
            router?.onRouteState = { [weak self] routeID, state in self?.routeDidChange(routeID, state) }
            router?.onRouteMessage = { [weak self] routeID, message in self?.receive(message, on: routeID) }
        }
        errorMessage = nil
        router?.startDiscovery()
    }

    public var isDiscovering: Bool { router?.isDiscovering ?? false }

    public func stopDiscovery() {
        guard route == nil else { return }
        router?.stopDiscovery()
    }

    /// Launches the Default Media Receiver on `sink` and loads `media` once
    /// the session is up (see `receive(_:on:)`).
    public func cast(_ media: CastMedia, to sink: MediaSink, from tab: WebTab?) async {
        guard let router else { return }
        if route != nil { stop() }
        self.media = media
        sourceTab = tab
        errorMessage = nil
        playerState = nil
        sessionID = nil
        mediaSessionID = nil
        status = .connecting(sinkID: sink.id)
        do {
            route = try await router.createRoute(sourceURN: CastProtocol.sourceURN(clientID: clientID), sink: sink)
        } catch {
            status = .idle
            errorMessage = error.description
        }
    }

    public func togglePlayback() {
        guard let route, let sessionID, let mediaSessionID else { return }
        sequenceNumber += 1
        route.send(CastProtocol.playbackMessage(clientID: clientID, sessionID: sessionID, mediaSessionID: mediaSessionID,
                                                sequenceNumber: sequenceNumber, play: playerState == "PAUSED"))
    }

    /// Stops the receiver app on the device.
    public func stop() {
        route?.terminate()
        reset()
    }

    private func reset() {
        route = nil
        sessionID = nil
        mediaSessionID = nil
        playerState = nil
        status = .idle
    }

    private func routeDidChange(_ routeID: String, _ state: MediaRouteState) {
        guard routeID == route?.id else { return }
        switch state {
        case .closed, .terminated: reset()
        case .connecting, .connected: break
        }
    }

    private func receive(_ message: String, on routeID: String) {
        guard let route, routeID == route.id, let event = CastProtocol.event(from: message) else { return }
        switch event {
        case let .session(id):
            guard sessionID == nil, let media else { return }
            sessionID = id
            status = .casting(sinkID: route.sinkID)
            sequenceNumber += 1
            route.send(CastProtocol.loadMessage(clientID: clientID, sessionID: id, sequenceNumber: sequenceNumber, media: media))
        case let .mediaStatus(state, mediaSessionID, idleReason):
            if state == "PLAYING", playerState == nil || playerState == "BUFFERING" { sourceTab?.pauseMedia() }
            playerState = state
            if let mediaSessionID { self.mediaSessionID = mediaSessionID }
            if state == "IDLE", idleReason == "ERROR" { errorMessage = "The device couldn't play this media." }
        case .stopped:
            reset()
        case let .error(description):
            errorMessage = description
        }
    }
}

extension WebTab {
    /// The media of the page to cast: the one playing, else the largest one.
    public func castableMedia() async -> Result<CastMedia, CastMediaError> {
        guard let engine,
              let found = await engine.evaluateJavaScript(Self.castableMediaScript) as? [String: Any],
              let url = found["url"] as? String else {
            return .failure(CastMediaError(description: "This page has no video or audio to cast."))
        }
        if let reason = CastMedia.unsupportedReason(for: url) {
            return .failure(CastMediaError(description: reason))
        }
        let title = (found["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? self.title
        return .success(CastMedia(url: url, title: title, posterURL: found["poster"] as? String,
                                  currentTime: found["time"] as? Double ?? 0, isVideo: found["video"] as? Bool ?? true,
                                  isLive: found["live"] as? Bool ?? false))
    }

    /// Pauses the page once its media plays on the device.
    public func pauseMedia() {
        engine?.executeJavaScript("document.querySelectorAll('video, audio').forEach(m => m.pause())")
    }

    private static let castableMediaScript = """
    (() => {
      const area = m => m.clientWidth * m.clientHeight;
      const media = [...document.querySelectorAll('video, audio')]
        .filter(m => m.currentSrc || m.src)
        .sort((a, b) => (Number(!b.paused) - Number(!a.paused)) || (area(b) - area(a)))[0];
      if (!media) return null;
      return {
        url: media.currentSrc || media.src,
        poster: media.poster || null,
        time: media.currentTime || 0,
        video: media.tagName === 'VIDEO',
        live: media.duration === Infinity,
        title: navigator.mediaSession?.metadata?.title || document.title,
      };
    })()
    """
}

public struct CastMediaError: Error {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}
