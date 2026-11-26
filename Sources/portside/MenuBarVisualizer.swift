import Accelerate
import AppKit
import Combine
import CoreAudio
import SwiftUI
import os.log

enum MenuBarVisualizerStyle: String, Codable, CaseIterable, Identifiable {
    case off, glow, bars, wave
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .glow: "Glow"
        case .bars: "Bars"
        case .wave: "Wave"
        }
    }
}

enum MenuBarVisualizerColor: String, Codable, CaseIterable, Identifiable {
    case album, accent, rainbow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .album: "Album"
        case .accent: "Accent"
        case .rainbow: "Rainbow"
        }
    }
}

/// Where the visualizer draws.
enum MenuBarVisualizerArea: String, Codable, CaseIterable, Identifiable {
    /// Inside the menu bar shape (full bar, split at the notch, or pills
    /// around items); the whole bar while no shape is drawn.
    case shape
    case bar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shape: "Match menu bar shape"
        case .bar: "Whole menu bar"
        }
    }
}

/// The menu bar shape's look while music plays, when it differs from the
/// usual one. Saved in `menuBarTriggers.look.visualizer.playingLook`.
struct MenuBarPlayingLook: Codable, Equatable {
    var background = DockBackground()
    var cornerRadius = 14.0
    var shadow = false

    init() {}

    /// Starts from the usual look, so turning it on changes nothing yet.
    init(from look: MenuBarLook) {
        background = look.background
        cornerRadius = look.cornerRadius
        shadow = look.shadow
    }

    private enum CodingKeys: String, CodingKey { case background, cornerRadius, shadow }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        background = c.value(.background, or: DockBackground())
        cornerRadius = c.value(.cornerRadius, or: 14.0)
        shadow = c.value(.shadow, or: false)
        self = sanitized
    }

    var sanitized: MenuBarPlayingLook {
        var copy = self
        copy.cornerRadius = cornerRadius.isFinite
            ? min(max(cornerRadius, MenuBarLook.cornerRange.lowerBound), MenuBarLook.cornerRange.upperBound) : 14
        return copy
    }
}

/// Saved in `menuBarTriggers.look.visualizer`. Every key is optional.
struct MenuBarVisualizerSettings: Codable, Equatable {
    static let intensityRange: ClosedRange<Double> = 0.2...1
    static let reactivityRange: ClosedRange<Double> = 0.25...2

    var style = MenuBarVisualizerStyle.off
    var color = MenuBarVisualizerColor.album
    var intensity = 0.6
    /// Follow the playing app's sound (a private audio tap, which asks for
    /// System Audio Recording once). Off, or without that permission, the
    /// animation keeps a steady pulse instead.
    var followsSound = true
    /// How strongly and how fast every style answers the music: 0.25 calm
    /// to 2 lively, 1 as designed.
    var reactivity = 1.0
    var area = MenuBarVisualizerArea.shape
    /// The menu bar shape to use while music plays; nil keeps the usual one.
    /// Works with the visualizer off too.
    var playingShape: MenuBarShape?
    /// The shape's look while music plays (background, border, corners,
    /// shadow); nil keeps the usual one.
    var playingLook: MenuBarPlayingLook?

    /// Something here follows Now Playing: the visualizer, or a shape or
    /// look for while music plays.
    var followsMusic: Bool { style != .off || playingShape != nil || playingLook != nil }

    init() {}

    private enum CodingKeys: String, CodingKey { case style, color, intensity, followsSound, reactivity, area, playingShape, playingLook }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = c.value(.style, or: MenuBarVisualizerStyle.off)
        color = c.value(.color, or: MenuBarVisualizerColor.album)
        intensity = c.value(.intensity, or: 0.6)
        followsSound = c.value(.followsSound, or: true)
        reactivity = c.value(.reactivity, or: 1.0)
        area = c.value(.area, or: MenuBarVisualizerArea.shape)
        playingShape = (try? c.decodeIfPresent(MenuBarShape.self, forKey: .playingShape)) ?? nil
        playingLook = (try? c.decodeIfPresent(MenuBarPlayingLook.self, forKey: .playingLook)) ?? nil
        self = sanitized
    }

    var sanitized: MenuBarVisualizerSettings {
        var copy = self
        copy.intensity = intensity.isFinite ? min(max(intensity, Self.intensityRange.lowerBound), Self.intensityRange.upperBound) : 0.6
        copy.playingLook = playingLook?.sanitized
        copy.reactivity = reactivity.isFinite ? min(max(reactivity, Self.reactivityRange.lowerBound), Self.reactivityRange.upperBound) : 1
        return copy
    }
}

/// Whether music plays, for the menu bar shape's "while music plays"
/// override. True from the moment a track plays until 1.5 s after it stops,
/// so a track change doesn't flip the shape.
@MainActor
final class MenuBarMusicPlayback: ObservableObject {
    static let shared = MenuBarMusicPlayback()
    @Published private(set) var isPlaying = false

    func set(_ value: Bool) {
        if value != isPlaying { isPlaying = value }
    }
}

// MARK: - Levels

/// The latest loudness and frequency bands, written on the audio queue and
/// read each frame. Values are 0...1.
final class MusicLevels: @unchecked Sendable {
    static let bandCount = 16
    private let lock = NSLock()
    private var level: Float = 0
    private var bands = [Float](repeating: 0, count: MusicLevels.bandCount)
    private var updated: TimeInterval = 0
    private var tapping = false

    /// A tap is running: no levels then means silence, not "no tap".
    var isTapping: Bool {
        get { lock.lock(); defer { lock.unlock() }; return tapping }
        set { lock.lock(); tapping = newValue; lock.unlock() }
    }

    func write(level: Float, bands: [Float]) {
        lock.lock()
        self.level = level
        self.bands = bands
        updated = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    /// Nil when nothing came in the last half second (no tap, or silence
    /// the tap does not deliver).
    func read() -> (level: Float, bands: [Float])? {
        lock.lock()
        defer { lock.unlock() }
        guard ProcessInfo.processInfo.systemUptime - updated < 0.5 else { return nil }
        return (level, bands)
    }

    func clear() {
        lock.lock()
        updated = 0
        lock.unlock()
    }
}

/// Turns tap buffers into `MusicLevels`: a 1024-point FFT of the mixed-down
/// signal, grouped into log-spaced bands. Runs on the tap's audio queue.
final class MusicSpectrum {
    static let size = 1024
    private let levels: MusicLevels
    private var samples = [Float](repeating: 0, count: MusicSpectrum.size)
    private var filled = 0
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: MusicSpectrum.size, isHalfWindow: false)
    private let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)

    init(levels: MusicLevels) {
        self.levels = levels
    }

    func consume(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buffer = list.first, let data = buffer.mData else { return }
        let channels = max(1, Int(buffer.mNumberChannels))
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        let floats = data.assumingMemoryBound(to: Float.self)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += floats[frame * channels + channel] }
            samples[filled] = sum / Float(channels)
            filled += 1
            if filled == Self.size {
                analyze()
                filled = 0
            }
        }
    }

    private func analyze() {
        let rms = vDSP.rootMeanSquare(samples)
        let windowed = vDSP.multiply(samples, window)
        var real = [Float](repeating: 0, count: Self.size / 2)
        var imaginary = [Float](repeating: 0, count: Self.size / 2)
        var magnitudes = [Float](repeating: 0, count: Self.size / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP.convert(interleavedComplexVector: Array(raw.bindMemory(to: DSPComplex.self)), toSplitComplexVector: &split)
                }
                fft?.forward(input: split, output: &split)
                vDSP.absolute(split, result: &magnitudes)
            }
        }
        levels.write(level: Self.loudness(rms), bands: Self.bands(magnitudes))
    }

    /// RMS to 0...1 over -50...-6 dBFS.
    static func loudness(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 50) / 44))
    }

    /// FFT magnitudes to `MusicLevels.bandCount` log-spaced bands, each in
    /// 0...1 over a 50 dB range. Internal for tests.
    static func bands(_ magnitudes: [Float]) -> [Float] {
        let count = MusicLevels.bandCount
        let bins = magnitudes.count
        guard bins > 2 else { return [Float](repeating: 0, count: count) }
        // Edges from bin 1 (about 43 Hz at 44.1 kHz) to the last bin, log
        // spaced, each at least one bin past the last so low bands differ.
        var edges = [1]
        for band in 1...count {
            let log = Int(pow(Float(bins - 1), Float(band) / Float(count)).rounded(.down))
            edges.append(min(bins - (count - band), max(edges[band - 1] + 1, log)))
        }
        return (0..<count).map { band in
            let slice = magnitudes[edges[band]..<max(edges[band] + 1, edges[band + 1])]
            let peak = slice.max() ?? 0
            let db = 20 * log10(max(peak / Float(MusicSpectrum.size / 4), 1e-6))
            return min(1, max(0, (db + 50) / 50))
        }
    }
}

/// Taps the playing app's processes for `MusicLevels`. One tap at a time,
/// started and stopped on the main thread.
final class MusicLevelMeter {
    let levels = MusicLevels()
    private(set) var bundleID: String?
    private var meter: ProcessAudioMeter?
    private let queue = DispatchQueue(label: "com.james.portside.visualizer-tap", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.james.portside", category: "MenuBar")

    func follow(_ next: String?) {
        guard next != bundleID else { return }
        bundleID = next
        let old = meter
        meter = nil
        levels.clear()
        levels.isTapping = false
        queue.async { [weak self] in
            old?.stop()
            guard let self, let next else { return }
            let processes = Set(AppActivity.audioProcessObjects().filter { object in
                guard let id = AppActivity.audioBundleID(object) else { return false }
                return id == next || id.hasPrefix(next + ".")
            })
            guard !processes.isEmpty else {
                self.logger.info("visualizer: no audio processes for \(next, privacy: .public)")
                return
            }
            let spectrum = MusicSpectrum(levels: self.levels)
            do {
                let tap = try ProcessAudioMeter(processes: processes, onBuffer: { spectrum.consume($0) }, onChange: { _ in })
                DispatchQueue.main.async {
                    if self.bundleID == next {
                        self.meter = tap
                        self.levels.isTapping = true
                    } else {
                        self.queue.async { tap.stop() }
                    }
                }
                self.logger.info("visualizer: following \(next, privacy: .public)")
            } catch {
                self.logger.error("visualizer: tap failed, pulsing instead: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Controller

/// Animates the menu bar while music plays. One click-through panel per
/// display, just under the menu bar's items (like the menu bar shape), shown
/// only while a track plays and the visualizer is on. The animation runs
/// only then; paused or stopped, the panels go away.
@MainActor
final class MenuBarVisualizer {
    private let model: DockModel
    private let widgets: WidgetStore
    private var settings = MenuBarVisualizerSettings()
    private var restricted = false
    private weak var nowPlaying: NowPlayingWidget?
    private var subscriptions: Set<AnyCancellable> = []
    private var mediaSubscription: AnyCancellable?
    private var panels: [NSPanel] = []
    private let meter = MusicLevelMeter()
    private let state = MenuBarVisualizerState()
    private var hideWork: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?

    init(model: DockModel, widgets: WidgetStore) {
        self.model = model
        self.widgets = widgets
        // Stay over the menu bar shape, which shares the level.
        MenuBarShapeOutlines.shared.above = { [weak self] in self?.panels ?? [] }
        model.$menuBarTriggers.map(\.look.visualizer).removeDuplicates()
            .combineLatest(model.$restrictedMode.removeDuplicates(), widgets.$hosts)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings, restricted, _ in
                MainActor.assumeIsolated { self?.apply(settings, restricted: restricted) }
            }
            .store(in: &subscriptions)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    private func apply(_ next: MenuBarVisualizerSettings, restricted: Bool) {
        settings = next
        self.restricted = restricted
        let media = next.followsMusic ? widgets.widget(NowPlayingWidget.kind) as? NowPlayingWidget : nil
        if media !== nowPlaying {
            nowPlaying = media
            mediaSubscription = media?.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
                // objectWillChange fires before the change lands.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
            }
        }
        update()
    }

    private func update() {
        let track = nowPlaying?.track
        let musicPlaying = track?.isPlaying == true && settings.followsMusic
        let drawing = musicPlaying && settings.style != .off
        state.settings = settings
        state.track = track
        // Audio is capture: restricted mode holds the tap off.
        meter.follow(drawing && settings.followsSound && !restricted ? track?.player.bundleID : nil)
        state.levels = meter.levels
        let playback = MenuBarMusicPlayback.shared
        if musicPlaying {
            hideWork?.cancel()
            hideWork = nil
            playback.set(true)
            if drawing {
                state.playing = true
                state.shown = true
                layout()
            } else if !panels.isEmpty {
                state.playing = false
                state.shown = false
                removePanels()
            }
        } else if (!panels.isEmpty || playback.isPlaying), hideWork == nil {
            // The drawing falls to rest (the wave flattens and sinks, bars
            // drop, the glow fades), then the panels go and the shape goes
            // back. A track change pauses only for a moment, so neither blinks.
            state.playing = false
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.hideWork = nil
                    self?.state.shown = false
                    self?.removePanels()
                    MenuBarMusicPlayback.shared.set(false)
                }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    private func layout() {
        guard state.shown else { return }
        let frames = NSScreen.screens.map { screen in
            MenuBarStylePlan.barFrame(screen: screen.frame, visible: screen.visibleFrame,
                                      statusThickness: NSStatusBar.system.thickness, safeTop: screen.safeAreaInsets.top)
        }
        state.frames = frames
        while panels.count > frames.count { panels.removeLast().orderOut(nil) }
        while panels.count < frames.count { panels.append(makePanel(index: panels.count)) }
        for (panel, frame) in zip(panels, frames) {
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            panel.orderFrontRegardless()
        }
    }

    private func removePanels() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    private func makePanel(index: Int) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // The menu bar shape's level: under the items, over the desktop.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) - 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        // Not in full-screen Spaces, where the menu bar is hidden.
        panel.collectionBehavior = [.ignoresCycle, .stationary, .canJoinAllSpaces]
        panel.contentView = MenuBarVisualizerLayerView(state: state, index: index)
        return panel
    }
}

/// What the panels draw; shared by every display's panel.
@MainActor
final class MenuBarVisualizerState: ObservableObject {
    @Published var settings = MenuBarVisualizerSettings()
    @Published var track: NowPlayingWidget.Track?
    /// Music is playing; false while the drawing falls to rest.
    @Published var playing = false
    /// The panels are up: the animation runs, playing or falling.
    @Published var shown = false
    /// Each panel's bar frame, by panel index.
    @Published var frames: [CGRect] = []
    var levels = MusicLevels()
}

// MARK: - Drawing

/// Eases the raw levels so the drawing moves smoothly: fast up, slow down.
final class VisualizerSmoother {
    enum Target {
        case levels(level: Float, bands: [Float])
        /// A tap runs and hears nothing: fall to rest.
        case silence
        /// No tap: a steady pulse made from the time.
        case pulse
    }

    /// Reactiveness 1 (the middle of the slider) answers at this strength:
    /// mastered music sits high on the loudness and band scales, and at
    /// full strength Bars and Glow pinned near the top all song long.
    static let baseGain = 0.55

    private(set) var level: Double = 0
    private(set) var bands = [Double](repeating: 0, count: MusicLevels.bandCount)
    /// The wave's three sines (long, medium, short), each 0...1: how much
    /// the bass, mids and treble move it, times how hard the music hits.
    private(set) var waveHeights = (low: 0.0, mid: 0.0, high: 0.0)
    /// 1 while music plays, easing to 0 after it stops: the drawing sinks
    /// and fades with it.
    private(set) var presence: Double = 0
    /// The loudness over about the last second.
    private(set) var average: Double = 0
    /// How far the music is above its recent loudness: hits, drops and
    /// chorus lifts read high, a steady passage low. Mastered tracks sit near
    /// one loudness, so this is what makes the wave follow the song.
    private(set) var punch: Double = 0

    /// `reactivity` (Reactiveness, 0.25...2, 1 in the middle) scales how
    /// strongly everything answers the music and how fast it rises and falls.
    func step(_ target: Target, time: Double, playing: Bool, reactivity: Double = 1) {
        let gain = Self.baseGain * reactivity
        var goal: (Double, [Double]) = (0, [Double](repeating: 0, count: bands.count))
        if playing {
            switch target {
            case .levels(let level, let raw): goal = (Double(level), raw.map(Double.init))
            case .silence: break
            case .pulse:
                let beat = 0.55 + 0.25 * sin(time * 2 * .pi * 0.9) + 0.1 * sin(time * 2 * .pi * 2.3)
                goal = (beat, bands.indices.map { index in
                    let x = Double(index) / Double(bands.count)
                    return max(0, 0.45 + 0.3 * sin(time * 3.1 + x * 9) * (1 - x * 0.5) + 0.15 * sin(time * 5.7 + x * 23))
                })
            }
        }
        let raw = goal.0
        goal = (min(1, goal.0 * gain), goal.1.map { min(1, $0 * gain) })
        let rise = min(0.9, 0.2 + 0.25 * reactivity), fall = min(0.5, 0.05 + 0.1 * reactivity)
        func ease(_ current: Double, _ target: Double) -> Double {
            current + (target - current) * (target > current ? rise : fall)
        }
        level = ease(level, goal.0)
        for index in bands.indices { bands[index] = ease(bands[index], goal.1[index]) }
        // Punch compares the music to itself, before the gain.
        average += (raw - average) * 0.035
        let lift = min(1, max(0, ((raw - average) * 4 + raw * 0.35) * reactivity))
        punch += (lift - punch) * (lift > punch ? 0.6 : 0.12)
        presence += ((playing ? 1 : 0) - presence) * (playing ? 0.25 : 0.08)
        func mean(_ range: Range<Int>) -> Double { bands[range].reduce(0, +) / Double(range.count) }
        let swing = 0.4 * level + 0.6 * punch
        let third = bands.count / 3
        waveHeights = (mean(0..<third) * swing, mean(third..<2 * third) * swing, mean(2 * third..<bands.count) * swing)
    }
}

/// One panel's visualizer, drawn with Core Animation: per outline, a
/// gradient layer (the colors) masked by a shape layer (the bars or the
/// wave). Each frame only swaps paths and colors; the window server draws
/// them. A SwiftUI Canvas did the same work in Portside's process, about
/// 9% of a core while music played. Runs a display link at up to 30 fps
/// while the panel is up; still under Reduce Motion.
@MainActor
final class MenuBarVisualizerLayerView: NSView {
    private let state: MenuBarVisualizerState
    private let index: Int
    private let smoother = VisualizerSmoother()
    private let easer = VisualizerAreaEaser()
    private var link: CADisplayLink?
    private var subscriptions: Set<AnyCancellable> = []
    private var areaLayers: [AreaLayers] = []
    private var colorKey: ColorKey?

    /// What the color depends on. The artwork is part of it: a new track
    /// often arrives before its art (Spotify's is downloaded), and keyed on
    /// the track alone the color stayed the fallback for the whole song.
    private struct ColorKey: Equatable {
        let track: String?
        let artwork: ObjectIdentifier?
        let mode: MenuBarVisualizerColor
    }
    private var baseColor = Color.accentColor

    /// One outline: clipped to its corners, holding the color layers.
    private final class AreaLayers {
        let container = CALayer()
        /// The bars, the glow, or the wave's line.
        let main = CAGradientLayer()
        let mainMask = CAShapeLayer()
        /// The wave's faint fill.
        let under = CAGradientLayer()
        let underMask = CAShapeLayer()

        init() {
            container.masksToBounds = true
            // Paths are laid out from the top left, like the outlines.
            container.isGeometryFlipped = true
            for gradient in [main, under] {
                gradient.startPoint = CGPoint(x: 0, y: 0.5)
                gradient.endPoint = CGPoint(x: 1, y: 0.5)
                container.addSublayer(gradient)
            }
            mainMask.fillColor = NSColor.black.cgColor
            underMask.fillColor = NSColor.black.cgColor
            under.mask = underMask
            under.opacity = 0.25
        }
    }

    init(state: MenuBarVisualizerState, index: Int) {
        self.state = state
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        state.$shown.combineLatest(state.$settings, MenuBarShapeOutlines.shared.$outlines)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateLink() } }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLink()
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func updateLink() {
        let running = state.shown && window != nil && !reduceMotion && state.settings.style != .off
        if running, link == nil {
            let next = displayLink(target: self, selector: #selector(tick(_:)))
            next.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            next.add(to: .main, forMode: .common)
            link = next
        } else if !running {
            link?.invalidate()
            link = nil
            // Still: one resting picture (Reduce Motion), or settings changed.
            if state.shown { render(time: 0) }
        }
    }

    #if DEBUG
    /// Debug renders: one frame at `time`, after `frames` steps.
    func renderForPreview(time: Double, frames: Int) {
        for step in 0..<frames { render(time: time - Double(frames - step) / 30) }
    }
    #endif

    @objc private func tick(_ link: CADisplayLink) {
        render(time: Date().timeIntervalSinceReferenceDate)
    }

    private func render(time: Double) {
        let still = reduceMotion
        if still {
            for _ in 0..<40 { smoother.step(.levels(level: 0.5, bands: [Float](repeating: 0.4, count: MusicLevels.bandCount)), time: 0, playing: state.playing) }
        } else {
            let read = state.levels.read()
            let target: VisualizerSmoother.Target = read.map { .levels(level: $0.level, bands: $0.bands) }
                ?? (state.levels.isTapping ? .silence : .pulse)
            smoother.step(target, time: time, playing: state.playing, reactivity: state.settings.reactivity)
        }
        let target = targetAreas ?? [.init(rect: bounds, cornerRadius: 0)]
        let areas = easer.step(toward: target, jump: still)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while areaLayers.count < areas.count {
            let next = AreaLayers()
            layer?.addSublayer(next.container)
            areaLayers.append(next)
        }
        while areaLayers.count > areas.count { areaLayers.removeLast().container.removeFromSuperlayer() }
        let settings = state.settings
        let tint = MenuBarVisualizerDrawing.tint(settings, time: still ? 0 : time, color: color)
        for (area, layers) in zip(areas, areaLayers) {
            // Outlines are top-left; the root layer is not flipped.
            layers.container.frame = CGRect(x: area.rect.minX, y: bounds.height - area.rect.maxY,
                                            width: area.rect.width, height: area.rect.height)
            layers.container.cornerRadius = area.cornerRadius
            layers.container.cornerCurve = .continuous
            update(layers, size: area.rect.size, settings: settings, time: still ? 0 : time, tint: tint)
        }
        CATransaction.commit()
    }

    private func update(_ layers: AreaLayers, size: CGSize, settings: MenuBarVisualizerSettings, time: Double, tint: (Double) -> Color) {
        let bounds = CGRect(origin: .zero, size: size)
        layers.main.frame = bounds
        layers.under.frame = bounds
        layers.mainMask.frame = bounds
        layers.underMask.frame = bounds
        let strength = settings.intensity
        func colors(alpha: Double) -> [CGColor] {
            (0...6).map { NSColor(tint(Double($0) / 6).opacity(alpha)).cgColor }
        }
        switch settings.style {
        case .off:
            layers.main.isHidden = true
            layers.under.isHidden = true
        case .glow:
            let stops = MenuBarVisualizerDrawing.glowStops(settings, smoother: smoother, tint: tint)
            layers.main.isHidden = false
            layers.under.isHidden = true
            layers.main.mask = nil
            layers.main.colors = stops.map { NSColor($0.color).cgColor }
            layers.main.locations = stops.map { NSNumber(value: $0.location) }
        case .bars:
            let path = CGMutablePath()
            for bar in MenuBarVisualizerDrawing.bars(size: size, smoother: smoother) {
                path.addRoundedRect(in: bar.rect, cornerWidth: min(2, bar.rect.width / 2), cornerHeight: min(2, bar.rect.height / 2))
            }
            layers.mainMask.path = path
            layers.mainMask.fillColor = NSColor.black.cgColor
            layers.mainMask.strokeColor = nil
            layers.main.mask = layers.mainMask
            layers.main.isHidden = false
            layers.under.isHidden = true
            layers.main.colors = colors(alpha: strength * smoother.presence * 0.6)
            layers.main.locations = nil
        case .wave:
            let line = MenuBarVisualizerDrawing.wave(size: size, smoother: smoother, time: time)
            layers.mainMask.path = line.cgPath
            layers.mainMask.fillColor = nil
            layers.mainMask.strokeColor = NSColor.black.cgColor
            layers.mainMask.lineWidth = 2
            layers.main.mask = layers.mainMask
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            layers.underMask.path = fill.cgPath
            let shades = colors(alpha: strength * 0.9 * smoother.presence)
            layers.main.colors = shades
            layers.under.colors = shades
            layers.main.locations = nil
            layers.main.isHidden = false
            layers.under.isHidden = false
        }
    }

    /// The menu bar shape's outlines on this bar when matching it, else nil
    /// (the whole bar).
    private var targetAreas: [MenuBarVisualizerDrawing.Area]? {
        guard state.settings.area == .shape, index < state.frames.count,
              let outline = MenuBarShapeOutlines.shared.outline(for: state.frames[index]) else { return nil }
        return outline.rects.map { .init(rect: $0, cornerRadius: min(outline.cornerRadius, $0.height / 2)) }
    }

    /// The album color is read once per track and artwork, not every frame.
    private var color: Color {
        let key = ColorKey(track: state.track?.id, artwork: state.track?.artwork.map(ObjectIdentifier.init), mode: state.settings.color)
        if colorKey != key {
            colorKey = key
            baseColor = switch state.settings.color {
            case .album: Self.visible(ArtworkTint.musicColor(state.track, fallback: .accentColor))
            case .accent: Self.visible(.accentColor)
            case .rainbow: .white
            }
        }
        return baseColor
    }

    /// The color with a floor on its brightness, so it shows over a dark or
    /// black menu bar shape; hue and saturation still follow the song.
    static func visible(_ color: Color) -> Color {
        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return color }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: saturation, brightness: max(brightness, 0.7))
    }
}

/// Eases the drawing areas toward the menu bar shape's outlines, one frame
/// at a time, so a change of shape (the shape while music plays) slides
/// instead of jumping. Matched by position; a new outline grows from its
/// middle, a gone one shrinks into its middle.
final class VisualizerAreaEaser {
    private(set) var rects: [CGRect] = []
    private(set) var radii: [CGFloat] = []
    /// Per frame at 30 fps: most of the way in about 0.35 s.
    static let rate: CGFloat = 0.22

    func step(toward target: [MenuBarVisualizerDrawing.Area], jump: Bool = false) -> [MenuBarVisualizerDrawing.Area] {
        if jump || rects.isEmpty {
            rects = target.map(\.rect)
            radii = target.map(\.cornerRadius)
        } else {
            while rects.count < target.count {
                let rect = target[rects.count].rect
                rects.append(CGRect(x: rect.midX, y: rect.minY, width: 0, height: rect.height))
                radii.append(target[radii.count].cornerRadius)
            }
            for index in rects.indices {
                let current = rects[index]
                let goal = index < target.count ? target[index].rect : CGRect(x: current.midX, y: current.minY, width: 0, height: current.height)
                let radius = index < target.count ? target[index].cornerRadius : radii[index]
                rects[index] = CGRect(x: ease(current.minX, goal.minX), y: ease(current.minY, goal.minY),
                                      width: ease(current.width, goal.width), height: ease(current.height, goal.height))
                radii[index] = ease(radii[index], radius)
            }
            // A gone outline leaves once it has shrunk away.
            while rects.count > target.count, rects[rects.count - 1].width < 0.5 {
                rects.removeLast()
                radii.removeLast()
            }
        }
        return zip(rects, radii).map { .init(rect: $0, cornerRadius: min($1, $0.height / 2)) }
    }

    private func ease(_ current: CGFloat, _ goal: CGFloat) -> CGFloat {
        abs(goal - current) < 0.25 ? goal : current + (goal - current) * Self.rate
    }
}

enum MenuBarVisualizerDrawing {
    /// One outline of the menu bar shape (a pill, or a side of the notch).
    struct Area {
        let rect: CGRect
        let cornerRadius: CGFloat
    }

    /// `areas` nil: the whole bar. Otherwise each outline gets its own
    /// drawing, centered on itself (bars mirror from its middle, the glow
    /// peaks there, the wave spans it), clipped to its corners.
    static func draw(_ settings: MenuBarVisualizerSettings, in canvas: inout GraphicsContext, size: CGSize,
                     areas: [Area]?, smoother: VisualizerSmoother, time: Double, color: Color) {
        guard let areas else {
            draw(settings, in: &canvas, size: size, smoother: smoother, time: time, color: color)
            return
        }
        for area in areas where area.rect.width > 0 && area.rect.height > 0 {
            var inside = canvas
            inside.clip(to: Path(roundedRect: area.rect, cornerRadius: area.cornerRadius, style: .continuous))
            inside.translateBy(x: area.rect.minX, y: area.rect.minY)
            draw(settings, in: &inside, size: area.rect.size, smoother: smoother, time: time, color: color)
        }
    }

    /// The color at `x` (0...1 along an outline).
    static func tint(_ settings: MenuBarVisualizerSettings, time: Double, color: Color) -> (Double) -> Color {
        { x in
            settings.color == .rainbow ? Color(hue: (x + time * 0.05).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 1) : color
        }
    }

    /// The glow: a wash that breathes with the loudness, brightest in the middle.
    static func glowStops(_ settings: MenuBarVisualizerSettings, smoother: VisualizerSmoother, tint: (Double) -> Color) -> [Gradient.Stop] {
        let alpha = settings.intensity * smoother.presence * (0.12 + 0.6 * smoother.level)
        return (0...6).map { index in
            let x = Double(index) / 6
            let edge = 1 - abs(x - 0.5) * 1.4
            return .init(color: tint(x).opacity(alpha * max(0.15, edge)), location: x)
        }
    }

    /// The bars: bands mirrored from the middle out (bass in the center),
    /// centered so a short pill keeps even margins. Silent, a bar rests as a
    /// 2 pt line on the floor.
    static func bars(size: CGSize, smoother: VisualizerSmoother) -> [(rect: CGRect, x: Double, value: Double)] {
        let bands = smoother.bands
        let slot: CGFloat = 10
        let count = max(1, Int(size.width / slot))
        let inset = (size.width - CGFloat(count) * slot) / 2
        return (0..<count).map { index in
            let x = (CGFloat(index) + 0.5) / CGFloat(count)
            let band = min(bands.count - 1, Int(abs(x - 0.5) * 2 * CGFloat(bands.count)))
            let value = bands[band] * smoother.presence
            let height = max(2 * smoother.presence, size.height * CGFloat(value))
            return (CGRect(x: inset + CGFloat(index) * slot + 2, y: size.height - height, width: slot - 4, height: height), Double(x), value)
        }
    }

    /// The wave's line: three smooth sines, long, medium and short, whose
    /// heights follow the bass, mids and treble and how hard the music hits,
    /// with tapered ends. Silent, it lies flat; stopped, it sinks to the
    /// bottom edge as it fades.
    static func wave(size: CGSize, smoother: VisualizerSmoother, time: Double) -> Path {
        let mid = size.height / 2 + size.height / 2 * CGFloat(1 - smoother.presence)
        let amplitude = size.height * 0.46
        let heights = smoother.waveHeights
        var path = Path()
        let steps = max(2, Int(size.width / 2))
        for step in 0...steps {
            let x = Double(step) / Double(steps)
            let sum = heights.low * sin(x * 2 * .pi * 1.5 + time * 2.2)
                + heights.mid * 0.6 * sin(x * 2 * .pi * 3.5 - time * 3.1)
                + heights.high * 0.35 * sin(x * 2 * .pi * 7 + time * 4.4)
            // Typical music at the middle Reactiveness fills about half the
            // height; a soft limit rounds loud peaks instead of flattening them.
            let value = tanh(sum * 3)
            let taper = sin(.pi * x)
            let y = mid + amplitude * CGFloat(value * (0.25 + 0.75 * taper))
            if step == 0 { path.move(to: CGPoint(x: 0, y: y)) } else { path.addLine(to: CGPoint(x: CGFloat(x) * size.width, y: y)) }
        }
        return path
    }

    /// The same drawing into a SwiftUI canvas, for the rendered previews.
    static func draw(_ settings: MenuBarVisualizerSettings, in canvas: inout GraphicsContext, size: CGSize,
                     smoother: VisualizerSmoother, time: Double, color: Color) {
        let strength = settings.intensity
        let tint = tint(settings, time: time, color: color)
        switch settings.style {
        case .off:
            return
        case .glow:
            canvas.fill(Path(CGRect(origin: .zero, size: size)),
                        with: .linearGradient(Gradient(stops: glowStops(settings, smoother: smoother, tint: tint)),
                                              startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
        case .bars:
            for bar in bars(size: size, smoother: smoother) {
                canvas.fill(Path(roundedRect: bar.rect, cornerRadius: 2), with: .color(tint(bar.x).opacity(strength * smoother.presence * 0.6)))
            }
        case .wave:
            let path = wave(size: size, smoother: smoother, time: time)
            let fill = Gradient(colors: (0...6).map { tint(Double($0) / 6).opacity(strength * 0.9 * smoother.presence) })
            let shading = GraphicsContext.Shading.linearGradient(fill, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
            canvas.stroke(path, with: shading, lineWidth: 2)
            var area = path
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            var under = canvas
            under.opacity = 0.25
            under.fill(area, with: shading)
        }
    }
}

#if DEBUG
extension MusicLevelMeter {
    /// `--check-visualizer [bundle id]`: taps the app (Spotify by default)
    /// for three seconds and prints the levels it reads.
    static func probe(_ bundleID: String) -> Int32 {
        let meter = MusicLevelMeter()
        meter.follow(bundleID)
        var reads = 0
        let smoother = VisualizerSmoother()
        for tick in 0..<240 {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 30))
            let read = meter.levels.read()
            if read != nil { reads += 1 }
            smoother.step(read.map { .levels(level: $0.level, bands: $0.bands) } ?? .silence, time: Double(tick) / 30, playing: true)
            guard tick % 15 == 14 else { continue }
            if let read {
                print(String(format: "level %.2f  punch %.2f  shown level %.2f  wave %.2f/%.2f/%.2f", read.level, smoother.punch, smoother.level,
                             smoother.waveHeights.low, smoother.waveHeights.mid, smoother.waveHeights.high))
            } else {
                print("no levels")
            }
        }
        meter.follow(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return reads > 0 ? 0 : 1
    }
}

extension MenuBarVisualizerDrawing {
    /// `--render-visualizer <dir>`: each style and color over a dark bar, mid-song.
    @MainActor
    static func render(to directory: String) -> Int32 {
        let smoother = VisualizerSmoother()
        for step in 0..<12 { smoother.step(.pulse, time: 1.3 + Double(step) / 30, playing: true) }
        var failed = false
        for style in MenuBarVisualizerStyle.allCases where style != .off {
            for color in [MenuBarVisualizerColor.album, .rainbow] {
                var settings = MenuBarVisualizerSettings()
                settings.style = style
                settings.color = color
                let view = Canvas { canvas, size in
                    canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.12)))
                    draw(settings, in: &canvas, size: size, smoother: smoother, time: 1.7, color: Color(red: 0.95, green: 0.3, blue: 0.45))
                    canvas.draw(Text("  Finder   File   Edit   View        ♪ 9:41").font(.system(size: 13, weight: .medium)).foregroundStyle(.white),
                                at: CGPoint(x: 8, y: size.height / 2), anchor: .leading)
                }.frame(width: 600, height: 24)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { failed = true; continue }
                let url = URL(fileURLWithPath: directory).appendingPathComponent("visualizer-\(style.rawValue)-\(color.rawValue).png")
                do { try png.write(to: url) } catch { failed = true }
            }
        }
        // Resting states and the pill outline.
        let loud = VisualizerSmoother.Target.levels(level: 0.8, bands: [Float](repeating: 0.7, count: MusicLevels.bandCount))
        let pills = [CGRect(x: 4, y: 1, width: 230, height: 22), CGRect(x: 380, y: 1, width: 216, height: 22)]
        let cases: [(String, MenuBarVisualizerStyle, (VisualizerSmoother) -> Void, Bool)] = [
            ("wave-silent", .wave, { s in for _ in 0..<20 { s.step(loud, time: 0, playing: true) }; for _ in 0..<40 { s.step(.silence, time: 0, playing: true) } }, false),
            ("wave-falling", .wave, { s in for _ in 0..<20 { s.step(loud, time: 0, playing: true) }; for _ in 0..<8 { s.step(.silence, time: 0, playing: false) } }, false),
            ("bars-silent", .bars, { s in for _ in 0..<20 { s.step(loud, time: 0, playing: true) }; for _ in 0..<40 { s.step(.silence, time: 0, playing: true) } }, false),
            ("bars-pills", .bars, { s in for step in 0..<12 { s.step(.pulse, time: 1.3 + Double(step) / 30, playing: true) } }, true),
            ("glow-pills", .glow, { s in for step in 0..<12 { s.step(.pulse, time: 1.3 + Double(step) / 30, playing: true) } }, true),
            ("wave-pills", .wave, { s in for step in 0..<12 { s.step(.pulse, time: 1.3 + Double(step) / 30, playing: true) } }, true),
        ]
        for (name, style, prepare, clipped) in cases {
            let resting = VisualizerSmoother()
            prepare(resting)
            var settings = MenuBarVisualizerSettings()
            settings.style = style
            let view = Canvas { canvas, size in
                canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.12)))
                if clipped {
                    for rect in pills { canvas.stroke(Path(roundedRect: rect, cornerRadius: 11, style: .continuous), with: .color(.white.opacity(0.25)), lineWidth: 1) }
                }
                draw(settings, in: &canvas, size: size, areas: clipped ? pills.map { .init(rect: $0, cornerRadius: 11) } : nil,
                     smoother: resting, time: 1.7, color: Color(red: 0.95, green: 0.3, blue: 0.45))
            }.frame(width: 600, height: 24)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { failed = true; continue }
            do { try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("visualizer-\(name).png")) } catch { failed = true }
        }
        // The live renderer (Core Animation layers), each style over two pills.
        let state = MenuBarVisualizerState()
        state.playing = true
        for style in [MenuBarVisualizerStyle.glow, .bars, .wave] {
            var settings = MenuBarVisualizerSettings()
            settings.style = style
            settings.area = .bar
            state.settings = settings
            let view = MenuBarVisualizerLayerView(state: state, index: 0)
            view.frame = CGRect(x: 0, y: 0, width: 600, height: 24)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
            view.renderForPreview(time: 1.7, frames: 12)
            guard let layer = view.layer, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 48, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { failed = true; continue }
            context.cgContext.scaleBy(x: 2, y: 2)
            layer.render(in: context.cgContext)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("visualizer-layers-\(style.rawValue).png"))
            }
        }
        print(failed ? "Some previews failed" : "Rendered visualizer previews to \(directory)")
        return failed ? 1 : 0
    }
}
#endif
