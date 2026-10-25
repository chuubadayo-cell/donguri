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

    struct Recording {
        var audio: Data?
        /// The loudest sample the page heard while recording (-1: unknown).
        var peak: Double = -1
        var note = ""
        var audioExtension = "m4a"
        var frames: [Data] = []
        var still: Data?
    }

    /// One pass over [start, end] that keeps the audio and the pictures
    /// together (see `record` in the page script).
    func record(from start: Double, to end: Double, fps: Double, maxWidth: Int,
                audio: Bool, frames: Bool, stillAt: Double?) async -> Recording {
        var arguments: [String: Any] = ["start": start, "end": end, "fps": fps, "width": maxWidth,
                                        "audio": audio, "frames": frames]
        arguments["still"] = stillAt ?? NSNull()
        let result = try? await webView.callAsyncJavaScript(
            "return await irohaPlayer.record(start, end, fps, width, audio, frames, still)",
            arguments: arguments, in: nil, contentWorld: Self.world)
        var recording = Recording()
        guard let dictionary = result as? [String: Any] else {
            print("[iroha] card recording: no result from the page")
            return recording
        }
        if let error = dictionary["audioError"] as? String { print("[iroha] card audio recording: \(error)") }
        if let error = dictionary["error"] as? String { print("[iroha] card recording: \(error)") }
        recording.audio = (dictionary["audio"] as? String).flatMap(Self.decodeDataURL)
        recording.peak = dictionary["peak"] as? Double ?? -1
        var parts: [String] = []
        if let error = dictionary["audioError"] as? String { parts.append(error) }
        if let error = dictionary["error"] as? String { parts.append(error) }
        parts.append("page peak \(String(format: "%.4f", recording.peak))")
        parts.append("context \(dictionary["context"] as? String ?? "?")")
        parts.append("src \(dictionary["src"] as? String ?? "?")")
        recording.note = parts.joined(separator: ", ")
        if let mime = dictionary["mime"] as? String, mime.contains("webm") { recording.audioExtension = "webm" }
        recording.frames = (dictionary["frames"] as? [String] ?? []).compactMap(Self.decodeDataURL)
        recording.still = (dictionary["still"] as? String).flatMap(Self.decodeDataURL)
        print("[iroha] card recording: audio \(recording.audio?.count ?? 0) bytes, \(recording.frames.count) frames, still \(recording.still != nil)")
        return recording
    }

    /// The audio YouTube has buffered for a stretch: an MP4 init segment and
    /// the fragments covering it, and where the first fragment starts.
    func bufferedAudio(from start: Double, to end: Double) async -> (clip: (data: Data, firstTime: Double)?, error: String) {
        let result = try? await webView.callAsyncJavaScript("return window.__irohaAudioClip ? window.__irohaAudioClip(start, end) : null",
                                                           arguments: ["start": start, "end": end],
                                                           in: nil, contentWorld: .page)
        var error = ""
        if let dictionary = result as? [String: Any], let message = dictionary["error"] as? String {
            error = message
        } else if result == nil {
            error = "the page has no audio hook"
        }
        if !error.isEmpty { print("[iroha] card audio from the player's buffer: \(error)") }
        guard let dictionary = result as? [String: Any],
              let base64 = dictionary["data"] as? String,
              let data = Data(base64Encoded: base64),
              let first = dictionary["first"] as? Double else { return (nil, error.isEmpty ? "nothing returned" : error) }
        return ((data, first), "")
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
      // One store per audio buffer: an ad and the video each get their own.
      const stores = [];
      const LIMIT = 40 * 1024 * 1024;

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
      function storeFor(buffer) {
        if (!buffer.__irohaStore) {
          buffer.__irohaStore = { init: null, timescale: 0, frags: [], bytes: 0, current: null };
          stores.push(buffer.__irohaStore);
          while (stores.length > 4) { stores.shift(); }
        }
        return buffer.__irohaStore;
      }
      function same(a, b) {
        if (!a || a.length !== b.length) { return false; }
        for (let i = 0; i < a.length; i++) { if (a[i] !== b[i]) { return false; } }
        return true;
      }
      function keep(store, data) {
        let b;
        if (data instanceof ArrayBuffer) { b = new Uint8Array(data.slice(0)); }
        else if (ArrayBuffer.isView(data)) { b = new Uint8Array(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)); }
        else { return; }
        if (b.length < 8) { return; }
        if (find(b, 0, b.length, ['moov'])) {
          const scale = timescale(b);
          if (scale && !same(store.init, b)) {
            // A different format (a quality change): older fragments don't
            // belong with this init segment.
            store.init = b; store.timescale = scale; store.frags = []; store.bytes = 0; store.current = null;
          }
          return;
        }
        if (!store.timescale) { return; }
        const ticks = decodeTime(b);
        if (ticks === null) {
          // The rest of the fragment being appended in pieces; it belongs to
          // the one appended last, which after a seek isn't the latest in time.
          const current = store.current;
          if (current) {
            const joined = new Uint8Array(current.data.length + b.length);
            joined.set(current.data); joined.set(b, current.data.length);
            store.bytes += b.length; current.data = joined;
          }
          return;
        }
        const t = ticks / store.timescale;
        store.frags = store.frags.filter(function (f) { if (Math.abs(f.t - t) < 0.001) { store.bytes -= f.data.length; return false; } return true; });
        const fragment = { t: t, data: b };
        store.frags.push(fragment);
        store.frags.sort(function (x, y) { return x.t - y.t; });
        store.current = fragment;
        store.bytes += b.length;
        while (store.bytes > LIMIT && store.frags.length > 1) {
          const dropped = store.frags.shift();
          store.bytes -= dropped.data.length;
          if (dropped === store.current) { store.current = null; }
        }
      }

      function hookSources(M) {
        if (!M || !M.prototype || M.prototype.__irohaHooked) { return; }
        M.prototype.__irohaHooked = true;
        const add = M.prototype.addSourceBuffer;
        M.prototype.addSourceBuffer = function (mime) {
          const buffer = add.apply(this, arguments);
          try {
            (window.__irohaMimes = window.__irohaMimes || []).push(String(mime).slice(0, 48));
            if (window.__irohaMimes.length > 6) { window.__irohaMimes.shift(); }
            if (/^audio\\/mp4/i.test(String(mime))) { buffer.__irohaAudio = true; }
          } catch (e) {}
          return buffer;
        };
      }
      hookSources(window.MediaSource);
      hookSources(window.ManagedMediaSource);
      if (window.SourceBuffer && !SourceBuffer.prototype.__irohaHooked) {
        SourceBuffer.prototype.__irohaHooked = true;
        const append = SourceBuffer.prototype.appendBuffer;
        SourceBuffer.prototype.appendBuffer = function (data) {
          if (this.__irohaAudio) { try { keep(storeFor(this), data); } catch (e) {} }
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

      function pick(store, start, end) {
        if (!store.init || !store.frags.length) { return null; }
        const frags = store.frags;
        let first = -1, last = -1;
        for (let i = 0; i < frags.length; i++) {
          const next = i + 1 < frags.length ? frags[i + 1].t : Infinity;
          if (frags[i].t < end && next > start) { if (first < 0) { first = i; } last = i; }
        }
        if (first < 0 || frags[first].t > start + 0.05) { return null; }
        // Past the last fragment held: its length isn't known, but YouTube's
        // are a few seconds.
        if (last === frags.length - 1 && end > frags[last].t + 12) { return null; }
        // Every fragment in the stretch has to be there, back to back.
        for (let i = first; i < last; i++) {
          if (frags[i + 1].t - frags[i].t > 15) { return null; }
        }
        return { store: store, first: first, last: last };
      }

      window.__irohaAudioClip = function (start, end) {
        // The video's buffer, not an ad's: of the buffers that hold the
        // stretch, the one reaching furthest into the video.
        let best = null;
        for (const store of stores) {
          const found = pick(store, start, end);
          if (found && (!best || store.frags[store.frags.length - 1].t > best.store.frags[best.store.frags.length - 1].t)) {
            best = found;
          }
        }
        if (!best) {
          const held = stores.map(function (s) {
            return s.frags.length ? s.frags[0].t.toFixed(1) + '-' + s.frags[s.frags.length - 1].t.toFixed(1) : 'empty';
          });
          return { error: 'not buffered (' + start.toFixed(1) + '-' + end.toFixed(1) + '; have ' + (held.join(', ') || 'no audio buffers') +
                   '; buffers made: ' + ((window.__irohaMimes || []).join(' | ') || 'none') + ')' };
        }
        const store = best.store;
        let size = store.init.length;
        for (let i = best.first; i <= best.last; i++) { size += store.frags[i].data.length; }
        const out = new Uint8Array(size);
        out.set(store.init);
        let offset = store.init.length;
        for (let i = best.first; i <= best.last; i++) { out.set(store.frags[i].data, offset); offset += store.frags[i].data.length; }
        return { data: base64(out), first: store.frags[best.first].t };
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
      // Sound on, at full volume. The replay for a card must be audible:
      // the recording is taken from what the element plays.
      function unmute(v) {
        v.__irohaMuted = false;
        if (v.muted) { v.muted = false; }
        if (v.volume < 1) { v.volume = 1; }
      }

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
          unmute(v);
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
          await seekTo(v, back);
          if (!wasPaused) { v.play().catch(function () {}); }
          return frames;
        },

        // Plays the line once (out loud, at normal speed) and keeps what a
        // card needs from that one pass: the audio, recorded through Web
        // Audio, and the GIF frames or the screenshot. Audio and pictures
        // cover exactly the same stretch.
        record: async function (start, end, fps, width, wantAudio, wantFrames, stillTime) {
          const v = video();
          if (!v) { return { error: 'no video' }; }
          const back = v.currentTime, wasPaused = v.paused, rate = v.playbackRate;
          let recorder = null, destination = null, graph = null, audioError = null;
          const chunks = [];
          let analyser = null, peak = 0;
          const samples = new Float32Array(1024);
          if (wantAudio) {
            try {
              // Web Audio is "ambient" by default on iOS: the silent switch
              // mutes it. As playback it sounds (and records) like the video.
              try { if (navigator.audioSession) { navigator.audioSession.type = 'playback'; } } catch (e) {}
              graph = window.__irohaAudioGraph;
              if (!graph || graph.element !== v) {
                // Routing the element through Web Audio is permanent, so it
                // is set up once per element and also kept playing out loud.
                const Context = window.AudioContext || window.webkitAudioContext;
                const context = (graph && graph.context) || new Context();
                const source = context.createMediaElementSource(v);
                source.connect(context.destination);
                v.addEventListener('play', function () { try { context.resume(); } catch (e) {} });
                graph = window.__irohaAudioGraph = { context: context, source: source, element: v };
              }
              await graph.context.resume();
              if (graph.context.state !== 'running') { throw new Error('audio context is ' + graph.context.state); }
              destination = graph.context.createMediaStreamDestination();
              graph.source.connect(destination);
              // To tell a recording of silence from one with sound.
              analyser = graph.context.createAnalyser();
              analyser.fftSize = 1024;
              graph.source.connect(analyser);
              const type = (window.MediaRecorder && MediaRecorder.isTypeSupported('audio/mp4')) ? 'audio/mp4' : '';
              recorder = new MediaRecorder(destination.stream, type ? { mimeType: type, audioBitsPerSecond: 128000 } : undefined);
              recorder.ondataavailable = function (e) { if (e.data && e.data.size) { chunks.push(e.data); } };
            } catch (e) {
              recorder = null;
              audioError = String(e && e.message || e);
            }
          }
          v.pause();
          unmute(v);
          v.playbackRate = 1;
          await seekTo(v, start);
          unmute(v);
          const frames = [];
          let still = null, next = start;
          if (recorder) { recorder.start(); }
          await v.play().catch(function () {});
          const deadline = Date.now() + (end - start) * 1000 + 8000;
          while (v.currentTime < end && Date.now() < deadline) {
            const t = v.currentTime;
            if (wantFrames && t >= next) {
              const f = draw(v, width);
              if (f) { frames.push(f); }
              next += 1 / fps;
            }
            if (still === null && stillTime !== null && t >= stillTime) { still = draw(v, 960); }
            // YouTube's player can mute the element again after a seek.
            if (v.muted || v.volume < 1) { unmute(v); }
            if (analyser) {
              analyser.getFloatTimeDomainData(samples);
              for (let i = 0; i < samples.length; i++) { const a = Math.abs(samples[i]); if (a > peak) { peak = a; } }
            }
            await wait(15);
          }
          v.pause();
          let audio = null, mime = null;
          if (recorder) {
            await new Promise(function (resolve) { recorder.onstop = resolve; recorder.stop(); });
            try { graph.source.disconnect(destination); } catch (e) {}
            try { if (analyser) { graph.source.disconnect(analyser); } } catch (e) {}
            const blob = new Blob(chunks, { type: recorder.mimeType || 'audio/mp4' });
            mime = blob.type;
            if (blob.size > 0) {
              audio = await new Promise(function (resolve) {
                const reader = new FileReader();
                reader.onloadend = function () { resolve(reader.result); };
                reader.onerror = function () { resolve(null); };
                reader.readAsDataURL(blob);
              });
            } else {
              audioError = 'recording was empty';
            }
          }
          if (still === null && stillTime !== null) { still = draw(v, 960); }
          v.playbackRate = rate;
          await seekTo(v, back);
          if (!wasPaused) { v.play().catch(function () {}); }
          return { audio: audio, mime: mime, frames: frames, still: still, audioError: audioError,
                   peak: analyser ? peak : -1, src: String(v.currentSrc || '').slice(0, 40),
                   context: graph && graph.context ? graph.context.state : 'none' };
        }
      };
    })();
    """
}
