//
//  VideoPlayerModel.swift
//  Donguri
//
//  One video being watched: YouTube or a file from the device, its
//  subtitles, where playback is, and the clips mined cards get.
//
//  YouTube plays natively from its HLS stream when YouTube allows it, and
//  otherwise in YouTube's own player (YouTubeWebPlayer). The switch is
//  automatic: a stream that fails, or hasn't started after a few seconds,
//  falls back, and the fallback is remembered for a while so the next
//  video starts there straight away.
//

import SwiftUI
import AVFoundation

/// Something to watch.
enum VideoItem: Identifiable, Hashable {
    case youtube(id: String, title: String?)
    case file(URL)

    var id: String {
        switch self {
        case .youtube(let id, _): "yt:" + id
        case .file(let url): "file:" + url.absoluteString
        }
    }
}

/// The playback position, kept apart from the model so that only the
/// scrubber and time labels redraw ten times a second.
@Observable
final class PlaybackClock {
    var time: Double = 0
    var duration: Double = 0
    var buffered: Double = 0
}

@Observable
final class VideoPlayerModel {
    let item: VideoItem
    let player = AVPlayer()
    let clock = PlaybackClock()
    let popups = PopupStack()

    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var title = ""
    private(set) var channel = ""
    private(set) var channelID: String?
    private(set) var viewCount: String?
    private(set) var details: String?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var info: YTPlayerInfo?
    private(set) var related: [YTVideo] = []

    enum Engine { case native, web }
    private(set) var engine: Engine = .native
    private(set) var web: YouTubeWebPlayer?
    private(set) var isAd = false
    /// Replaying a line to record a card's audio and pictures.
    private(set) var isMakingCard = false
    private(set) var canSkipAd = false

    // Subtitles
    private(set) var tracks: [YTCaptionTrack] = []
    private(set) var selectedTrack: YTCaptionTrack?
    private(set) var subtitleSource: String?
    private(set) var loadingSubtitles = false
    private(set) var subtitleError: String?
    /// The lines as loaded; `cues` is these shifted by `subtitleDelay`.
    private var rawCues: [SubtitleCue] = []
    private(set) var cues: [SubtitleCue] = []
    /// Seconds added to every line (for files whose subtitles are early or late).
    var subtitleDelay: Double = 0 {
        didSet { applyDelay() }
    }
    /// The line on screen right now, if any.
    private(set) var activeCue: SubtitleCue?
    /// The most recent line to have started, for previous/next.
    private(set) var lastCueIndex: Int?
    /// Blurred lines the user has tapped to read.
    var revealedCueIDs: Set<Int> = []

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var mediaTasks: [String: Task<CardMedia, Never>] = [:]
    @ObservationIgnored private var started = false
    /// A file picked from Files stays readable while it plays.
    @ObservationIgnored private var scopedFile: URL?
    /// The native stream has shown it plays (time moved).
    @ObservationIgnored private var nativeStarted = false
    @ObservationIgnored private var nativeStartTime: Double = 0
    @ObservationIgnored private var userPaused = false
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var errorObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSaved = Date.distantPast
    /// Play/pause shows at once; the page's own report catches up after.
    @ObservationIgnored private var commandedPlayingUntil = Date.distantPast

    private static let positionsKey = "iroha.video.positions"
    private static let nativeFailedKey = "iroha.video.nativeFailedAt"

    /// The direct stream failed recently; go straight to YouTube's player.
    private static var nativeRecentlyFailed: Bool {
        guard let date = UserDefaults.standard.object(forKey: nativeFailedKey) as? Date else { return false }
        return Date.now.timeIntervalSince(date) < 6 * 3600
    }

    init(item: VideoItem) {
        self.item = item
        player.automaticallyWaitsToMinimizeStalling = true
    }

    var clipSource: ClipSource? {
        switch item {
        case .file(let url):
            return .file(url)
        case .youtube:
            if engine == .web {
                // YouTube's page playing plain HLS: that stream works for clips.
                guard let source = web?.state.source, source.hasPrefix("http"), source.contains("m3u8"),
                      let url = URL(string: source) else { return nil }
                return .stream(url)
            }
            return info?.hlsURL.map(ClipSource.stream)
        }
    }

    var videoID: String? {
        if case .youtube(let id, _) = item { return id }
        return nil
    }

    // MARK: Loading

    func start() async {
        guard !started else { return }
        started = true
        // Off the main thread: activating the session can block for a while,
        // which froze the player's buttons.
        Task.detached(priority: .userInitiated) {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        observePlayer()
        switch item {
        case .file(let url):
            if url.startAccessingSecurityScopedResource() { scopedFile = url }
            title = url.deletingPathExtension().lastPathComponent
            prepare(AVURLAsset(url: url))
            phase = .ready
            restorePosition()
            player.play()
            // Subtitles beside the video (same name, .srt/.vtt/.ass).
            for ext in ["srt", "vtt", "ass", "ssa"] {
                let sibling = url.deletingPathExtension().appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: sibling.path(percentEncoded: false)) {
                    importSubtitles(from: sibling)
                    break
                }
            }
        case .youtube(let id, let knownTitle):
            title = knownTitle ?? ""
            let info = try? await YouTubeClient.shared.playerInfo(id)
            self.info = info
            if let info {
                if !info.title.isEmpty { title = info.title }
                channel = info.channel
                channelID = info.channelID
                viewCount = info.viewCount
                details = info.description
                tracks = info.captionTracks
                Task { await loadSubtitles(track: YouTubeClient.defaultTrack(in: info.captionTracks)) }
            }
            Task { related = (try? await YouTubeClient.shared.related(id).videos) ?? [] }
            if let hls = info?.hlsURL, info?.playable == true, !Self.nativeRecentlyFailed {
                startNative(hls)
            } else {
                // No usable stream (or it failed lately): YouTube's player
                // can play anything the site can.
                startWeb(at: savedPosition() ?? 0)
            }
        }
    }

    private func startNative(_ hls: URL) {
        engine = .native
        prepare(AVURLAsset(url: hls, options: [AVURLAssetHTTPUserAgentKey: YouTubeClient.userAgent]))
        phase = .ready
        restorePosition()
        nativeStartTime = clock.time
        player.play()
        if let item = player.currentItem {
            itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let failed = item.status == .failed
                let message = item.error?.localizedDescription ?? ""
                Task { @MainActor in
                    guard failed else { return }
                    print("[iroha] native stream failed: \(message)")
                    self?.fallBackToWeb()
                }
            }
            errorObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification,
                                                                   object: item, queue: .main) { notification in
                guard let event = (notification.object as? AVPlayerItem)?.errorLog()?.events.last else { return }
                print("[iroha] native stream error \(event.errorStatusCode) \(event.errorDomain): \(event.errorComment ?? "") \(event.uri ?? "")")
            }
        }
        // A stream that hasn't started moving in this long isn't going to.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(9))
            guard let self, self.engine == .native, !self.nativeStarted, !self.userPaused else { return }
            print("[iroha] native stream didn't start; using YouTube's player")
            self.fallBackToWeb()
        }
    }

    private func fallBackToWeb() {
        guard engine == .native, case .youtube = item else { return }
        UserDefaults.standard.set(Date.now, forKey: Self.nativeFailedKey)
        let position = clock.time
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservation = nil
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
        errorObserver = nil
        startWeb(at: position)
    }

    private func startWeb(at position: Double) {
        guard case .youtube(let id, _) = item else { return }
        engine = .web
        isBuffering = true
        let web = YouTubeWebPlayer(videoID: id, startAt: position)
        web.onState = { [weak self] state in self?.webStateChanged(state) }
        self.web = web
        web.load()
        phase = .ready
        if position > 0 { clock.time = position }
    }

    private func webStateChanged(_ state: YouTubeWebPlayer.State) {
        guard engine == .web else { return }
        // Written only when they change. An @Observable property notifies
        // on every assignment, equal or not, and these reports come five
        // times a second: assigning blindly redrew the whole player (and
        // its transcript) that often, which is what made buttons lag.
        update(\.isAd, state.isAd)
        update(\.canSkipAd, state.canSkipAd)
        if Date.now > commandedPlayingUntil {
            update(\.isPlaying, state.ready && !state.paused)
        }
        update(\.isBuffering, !state.ready || state.waiting)
        guard state.ready, !state.isAd else { return }
        if clock.time != state.time { clock.time = state.time }
        if state.duration > 0, clock.duration != state.duration { clock.duration = state.duration }
        if abs(clock.buffered - state.buffered) > 0.5 { clock.buffered = state.buffered }
        updateCue(at: state.time)
        if Date.now.timeIntervalSince(lastSaved) > 5 {
            lastSaved = .now
            savePosition(state.time)
        }
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<VideoPlayerModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func prepare(_ asset: AVURLAsset) {
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 8
        player.replaceCurrentItem(with: playerItem)
        player.defaultRate = Float(VideoSettings.shared.playbackRate)
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        observations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let status = player.timeControlStatus
                Task { @MainActor in
                    self?.update(\.isPlaying, status != .paused)
                    self?.update(\.isBuffering, status == .waitingToPlayAtSpecifiedRate)
                }
            },
        ]
    }

    private func tick(_ time: Double) {
        guard time.isFinite, engine == .native else { return }
        if !nativeStarted, time > nativeStartTime + 0.3 { nativeStarted = true }
        clock.time = time
        if let item = player.currentItem {
            let duration = item.duration.seconds
            if duration.isFinite, duration > 0, clock.duration != duration { clock.duration = duration }
            if let range = item.loadedTimeRanges.last?.timeRangeValue {
                clock.buffered = (range.start + range.duration).seconds
            }
        } else if let info, clock.duration == 0 {
            clock.duration = info.duration
        }
        updateCue(at: time)
        if Date.now.timeIntervalSince(lastSaved) > 5 {
            lastSaved = .now
            savePosition(time)
        }
    }

    private func updateCue(at time: Double) {
        guard !cues.isEmpty else {
            if activeCue != nil { activeCue = nil }
            return
        }
        // The last line starting at or before `time`.
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time + 0.02 { low = mid + 1 } else { high = mid }
        }
        let index = low - 1
        let last: Int? = index >= 0 ? index : nil
        if last != lastCueIndex { lastCueIndex = last }
        let active = last.flatMap { cues[$0].end > time ? cues[$0] : nil }
        if active?.id != activeCue?.id {
            activeCue = active
        }
    }

    // MARK: Controls

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            if clock.duration > 0, clock.time >= clock.duration - 0.5 { seek(to: 0) }
            resume()
        }
        Haptics.play(.selection)
    }

    func pause() {
        userPaused = true
        switch engine {
        case .native: player.pause()
        case .web:
            isPlaying = false
            commandedPlayingUntil = .now.addingTimeInterval(0.8)
            web?.pause()
        }
    }

    func resume() {
        userPaused = false
        let rate = VideoSettings.shared.playbackRate
        switch engine {
        case .native: player.playImmediately(atRate: Float(rate))
        case .web:
            isPlaying = true
            commandedPlayingUntil = .now.addingTimeInterval(0.8)
            web?.play(rate: rate)
        }
    }

    func skipAd() {
        web?.skipAd()
    }

    func seek(to time: Double, play: Bool? = nil) {
        let target = max(0, clock.duration > 0 ? min(time, clock.duration - 0.1) : time)
        clock.time = target
        updateCue(at: target)
        switch engine {
        case .native:
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                        toleranceBefore: CMTime(seconds: 0.03, preferredTimescale: 600),
                        toleranceAfter: CMTime(seconds: 0.03, preferredTimescale: 600))
        case .web:
            web?.seek(to: target)
        }
        if play == true { resume() }
        if play == false { pause() }
    }

    func skip(by seconds: Double) {
        seek(to: clock.time + seconds)
    }

    func setRate(_ rate: Double) {
        VideoSettings.shared.playbackRate = rate
        switch engine {
        case .native:
            player.defaultRate = Float(rate)
            if isPlaying { player.rate = Float(rate) }
        case .web:
            web?.setRate(rate)
        }
    }

    /// Back to the start of the line on screen, or the one before it if
    /// the line has only just started (asbplayer's A key).
    func previousCue() {
        guard !cues.isEmpty else { skip(by: -10); return }
        guard let last = lastCueIndex else { seek(to: cues[0].start); return }
        let target = clock.time - cues[last].start < 1 && last > 0 ? last - 1 : last
        seek(to: cues[target].start)
        Haptics.play(.selection)
    }

    /// The start of the next line (asbplayer's D key).
    func nextCue() {
        guard !cues.isEmpty else { skip(by: 10); return }
        let next = lastCueIndex.map { $0 + 1 } ?? 0
        guard next < cues.count else { return }
        seek(to: cues[next].start)
        Haptics.play(.selection)
    }

    /// Plays the current (or last) line again from its start.
    func replayCue() {
        guard let index = lastCueIndex ?? (cues.isEmpty ? nil : 0) else { return }
        seek(to: cues[index].start, play: true)
        Haptics.play(.selection)
    }

    func play(_ cue: SubtitleCue) {
        seek(to: cue.start, play: true)
    }

    // MARK: Subtitles

    func loadSubtitles(track: YTCaptionTrack?) async {
        guard let info else { return }
        loadingSubtitles = true
        subtitleError = nil
        selectedTrack = track
        defer { loadingSubtitles = false }
        if let loaded = await YouTubeClient.shared.subtitles(for: info, track: track), !loaded.isEmpty {
            setCues(loaded, source: track?.name ?? String(localized: "字幕"))
        } else if track != nil || info.transcriptParams != nil {
            subtitleError = String(localized: "字幕を読み込めませんでした")
        }
    }

    func importSubtitles(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let parsed = SubtitleParser.parse(data), !parsed.isEmpty else {
            subtitleError = String(localized: "字幕ファイルを読み込めませんでした")
            return
        }
        subtitleError = nil
        selectedTrack = nil
        setCues(parsed, source: url.lastPathComponent)
    }

    private func setCues(_ new: [SubtitleCue], source: String) {
        rawCues = new
        subtitleSource = source
        subtitleDelay = 0
        applyDelay()
        mediaTasks.removeAll()
    }

    private func applyDelay() {
        cues = rawCues.map { cue in
            SubtitleCue(id: cue.id, start: cue.start + subtitleDelay, end: cue.end + subtitleDelay, text: cue.text)
        }
        updateCue(at: clock.time)
    }

    // MARK: Lookups and mining

    /// A word tapped in `cue`: pause if wanted, and start making the
    /// card's clip so it's ready by the time the + is pressed.
    func prepareLookup(in cue: SubtitleCue) {
        if VideoSettings.shared.pauseOnLookup { pause() }
        let stillTime = (cue.start...max(cue.start, cue.end)).contains(clock.time) ? clock.time : (cue.start + cue.end) / 2
        popups.documentTitle = title.isEmpty ? nil : title
        popups.coverURL = nil
        // In YouTube's player a GIF means playing the line again, which
        // would jump the video about; that waits for the + instead.
        // In YouTube's player the card's audio and pictures come from
        // playing the line again, so that waits for the + instead of
        // jumping the video about on every lookup.
        if engine != .web {
            _ = mediaTask(for: cue, still: stillTime)
        }
        popups.mediaProvider = { [weak self] in
            guard let self else { return nil }
            var media = await self.mediaTask(for: cue, still: stillTime).value
            // Audio made at lookup time can miss (not buffered yet); try
            // once more now that + has been pressed.
            if VideoSettings.shared.cardAudio, media.audioURL == nil, self.engine != .web {
                self.forgetMedia(for: cue)
                let again = await self.mediaTask(for: cue, still: stillTime).value
                media.audioURL = again.audioURL
                media.imageURL = media.imageURL ?? again.imageURL
            }
            return media
        }
    }

    private func forgetMedia(for cue: SubtitleCue) {
        for key in mediaTasks.keys where key.hasPrefix("\(cue.id)|") {
            mediaTasks[key] = nil
        }
    }

    private func mediaTask(for cue: SubtitleCue, still: Double) -> Task<CardMedia, Never> {
        let settings = VideoSettings.shared
        let key = "\(cue.id)|\(cue.start)|\(settings.cardImage.rawValue)|\(settings.cardAudio)|\(settings.paddingBefore)|\(settings.paddingAfter)"
        if let task = mediaTasks[key] { return task }
        let start = max(0, cue.start - Double(settings.paddingBefore) / 1000)
        let end = max(start + 0.2, cue.end + Double(settings.paddingAfter) / 1000)
        let imageKind = settings.cardImage
        let wantsAudio = settings.cardAudio
        if engine == .web, let web {
            let stream = clipSource
            let hls = info?.hlsURL
            let task = Task<CardMedia, Never> {
                self.isMakingCard = true
                defer { self.isMakingCard = false }
                return await Self.webMedia(web: web, stream: stream, hls: hls, start: start, end: end, still: still,
                                           imageKind: imageKind, wantsAudio: wantsAudio)
            }
            mediaTasks[key] = task
            return task
        }
        guard let source = clipSource else { return Task { CardMedia() } }
        let task = Task<CardMedia, Never> {
            async let audio: URL? = wantsAudio ? await ClipCapture.audio(from: source, start: start, end: end) : nil
            async let image: URL? = await ClipCapture.image(from: source, kind: imageKind,
                                                            start: start, end: end, stillAt: still)
            return CardMedia(imageURL: await image, audioURL: await audio)
        }
        mediaTasks[key] = task
        return task
    }

    /// Card media from YouTube's player: the audio out of what it has
    /// buffered (or its stream, if it plays plain HLS), the picture from
    /// its video element.
    private static func webMedia(web: YouTubeWebPlayer, stream: ClipSource?, hls: URL?, start: Double, end: Double,
                                 still: Double, imageKind: ClipImageKind, wantsAudio: Bool) async -> CardMedia {
        var media = CardMedia()
        // YouTube's page playing a plain HLS stream: cut from that, no replay.
        if let stream {
            if wantsAudio { media.audioURL = await ClipCapture.audio(from: stream, start: start, end: end) }
            media.imageURL = await ClipCapture.image(from: stream, kind: imageKind, start: start, end: end, stillAt: still)
            if (!wantsAudio || media.audioURL != nil), (imageKind == .none || media.imageURL != nil) { return media }
        }

        // One pass over the line, as asbplayer does it: audio and pictures
        // recorded together, so they cover exactly the same stretch.
        let length = end - start
        let fps: Double = length > 5 ? 6 : 8
        let stillTime = imageKind == .screenshot ? min(max(still, start), end - 0.05) : nil
        let recording = await web.record(from: start, to: end, fps: fps, maxWidth: 400,
                                         audio: wantsAudio && media.audioURL == nil,
                                         frames: imageKind == .gif && media.imageURL == nil,
                                         stillAt: media.imageURL == nil ? stillTime : nil)

        if wantsAudio, media.audioURL == nil, let audio = recording.audio {
            let raw = ClipCapture.newFile(recording.audioExtension)
            if (try? audio.write(to: raw)) != nil {
                // Re-encoded to a plain .m4a, which every Anki plays.
                if let clean = await ClipCapture.exportAudio(asset: AVURLAsset(url: raw), range: nil) {
                    try? FileManager.default.removeItem(at: raw)
                    media.audioURL = clean
                } else {
                    media.audioURL = raw
                }
            }
        }
        if media.imageURL == nil {
            switch imageKind {
            case .none:
                break
            case .screenshot:
                if let data = recording.still, let image = UIImage(data: data)?.cgImage {
                    media.imageURL = ClipCapture.writeJPEG(image)
                }
            case .gif:
                var frames = recording.frames.compactMap { UIImage(data: $0)?.cgImage }
                // A long line keeps an even spread of at most 64 frames.
                if frames.count > 64 {
                    let step = Double(frames.count) / 64
                    frames = (0..<64).map { frames[Int(Double($0) * step)] }
                }
                if frames.count > 1 {
                    media.imageURL = ClipCapture.writeGIF(frames, delay: length / Double(frames.count))
                }
            }
        }

        // Fallbacks, if the recording missed something.
        if wantsAudio, media.audioURL == nil {
            if let buffered = await web.bufferedAudio(from: start, to: end) {
                media.audioURL = await ClipCapture.cutFragmentedMP4(buffered.data, firstTime: buffered.firstTime,
                                                                    start: start, end: end)
            }
            if media.audioURL == nil, let hls {
                media.audioURL = await ClipCapture.audio(from: .stream(hls), start: start, end: end)
            }
            if media.audioURL == nil { print("[iroha] no audio for the card (web player)") }
        }
        if imageKind != .none, media.imageURL == nil,
           let data = await web.frame(at: still, maxWidth: 960), let image = UIImage(data: data)?.cgImage {
            media.imageURL = ClipCapture.writeJPEG(image)
        }
        return media
    }

    // MARK: Resume

    private func savePosition(_ time: Double) {
        guard clock.duration > 60 else { return }
        var positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Double] ?? [:]
        // Finished videos start again from the top.
        positions[item.id] = time > clock.duration - 20 ? nil : time
        if positions.count > 300 { positions = Dictionary(uniqueKeysWithValues: positions.prefix(200).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(positions, forKey: Self.positionsKey)
    }

    private func savedPosition() -> Double? {
        let positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Double] ?? [:]
        guard let saved = positions[item.id], saved > 5 else { return nil }
        return saved
    }

    private func restorePosition() {
        if let saved = savedPosition() {
            player.seek(to: CMTime(seconds: saved, preferredTimescale: 600))
            clock.time = saved
        }
    }

    func stop() {
        savePosition(clock.time)
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.removeAll()
        player.replaceCurrentItem(with: nil)
        itemObservation = nil
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
        errorObserver = nil
        web?.teardown()
        web = nil
        popups.closeAll()
        scopedFile?.stopAccessingSecurityScopedResource()
        scopedFile = nil
    }
}
