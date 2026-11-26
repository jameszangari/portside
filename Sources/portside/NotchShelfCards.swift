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
                    focusButton(track) { PlayerIcon(bundleID: track.player.bundleID).frame(width: 16, height: 16) }
                }
                NotchProgressBar(track: track, seekable: preferences.musicSeeking, accent: ArtworkTint.musicColor(track, fallback: preferences.accent.color)) { widget.seek(to: $0) }
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
            NotchProgressBar(track: track, seekable: preferences.musicSeeking, accent: ArtworkTint.musicColor(track, fallback: preferences.accent.color)) { widget.seek(to: $0) }
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

    /// The art and the player's icon open the player, as in Bartender.
    private func focusButton<Label: View>(_ track: NowPlayingWidget.Track, @ViewBuilder label: () -> Label) -> some View {
        Button { widget.focusPlayer() } label: { label().contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .help("Open \(track.player.name)")
            .accessibilityLabel("Open \(track.player.name)")
    }

    private func art(_ track: NowPlayingWidget.Track, side: CGFloat) -> some View {
        focusButton(track) { artwork(track, side: side) }
    }

    @ViewBuilder
    private func artwork(_ track: NowPlayingWidget.Track, side: CGFloat) -> some View {
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

    private static var accentCache: [ObjectIdentifier: Color] = [:]

    /// The playing track's art color, else `fallback` (no art).
    static func musicColor(_ track: NowPlayingWidget.Track?, fallback: Color) -> Color {
        track?.artwork.flatMap(accent) ?? fallback
    }

    /// The art's liveliest color, brightened for the audio bars as in
    /// Bartender: the most saturated of an 8 by 8 sample that is not near
    /// black. Gray art gives white.
    static func accent(for image: NSImage) -> Color? {
        let key = ObjectIdentifier(image)
        if let cached = accentCache[key] { return cached }
        let side = 8
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .medium
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var best: (hue: CGFloat, saturation: CGFloat, score: CGFloat)?
        for x in 0..<side {
            for y in 0..<side {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
                pixel.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                guard brightness > 0.2 else { continue }
                let score = saturation * (0.5 + brightness)
                if score > best?.score ?? -1 { best = (hue, saturation, score) }
            }
        }
        let color = best.map { $0.saturation < 0.15 ? Color.white : Color(hue: $0.hue, saturation: min(0.85, max(0.45, $0.saturation)), brightness: 0.95) }
            ?? .white
        if accentCache.count > 32 { accentCache.removeAll() }
        accentCache[key] = color
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

/// The shelf's Clipboard page (SHELF-06): the latest copied texts from
/// Clipboard History as cards. A click copies one back to the pasteboard
/// (nothing is pasted), a drag carries its text out, and hovering shows a
/// delete button. Paused history says so, with Resume.
struct NotchClipboardPage: View {
    @ObservedObject var service: ClipboardService
    let preferences: AgentNotchSettings
    /// The search hotkey's field is up (SHELF-11).
    var searching = false
    @Binding var query: String
    /// The Search button (true) or the field's close button (false).
    var onSearch: (Bool) -> Void = { _ in }
    /// Return copied a match; the shelf closes.
    var onDone: () -> Void = {}
    @FocusState private var fieldFocused: Bool
    @State private var copied: UUID?
    @State private var hovered: UUID?
    @State private var failure: String?
    /// Clear was clicked once; a second click clears the whole history.
    @State private var confirmClear = false

    static let columns = 3
    static let maxRows = 2
    static let cardHeight: CGFloat = 64
    static let spacing: CGFloat = 8

    /// Cards shown: the newest first, up to two rows.
    static func shown(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        Array(entries.sorted { $0.date > $1.date }.prefix(columns * maxRows))
    }

    static let searchHeight: CGFloat = 30

    /// Entries whose text holds every typed word, newest first, up to two
    /// rows; no words shows the newest.
    static func matches(_ entries: [ClipboardEntry], query: String) -> [ClipboardEntry] {
        let terms = CommandCenterRanker.terms(query)
        return shown(terms.isEmpty ? entries : entries.filter { entry in
            let folded = CommandCenterRanker.normalize(entry.text)
            return terms.allSatisfy(folded.contains)
        })
    }

    /// Content height for `count` entries, the paused note and the header
    /// (Search and Clear, or the search field in the same place) included.
    /// While searching it holds two rows, so the shelf stays still as you
    /// type.
    static func height(count: Int, paused: Bool, searching: Bool = false) -> CGFloat {
        let note: CGFloat = paused ? 30 : 0
        if searching { return searchHeight + spacing + note + 2 * cardHeight + spacing }
        guard count > 0 else { return note + 96 }
        let rows = CGFloat(min(maxRows, (min(count, columns * maxRows) + columns - 1) / columns))
        return searchHeight + spacing + note + rows * cardHeight + (rows - 1) * spacing
    }

    var body: some View {
        let entries = searching ? Self.matches(service.entries, query: query) : Self.shown(service.entries)
        VStack(alignment: .leading, spacing: Self.spacing) {
            if searching {
                searchField(first: entries.first)
            } else if !entries.isEmpty {
                header
            }
            if service.prefs.paused {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                    Text("Clipboard History is paused").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("Resume") { service.setPaused(false) }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .frame(height: 22)
            }
            if entries.isEmpty, searching, !service.entries.isEmpty {
                Text("No copied text matches").foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity).frame(height: 2 * Self.cardHeight)
            } else if entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard").font(.title2).foregroundStyle(preferences.accent.color)
                    Text("Nothing copied yet").fontWeight(.medium)
                    Text("Text you copy shows up here.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity).frame(height: 96)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: Self.columns), spacing: Self.spacing) {
                    ForEach(entries) { card($0) }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let failure {
                Text(failure).font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.red.opacity(0.85), in: Capsule())
            }
        }
    }

    /// Above the cards, where the search field opens: the count and how
    /// long history keeps text, Search and Clear. Clear deletes every
    /// entry, not only the cards shown, so it asks first.
    private var header: some View {
        let count = service.entries.count
        return HStack(spacing: 10) {
            if confirmClear {
                Text("Clear all \(count) copied \(count == 1 ? "text" : "texts")? This cannot be undone.")
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button("Cancel") { confirmClear = false }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                Button("Clear History") {
                    service.clear()
                    confirmClear = false
                }
                .buttonStyle(.plain).foregroundStyle(.red)
            } else {
                Text("\(count) copied, kept for \(Self.expiryPhrase(service.prefs.expiryHours))").foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button { onSearch(true) } label: { Label("Search", systemImage: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                    .help("Search all copied text")
                Button("Clear") { confirmClear = true }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                    .accessibilityLabel("Clear clipboard history")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .frame(height: Self.searchHeight)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onDisappear { confirmClear = false }
    }

    static func expiryPhrase(_ hours: Int) -> String {
        switch hours {
        case 1: "1 hour"
        case 24: "1 day"
        case 168: "7 days"
        case 720: "30 days"
        default: hours % 24 == 0 ? "\(hours / 24) days" : "\(hours) hours"
        }
    }

    /// Opened from the search hotkey or the Search button. Type to filter;
    /// Return copies the first match and closes the shelf, the close button
    /// ends the search, Escape closes the shelf.
    private func searchField(first: ClipboardEntry?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.55))
            TextField("Search copied text", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit {
                    guard let first else { return }
                    if case .success = service.copy(first.id) { onDone() } else { copy(first) }
                }
            Button { onSearch(false) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.45)) }
                .buttonStyle(.plain)
                .accessibilityLabel("End search")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: Self.searchHeight)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear { fieldFocused = true }
    }

    private func card(_ entry: ClipboardEntry) -> some View {
        let isCopied = copied == entry.id
        return Button { copy(entry) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    if isCopied {
                        Image(systemName: "checkmark").foregroundStyle(.green)
                        Text("Copied").foregroundStyle(.green)
                    } else {
                        Text(entry.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .font(.system(size: 9.5, weight: .medium)).lineLimit(1)
            }
            .padding(9)
            .frame(height: Self.cardHeight)
            .background(Color.white.opacity(hovered == entry.id ? 0.1 : 0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hovered == entry.id {
                Button { delete(entry) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .frame(width: 16, height: 16).background(.black.opacity(0.7), in: Circle())
                }
                .buttonStyle(.plain).padding(4)
                .accessibilityLabel("Delete")
            }
        }
        .onHover { hovered = notchHover($0, entry.id, hovered) }
        .onDrag { NSItemProvider(object: entry.text as NSString) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.title)
        .accessibilityHint("Copies it to the clipboard")
        .accessibilityAction(named: "Delete") { delete(entry) }
    }

    private func copy(_ entry: ClipboardEntry) {
        switch service.copy(entry.id) {
        case .success:
            copied = entry.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == entry.id { copied = nil } }
        case .failure(let error): show(error.reason)
        }
    }

    private func delete(_ entry: ClipboardEntry) {
        if case .failure(let error) = service.delete(entry.id) { show(error.reason) }
    }

    private func show(_ message: String) {
        failure = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if failure == message { failure = nil } }
    }
}

/// The Files page (SHELF-06b), as in Bartender: files dropped on the notch,
/// up to six, with an AirDrop card beside them. Click opens a file, drag
/// hands out a copy, right click has the rest.
struct NotchFilesPage: View {
    @ObservedObject var shelf: NotchFileShelf
    let preferences: AgentNotchSettings
    /// A file drag is over the notch.
    let dragOver: Bool
    @State private var hovered: UUID?
    @State private var airDropOver = false
    @State private var failure: String?

    static let columns = 3
    static let tileHeight: CGFloat = 64
    static let spacing: CGFloat = 8
    static let footerHeight: CGFloat = 18
    static let airDropWidth: CGFloat = 112
    static let emptyHeight: CGFloat = 96

    /// Content height for `count` files.
    static func height(count: Int) -> CGFloat {
        guard count > 0 else { return emptyHeight }
        let rows = CGFloat((min(count, NotchFileTray.limit) + columns - 1) / columns)
        return rows * tileHeight + (rows - 1) * spacing + spacing + footerHeight
    }

    var body: some View {
        let items = shelf.items
        HStack(alignment: .top, spacing: Self.spacing) {
            if items.isEmpty {
                dropZone
            } else {
                VStack(alignment: .leading, spacing: Self.spacing) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: Self.columns),
                              spacing: Self.spacing) {
                        ForEach(items) { tile($0) }
                    }
                    HStack(spacing: 6) {
                        Text("Files kept for \(preferences.filesKeep.phrase)").foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        Button("Clear") { shelf.removeAll() }
                            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                    }
                    .font(.system(size: 10, weight: .medium))
                    .frame(height: Self.footerHeight)
                }
            }
            airDropCard(items.map(\.url))
        }
        .frame(height: Self.height(count: items.count), alignment: .top)
        .overlay(alignment: .bottom) {
            if let failure {
                Text(failure).font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.red.opacity(0.85), in: Capsule())
            }
        }
        .onAppear { shelf.prune() }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down").font(.title2).foregroundStyle(preferences.accent.color)
            Text("Drop Files Here").fontWeight(.medium)
            Text("Files kept for \(preferences.filesKeep.phrase)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity).frame(height: Self.emptyHeight)
        .background(.white.opacity(dragOver ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(dragOver ? 0.5 : 0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .accessibilityElement(children: .combine)
    }

    // Split in two: as one modifier chain this took over a second to type-check.
    private func tile(_ item: NotchFileTray.Item) -> some View {
        tileFace(item)
            .overlay { dragSource(item) }
            .overlay(alignment: .topTrailing) {
                if hovered == item.id {
                    Button { shelf.remove(item.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            .frame(width: 16, height: 16).background(.black.opacity(0.7), in: Circle())
                    }
                    .buttonStyle(.plain).padding(4)
                    .accessibilityLabel("Remove")
                }
            }
            .onHover { hovered = notchHover($0, item.id, hovered) }
            .help(item.path)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens it. Drag to copy it somewhere.")
            .accessibilityAction { open(item) }
            .accessibilityAction(named: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            .accessibilityAction(named: "Remove") { shelf.remove(item.id) }
    }

    private func tileFace(_ item: NotchFileTray.Item) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable().interpolation(.high).frame(width: 30, height: 30)
            Text(item.name).font(.system(size: 10)).lineLimit(2).truncationMode(.middle)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .frame(height: Self.tileHeight)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(hovered == item.id ? 0.1 : 0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func dragSource(_ item: NotchFileTray.Item) -> NotchFileDragSource {
        NotchFileDragSource(url: item.url, onOpen: { open(item) }, onDragEnded: { delivered in
            if delivered, preferences.filesRemoveAfterDrag { shelf.remove(item.id) }
        }, menu: { menu(item) })
    }

    private func airDropCard(_ urls: [URL]) -> some View {
        Button {
            if !NotchFileShelf.airDrop(urls) { show(urls.isEmpty ? "Drop files on AirDrop to send them" : "AirDrop is not available") }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "airplayaudio").font(.system(size: 22, weight: .medium))
                    .foregroundStyle(airDropOver ? preferences.accent.color : .white)
                Text("AirDrop").font(.system(size: 11, weight: .medium))
            }
            .frame(width: Self.airDropWidth)
            .frame(maxHeight: .infinity)
            .background(.white.opacity(airDropOver ? 0.14 : 0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $airDropOver) { providers in
            NotchFilesPage.urls(from: providers) { dropped in
                if !NotchFileShelf.airDrop(dropped) { show("AirDrop is not available") }
            }
            return true
        }
        .help(urls.isEmpty ? "Drop files here to send them with AirDrop" : "Send these files with AirDrop")
        .accessibilityLabel("AirDrop")
        .accessibilityHint(urls.isEmpty ? "Drop files here to send them" : "Sends the files on the shelf")
    }

    private func open(_ item: NotchFileTray.Item) {
        guard FileManager.default.fileExists(atPath: item.path) else {
            shelf.prune()
            return show("That file moved or was deleted")
        }
        NSWorkspace.shared.open(item.url)
    }

    private func menu(_ item: NotchFileTray.Item) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open") { open(item) })
        menu.addItem(ClosureMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) })
        menu.addItem(ClosureMenuItem("Copy") { NotchFileShelf.copy(item.url) })
        menu.addItem(ClosureMenuItem("AirDrop") { if !NotchFileShelf.airDrop([item.url]) { show("AirDrop is not available") } })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Remove from Shelf") { shelf.remove(item.id) })
        return menu
    }

    private func show(_ message: String) {
        failure = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if failure == message { failure = nil } }
    }

    /// File URLs from a drop, on the main queue.
    static func urls(from providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [Int: URL] = [:]
        let lock = NSLock()
        for (index, provider) in providers.enumerated() where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.lock(); urls[index] = url; lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(urls.sorted { $0.key < $1.key }.map(\.value)) }
    }
}

/// The meeting card (SHELF-07): its calendar color, title, time and a
/// countdown, with Join when the event has a meeting link.
struct NotchMeetingCard: View {
    let event: CalendarWidget.NextEvent

    /// The strip side's room for the meeting: the calendar mark, a gap and
    /// the longest text ("in 59 min", "1:02:03"), plus the 12 pt margins.
    /// An alert's symbol and "100%" fit in it too.
    static let sideWidth: CGFloat = 12 + 16 + 6 + 64 + 12

    /// The strip width that fits the meeting, laid out as the HUD's.
    static func stripWidth(notch: CGFloat, flare: CGFloat) -> CGFloat {
        notch > 0 ? notch + 2 * sideWidth + flare : 3 * sideWidth + flare
    }

    /// "in 4 min", "in 1 min", "now".
    static func countdown(to start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 0 ? "now" : "in \(minutes) min"
    }

    /// The meeting's timer, time since it started: "4:05", "1:02:03".
    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let (h, m, s) = (seconds / 3600, seconds % 3600 / 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The strip's text: the countdown before it starts, then its timer
    /// (or "now" for one without a timer).
    static func stripText(_ event: CalendarWidget.NextEvent, now: Date) -> String {
        guard now >= event.start, NotchMeetingSoon.timed(start: event.start, end: event.end) else { return countdown(to: event.start, now: now) }
        return elapsed(since: event.start, now: now)
    }

    /// The card's line: "10:00  ·  in 4 min", then "10:00 to 10:30  ·  18 min left".
    static func detail(_ event: CalendarWidget.NextEvent, now: Date) -> String {
        let time = event.start.formatted(.dateTime.hour().minute())
        guard now >= event.start, let end = event.end, NotchMeetingSoon.timed(start: event.start, end: end) else {
            return "\(time)  ·  \(countdown(to: event.start, now: now))"
        }
        let left = max(1, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
        return "\(time) to \(end.formatted(.dateTime.hour().minute()))  ·  \(left) min left"
    }

    var body: some View {
        HStack(spacing: 12) {
            Capsule().fill(event.color).frame(width: 4, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).fontWeight(.semibold).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(Self.detail(event, now: context.date))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).monospacedDigit()
                }
            }
            Spacer(minLength: 4)
            if let meeting = event.meeting {
                Button("Join") { NSWorkspace.shared.open(meeting) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.green.opacity(0.85), in: Capsule())
                    .accessibilityLabel("Join \(event.title)")
            }
        }
        .frame(height: 52)
        .accessibilityElement(children: .combine)
    }
}

/// The hovered card after the pointer enters (`inside`) or leaves the card
/// `id`. Leaving keeps a card the pointer has already moved on to. A plain
/// function: inline in `.onHover` this one ternary cost about a second of
/// type checking.
private func notchHover(_ inside: Bool, _ id: UUID, _ hovered: UUID?) -> UUID? {
    if inside { return id }
    return hovered == id ? nil : hovered
}
