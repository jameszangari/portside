import AppKit
import os.log

/// System-wide Now Playing through MediaRemote, for players Portside
/// cannot script (anything but Spotify and Music: other Spotify clients,
/// browsers, Podcasts).
///
/// Private API, and fenced off: since macOS 15.4 MediaRemote answers only
/// Apple processes, so the vendored MediaRemoteAdapter dylib (see
/// Sources/MediaRemoteAdapter/README.md) runs inside `/usr/bin/perl` and
/// streams JSON lines back over a pipe. Portside never loads it. A missing
/// dylib or a failed launch leaves Now Playing on Spotify and Music only.
final class MediaRemoteNowPlaying {
    struct Snapshot: Equatable {
        /// The app playing; for web media, the browser rather than its helper.
        let bundleID: String
        let id: String
        let title: String
        let artist: String?
        let artwork: NSImage?
        let isPlaying: Bool
        var duration: TimeInterval? = nil
        var elapsed: TimeInterval? = nil
        /// When `elapsed` held (the adapter's `timestamp`).
        var elapsedAt = Date()
    }

    /// MRACommand values from MediaRemoteAdapter.h.
    enum Command: Int {
        case togglePlayPause = 2, next = 4, previous = 5
    }

    private static let logger = Logger(subsystem: "com.james.portside", category: "Widgets")
    private static let libraryName = "libMediaRemoteAdapter.dylib"

    /// Contents/Frameworks in the app; next to the executable under `swift run`.
    static let library: URL? = {
        let candidates = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent(libraryName),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(libraryName),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }()

    /// Loads the dylib and calls one adapter function, which reads its
    /// options from the environment. With "watch", a forked child blocks on
    /// stdin and ends the stream once Portside's end of the pipe closes, so
    /// a crash leaves no stream running.
    private static let launcher = """
    use DynaLoader;
    if ($ARGV[2] eq "watch" && fork() == 0) {
        close STDOUT; close STDERR;
        1 while <STDIN>;
        my $parent = getppid();
        kill 'TERM', $parent if $parent > 1;
        exit 0;
    }
    my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die "load failed\\n";
    my $s = DynaLoader::dl_find_symbol($h, $ARGV[1]) or die "symbol missing\\n";
    DynaLoader::dl_install_xsub("main::run", $s);
    &main::run();
    """

    private var process: Process?
    private var input: Pipe?
    private var onChange: ((Snapshot?) -> Void)?
    private var launches = 0
    private var launchedAt = Date.distantPast

    /// Touched only on the stdout reader's queue.
    private var buffer = Data()
    private var state: [String: Any] = [:]
    private var artwork: NSImage?

    var available: Bool { Self.library != nil }

    /// `onChange` runs on the main queue, nil when nothing plays.
    func start(_ onChange: @escaping (Snapshot?) -> Void) {
        guard process == nil, let library = Self.library else { return }
        self.onChange = onChange
        launch(library)
    }

    func stop() {
        onChange = nil
        let process = process
        self.process = nil
        try? input?.fileHandleForWriting.close()
        input = nil
        if process?.isRunning == true { process?.terminate() }
    }

    /// False when the adapter is missing or would not start.
    @discardableResult
    func send(_ command: Command) -> Bool {
        guard let library = Self.library else { return false }
        let task = Self.task(library, function: "adapter_send_env", watch: false,
                             environment: ["MEDIAREMOTEADAPTER_PARAM_adapter_send_0_command": "\(command.rawValue)"])
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        do {
            try task.run()
            return true
        } catch {
            Self.logger.error("now playing: media remote send failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Jumps to `seconds` into the current item.
    func seek(to seconds: TimeInterval) {
        guard let library = Self.library else { return }
        let task = Self.task(library, function: "adapter_seek_env", watch: false,
                             environment: ["MEDIAREMOTEADAPTER_PARAM_adapter_seek_0_position": "\(Int64(seconds * 1_000_000))"])
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        try? task.run()
    }

    private static func task(_ library: URL, function: String, watch: Bool, environment: [String: String]) -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = ["-e", launcher, library.path, function, watch ? "watch" : "once"]
        task.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        task.standardError = FileHandle.nullDevice
        return task
    }

    private func launch(_ library: URL) {
        // 125 ms debounce, as Bartender uses: a track change arrives as a burst.
        let task = Self.task(library, function: "adapter_stream_env", watch: true,
                             environment: ["MEDIAREMOTEADAPTER_OPTION_debounce": "125"])
        let input = Pipe()
        let output = Pipe()
        task.standardInput = input
        task.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.buffer = Data()
            } else {
                self?.read(data)
            }
        }
        task.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.ended(ended, library: library) }
        }
        do {
            try task.run()
        } catch {
            Self.logger.error("now playing: media remote stream failed to start: \(error.localizedDescription, privacy: .public)")
            return
        }
        process = task
        self.input = input
        launches += 1
        launchedAt = Date()
    }

    /// Restarts a stream that died, a few times; one that ran a while
    /// earns its retries back.
    private func ended(_ task: Process, library: URL) {
        guard task === process else { return }
        process = nil
        input = nil
        onChange?(nil)
        if Date().timeIntervalSince(launchedAt) > 60 { launches = 0 }
        guard launches < 3 else {
            Self.logger.error("now playing: media remote stream keeps exiting (\(task.terminationStatus)); giving up")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.process == nil, self.onChange != nil else { return }
            self.launch(library)
        }
    }

    private func read(_ data: Data) {
        buffer.append(data)
        var changed = false
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let artworkChanged = Self.merge(line, into: &state) else { continue }
            changed = true
            if artworkChanged {
                artwork = (state["artworkData"] as? String)
                    .flatMap { Data(base64Encoded: $0) }
                    .flatMap(NSImage.init(data:))
            }
        }
        guard changed else { return }
        let snapshot = Self.snapshot(state, artwork: artwork)
        DispatchQueue.main.async { [weak self] in self?.onChange?(snapshot) }
    }

    /// One `{"type":"data","diff":Bool,"payload":{...}}` line. A full
    /// payload replaces the state; a diff merges, null removing a key.
    /// Nil for a line that is not data; otherwise whether the art may
    /// have changed.
    static func merge(_ line: Data, into state: inout [String: Any]) -> Bool? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "data",
              let payload = object["payload"] as? [String: Any] else { return nil }
        guard object["diff"] as? Bool == true else {
            state = payload
            return true
        }
        for (key, value) in payload {
            state[key] = value is NSNull ? nil : value
        }
        return payload["artworkData"] != nil
    }

    static func snapshot(_ state: [String: Any], artwork: NSImage?) -> Snapshot? {
        guard let title = state["title"] as? String, !title.isEmpty,
              let bundleID = (state["parentApplicationBundleIdentifier"] ?? state["bundleIdentifier"]) as? String
        else { return nil }
        let artist = (state["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let id = (state["contentItemIdentifier"] ?? state["uniqueIdentifier"]).map { "\($0)" }
            ?? [title, artist ?? ""].joined(separator: "\u{1F}")
        let seconds = { (key: String) -> TimeInterval? in
            guard let value = (state[key] as? NSNumber)?.doubleValue, value.isFinite, value >= 0 else { return nil }
            return value
        }
        let stamp = (state["timestamp"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        return Snapshot(bundleID: bundleID, id: id, title: title, artist: artist,
                        artwork: artwork, isPlaying: state["playing"] as? Bool ?? false,
                        duration: seconds("duration").flatMap { $0 > 0 ? $0 : nil }, elapsed: seconds("elapsedTime"),
                        elapsedAt: stamp ?? Date())
    }
}
