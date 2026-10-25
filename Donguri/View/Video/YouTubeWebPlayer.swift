//
//  YouTubeWebPlayer.swift
//  Donguri
//
//  YouTube's own player, for when its stream can't be played directly.
//  The mobile watch page loads in a web view (signed in, with the
//  browser's cookies) and is styled down to nothing but the video, full
//  bleed, under the app's own controls and subtitles. Its <video> element
//  is driven by script.
//
//  Clips for cards come from the page too: the audio from the data
//  YouTube's player feeds its audio buffer (kept as it's appended, so
//  mining needs no replay), the pictures from the video element drawn
//  into a canvas.
//

import Foundation
import WebKit

@MainActor
final class YouTubeWebPlayer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    struct State {
        var ready = false
        var time: Double = 0
        var duration: Double = 0
        var paused = true
        var waiting = false
        var isAd = false
        var canSkipAd = false
        var buffered: Double = 0
        var source = ""
    }

    let webView: WKWebView
    var onState: ((State) -> Void)?
    private(set) var state = State()
    private let videoID: String
    private var startTime: Double
    /// Keep asking the page to play until it does (autoplay can stall).
    private var wantsPlaying = true
    private var loadedAt = Date.now

    static let world = WKContentWorld.world(name: "iroha-player")

    init(videoID: String, startAt: Double) {
        self.videoID = videoID
        self.startTime = startAt
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = false
        let controller = configuration.userContentController
        // The audio hook has to run in the page's own world, before
        // YouTube's player builds its media source.
        controller.addUserScript(WKUserScript(source: Self.audioHook, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: Self.controllerScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: Self.world))
        if BehaviorSettings.shared.contentBlocking {
            YouTubeAdScripts.install(in: controller, world: Self.world)
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = SafariUserAgent.mobile
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        // The app's controls sit on top; the page never sees a touch.
        webView.isUserInteractionEnabled = false
        super.init()
        controller.add(WeakMessageHandler(self), contentWorld: Self.world, name: "irohaVideo")
        webView.navigationDelegate = self
    }

    func load() {
        loadedAt = .now
        var components = URLComponents(string: "https://m.youtube.com/watch")!
        var items = [URLQueryItem(name: "v", value: videoID), URLQueryItem(name: "hl", value: "ja")]
        // The account chosen in the YouTube screen.
        if let account = YouTubeAccount.current {
            items.append(URLQueryItem(name: "authuser", value: String(account.authUser)))
        }
        components.queryItems = items
        webView.load(URLRequest(url: components.url!))
    }

    func teardown() {
        run("window.irohaPlayer && irohaPlayer.pause()")
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.loadHTMLString("", baseURL: nil)
    }

    // MARK: Control

    func play(rate: Double) {
        wantsPlaying = true
        run("irohaPlayer.play(\(rate))")
    }

    func pause() {
        wantsPlaying = false
        run("irohaPlayer.pause()")
    }

    func seek(to time: Double) {
        run("irohaPlayer.seek(\(time))")
    }

    func setRate(_ rate: Double) {
        run("irohaPlayer.rate(\(rate))")
    }

    func skipAd() {
        run("irohaPlayer.skipAd()")
    }

    private func run(_ script: String) {
        webView.evaluateJavaScript(script, in: nil, in: Self.world, completionHandler: nil)
    }

    // MARK: Page events

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        var next = State()
        next.ready = body["ready"] as? Bool ?? false
        next.time = body["t"] as? Double ?? 0
        next.duration = body["d"] as? Double ?? 0
        next.paused = body["paused"] as? Bool ?? true
        next.waiting = body["waiting"] as? Bool ?? false
        next.isAd = body["ad"] as? Bool ?? false
        next.canSkipAd = body["skip"] as? Bool ?? false
        next.buffered = body["buf"] as? Double ?? 0
        next.source = body["src"] as? String ?? ""
        let firstReady = next.ready && !state.ready
        state = next
        if firstReady, !next.isAd {
            if startTime > 5 { seek(to: startTime) }
            startTime = 0
        }
        // Autoplay sometimes doesn't take; nudge it for the first while.
        if next.ready, next.paused, wantsPlaying, !next.isAd, Date.now.timeIntervalSince(loadedAt) < 15 {
            run("irohaPlayer.play()")
        }
        // Stop at the end rather than let YouTube move on to another video.
        if next.ready, !next.isAd, next.duration > 0, next.time >= next.duration - 0.35, !next.paused {
            pause()
        }
        onState?(next)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // Only this video's page; YouTube's own "up next" stays out.
        if let url = navigationAction.request.url, navigationAction.targetFrame?.isMainFrame == true,
           let id = YouTubeClient.videoID(in: url), id != videoID {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: Clips

    /// The frame on screen as a JPEG, or nil.
    func frame(maxWidth: Int) async -> Data? {
        let result = try? await webView.callAsyncJavaScript("return irohaPlayer.frame(\(maxWidth))",
                                                           arguments: [:], in: nil, contentWorld: Self.world)
        return (result as? String).flatMap(Self.decodeDataURL)
    }

    /// The frame at `time`: seeks there and back if it isn't on screen.
    func frame(at time: Double, maxWidth: Int) async -> Data? {
        let result = try? await webView.callAsyncJavaScript("return await irohaPlayer.frameAt(time, width)",
                                                           arguments: ["time": time, "width": maxWidth],
                                                           in: nil, contentWorld: Self.world)
        return (result as? String).flatMap(Self.decodeDataURL)
    }

    /// Frames across a stretch, by playing it again muted.
    func frames(from start: Double, to end: Double, fps: Double, maxWidth: Int) async -> [Data] {
        let result = try? await webView.callAsyncJavaScript("return await irohaPlayer.frames(start, end, fps, width)",
                                                           arguments: ["start": start, "end": end, "fps": fps, "width": maxWidth],
                                                           in: nil, contentWorld: Self.world)
        return (result as? [String] ?? []).compactMap(Self.decodeDataURL)
    }

    /// The audio YouTube has buffered for a stretch: an MP4 init segment and
    /// the fragments covering it, and where the first fragment starts.
    func bufferedAudio(from start: Double, to end: Double) async -> (data: Data, firstTime: Double)? {
        let result = try? await webView.callAsyncJavaScript("return window.__irohaAudioClip ? window.__irohaAudioClip(start, end) : null",
                                                           arguments: ["start": start, "end": end],
                                                           in: nil, contentWorld: .page)
        guard let dictionary = result as? [String: Any],
              let base64 = dictionary["data"] as? String,
              let data = Data(base64Encoded: base64),
              let first = dictionary["first"] as? Double else { return nil }
        return (data, first)
    }

    private static func decodeDataURL(_ string: String) -> Data? {
        guard let comma = string.firstIndex(of: ","), string.hasPrefix("data:") else { return nil }
        return Data(base64Encoded: String(string[string.index(after: comma)...]))
    }

    // MARK: Scripts

    /// Keeps a copy of everything YouTube's player appends to its audio
    /// buffer (MP4 audio: one init segment, then fragments, each timed by
    /// its tfdt box), and hands back the stretch a card needs.
    static let audioHook = """
    (function () {
      if (window.__irohaAudioHook) { return; }
      window.__irohaAudioHook = true;
      const store = { init: null, timescale: 0, frags: [], bytes: 0 };
      const LIMIT = 48 * 1024 * 1024;

      function u32(b, p) { return ((b[p] << 24) >>> 0) + (b[p + 1] << 16) + (b[p + 2] << 8) + b[p + 3]; }
      function type(b, p) { return String.fromCharCode(b[p + 4], b[p + 5], b[p + 6], b[p + 7]); }
      function each(b, start, end, fn) {
        let p = start;
        while (p + 8 <= end) {
          let size = u32(b, p), header = 8;
          if (size === 1) { size = u32(b, p + 8) * 4294967296 + u32(b, p + 12); header = 16; }
          else if (size === 0) { size = end - p; }
          if (size < 8 || p + size > end) { fn(type(b, p), p, p + header, end, true); return; }
          if (fn(type(b, p), p, p + header, p + size, false) === false) { return; }
          p += size;
        }
      }
      function find(b, start, end, path) {
        let found = null;
        each(b, start, end, function (t, boxStart, body, boxEnd) {
          if (t !== path[0]) { return; }
          found = path.length === 1 ? [boxStart, body, boxEnd] : find(b, body, boxEnd, path.slice(1));
          return found ? false : undefined;
        });
        return found;
      }
      function timescale(b) {
        const mdhd = find(b, 0, b.length, ['moov', 'trak', 'mdia', 'mdhd']);
        if (!mdhd) { return 0; }
        const v = b[mdhd[1]];
        return u32(b, mdhd[1] + (v === 1 ? 20 : 12));
      }
      function decodeTime(b) {
        const tfdt = find(b, 0, b.length, ['moof', 'traf', 'tfdt']);
        if (!tfdt) { return null; }
        const v = b[tfdt[1]];
        return v === 1 ? u32(b, tfdt[1] + 4) * 4294967296 + u32(b, tfdt[1] + 8) : u32(b, tfdt[1] + 4);
      }
      function keep(data) {
        let b;
        if (data instanceof ArrayBuffer) { b = new Uint8Array(data.slice(0)); }
        else if (ArrayBuffer.isView(data)) { b = new Uint8Array(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)); }
        else { return; }
        if (b.length < 8) { return; }
        if (find(b, 0, b.length, ['moov'])) {
          const scale = timescale(b);
          if (scale) {
            if (store.init && store.init.length === b.length) { return; }
            store.init = b; store.timescale = scale; store.frags = []; store.bytes = 0;
          }
          return;
        }
        if (!store.timescale) { return; }
        const ticks = decodeTime(b);
        if (ticks === null) {
          // The rest of a fragment appended in pieces.
          const last = store.frags[store.frags.length - 1];
          if (last) {
            const joined = new Uint8Array(last.data.length + b.length);
            joined.set(last.data); joined.set(b, last.data.length);
            store.bytes += b.length; last.data = joined;
          }
          return;
        }
        const t = ticks / store.timescale;
        store.frags = store.frags.filter(function (f) { if (Math.abs(f.t - t) < 0.001) { store.bytes -= f.data.length; return false; } return true; });
        store.frags.push({ t: t, data: b });
        store.frags.sort(function (x, y) { return x.t - y.t; });
        store.bytes += b.length;
        while (store.bytes > LIMIT && store.frags.length > 1) { store.bytes -= store.frags.shift().data.length; }
      }

      function hookSources(M) {
        if (!M || !M.prototype || M.prototype.__irohaHooked) { return; }
        M.prototype.__irohaHooked = true;
        const add = M.prototype.addSourceBuffer;
        M.prototype.addSourceBuffer = function (mime) {
          const buffer = add.apply(this, arguments);
          try { if (/^audio\\/mp4/i.test(String(mime))) { buffer.__irohaAudio = true; } } catch (e) {}
          return buffer;
        };
      }
      hookSources(window.MediaSource);
      hookSources(window.ManagedMediaSource);
      if (window.SourceBuffer && !SourceBuffer.prototype.__irohaHooked) {
        SourceBuffer.prototype.__irohaHooked = true;
        const append = SourceBuffer.prototype.appendBuffer;
        SourceBuffer.prototype.appendBuffer = function (data) {
          if (this.__irohaAudio) { try { keep(data); } catch (e) {} }
          return append.apply(this, arguments);
        };
      }

      function base64(bytes) {
        let out = '';
        const chunk = 0x8000;
        for (let i = 0; i < bytes.length; i += chunk) {
          out += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
        }
        return btoa(out);
      }

      window.__irohaAudioClip = function (start, end) {
        if (!store.init || !store.frags.length) { return null; }
        const frags = store.frags;
        let first = -1, last = -1;
        for (let i = 0; i < frags.length; i++) {
          const next = i + 1 < frags.length ? frags[i + 1].t : Infinity;
          if (frags[i].t < end && next > start) { if (first < 0) { first = i; } last = i; }
        }
        if (first < 0) { return null; }
        // Every fragment in the stretch has to be there, back to back.
        for (let i = first; i < last; i++) {
          if (frags[i + 1].t - frags[i].t > 15) { return null; }
        }
        let size = store.init.length;
        for (let i = first; i <= last; i++) { size += frags[i].data.length; }
        const out = new Uint8Array(size);
        out.set(store.init);
        let offset = store.init.length;
        for (let i = first; i <= last; i++) { out.set(frags[i].data, offset); offset += frags[i].data.length; }
        return { data: base64(out), first: frags[first].t };
      };
    })();
    """

    /// Styles the page down to the video and reports on it.
    static let controllerScript = """
    (function () {
      if (window.irohaPlayer) { return; }
      const css = [
        'html, body { background: #000 !important; overflow: hidden !important; }',
        '.iroha-player { position: fixed !important; inset: 0 !important; left: 0 !important; top: 0 !important; width: 100vw !important; height: 100vh !important; z-index: 2147483647 !important; background: #000 !important; margin: 0 !important; padding: 0 !important; transform: none !important; }',
        '.iroha-player video { position: absolute !important; left: 0 !important; top: 0 !important; width: 100vw !important; height: 100vh !important; object-fit: contain !important; transform: none !important; }',
        '.ytp-caption-window-container, .caption-window, .captions-text, .ytp-chrome-bottom, .ytp-chrome-top, .ytp-gradient-bottom, .ytp-gradient-top,',
        '.player-controls-background, .player-controls-content, .player-controls-top, .player-controls-bottom, .player-controls-middle,',
        '.ytm-autonav-bar, .ytp-pause-overlay, .ytp-ce-element, .ytp-endscreen-content, .ytp-watermark, .ytp-paid-content-overlay,',
        '.ytp-spinner, .ytmCuedOverlayHost, .ytp-cued-thumbnail-overlay, ytm-mobile-topbar-renderer, ytm-pivot-bar-renderer,',
        '.ytm-app-upsell, ytm-upsell-dialog-renderer, .player-control-container,',
        '.ytp-unmute, [class*="unmute" i], [class*="Unmute"], .ytp-mute-button, .ytmMuteIndicator { display: none !important; }'
      ].join('\\n');
      function style() {
        if (document.getElementById('iroha-player-style')) { return; }
        const s = document.createElement('style');
        s.id = 'iroha-player-style';
        s.textContent = css;
        (document.head || document.documentElement).appendChild(s);
      }
      function video() {
        return document.querySelector('video.html5-main-video') || document.querySelector('#movie_player video') || document.querySelector('video');
      }
      function player() {
        return document.querySelector('#movie_player') || document.querySelector('.html5-video-player');
      }
      function post(message) {
        try { webkit.messageHandlers.irohaVideo.postMessage(message); } catch (e) {}
      }
      function skipButton() {
        return document.querySelector('.ytp-ad-skip-button, .ytp-skip-ad-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button-container button, .ytp-skip-ad button');
      }
      function tick() {
        style();
        const v = video();
        if (!v) { post({ ready: false }); return; }
        const box = player() || v.parentElement;
        if (box && !box.classList.contains('iroha-player')) { box.classList.add('iroha-player'); }
        if (!v.__irohaListening) {
          // Play, pause and seeks are reported at once, not at the next tick.
          v.__irohaListening = true;
          ['play', 'pause', 'seeked', 'playing', 'waiting'].forEach(function (name) {
            v.addEventListener(name, function () { setTimeout(tick, 0); });
          });
        }
        const p = player();
        const ad = !!(p && (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting')));
        if (v.muted && !v.__irohaMuted && !ad) { v.muted = false; }
        let buffered = 0;
        try { if (v.buffered.length) { buffered = v.buffered.end(v.buffered.length - 1); } } catch (e) {}
        post({
          ready: v.readyState > 0, t: v.currentTime || 0, d: isFinite(v.duration) ? v.duration : 0,
          paused: v.paused, waiting: !v.paused && v.readyState < 3, ad: ad, skip: !!skipButton(),
          buf: buffered, src: v.currentSrc || ''
        });
      }
      setInterval(tick, 200);
      document.addEventListener('DOMContentLoaded', style);

      function draw(v, width) {
        if (!v || !v.videoWidth) { return null; }
        const scale = Math.min(1, width / v.videoWidth);
        const c = document.createElement('canvas');
        c.width = Math.round(v.videoWidth * scale);
        c.height = Math.round(v.videoHeight * scale);
        c.getContext('2d').drawImage(v, 0, 0, c.width, c.height);
        try { return c.toDataURL('image/jpeg', 0.8); } catch (e) { return null; }
      }
      function seekTo(v, t) {
        return new Promise(function (resolve) {
          let done = false;
          function finish() { if (!done) { done = true; v.removeEventListener('seeked', finish); setTimeout(resolve, 80); } }
          v.addEventListener('seeked', finish);
          v.currentTime = t;
          setTimeout(finish, 4000);
        });
      }
      function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

      window.irohaPlayer = {
        play: function (rate) { const v = video(); if (!v) { return; } if (rate) { v.playbackRate = rate; } v.play().catch(function () {}); },
        pause: function () { const v = video(); if (v) { v.pause(); } },
        seek: function (t) { const v = video(); if (v) { v.currentTime = t; } },
        rate: function (r) { const v = video(); if (v) { v.playbackRate = r; } },
        skipAd: function () { const b = skipButton(); if (b) { b.click(); } },
        frame: function (width) { return draw(video(), width); },
        frameAt: async function (t, width) {
          const v = video();
          if (!v) { return null; }
          if (Math.abs(v.currentTime - t) < 0.3) { return draw(v, width); }
          const back = v.currentTime, wasPaused = v.paused;
          v.pause();
          await seekTo(v, t);
          const image = draw(v, width);
          await seekTo(v, back);
          if (!wasPaused) { v.play().catch(function () {}); }
          return image;
        },
        frames: async function (start, end, fps, width) {
          const v = video();
          if (!v) { return []; }
          const back = v.currentTime, wasPaused = v.paused, rate = v.playbackRate;
          v.pause();
          v.__irohaMuted = true; v.muted = true;
          await seekTo(v, start);
          v.playbackRate = 1;
          await v.play().catch(function () {});
          const frames = [];
          let next = start;
          const deadline = Date.now() + (end - start) * 1000 + 8000;
          while (v.currentTime < end && Date.now() < deadline) {
            if (v.currentTime >= next) {
              const f = draw(v, width);
              if (f) { frames.push(f); }
              next += 1 / fps;
            }
            await wait(Math.max(15, 500 / fps));
          }
          v.pause();
          v.playbackRate = rate;
          v.muted = false; v.__irohaMuted = false;
          await seekTo(v, back);
          if (!wasPaused) { v.play().catch(function () {}); }
          return frames;
        }
      };
    })();
    """
}
