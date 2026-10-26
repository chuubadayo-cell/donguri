//
//  VideoSettings.swift
//  Donguri
//
//  How the video player shows subtitles and what it puts on mined cards.
//  The blur and placement follow asbplayer.
//

import SwiftUI

@Observable
final class VideoSettings {
    static let shared = VideoSettings()

    private static let prefix = "iroha.video."

    enum SubtitlePosition: String, CaseIterable, Identifiable {
        case bottom, top
        var id: String { rawValue }
    }

    var subtitlePosition: SubtitlePosition { didSet { save(subtitlePosition.rawValue, "subtitlePosition") } }
    /// Subtitles start blurred and come clear when tapped (or paused).
    var blurSubtitles: Bool { didSet { save(blurSubtitles, "blurSubtitles") } }
    /// Pausing shows the blurred line clearly.
    var unblurWhenPaused: Bool { didSet { save(unblurWhenPaused, "unblurWhenPaused") } }
    var showSubtitles: Bool { didSet { save(showSubtitles, "showSubtitles") } }
    var subtitleSize: Double { didSet { save(subtitleSize, "subtitleSize") } }
    /// Tapping a word in the subtitles pauses the video.
    var pauseOnLookup: Bool { didSet { save(pauseOnLookup, "pauseOnLookup") } }
    /// Double-tapping the sides of the video jumps by subtitle line
    /// instead of by 10 seconds.
    var doubleTapSeeksLines: Bool { didSet { save(doubleTapSeeksLines, "doubleTapSeeksLines") } }
    /// Pause at the end of every subtitle line (asbplayer's auto-pause).
    var autoPause: Bool { didSet { save(autoPause, "autoPause") } }
    /// Keep playing (the sound) when the app leaves the screen or the
    /// phone locks.
    var backgroundPlayback: Bool { didSet { save(backgroundPlayback, "backgroundPlayback") } }

    var cardImage: ClipImageKind { didSet { save(cardImage.rawValue, "cardImage") } }
    var cardAudio: Bool { didSet { save(cardAudio, "cardAudio") } }
    /// Added before and after the line, in milliseconds.
    var paddingBefore: Int { didSet { save(paddingBefore, "paddingBefore") } }
    var paddingAfter: Int { didSet { save(paddingAfter, "paddingAfter") } }

    var playbackRate: Double { didSet { save(playbackRate, "playbackRate") } }

    static let rates: [Double] = [0.5, 0.75, 0.9, 1, 1.25, 1.5, 2]

    private init() {
        let d = UserDefaults.standard
        let p = Self.prefix
        subtitlePosition = d.string(forKey: p + "subtitlePosition").flatMap(SubtitlePosition.init(rawValue:)) ?? .bottom
        blurSubtitles = d.object(forKey: p + "blurSubtitles") as? Bool ?? false
        unblurWhenPaused = d.object(forKey: p + "unblurWhenPaused") as? Bool ?? true
        showSubtitles = d.object(forKey: p + "showSubtitles") as? Bool ?? true
        subtitleSize = d.object(forKey: p + "subtitleSize") as? Double ?? 20
        pauseOnLookup = d.object(forKey: p + "pauseOnLookup") as? Bool ?? true
        doubleTapSeeksLines = d.object(forKey: p + "doubleTapSeeksLines") as? Bool ?? true
        autoPause = d.object(forKey: p + "autoPause") as? Bool ?? false
        backgroundPlayback = d.object(forKey: p + "backgroundPlayback") as? Bool ?? true
        cardImage = d.string(forKey: p + "cardImage").flatMap(ClipImageKind.init(rawValue:)) ?? .screenshot
        cardAudio = d.object(forKey: p + "cardAudio") as? Bool ?? true
        paddingBefore = d.object(forKey: p + "paddingBefore") as? Int ?? 0
        paddingAfter = d.object(forKey: p + "paddingAfter") as? Int ?? 250
        playbackRate = d.object(forKey: p + "playbackRate") as? Double ?? 1
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: Self.prefix + key)
    }
}
