import AppKit
import SwiftUI
import os.log

/// The track playing in Spotify or Music: album art, song, artist, and
/// previous / play-pause / next.
///
/// Event-driven: each player posts a public distributed notification on
/// every play, pause, or track change. Portside then asks that player for
/// the full track over AppleScript (needs Automation permission, asked once
/// per player), which also gives the art. Without permission it shows what
/// the notification carries: song and artist, with the player's icon.
final class NowPlayingWidget: DockWidget {
    static let kind = "nowPlaying"
    let name = "Now Playing"
    var hoverTitle: String {
        guard let track else { return "Now Playing · Nothing playing" }
        return [track.title, track.artist].compactMap { $0 }.joined(separator: " · ")
            + (track.isPlaying ? "" : " (Paused)")
    }
    let icon = Image(systemName: "music.note")
    let size = WidgetSize.large
    let refreshInterval: TimeInterval = 0

    struct Track: Equatable {
        /// Player's own track id, so art is only fetched on a new track.
        let id: String
        let title: String
        let artist: String?
        var artwork: NSImage?
        let artworkURL: URL?
        var isPlaying: Bool
        let player: Player
    }

    struct Player: Equatable {
        let bundleID: String
        /// AppleScript application name.
        let name: String
        let notification: String
    }

    enum Command: String {
        case previous = "previous track", playPause = "playpause", next = "next track"

        /// NX_KEYTYPE_PREVIOUS, NX_KEYTYPE_PLAY, NX_KEYTYPE_NEXT.
        var mediaKey: Int {
            switch self {
            case .previous: 18
            case .playPause: 16
            case .next: 17
            }
        }
    }

    static let players = [
        Player(bundleID: "com.spotify.client", name: "Spotify", notification: "com.spotify.client.PlaybackStateChanged"),
        Player(bundleID: "com.apple.Music", name: "Music", notification: "com.apple.Music.playerInfo"),
    ]

    /// Each player's current track, by bundle id.
    @Published private var tracks: [String: Track] = [:]
    /// Bundle ids, most recently changed first.
    private var recent: [String] = []

    /// The playing track that changed last, else the last paused one.
    var track: Track? {
        let ordered = recent.compactMap { tracks[$0] }
        return ordered.first { $0.isPlaying } ?? ordered.first
    }

    /// Players with a read in flight, and those that changed meanwhile.
    /// Keeps a slow player from queueing a read per notification.
    private var reading: Set<String> = []
    private var stale: Set<String> = []
    /// Each player's latest notification, for when AppleScript is denied.
    private var lastNote: [String: [AnyHashable: Any]] = [:]

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// AppleScript runs here, off the main thread: an Apple event can wait
    /// on a busy player, and the first one waits on the permission prompt.
    private let scriptQueue = DispatchQueue(label: "com.james.portside.nowplaying")
    private let logger = Logger(subsystem: "com.james.portside", category: "Widgets")

    func start() {
        let distributed = DistributedNotificationCenter.default()
        for player in Self.players {
            let token = distributed.addObserver(forName: .init(player.notification), object: nil, queue: .main) { [weak self] note in
                self?.fetch(player, note: note.userInfo)
            }
            observers.append((distributed, token))
        }
        // A player that quits sends no "Stopped".
        let workspace = NSWorkspace.shared.notificationCenter
        let token = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let id = app?.bundleIdentifier, self?.tracks[id] != nil {
                self?.set(nil, for: id)
            }
        }
        observers.append((workspace, token))
    }

    func stop() {
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
    }

    /// Once at start: pick up a track that was already playing.
    func refresh() {
        for player in Self.players where Self.isRunning(player) {
            fetch(player, note: nil)
        }
    }

    func activate() {
        send(.playPause)
    }

    func send(_ command: Command) {
        guard let track else { return }
        if command == .playPause {
            // Show the new state now; the player's notification confirms.
            tracks[track.player.bundleID]?.isPlaying.toggle()
        }
        scriptQueue.async { [logger] in
            if PlayerScript.run("tell application \"\(track.player.name)\" to \(command.rawValue)", player: track.player) == nil {
                Self.postMediaKey(command.mediaKey)
                logger.info("now playing: \(command.rawValue, privacy: .public) via media key")
            }
        }
    }

    private func fetch(_ player: Player, note: [AnyHashable: Any]?) {
        let id = player.bundleID
        if let note { lastNote[id] = note }
        guard !reading.contains(id) else {
            stale.insert(id)
            return
        }
        reading.insert(id)
        let previous = tracks[id]
        scriptQueue.async { [weak self] in
            let result = PlayerScript.read(player, previous: previous)
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading.remove(id)
                self.apply(result, player: player, note: self.lastNote[id])
                if self.stale.remove(id) != nil { self.fetch(player, note: nil) }
            }
        }
    }

    private func apply(_ result: PlayerScript.Result, player: Player, note: [AnyHashable: Any]?) {
        switch result {
        case .stopped:
            set(nil, for: player.bundleID)
        case .track(let track):
            set(track, for: player.bundleID)
            if track.artwork == nil, let url = track.artworkURL {
                loadArtwork(url, trackID: track.id, player: player)
            }
        case .unavailable:
            // No Automation permission: the notification's own fields.
            let state = note?["Player State"] as? String
            guard let note, let title = note["Name"] as? String, !title.isEmpty, state != "Stopped" else {
                if note != nil { set(nil, for: player.bundleID) }
                return
            }
            let id = (note["Track ID"] ?? note["PersistentID"]).map { "\($0)" } ?? title
            set(Track(id: id, title: title, artist: note["Artist"] as? String, artwork: nil, artworkURL: nil,
                      isPlaying: state == "Playing", player: player), for: player.bundleID)
        }
    }

    private func set(_ track: Track?, for bundleID: String) {
        recent.removeAll { $0 == bundleID }
        if track != nil { recent.insert(bundleID, at: 0) }
        guard tracks[bundleID] != track else { return }
        let changed = tracks[bundleID]?.id != track?.id
        tracks[bundleID] = track
        if changed || track == nil {
            logger.info("now playing (\(bundleID, privacy: .public)): \(track == nil ? "stopped" : track!.isPlaying ? "playing" : "paused", privacy: .public), art \(track?.artwork != nil || track?.artworkURL != nil)")
        }
    }

    /// Spotify hands back an art URL; fetched once per track.
    private func loadArtwork(_ url: URL, trackID: String, player: Player) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.tracks[player.bundleID]?.id == trackID else { return }
                self.tracks[player.bundleID]?.artwork = image
            }
        }.resume()
    }

    private static func isRunning(_ player: Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
    }

    /// A keyboard media key; macOS routes it to the current Now Playing
    /// app. Fallback when Automation is denied. Needs Accessibility.
    private static func postMediaKey(_ key: Int) {
        for down in [true, false] {
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                data1: (key << 16) | ((down ? 0xA : 0xB) << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    var body: some View {
        NowPlayingView(track: track) { [weak self] in self?.send($0) }
    }
}

/// AppleScript calls to Spotify and Music. Call off the main thread.
private enum PlayerScript {
    enum Result {
        case stopped, track(NowPlayingWidget.Track), unavailable
    }

    private static let logger = Logger(subsystem: "com.james.portside", category: "Widgets")

    /// Each script checks `is running` first, so it never launches a
    /// player that quit in the meantime.
    static func read(_ player: NowPlayingWidget.Player, previous: NowPlayingWidget.Track?) -> Result {
        let fields = player.bundleID == "com.spotify.client"
            ? "artist of t, id of t, artwork url of t"
            : "artist of t, persistent ID of t"
        let source = """
        if application "\(player.name)" is running then
            tell application "\(player.name)"
                set s to player state as string
                if s is "stopped" then return {s}
                set t to current track
                return {s, name of t, \(fields)}
            end tell
        end if
        return {"stopped"}
        """
        guard let list = run(source, player: player) else { return .unavailable }
        let items = (1...max(list.numberOfItems, 1)).map { list.atIndex($0)?.stringValue }
        guard items.count >= 4, items[0] != "stopped", let title = items[1], !title.isEmpty else { return .stopped }
        let id = items[3] ?? title
        var artwork = previous?.id == id ? previous?.artwork : nil
        let artworkURL = items.count > 4 ? items[4].flatMap(URL.init(string:)) : nil
        if artwork == nil, player.bundleID == "com.apple.Music" {
            artwork = musicArtwork(player)
        }
        return .track(NowPlayingWidget.Track(
            id: id, title: title, artist: items[2].flatMap { $0.isEmpty ? nil : $0 },
            artwork: artwork, artworkURL: artworkURL,
            isPlaying: items[0] == "playing", player: player))
    }

    /// Music returns the art itself (JPEG or PNG bytes).
    private static func musicArtwork(_ player: NowPlayingWidget.Player) -> NSImage? {
        let source = """
        if application "Music" is running then
            tell application "Music" to return data of artwork 1 of current track
        end if
        """
        guard let result = run(source, player: player, quiet: true) else { return nil }
        return NSImage(data: result.data)
    }

    /// Nil when Automation is denied or the script fails. The first call
    /// per player shows the system's Automation prompt. No
    /// `AEDeterminePermissionToAutomateTarget` up front: it can block with
    /// no timeout while consent is undecided. A busy player times out
    /// after 5s instead of holding the queue.
    @discardableResult
    static func run(_ source: String, player: NowPlayingWidget.Player, quiet: Bool = false) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: "with timeout of 5 seconds\n\(source)\nend timeout")?
            .executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            if number == Int(errAEEventNotPermitted) {
                logger.error("now playing: no Automation access to \(player.name, privacy: .public)")
            } else if !quiet {
                logger.error("now playing: \(player.name, privacy: .public) script failed (\(number))")
            }
            return nil
        }
        return result
    }
}

struct NowPlayingView: View {
    let track: NowPlayingWidget.Track?
    let send: (NowPlayingWidget.Command) -> Void
    @Environment(\.dockTileSize) private var tile
    @Environment(\.widgetSize) private var chosen

    var body: some View {
        let size = WidgetSize.resolved(chosen, natural: .large)
        let inset = WidgetLayout.inset(tile)
        let side = WidgetLayout.itemSide(tile)
        WidgetTile(size: size) {
            if let track {
                switch size {
                case .small:
                    Artwork(track: track, side: side, cornerMark: true)
                case .medium:
                    // No text: art and controls spaced evenly.
                    EvenRow {
                        Artwork(track: track, side: side, cornerMark: false)
                        controlButtons(track)
                    }
                case .large:
                    HStack(spacing: inset) {
                        Artwork(track: track, side: side, cornerMark: false)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(track.title)
                                .font(.system(size: WidgetTypography.fontSize(6.5, tile: tile), weight: .semibold))
                            if let artist = track.artist {
                                Text(artist)
                                    .font(.system(size: WidgetTypography.fontSize(5.5, tile: tile)))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: inset) { controlButtons(track) }
                    }
                    .padding(.horizontal, inset)
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: WidgetTypography.fontSize(12, tile: tile)))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Previous / play-pause / next, as separate views so the row lays
    /// them out (evenly on Wide, `inset` apart on Extra Wide).
    @ViewBuilder
    private func controlButtons(_ track: NowPlayingWidget.Track) -> some View {
        ControlGlyph(symbol: "backward.fill", command: .previous, points: 5.5, send: send)
        ControlGlyph(symbol: track.isPlaying ? "pause.fill" : "play.fill", command: .playPause, points: 7.5, send: send)
        ControlGlyph(symbol: "forward.fill", command: .next, points: 5.5, send: send)
    }
}

/// One control. Sized to its glyph so spacing is measured between what you
/// see; it takes its own tap, ahead of the tile's (play-pause). Skip glyphs
/// are twice as wide as play, so they get a smaller size.
private struct ControlGlyph: View {
    let symbol: String
    let command: NowPlayingWidget.Command
    let points: CGFloat
    let send: (NowPlayingWidget.Command) -> Void
    @Environment(\.dockTileSize) private var tile

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: WidgetTypography.fontSize(points, tile: tile)))
            .foregroundStyle(command == .playPause ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(height: tile * 0.5)
            .contentShape(Rectangle())
            .onTapGesture { send(command) }
            .accessibilityLabel(command.rawValue.capitalized)
            .accessibilityAddTraits(.isButton)
    }
}

/// Album art, or the player's icon until art arrives. Small adds a
/// play/pause mark in the corner, since it has no controls.
private struct Artwork: View {
    let track: NowPlayingWidget.Track
    let side: CGFloat
    let cornerMark: Bool

    var body: some View {
        Group {
            if let artwork = track.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.16, style: .continuous))
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: track.player.bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                Image(systemName: "music.note")
                    .resizable()
                    .scaledToFit()
                    .padding(side * 0.2)
            }
        }
        .frame(width: side, height: side)
        .overlay(alignment: .bottomTrailing) {
            if cornerMark {
                Image(systemName: track.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
                    .frame(width: side * 0.36, height: side * 0.36)
                    .padding(side * 0.04)
            }
        }
    }
}
