import XCTest
@testable import portside

final class MediaRemoteNowPlayingTests: XCTestCase {
    private func line(_ json: String) -> Data { Data(json.utf8) }

    func testFullPayloadReplacesAndDiffMerges() {
        var state: [String: Any] = ["stale": 1]
        let full = #"{"type":"data","diff":false,"payload":{"title":"Airbender","artist":"Anderson .Paak","playing":true,"bundleIdentifier":"rocks.spotifast.Spotifast","contentItemIdentifier":"A"}}"#
        XCTAssertEqual(MediaRemoteNowPlaying.merge(line(full), into: &state), true)
        XCTAssertNil(state["stale"], "a full payload replaces the state")

        let pause = #"{"type":"data","diff":true,"payload":{"playing":false,"artist":null}}"#
        XCTAssertEqual(MediaRemoteNowPlaying.merge(line(pause), into: &state), false, "no artwork in the diff")
        let snapshot = MediaRemoteNowPlaying.snapshot(state, artwork: nil)
        XCTAssertEqual(snapshot?.title, "Airbender")
        XCTAssertEqual(snapshot?.isPlaying, false)
        XCTAssertNil(snapshot?.artist, "null removes the key")
        XCTAssertEqual(snapshot?.id, "A")
        XCTAssertEqual(snapshot?.bundleID, "rocks.spotifast.Spotifast")

        XCTAssertNil(MediaRemoteNowPlaying.merge(line("not json"), into: &state))
        XCTAssertNil(MediaRemoteNowPlaying.merge(line(#"{"type":"error"}"#), into: &state))
        XCTAssertEqual(state["title"] as? String, "Airbender", "ignored lines leave the state alone")
    }

    func testSnapshotNeedsATitleAndPrefersTheParentApp() {
        XCTAssertNil(MediaRemoteNowPlaying.snapshot([:], artwork: nil), "empty payload: nothing playing")
        XCTAssertNil(MediaRemoteNowPlaying.snapshot(["title": "", "bundleIdentifier": "x"], artwork: nil))
        let web = MediaRemoteNowPlaying.snapshot([
            "title": "Video", "bundleIdentifier": "com.apple.WebKit.GPU",
            "parentApplicationBundleIdentifier": "com.apple.Safari",
        ], artwork: nil)
        XCTAssertEqual(web?.bundleID, "com.apple.Safari")
        XCTAssertEqual(web?.isPlaying, false)
        XCTAssertNotNil(web?.id, "no item id: falls back to title and artist")
    }

    func testSpotifyWithoutAutomationTakesArtFromTheStream() {
        let spotify = NowPlayingWidget.players[0]
        let art = NSImage(size: NSSize(width: 4, height: 4))
        let track = NowPlayingWidget.Track(id: "t", title: "Airbender", artist: "Anderson .Paak", artwork: nil,
                                           artworkURL: nil, isPlaying: true, player: spotify)
        let snapshot = MediaRemoteNowPlaying.Snapshot(bundleID: spotify.bundleID, id: "s", title: "Airbender", artist: nil,
                                                      artwork: art, isPlaying: true, duration: 200, elapsed: 30)
        let filled = NowPlayingWidget.filled(track, from: snapshot)
        XCTAssertTrue(filled?.artwork === art)
        XCTAssertEqual(filled?.duration, 200)
        XCTAssertEqual(filled?.elapsed, 30)
        XCTAssertEqual(filled?.title, "Airbender", "the notification's own fields stay")

        let other = MediaRemoteNowPlaying.Snapshot(bundleID: spotify.bundleID, id: "s", title: "Next song", artist: nil,
                                                   artwork: art, isPlaying: true)
        XCTAssertNil(NowPlayingWidget.filled(track, from: other), "another song's art is not used")
        var withURL = NowPlayingWidget.Track(id: "t", title: "Airbender", artist: nil, artwork: nil,
                                             artworkURL: URL(string: "https://i.scdn.co/x"), isPlaying: true, player: spotify)
        XCTAssertNil(NowPlayingWidget.filled(withURL, from: snapshot), "AppleScript's art wins")
        withURL = track
        XCTAssertNil(NowPlayingWidget.filled(withURL, from: MediaRemoteNowPlaying.Snapshot(
            bundleID: "com.brave.Browser", id: "s", title: "Airbender", artist: nil, artwork: art, isPlaying: true)),
            "only the same player")
    }
}
