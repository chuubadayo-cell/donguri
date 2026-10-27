//
//  PictureInPicture.swift
//  Donguri
//
//  iOS's own floating player when the app is left while a video plays
//  full screen (sideways): the native player through AVKit's automatic
//  start, YouTube's page by asking its <video> element. Not while a card
//  is handed to AnkiMobile, which leaves the app too but comes straight
//  back.
//

import AVKit
import UIKit
import WebKit

@MainActor
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = PictureInPicture()

    private static let enabledKey = "iroha.video.autoPiP"

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey); apply() }
    }

    /// The player is full screen and playing.
    private var wanted = false
    private var suppressedUntil = Date.distantPast
    private weak var native: AVPictureInPictureController?
    private weak var webView: WKWebView?
    private(set) var isActive = false
    private var webActive = false
    private var observers: [NSObjectProtocol] = []

    private override init() {
        super.init()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PictureInPicture.shared.resigning() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PictureInPicture.shared.returned() }
            },
        ]
    }

    /// The native player's layer, for AVKit's automatic start.
    func attach(_ layer: AVPlayerLayer) -> AVPictureInPictureController? {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: layer) else { return nil }
        controller.delegate = self
        native = controller
        apply()
        return controller
    }

    /// The controller of the layer now drawing the video.
    func use(_ controller: AVPictureInPictureController?) {
        native = controller
        apply()
    }

    /// YouTube's page, whose video element can float too.
    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    /// Whether leaving the app now should float the video.
    func setWanted(_ value: Bool) {
        guard wanted != value else { return }
        wanted = value
        apply()
    }

    /// A card is going to AnkiMobile and coming back: no floating player.
    func suppressForHandoff() {
        suppressedUntil = Date.now.addingTimeInterval(20)
        apply()
    }

    private var allowed: Bool { enabled && wanted && Date.now >= suppressedUntil }

    private func apply() {
        native?.canStartPictureInPictureAutomaticallyFromInline = allowed
    }

    private func resigning() {
        // AVKit starts the native player's by itself; the page's is asked.
        guard allowed, let webView, webView.window != nil else { return }
        webActive = true
        webView.evaluateJavaScript("""
            (function () {
              const v = document.querySelector('video.html5-main-video') || document.querySelector('video');
              if (!v || v.paused || !v.webkitSupportsPresentationMode || !v.webkitSupportsPresentationMode('picture-in-picture')) { return false; }
              v.removeAttribute('disablepictureinpicture');
              v.webkitSetPresentationMode('picture-in-picture');
              return true;
            })();
            """, completionHandler: nil)
    }

    private func returned() {
        if Date.now >= suppressedUntil { suppressedUntil = .distantPast }
        apply()
        guard webActive, let webView else { return }
        webActive = false
        webView.evaluateJavaScript("""
            (function () {
              const v = document.querySelector('video.html5-main-video') || document.querySelector('video');
              if (v && v.webkitPresentationMode === 'picture-in-picture') { v.webkitSetPresentationMode('inline'); }
            })();
            """, completionHandler: nil)
    }

    // MARK: AVPictureInPictureControllerDelegate

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { isActive = false }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
