import Foundation
import Testing
@testable import ArrowKit

struct CastProtocolTests {
    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    @Test func sourceLaunchesTheDefaultMediaReceiver() {
        #expect(CastProtocol.sourceURN(clientID: "123") == "cast:CC1AD845?clientId=123")
    }

    @Test func loadMessageWrapsTheMediaRequest() {
        let media = CastMedia(url: "https://cdn.example.com/movie.mp4?token=1", title: "Movie",
                              posterURL: "https://cdn.example.com/poster.jpg", currentTime: 42)
        let message = object(CastProtocol.loadMessage(clientID: "c1", sessionID: "s1", sequenceNumber: 3, media: media))
        #expect(message["type"] as? String == "v2_message")
        #expect(message["clientId"] as? String == "c1")
        #expect(message["sequenceNumber"] as? Int == 3)

        let body = message["message"] as? [String: Any]
        #expect(body?["type"] as? String == "LOAD")
        #expect(body?["sessionId"] as? String == "s1")
        #expect(body?["currentTime"] as? Double == 42)
        let payload = body?["media"] as? [String: Any]
        #expect(payload?["contentId"] as? String == "https://cdn.example.com/movie.mp4?token=1")
        #expect(payload?["contentType"] as? String == "video/mp4")
        #expect(payload?["streamType"] as? String == "BUFFERED")
        let metadata = payload?["metadata"] as? [String: Any]
        #expect(metadata?["title"] as? String == "Movie")
        #expect((metadata?["images"] as? [[String: Any]])?.first?["url"] as? String == "https://cdn.example.com/poster.jpg")
    }

    @Test func liveStreamsStartAtTheLiveEdge() {
        let media = CastMedia(url: "https://live.example.com/index.m3u8", title: "Live", currentTime: 600, isLive: true)
        let body = object(CastProtocol.loadMessage(clientID: "c", sessionID: "s", sequenceNumber: 1, media: media))["message"]
            as? [String: Any]
        let payload = body?["media"] as? [String: Any]
        #expect(payload?["contentType"] as? String == "application/x-mpegURL")
        #expect(payload?["streamType"] as? String == "LIVE")
        #expect(body?["currentTime"] as? Double == 0)
    }

    @Test func contentTypeFollowsTheExtension() {
        #expect(CastMedia(url: "https://a.com/v.webm", title: "").contentType == "video/webm")
        #expect(CastMedia(url: "https://a.com/manifest.mpd", title: "").contentType == "application/dash+xml")
        #expect(CastMedia(url: "https://a.com/song.mp3", title: "", isVideo: false).contentType == "audio/mpeg")
        #expect(CastMedia(url: "https://a.com/stream", title: "").contentType == "video/mp4")
    }

    @Test func onlyAddressesTheDeviceCanReachAreCast() {
        #expect(CastMedia.unsupportedReason(for: "https://cdn.example.com/a.mp4") == nil)
        #expect(CastMedia.unsupportedReason(for: "blob:https://www.youtube.com/0b5f") != nil)
        #expect(CastMedia.unsupportedReason(for: "file:///Users/me/a.mp4") != nil)
        #expect(CastMedia.unsupportedReason(for: "http://localhost:8080/a.mp4") != nil)
        #expect(CastMedia.unsupportedReason(for: "http://127.0.0.1/a.mp4") != nil)
        #expect(CastMedia.unsupportedReason(for: "") != nil)
    }

    @Test func readsReceiverEvents() {
        #expect(CastProtocol.event(from: #"{"type":"new_session","clientId":"c","message":{"sessionId":"abc","appId":"CC1AD845"}}"#)
            == .session(id: "abc"))
        #expect(CastProtocol.event(from: """
        {"type":"v2_message","clientId":"c","message":{"type":"MEDIA_STATUS","status":[{"mediaSessionId":1,"playerState":"PLAYING"}]}}
        """) == .mediaStatus(playerState: "PLAYING", mediaSessionID: 1, idleReason: nil))
        #expect(CastProtocol.event(from: #"{"type":"receiver_action","message":{"action":"stop"}}"#) == .stopped)
        #expect(CastProtocol.event(from: #"{"type":"v2_message","message":{"type":"LOAD_FAILED"}}"#)
            == .error("The device couldn't play this media."))
        #expect(CastProtocol.event(from: #"{"type":"error","message":{"code":"session_error","description":"Launch failed"}}"#)
            == .error("Launch failed"))
        #expect(CastProtocol.event(from: #"{"type":"app_message","message":{}}"#) == nil)
        #expect(CastProtocol.event(from: "not json") == nil)
    }

    @Test func playbackMessageTargetsTheMediaSession() {
        let body = object(CastProtocol.playbackMessage(clientID: "c", sessionID: "s", mediaSessionID: 7, sequenceNumber: 2,
                                                       play: false))["message"] as? [String: Any]
        #expect(body?["type"] as? String == "PAUSE")
        #expect(body?["mediaSessionId"] as? Int == 7)
    }
}
