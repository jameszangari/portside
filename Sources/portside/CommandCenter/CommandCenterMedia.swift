import AVFoundation
import AVKit
import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Checks a file path against the chosen folders right now, so a row's
/// thumbnail or preview never reads a path the index no longer vouches for.
private struct FileAuthorizerKey: EnvironmentKey {
    static let defaultValue: @MainActor (String) -> URL? = { _ in nil }
}

extension EnvironmentValues {
    var fileAuthorizer: @MainActor (String) -> URL? {
        get { self[FileAuthorizerKey.self] }
        set { self[FileAuthorizerKey.self] = newValue }
    }
}

// MARK: - Row thumbnails

/// Thumbnails for file rows (images, PDFs, movies and anything else Quick
/// Look can draw), made by the public `QLThumbnailGenerator`. The file icon
/// stands in until one arrives and when there is none.
@MainActor
enum FileThumbnails {
    static let side: CGFloat = 24
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    static func cached(_ path: String) -> NSImage? { cache.object(forKey: path as NSString) }

    /// The thumbnail, or nil when Quick Look has none. Cached per path.
    static func load(_ url: URL, scale: CGFloat) async -> NSImage? {
        if let image = cached(url.path) { return image }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side * 2, height: side * 2), scale: scale, representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
              !Task.isCancelled else { return nil }
        let image = representation.nsImage
        cache.setObject(image, forKey: url.path as NSString)
        return image
    }
}

struct FileThumbnailIcon: View {
    let path: String
    @Environment(\.fileAuthorizer) private var authorize
    @Environment(\.displayScale) private var scale
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? CommandCenterIconCache.icon(for: path))
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: FileThumbnails.side, height: FileThumbnails.side)
            .clipShape(RoundedRectangle(cornerRadius: image == nil ? 0 : 4, style: .continuous))
            .frame(width: 24)
            .accessibilityHidden(true)
            .task(id: path) {
                image = FileThumbnails.cached(path)
                guard image == nil, let url = authorize(path) else { return }
                image = await FileThumbnails.load(url, scale: scale)
            }
    }
}

// MARK: - Playable media

enum MediaKind {
    case audio, video, other

    static func of(_ url: URL) -> MediaKind {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return .other
    }
}

/// One player for the preview screen. Playback starts with the screen and
/// stops when it goes away; the time observer exists only while it does.
@MainActor
final class MediaPlayerModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var failed = false
    let player: AVPlayer
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var scrubbing = false

    init(url: URL) {
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.seek(to: 0)
            }
        }
        Task { [weak self] in
            guard let item = self?.player.currentItem else { return }
            let seconds = (try? await item.asset.load(.duration).seconds) ?? 0
            guard let self else { return }
            if seconds.isFinite, seconds > 0 { duration = seconds } else { failed = true }
        }
    }

    func start() {
        player.play()
        isPlaying = true
    }

    func stop() {
        player.pause()
        isPlaying = false
    }

    func toggle() { isPlaying ? stop() : start() }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: fraction * duration, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        progress = fraction
    }

    func setScrubbing(_ active: Bool) { scrubbing = active }

    private func tick(_ time: CMTime) {
        guard !scrubbing, duration > 0 else { return }
        progress = min(max(time.seconds / duration, 0), 1)
    }

    func close() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Audio: the file's icon as cover art, a play button, a scrubber and the
/// time, in the panel's own style.
struct AudioPreview: View {
    let url: URL
    @StateObject private var model: MediaPlayerModel

    init(url: URL) {
        self.url = url
        _model = StateObject(wrappedValue: MediaPlayerModel(url: url))
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(nsImage: CommandCenterIconCache.icon(for: url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .accessibilityHidden(true)
            if model.failed {
                Text("This file could not be played.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Button { model.toggle() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15))
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.primary.opacity(0.14)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                    Text(MediaPlayerModel.clock(model.progress * model.duration))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                    Slider(
                        value: Binding(get: { model.progress }, set: { model.seek(to: $0) }),
                        in: 0...1,
                        onEditingChanged: { model.setScrubbing($0) }
                    )
                    .controlSize(.small)
                    .accessibilityLabel("Position")
                    Text(MediaPlayerModel.clock(model.duration))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .leading)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 28)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.start() }
        .onDisappear { model.close() }
    }
}

/// Video: the system player with its inline controls.
struct VideoPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.player = AVPlayer(url: url)
        view.player?.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
