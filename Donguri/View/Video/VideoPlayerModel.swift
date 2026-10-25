//
//  VideoPlayerModel.swift
//  Donguri
//
//  One video being watched: YouTube (played natively from its HLS stream)
//  or a file from the device, its subtitles, where playback is, and the
//  clips mined cards get.
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
    /// A blurred line the user has revealed.
    var revealedCueID: Int?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var mediaTasks: [String: Task<CardMedia, Never>] = [:]
    @ObservationIgnored private var started = false
    /// A file picked from Files stays readable while it plays.
    @ObservationIgnored private var scopedFile: URL?

    private static let positionsKey = "iroha.video.positions"

    init(item: VideoItem) {
        self.item = item
        player.automaticallyWaitsToMinimizeStalling = true
    }

    var clipSource: ClipSource? {
        switch item {
        case .file(let url): return .file(url)
        case .youtube: return info?.hlsURL.map(ClipSource.stream)
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
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
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
            do {
                let info = try await YouTubeClient.shared.playerInfo(id)
                self.info = info
                if !info.title.isEmpty { title = info.title }
                channel = info.channel
                channelID = info.channelID
                viewCount = info.viewCount
                details = info.description
                tracks = info.captionTracks
                guard let hls = info.hlsURL else {
                    phase = .failed(info.reason ?? String(localized: "この動画はアプリ内で再生できません"))
                    return
                }
                prepare(AVURLAsset(url: hls, options: [AVURLAssetHTTPUserAgentKey: YouTubeClient.userAgent]))
                phase = .ready
                restorePosition()
                player.play()
                Task { await loadSubtitles(track: YouTubeClient.defaultTrack(in: info.captionTracks)) }
                Task { related = (try? await YouTubeClient.shared.related(id).videos) ?? [] }
            } catch {
                phase = .failed(String(localized: "動画を読み込めませんでした"))
            }
        }
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
                    self?.isPlaying = status != .paused
                    self?.isBuffering = status == .waitingToPlayAtSpecifiedRate
                }
            },
        ]
    }

    private func tick(_ time: Double) {
        guard time.isFinite else { return }
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
        if Int(time) % 5 == 0 { savePosition(time) }
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
            if revealedCueID != nil, revealedCueID != active?.id { revealedCueID = nil }
        }
    }

    // MARK: Controls

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if clock.duration > 0, clock.time >= clock.duration - 0.5 { seek(to: 0) }
            player.playImmediately(atRate: Float(VideoSettings.shared.playbackRate))
        }
        Haptics.play(.selection)
    }

    func pause() {
        player.pause()
    }

    func seek(to time: Double, play: Bool? = nil) {
        let target = max(0, clock.duration > 0 ? min(time, clock.duration - 0.1) : time)
        clock.time = target
        updateCue(at: target)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.03, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.03, preferredTimescale: 600))
        if play == true { player.playImmediately(atRate: Float(VideoSettings.shared.playbackRate)) }
        if play == false { player.pause() }
    }

    func skip(by seconds: Double) {
        seek(to: clock.time + seconds)
    }

    func setRate(_ rate: Double) {
        VideoSettings.shared.playbackRate = rate
        player.defaultRate = Float(rate)
        if isPlaying { player.rate = Float(rate) }
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
        if VideoSettings.shared.pauseOnLookup { player.pause() }
        let stillTime = (cue.start...max(cue.start, cue.end)).contains(clock.time) ? clock.time : (cue.start + cue.end) / 2
        popups.documentTitle = title.isEmpty ? nil : title
        popups.coverURL = nil
        _ = mediaTask(for: cue, still: stillTime)
        popups.mediaProvider = { [weak self] in
            guard let self else { return nil }
            return await self.mediaTask(for: cue, still: stillTime).value
        }
    }

    private func mediaTask(for cue: SubtitleCue, still: Double) -> Task<CardMedia, Never> {
        let settings = VideoSettings.shared
        let key = "\(cue.id)|\(cue.start)|\(settings.cardImage.rawValue)|\(settings.cardAudio)|\(settings.paddingBefore)|\(settings.paddingAfter)"
        if let task = mediaTasks[key] { return task }
        guard let source = clipSource else { return Task { CardMedia() } }
        let start = max(0, cue.start - Double(settings.paddingBefore) / 1000)
        let end = max(start + 0.2, cue.end + Double(settings.paddingAfter) / 1000)
        let imageKind = settings.cardImage
        let wantsAudio = settings.cardAudio
        let task = Task<CardMedia, Never> {
            async let audio: URL? = wantsAudio ? await ClipCapture.audio(from: source, start: start, end: end) : nil
            async let image: URL? = await ClipCapture.image(from: source, kind: imageKind,
                                                            start: start, end: end, stillAt: still)
            return CardMedia(imageURL: await image, audioURL: await audio)
        }
        mediaTasks[key] = task
        return task
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

    private func restorePosition() {
        let positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Double] ?? [:]
        if let saved = positions[item.id], saved > 5 {
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
        popups.closeAll()
        scopedFile?.stopAccessingSecurityScopedResource()
        scopedFile = nil
    }
}
