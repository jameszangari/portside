import CoreAudio
import SwiftUI
import XCTest
@testable import portside

final class MenuBarVisualizerTests: XCTestCase {
    func testSettingsDefaultOffAndClampIntensity() throws {
        let empty = try JSONDecoder().decode(MenuBarVisualizerSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.style, .off, "off until chosen")
        XCTAssertEqual(empty.color, .album)
        XCTAssertTrue(empty.followsSound)
        let loud = try JSONDecoder().decode(MenuBarVisualizerSettings.self, from: Data(#"{"style":"bars","intensity":7,"color":"nope"}"#.utf8))
        XCTAssertEqual(loud.style, .bars)
        XCTAssertEqual(loud.intensity, 1)
        XCTAssertEqual(loud.color, .album, "an unknown color reads as the default")
    }

    func testMenuBarLookKeepsTheVisualizer() throws {
        var look = MenuBarLook()
        look.visualizer.style = .wave
        look.visualizer.color = .rainbow
        look.visualizer.followsSound = false
        let restored = try JSONDecoder().decode(MenuBarLook.self, from: JSONEncoder().encode(look))
        XCTAssertEqual(restored.visualizer, look.visualizer)
        let old = try JSONDecoder().decode(MenuBarLook.self, from: Data(#"{"shape":"full"}"#.utf8))
        XCTAssertEqual(old.visualizer, MenuBarVisualizerSettings(), "a file from before the visualizer")
    }

    func testSpectrumPutsALowToneInALowBand() {
        let levels = MusicLevels()
        let spectrum = MusicSpectrum(levels: levels)
        // 100 Hz at 44.1 kHz, half scale, stereo interleaved.
        let frames = MusicSpectrum.size
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = 0.5 * Float(sin(2 * Double.pi * 100 * Double(frame) / 44_100))
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        samples.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            spectrum.consume(&list)
        }
        let read = levels.read()
        XCTAssertNotNil(read, "one full window analyzes")
        guard let read else { return }
        XCTAssertGreaterThan(read.level, 0.6, "half scale is loud")
        let loudest = read.bands.indices.max { read.bands[$0] < read.bands[$1] }!
        XCTAssertLessThan(loudest, MusicLevels.bandCount / 2, "100 Hz lands in the low half")
        XCTAssertLessThan(read.bands.last!, read.bands[loudest] * 0.7, "the top band stays quieter")
    }

    func testSilenceIsZero() {
        XCTAssertEqual(MusicSpectrum.loudness(0), 0)
        XCTAssertEqual(MusicSpectrum.bands([Float](repeating: 0, count: 512)), [Float](repeating: 0, count: MusicLevels.bandCount))
    }

    func testEveryStyleFallsToRestWhenTheSoundStops() {
        let smoother = VisualizerSmoother()
        let loud = VisualizerSmoother.Target.levels(level: 0.9, bands: [Float](repeating: 0.8, count: MusicLevels.bandCount))
        for _ in 0..<30 { smoother.step(loud, time: 0, playing: true) }
        XCTAssertEqual(smoother.level, 0.9 * VisualizerSmoother.baseGain, accuracy: 0.01, "the middle Reactiveness answers at the base gain")
        XCTAssertGreaterThan(smoother.presence, 0.95)

        // Silence while still playing: flat, but still there.
        for _ in 0..<45 { smoother.step(.silence, time: 0, playing: true) }
        XCTAssertLessThan(smoother.level, 0.01, "the wave lies flat")
        XCTAssertLessThan(smoother.bands.max()!, 0.01, "bars drop")
        XCTAssertGreaterThan(smoother.presence, 0.95)

        // Stopped: everything sinks and fades within the 1.5 s before the panels go.
        for _ in 0..<30 { smoother.step(loud, time: 0, playing: true) }
        for _ in 0..<45 { smoother.step(loud, time: 0, playing: false) }
        XCTAssertLessThan(smoother.level, 0.01)
        XCTAssertLessThan(smoother.presence, 0.03)
    }

    func testAreaDefaultsToTheMenuBarShape() throws {
        XCTAssertEqual(try JSONDecoder().decode(MenuBarVisualizerSettings.self, from: Data("{}".utf8)).area, .shape)
        XCTAssertEqual(try JSONDecoder().decode(MenuBarVisualizerSettings.self, from: Data(#"{"area":"bar"}"#.utf8)).area, .bar)
    }

    func testPunchFollowsChangesNotLoudnessAlone() {
        let smoother = VisualizerSmoother()
        func play(_ level: Float, frames: Int) {
            for _ in 0..<frames { smoother.step(.levels(level: level, bands: [Float](repeating: level, count: MusicLevels.bandCount)), time: 0, playing: true) }
        }
        play(0.7, frames: 150)
        let steady = smoother.punch
        XCTAssertLessThan(steady, 0.4, "a steady loud passage calms down")
        play(0.3, frames: 60)
        play(0.9, frames: 3)
        XCTAssertGreaterThan(smoother.punch, steady + 0.4, "a hit after a quiet part jumps")
        play(0, frames: 60)
        XCTAssertLessThan(smoother.punch, 0.01, "silence is flat")
    }

    func testShapeWhilePlayingIsOptional() throws {
        XCTAssertNil(try JSONDecoder().decode(MenuBarVisualizerSettings.self, from: Data("{}".utf8)).playingShape, "no override by default")
        XCTAssertEqual(try JSONDecoder().decode(MenuBarVisualizerSettings.self, from: Data(#"{"playingShape":"pills"}"#.utf8)).playingShape, .pills)
        XCTAssertNil(try JSONDecoder().decode(MenuBarVisualizerSettings.self, from: Data(#"{"playingShape":"blob"}"#.utf8)).playingShape, "unknown reads as none")
        var look = MenuBarLook()
        look.visualizer.playingShape = .full
        XCTAssertEqual(try JSONDecoder().decode(MenuBarLook.self, from: JSONEncoder().encode(look)).visualizer.playingShape, .full)
    }

    func testAreasSlideBetweenShapes() {
        typealias Area = MenuBarVisualizerDrawing.Area
        let easer = VisualizerAreaEaser()
        let bar = [Area(rect: CGRect(x: 0, y: 0, width: 600, height: 24), cornerRadius: 0)]
        let pills = [Area(rect: CGRect(x: 10, y: 1, width: 200, height: 22), cornerRadius: 11),
                     Area(rect: CGRect(x: 400, y: 1, width: 190, height: 22), cornerRadius: 11)]
        XCTAssertEqual(easer.step(toward: bar).map(\.rect), bar.map(\.rect), "the first frame starts in place")
        let first = easer.step(toward: pills)
        XCTAssertEqual(first.count, 2, "the second pill grows in")
        XCTAssertGreaterThan(first[0].rect.width, 200, "the bar narrows, it doesn't jump")
        XCTAssertLessThan(first[1].rect.width, 190)
        var last = first
        for _ in 0..<40 { last = easer.step(toward: pills) }
        XCTAssertEqual(last.map(\.rect), pills.map(\.rect), "settled")
        for _ in 0..<40 { last = easer.step(toward: bar) }
        XCTAssertEqual(last.map(\.rect), bar.map(\.rect), "the extra pill shrank away")
    }

    func testLookWhilePlaying() throws {
        let plain = try JSONDecoder().decode(MenuBarVisualizerSettings.self, from: Data("{}".utf8))
        XCTAssertNil(plain.playingLook, "same look as usual by default")
        XCTAssertFalse(plain.followsMusic)
        var look = MenuBarLook()
        look.cornerRadius = 6
        look.shadow = true
        look.background.style = .solid
        let copy = MenuBarPlayingLook(from: look)
        XCTAssertEqual(copy.cornerRadius, 6, "starts as a copy of the usual look")
        XCTAssertTrue(copy.shadow)
        XCTAssertEqual(copy.background, look.background)
        look.visualizer.playingLook = copy
        XCTAssertTrue(look.visualizer.followsMusic, "a look alone follows Now Playing")
        let restored = try JSONDecoder().decode(MenuBarLook.self, from: JSONEncoder().encode(look))
        XCTAssertEqual(restored.visualizer.playingLook, copy)
        let wild = try JSONDecoder().decode(MenuBarPlayingLook.self, from: Data(#"{"cornerRadius":400}"#.utf8))
        XCTAssertEqual(wild.cornerRadius, MenuBarLook.cornerRange.upperBound)
    }

    @MainActor
    func testDarkColorsAreLiftedToShowOverABlackShape() {
        func hsb(_ color: Color) -> (CGFloat, CGFloat, CGFloat) {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            NSColor(color).usingColorSpace(.deviceRGB)!.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return (h, s, b)
        }
        let dark = hsb(MenuBarVisualizerLayerView.visible(Color(hue: 0.6, saturation: 0.8, brightness: 0.2)))
        XCTAssertEqual(dark.2, 0.7, accuracy: 0.01, "a dark album color is brightened")
        XCTAssertEqual(dark.0, 0.6, accuracy: 0.01, "its hue stays")
        XCTAssertEqual(dark.1, 0.8, accuracy: 0.02)
        XCTAssertEqual(hsb(MenuBarVisualizerLayerView.visible(Color(hue: 0.1, saturation: 0.5, brightness: 0.9))).2, 0.9, accuracy: 0.01, "bright colors are left alone")
    }

    func testWaveIsSmoothAndReactivenessScalesTheResponse() {
        let target = VisualizerSmoother.Target.levels(level: 0.8, bands: [Float](repeating: 0.7, count: MusicLevels.bandCount))
        let calm = VisualizerSmoother(), middle = VisualizerSmoother(), lively = VisualizerSmoother()
        for _ in 0..<60 {
            calm.step(target, time: 0, playing: true, reactivity: 0.25)
            middle.step(target, time: 0, playing: true, reactivity: 1)
            lively.step(target, time: 0, playing: true, reactivity: 2)
        }
        XCTAssertEqual(middle.level, 0.8 * VisualizerSmoother.baseGain, accuracy: 0.01, "the middle leaves headroom")
        XCTAssertLessThan(middle.level, 0.6, "typical music no longer pins it near the top")
        XCTAssertLessThan(calm.level, middle.level)
        XCTAssertGreaterThan(lively.level, middle.level)
        XCTAssertGreaterThan(lively.waveHeights.low, calm.waveHeights.low)

        // Smooth at any setting: neighbouring points along the line differ little.
        let size = CGSize(width: 600, height: 24)
        let path = MenuBarVisualizerDrawing.wave(size: size, smoother: lively, time: 1.3).cgPath
        var ys: [CGFloat] = []
        path.applyWithBlock { element in
            let kind = element.pointee.type
            if kind == .moveToPoint || kind == .addLineToPoint { ys.append(element.pointee.points[0].y) }
        }
        // Jagged means the direction changes abruptly: the second difference.
        let bends = (1..<(ys.count - 1)).map { abs(ys[$0 + 1] - 2 * ys[$0] + ys[$0 - 1]) }
        XCTAssertLessThan(bends.max()!, 0.5, "no sudden turns between points 2 pt apart")

        for _ in 0..<60 { lively.step(.silence, time: 0, playing: true, reactivity: 2) }
        XCTAssertLessThan(max(lively.waveHeights.low, lively.waveHeights.mid, lively.waveHeights.high), 0.01, "silence lays it flat")
    }

    func testReactivenessDefaultsAndClamps() throws {
        XCTAssertEqual(try JSONDecoder().decode(MenuBarVisualizerSettings.self, from: Data("{}".utf8)).reactivity, 1)
        XCTAssertEqual(try JSONDecoder().decode(MenuBarVisualizerSettings.self, from: Data(#"{"reactivity":9}"#.utf8)).reactivity, 2)
    }
}
