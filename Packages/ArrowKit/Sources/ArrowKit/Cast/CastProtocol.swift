import Foundation

/// The video or audio of a page, as sent to a Cast device.
public struct CastMedia: Equatable, Sendable {
    public var url: String
    public var title: String
    public var posterURL: String?
    /// Playback position, in seconds.
    public var currentTime: Double
    public var isVideo: Bool
    /// A live stream (no fixed duration).
    public var isLive: Bool

    public init(url: String, title: String, posterURL: String? = nil, currentTime: Double = 0, isVideo: Bool = true,
                isLive: Bool = false) {
        self.url = url
        self.title = title
        self.posterURL = posterURL
        self.currentTime = currentTime
        self.isVideo = isVideo
        self.isLive = isLive
    }

    /// Why a media URL can't be cast: the device fetches it itself, so it
    /// must be a plain web address it can reach (not a `blob:` stream built
    /// by the page, a local file or this Mac's loopback address).
    public static func unsupportedReason(for url: String) -> String? {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased() else {
            return "This page has no video to cast."
        }
        guard scheme == "http" || scheme == "https" else {
            return "This video is streamed by the page and can't be sent to a Cast device."
        }
        let host = components.host?.lowercased() ?? ""
        if host.isEmpty || host == "localhost" || host.hasPrefix("127.") || host == "[::1]" || host == "::1" {
            return "This video is served by this Mac only and can't be reached by a Cast device."
        }
        return nil
    }

    /// MIME type from the file extension (the receiver needs one).
    public var contentType: String {
        let path = URLComponents(string: url)?.path.lowercased() ?? ""
        switch (path as NSString).pathExtension {
        case "m3u8": return "application/x-mpegURL"
        case "mpd": return "application/dash+xml"
        case "webm": return isVideo ? "video/webm" : "audio/webm"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "ogg", "oga": return "audio/ogg"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "mov": return "video/quicktime"
        default: return isVideo ? "video/mp4" : "audio/mpeg"
        }
    }
}

/// Messages exchanged with Chromium's Media Router for a Cast session, in
/// the format the Cast sender SDK uses with Chrome (`client_connect`,
/// `v2_message`, `new_session`…).
public enum CastProtocol {
    /// Google's Default Media Receiver: plays a media URL on the device.
    public static let defaultMediaReceiverID = "CC1AD845"

    /// Media source to launch `appID`, for a sender identified by `clientID`.
    public static func sourceURN(appID: String = defaultMediaReceiverID, clientID: String) -> String {
        "cast:\(appID)?clientId=\(clientID)"
    }

    /// Asks the receiver to load and play `media`.
    public static func loadMessage(clientID: String, sessionID: String, sequenceNumber: Int, media: CastMedia) -> String {
        var metadata: [String: Any] = [
            "metadataType": media.isVideo ? 1 : 3, // MOVIE or MUSIC_TRACK
            "title": media.title,
        ]
        if let posterURL = media.posterURL, CastMedia.unsupportedReason(for: posterURL) == nil {
            metadata["images"] = [["url": posterURL]]
        }
        return v2Message(clientID: clientID, sequenceNumber: sequenceNumber, body: [
            "type": "LOAD",
            "sessionId": sessionID,
            "media": [
                "contentId": media.url,
                "contentUrl": media.url,
                "contentType": media.contentType,
                "streamType": media.isLive ? "LIVE" : "BUFFERED",
                "metadata": metadata,
            ],
            "autoplay": true,
            "currentTime": media.isLive ? 0 : media.currentTime,
        ])
    }

    /// PLAY or PAUSE for the media session `mediaSessionID`.
    public static func playbackMessage(clientID: String, sessionID: String, mediaSessionID: Int, sequenceNumber: Int,
                                       play: Bool) -> String {
        v2Message(clientID: clientID, sequenceNumber: sequenceNumber, body: [
            "type": play ? "PLAY" : "PAUSE",
            "sessionId": sessionID,
            "mediaSessionId": mediaSessionID,
        ])
    }

    private static func v2Message(clientID: String, sequenceNumber: Int, body: [String: Any]) -> String {
        json([
            "type": "v2_message",
            "clientId": clientID,
            "sequenceNumber": sequenceNumber,
            "timeoutMillis": 0,
            "message": body,
        ])
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// What the receiver reports.
    public enum Event: Equatable, Sendable {
        /// The receiver app started (or the sender joined it).
        case session(id: String)
        /// Media status: "IDLE", "BUFFERING", "PLAYING" or "PAUSED".
        case mediaStatus(playerState: String, mediaSessionID: Int?, idleReason: String?)
        /// The session was stopped on the device, or by another sender.
        case stopped
        case error(String)
    }

    /// Reads a message received over the route (nil for messages that need
    /// no handling, such as acknowledgements).
    public static func event(from message: String) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let body = object["message"]
        switch type {
        case "new_session", "update_session":
            guard let sessionID = (body as? [String: Any])?["sessionId"] as? String else { return nil }
            return .session(id: sessionID)
        case "receiver_action":
            return (body as? [String: Any])?["action"] as? String == "stop" ? .stopped : nil
        case "error":
            let error = body as? [String: Any]
            return .error(error?["description"] as? String ?? error?["code"] as? String ?? "The device reported an error.")
        case "v2_message":
            guard let body = body as? [String: Any], let kind = body["type"] as? String else { return nil }
            switch kind {
            case "MEDIA_STATUS":
                guard let status = (body["status"] as? [[String: Any]])?.first,
                      let state = status["playerState"] as? String else { return nil }
                return .mediaStatus(playerState: state, mediaSessionID: status["mediaSessionId"] as? Int,
                                    idleReason: status["idleReason"] as? String)
            case "LOAD_FAILED", "LOAD_CANCELLED":
                return .error("The device couldn't play this media.")
            case "INVALID_REQUEST", "INVALID_PLAYER_STATE":
                return .error(body["reason"] as? String ?? "The device rejected the request.")
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
