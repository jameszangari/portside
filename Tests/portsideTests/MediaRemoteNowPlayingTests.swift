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
}
