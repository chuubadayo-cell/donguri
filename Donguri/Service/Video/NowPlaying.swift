//
//  NowPlaying.swift
//  Donguri
//
//  The lock screen and Control Center for the video playing: title,
//  channel, thumbnail and position, and their buttons. ⏮ and ⏭ step
//  through subtitle lines, which is what mining wants. YouTube's own
//  player in a web view publishes its own play and pause through WebKit,
//  so for it only the line buttons are added.
//

import Foundation
import MediaPlayer
import UIKit

enum NowPlaying {
    nonisolated struct Actions: Sendable {
        var play: @Sendable () -> Void
        var pause: @Sendable () -> Void
        var toggle: @Sendable () -> Void
        var nextLine: @Sendable () -> Void
        var previousLine: @Sendable () -> Void
        var seek: @Sendable (Double) -> Void
    }

    private static var targets: [(MPRemoteCommand, Any)] = []
    private static var artworkURL: URL?
    private static var artwork: MPMediaItemArtwork?

    /// Takes over the lock screen's buttons. `transport` is false when
    /// WebKit already handles play, pause and seeking.
    static func activate(_ actions: Actions, transport: Bool) {
        deactivate()
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ handler: @escaping @Sendable (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            targets.append((command, command.addTarget(handler: makeHandler(handler))))
        }
        if transport {
            add(center.playCommand) { _ in actions.play() }
            add(center.pauseCommand) { _ in actions.pause() }
            add(center.togglePlayPauseCommand) { _ in actions.toggle() }
            add(center.changePlaybackPositionCommand) { event in
                if let event = event as? MPChangePlaybackPositionCommandEvent { actions.seek(event.positionTime) }
            }
        }
        add(center.nextTrackCommand) { _ in actions.nextLine() }
        add(center.previousTrackCommand) { _ in actions.previousLine() }
    }

    static func deactivate() {
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        artworkURL = nil
        artwork = nil
    }

    /// The details shown. iOS moves the position along by itself from the
    /// rate, so this is only needed when something changes.
    static func update(title: String, channel: String, duration: Double, elapsed: Double, rate: Double, thumbnail: URL?) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: channel,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork, artworkURL == thumbnail { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let thumbnail, thumbnail != artworkURL {
            artworkURL = thumbnail
            Task {
                guard let image = await MediaStore.shared.image(for: thumbnail, maxPixelSize: 600),
                      artworkURL == thumbnail else { return }
                artwork = makeArtwork(image)
                var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                current[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            }
        }
    }

    /// Built outside the main actor: MediaPlayer calls these from its own
    /// threads, and a main-actor closure called there would trap.
    private nonisolated static func makeHandler(_ action: @escaping @Sendable (MPRemoteCommandEvent) -> Void)
        -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            action(event)
            return .success
        }
    }

    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
