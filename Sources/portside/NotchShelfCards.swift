import AppKit
import SwiftUI

/// The Notch Shelf's large cards (SHELF-04c): music, weather and calendar,
/// drawn on the black notch surface rather than as dock tiles.
enum NotchShelfCardLayout {
    /// Below the strip, as wide as the open shelf.
    case wide
    /// One of the Widgets page's two slots.
    case slot
}

enum NotchShelfCardMetrics {
    static let wideArt: CGFloat = 80
    /// The wide music card's content height (art column and text column).
    static let wideHeight: CGFloat = 84
    /// A Widgets page slot, padding included.
    static let slotHeight: CGFloat = 130
    static let slotRadius: CGFloat = 16
}

/// Music everywhere it shows: art (square or spinning vinyl), title, artist,
/// the player's icon, a progress bar that can seek, and large controls.
struct NotchMusicCard: View {
    @ObservedObject var widget: NowPlayingWidget
    let preferences: AgentNotchSettings
    let layout: NotchShelfCardLayout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let track = widget.track {
                switch layout {
                case .wide: wide(track)
                case .slot: slot(track)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(.white.opacity(0.35))
                    Text("Nothing playing").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(alignment: .leading) {
            // Wide: a rounded wash reaching past the card's content; a slot's own shape clips it.
            if layout == .wide {
                tint.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)).padding(-10)
            } else {
                tint.padding(-12)
            }
        }
    }

    private func wide(_ track: NowPlayingWidget.Track) -> some View {
        HStack(alignment: .center, spacing: 14) {
            art(track, side: NotchShelfCardMetrics.wideArt)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    titles(track, title: 14, artist: 12)
                    Spacer(minLength: 4)
                    PlayerIcon(bundleID: track.player.bundleID).frame(width: 16, height: 16)
                }
                NotchProgressBar(track: track, seekable: preferences.musicSeeking, accent: preferences.accent.color) { widget.seek(to: $0) }
                controls(track, small: 15, large: 21, spacing: 34)
            }
            .frame(height: NotchShelfCardMetrics.wideHeight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing: \(track.title)\(track.artist.map { " by \($0)" } ?? "")")
    }

    private func slot(_ track: NowPlayingWidget.Track) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                art(track, side: 48)
                titles(track, title: 13, artist: 11)
                Spacer(minLength: 0)
            }
            NotchProgressBar(track: track, seekable: preferences.musicSeeking, accent: preferences.accent.color) { widget.seek(to: $0) }
            controls(track, small: 13, large: 18, spacing: 26)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing: \(track.title)\(track.artist.map { " by \($0)" } ?? "")")
    }

    private func titles(_ track: NowPlayingWidget.Track, title: CGFloat, artist: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title).font(.system(size: title, weight: .semibold)).lineLimit(1)
            Text(track.artist ?? track.player.name).font(.system(size: artist)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
    }

    @ViewBuilder
    private func art(_ track: NowPlayingWidget.Track, side: CGFloat) -> some View {
        if preferences.musicStyle == .vinyl {
            VinylArt(artwork: track.artwork, side: side, spinning: track.isPlaying && preferences.animate && !reduceMotion)
        } else {
            Group {
                if let artwork = track.artwork {
                    Image(nsImage: artwork).resizable().interpolation(.high).scaledToFill()
                } else {
                    Image(systemName: "music.note").font(.system(size: side * 0.35)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: side, height: side)
            .background(.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: side * 0.16, style: .continuous))
        }
    }

    private func controls(_ track: NowPlayingWidget.Track, small: CGFloat, large: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            control("backward.fill", size: small, label: "Previous track") { widget.send(.previous) }
            control(track.isPlaying ? "pause.fill" : "play.fill", size: large, label: track.isPlaying ? "Pause" : "Play") { widget.send(.playPause) }
            control("forward.fill", size: small, label: "Next track") { widget.send(.next) }
        }
        .frame(maxWidth: .infinity)
    }

    private func control(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: size + 14, height: size + 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var tint: some View {
        if preferences.musicTint, let artwork = widget.track?.artwork, let color = ArtworkTint.color(for: artwork) {
            LinearGradient(colors: [color.opacity(0.75), color.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .allowsHitTesting(false)
        }
    }
}

/// Elapsed and total time with a bar; dragging seeks when allowed. Ticks
/// once a second while visible and playing.
struct NotchProgressBar: View {
    let track: NowPlayingWidget.Track
    let seekable: Bool
    let accent: Color
    let seek: (TimeInterval) -> Void
    @State private var dragging: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = track.duration
            let position = track.position(at: context.date) ?? 0
            let fraction = dragging ?? duration.map { $0 > 0 ? position / $0 : 0 } ?? 0
            HStack(spacing: 8) {
                Text(Self.time(dragging.flatMap { d in duration.map { d * $0 } } ?? position, known: track.elapsed != nil))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(dragging == nil ? .white.opacity(0.8) : accent)
                            .frame(width: geometry.size.width * min(1, max(0, fraction)))
                    }
                    .frame(height: dragging == nil ? 4 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard seekable, duration != nil else { return }
                            dragging = min(1, max(0, value.location.x / max(1, geometry.size.width)))
                        }
                        .onEnded { _ in
                            if let dragging, let duration { seek(dragging * duration) }
                            dragging = nil
                        })
                }
                .frame(height: 12)
                Text(Self.time(duration ?? 0, known: duration != nil))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(track.duration.map { "\(Self.time(track.position(at: Date()) ?? 0, known: true)) of \(Self.time($0, known: true))" } ?? "Unknown")
    }

    static func time(_ seconds: TimeInterval, known: Bool) -> String {
        guard known, seconds.isFinite else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Round art turning like a record while playing, with a spindle hole.
private struct VinylArt: View {
    let artwork: NSImage?
    let side: CGFloat
    let spinning: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !spinning)) { context in
            let degrees = (context.date.timeIntervalSinceReferenceDate * 45).truncatingRemainder(dividingBy: 360)
            ZStack {
                Circle().fill(Color(white: 0.08))
                Group {
                    if let artwork { Image(nsImage: artwork).resizable().interpolation(.high).scaledToFill() }
                    else { Image(systemName: "music.note").font(.system(size: side * 0.3)).foregroundStyle(.white.opacity(0.5)) }
                }
                .frame(width: side * 0.9, height: side * 0.9)
                .clipShape(Circle())
                Circle().strokeBorder(.black.opacity(0.35), lineWidth: side * 0.05)
                Circle().fill(.black).frame(width: side * 0.12, height: side * 0.12)
                    .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
            }
            .frame(width: side, height: side)
            .rotationEffect(.degrees(spinning ? degrees : 0))
        }
    }
}

private struct PlayerIcon: View {
    let bundleID: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// The art's average color, darkened so white text stays readable.
@MainActor
enum ArtworkTint {
    private static var cache: [ObjectIdentifier: Color] = [:]

    static func color(for image: NSImage) -> Color? {
        let key = ObjectIdentifier(image)
        if let cached = cache[key] { return cached }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .medium
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        guard let average = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return nil }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let color = Color(hue: hue, saturation: min(1, saturation * 1.2), brightness: min(0.42, brightness))
        if cache.count > 32 { cache.removeAll() }
        cache[key] = color
        return color
    }
}

/// Weather slot: conditions, temperature, high and low, and the place.
struct NotchWeatherCard: View {
    @ObservedObject var widget: WeatherWidget

    var body: some View {
        Button { widget.activate() } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    Image(systemName: widget.symbol).symbolRenderingMode(.multicolor).font(.system(size: 26))
                    Spacer(minLength: 4)
                    if let place = widget.place {
                        Text(place).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(widget.temperature.map { "\(Int($0.rounded()))°" } ?? "--")
                    .font(.system(size: 34, weight: .semibold)).monospacedDigit()
                Text(widget.condition ?? "Loading").font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let high = widget.high, let low = widget.low {
                    Text("H:\(Int(high.rounded()))°  L:\(Int(low.rounded()))°")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Weather")
    }
}

/// Calendar slot: today, then the next three events with their calendar's
/// color and a Join button when there is a meeting link.
struct NotchCalendarCard: View {
    @ObservedObject var widget: CalendarWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(widget.today.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.red)
                Text(widget.today.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            switch widget.access {
            case .granted:
                if widget.upcoming.isEmpty {
                    Spacer(minLength: 0)
                    Text("No more events today").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    Spacer(minLength: 0)
                } else {
                    ForEach(Array(widget.upcoming.prefix(3).enumerated()), id: \.offset) { _, event in row(event) }
                    Spacer(minLength: 0)
                }
            case .unknown, .denied:
                Spacer(minLength: 0)
                Button(widget.access == .unknown ? "Connect Calendar" : "Calendar Access…") { widget.activate() }
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ event: CalendarWidget.NextEvent) -> some View {
        HStack(spacing: 7) {
            Capsule().fill(event.color).frame(width: 3, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(event.isAllDay ? "All day" : event.start.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).monospacedDigit()
            }
            Spacer(minLength: 2)
            if let meeting = event.meeting {
                Button("Join") { NSWorkspace.shared.open(meeting) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.green.opacity(0.85), in: Capsule())
                    .accessibilityLabel("Join \(event.title)")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
