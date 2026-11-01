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
        configuration.allowsPictureInPictureMediaPlayback = true
        let controller = configuration.userContentController
        // The audio hook has to run in the page's own world, before
        // YouTube's player builds its media source.
        controller.addUserScript(WKUserScript(source: Self.audioHook, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: Self.alwaysVisible, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: Self.qualityScript, injectionTime: .atDocumentStart,
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

    // MARK: Quality

    /// The qualities YouTube offers for this video (best first, as its
    /// names: hd1080, hd720, large…) and the one playing.
    func qualities() async -> (levels: [String], current: String) {
        let result = try? await webView.callAsyncJavaScript(
            "return window.__irohaQuality ? window.__irohaQuality.info() : null",
            arguments: [:], in: nil, contentWorld: .page)
        guard let dictionary = result as? [String: Any] else { return ([], "") }
        let levels = (dictionary["levels"] as? [String] ?? []).filter { $0 != "auto" }
        return (levels, dictionary["current"] as? String ?? "")
    }

    /// Plays at `cap` or the best below it ("auto" leaves it to YouTube).
    func setQuality(cap: String) {
        let escaped = cap.replacingOccurrences(of: "'", with: "")
        webView.evaluateJavaScript("window.__irohaQuality && window.__irohaQuality.set('\(escaped)')",
                                   in: nil, in: .page, completionHandler: nil)
    }

    /// YouTube's player gets its API a little after the video is ready,
    /// and may pick its own quality as it starts: asked a few times.
    private func applyPreferredQuality() {
        for delay in [0.0, 1.0, 3.0, 6.0] {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !self.state.isAd else { return }
                self.setQuality(cap: VideoSettings.shared.videoQuality)
            }
        }
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
        let adEnded = state.isAd && !next.isAd
        state = next
        if firstReady, !next.isAd {
            if startTime > 5 { seek(to: startTime) }
            startTime = 0
        }
        // The chosen quality, once YouTube's player can take it (again
        // after an ad, which has its own).
        if next.ready, !next.isAd, firstReady || adEnded {
            applyPreferredQuality()
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

    /// A small frame for the miniplayer, decoded off the main actor so
    /// drawing it never waits on JPEG decoding.
    func miniFrame(maxWidth: Int) async -> UIImage? {
        guard let result = try? await webView.callAsyncJavaScript("return irohaPlayer.miniFrame(\(maxWidth))",
                                                                  arguments: [:], in: nil, contentWorld: Self.world),
              let string = result as? String else { return nil }
        return await Self.decodeImage(string)
    }

    @concurrent
    private nonisolated static func decodeImage(_ dataURL: String) async -> UIImage? {
        guard let data = decodeDataURL(dataURL) else { return nil }
        return UIImage(data: data)?.preparingForDisplay()
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
        var frames: [Data] = []
        var still: Data?
    }

    /// The line played once more for its GIF frames or screenshot (see
    /// `record` in the page script).
    func record(from start: Double, to end: Double, fps: Double, maxWidth: Int,
                frames: Bool, stillAt: Double?) async -> Recording {
        var arguments: [String: Any] = ["start": start, "end": end, "fps": fps, "width": maxWidth, "frames": frames]
        arguments["still"] = stillAt ?? NSNull()
        let result = try? await webView.callAsyncJavaScript(
            "return await irohaPlayer.record(start, end, fps, width, false, frames, still)",
            arguments: arguments, in: nil, contentWorld: Self.world)
        var recording = Recording()
        guard let dictionary = result as? [String: Any] else {
            print("[iroha] card recording: no result from the page")
            return recording
        }
        if let error = dictionary["error"] as? String { print("[iroha] card recording: \(error)") }
        recording.frames = (dictionary["frames"] as? [String] ?? []).compactMap(Self.decodeDataURL)
        recording.still = (dictionary["still"] as? String).flatMap(Self.decodeDataURL)
        return recording
    }

    /// The audio YouTube has buffered for a stretch: an MP4 init segment and
    /// the fragments covering it, and where the first fragment starts.
    func bufferedAudio(from start: Double, to end: Double) async -> (clip: (data: Data, firstTime: Double, isWebM: Bool)?, error: String) {
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
        return ((data, first, (dictionary["kind"] as? String) == "webm"), "")
    }

    private nonisolated static func decodeDataURL(_ string: String) -> Data? {
        guard let comma = string.firstIndex(of: ","), string.hasPrefix("data:") else { return nil }
        return Data(base64Encoded: String(string[string.index(after: comma)...]))
    }

    // MARK: Scripts

    /// YouTube pauses when its page is hidden (background play is a paid
    /// feature). The page is told it never is, so the video plays on when
    /// the app leaves the screen.
    static let alwaysVisible = """
    (function () {
      if (window.__irohaVisible) { return; }
      window.__irohaVisible = true;
      try {
        Object.defineProperty(Document.prototype, 'hidden', { get: function () { return false; }, configurable: true });
        Object.defineProperty(Document.prototype, 'visibilityState', { get: function () { return 'visible'; }, configurable: true });
        Object.defineProperty(Document.prototype, 'webkitHidden', { get: function () { return false; }, configurable: true });
        Object.defineProperty(Document.prototype, 'webkitVisibilityState', { get: function () { return 'visible'; }, configurable: true });
        Document.prototype.hasFocus = function () { return true; };
      } catch (e) {}
      const swallow = function (event) { event.stopImmediatePropagation(); };
      ['visibilitychange', 'webkitvisibilitychange', 'pagehide', 'freeze', 'blur'].forEach(function (type) {
        window.addEventListener(type, swallow, true);
        document.addEventListener(type, swallow, true);
      });
    })();
    """

    /// YouTube's player's own quality API (page world: the methods live on
    /// its element there).
    static let qualityScript = """
    (function () {
      if (window.__irohaQuality) { return; }
      const order = ['highres', 'hd2880', 'hd2160', 'hd1440', 'hd1080', 'hd720', 'large', 'medium', 'small', 'tiny'];
      function player() { return document.getElementById('movie_player') || document.querySelector('.html5-video-player'); }
      window.__irohaQuality = {
        info: function () {
          const p = player();
          if (!p || typeof p.getAvailableQualityLevels !== 'function') { return { levels: [], current: '' }; }
          return { levels: p.getAvailableQualityLevels() || [], current: (p.getPlaybackQuality && p.getPlaybackQuality()) || '' };
        },
        set: function (cap) {
          const p = player();
          if (!p || typeof p.getAvailableQualityLevels !== 'function') { return false; }
          if (cap === 'auto') {
            if (p.setPlaybackQualityRange) { p.setPlaybackQualityRange('auto', 'auto'); }
            return true;
          }
          const levels = (p.getAvailableQualityLevels() || []).filter(function (q) { return q !== 'auto'; });
          const limit = order.indexOf(cap);
          let chosen = null;
          for (const q of levels) {
            const rank = order.indexOf(q);
            if (rank >= 0 && rank >= limit) { chosen = q; break; }
          }
          if (!chosen) { chosen = levels[levels.length - 1]; }
          if (!chosen) { return false; }
          if (p.setPlaybackQualityRange) { p.setPlaybackQualityRange(chosen, chosen); }
          if (p.setPlaybackQuality) { p.setPlaybackQuality(chosen); }
          return chosen;
        }
      };
    })();
    """

    /// Keeps a copy of everything YouTube's player appends to its audio
    /// buffer (MP4 audio: one init segment, then fragments, each timed by
    /// its tfdt box), and hands back the stretch a card needs.
    static let audioHook = """
    (function () {
      if (window.__irohaAudioHook) { return; }
      window.__irohaAudioHook = true;
      // One store per audio buffer: an ad and the video each get their own.
      const stores = [];
      // About a quarter of an hour of YouTube's audio per buffer: a card
      // is made from a line just heard, and this lives in the page's memory.
      const LIMIT = 16 * 1024 * 1024;

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
          buffer.__irohaStore = { kind: buffer.__irohaAudio, init: null, timescale: 0, frags: [], bytes: 0, current: null };
          stores.push(buffer.__irohaStore);
          while (stores.length > 3) { stores.shift(); }
        }
        return buffer.__irohaStore;
      }
      function same(a, b) {
        if (!a || a.length !== b.length) { return false; }
        for (let i = 0; i < a.length; i++) { if (a[i] !== b[i]) { return false; } }
        return true;
      }
      function bytesOf(data) {
        if (data instanceof ArrayBuffer) { return new Uint8Array(data.slice(0)); }
        if (ArrayBuffer.isView(data)) { return new Uint8Array(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)); }
        return null;
      }
      function addFragment(store, t, b) {
        // Kept in time order by inserting in place: appends come several a
        // second, and filtering and sorting thousands of fragments for each
        // one added up.
        const frags = store.frags;
        let low = 0, high = frags.length;
        while (low < high) { const mid = (low + high) >> 1; if (frags[mid].t < t - 0.001) { low = mid + 1; } else { high = mid; } }
        const fragment = { t: t, data: b };
        if (low < frags.length && Math.abs(frags[low].t - t) < 0.001) {
          // The same fragment again (after a seek back): replace it.
          store.bytes -= frags[low].data.length;
          frags[low] = fragment;
        } else {
          frags.splice(low, 0, fragment);
        }
        store.current = fragment;
        store.bytes += b.length;
        while (store.bytes > LIMIT && store.frags.length > 1) {
          const dropped = store.frags.shift();
          store.bytes -= dropped.data.length;
          if (dropped === store.current) { store.current = null; }
        }
      }
      function continueFragment(store, b) {
        // The rest of the fragment being appended in pieces; it belongs to
        // the one appended last, which after a seek isn't the latest in time.
        const current = store.current;
        if (!current) { return; }
        const joined = new Uint8Array(current.data.length + b.length);
        joined.set(current.data); joined.set(b, current.data.length);
        store.bytes += b.length; current.data = joined;
      }

      // WebM (Opus), which YouTube sends Safari: an init segment (EBML
      // header, Info, Tracks), then Clusters, each timed by its Timecode.
      function ebmlId(b, p) {
        const f = b[p];
        const len = f >= 0x80 ? 1 : f >= 0x40 ? 2 : f >= 0x20 ? 3 : f >= 0x10 ? 4 : 0;
        if (!len || p + len > b.length) { return null; }
        let id = 0;
        for (let i = 0; i < len; i++) { id = id * 256 + b[p + i]; }
        return { id: id, len: len };
      }
      function ebmlSize(b, p) {
        const f = b[p];
        if (f === undefined) { return null; }
        let len = 1, mask = 0x80;
        while (len <= 8 && !(f & mask)) { mask >>= 1; len++; }
        if (len > 8 || p + len > b.length) { return null; }
        let v = f & (mask - 1), unknown = v === mask - 1;
        for (let i = 1; i < len; i++) { v = v * 256 + b[p + i]; if (b[p + i] !== 0xff) { unknown = false; } }
        return { v: v, len: len, unknown: unknown };
      }
      function uint(b, p, n) { let v = 0; for (let i = 0; i < n; i++) { v = v * 256 + b[p + i]; } return v; }
      function indexOf(b, pattern, from) {
        outer: for (let i = from || 0; i + pattern.length <= b.length; i++) {
          for (let j = 0; j < pattern.length; j++) { if (b[i + j] !== pattern[j]) { continue outer; } }
          return i;
        }
        return -1;
      }
      const CLUSTER = [0x1f, 0x43, 0xb6, 0x75];
      function startsWith(b, pattern) { return indexOf(b.subarray(0, pattern.length), pattern, 0) === 0; }
      /// Ticks of the Cluster starting at 0, or null.
      function clusterTicks(b) {
        const id = ebmlId(b, 0);
        if (!id || id.id !== 0x1f43b675) { return null; }
        const size = ebmlSize(b, id.len);
        if (!size) { return null; }
        let p = id.len + size.len;
        const end = Math.min(b.length, size.unknown ? b.length : p + size.v);
        while (p < end) {
          const child = ebmlId(b, p); if (!child) { return null; }
          const childSize = ebmlSize(b, p + child.len); if (!childSize) { return null; }
          const body = p + child.len + childSize.len;
          if (child.id === 0xe7) { return body + childSize.v <= b.length ? uint(b, body, childSize.v) : null; }
          if (childSize.unknown) { return null; }
          p = body + childSize.v;
        }
        return null;
      }
      /// Seconds per tick, from the init segment's TimecodeScale (ns).
      function tickSeconds(init) {
        const at = indexOf(init, [0x2a, 0xd7, 0xb1], 0);
        if (at < 0) { return 0.001; }
        const size = ebmlSize(init, at + 3);
        if (!size || size.v > 8) { return 0.001; }
        return uint(init, at + 3 + size.len, size.v) / 1e9;
      }
      function keepWebM(store, b) {
        if (startsWith(b, [0x1a, 0x45, 0xdf, 0xa3])) {
          // The init segment, possibly with the first cluster after it.
          const cluster = indexOf(b, CLUSTER, 4);
          const init = cluster > 0 ? b.slice(0, cluster) : b;
          if (!same(store.init, init)) {
            store.init = init; store.timescale = tickSeconds(init);
            store.frags = []; store.bytes = 0; store.current = null;
          }
          if (cluster > 0) { keepWebM(store, b.slice(cluster)); }
          return;
        }
        if (!store.timescale) { return; }
        const ticks = startsWith(b, CLUSTER) ? clusterTicks(b) : null;
        if (ticks === null) { continueFragment(store, b); return; }
        addFragment(store, ticks * store.timescale, b);
      }

      function keep(store, data) {
        const b = bytesOf(data);
        if (!b || b.length < 4) { return; }
        if (store.kind === 'webm') { keepWebM(store, b); return; }
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
        if (ticks === null) { continueFragment(store, b); return; }
        addFragment(store, ticks / store.timescale, b);
      }

      // appendBuffer is hooked wherever the buffers really get it from. On
      // iPhone only ManagedMediaSource exists and SourceBuffer may not be a
      // global, so the buffer's own prototype chain is what counts.
      window.__irohaAppends = 0;
      function hookAppend(proto) {
        if (!proto || !Object.prototype.hasOwnProperty.call(proto, 'appendBuffer')) { return; }
        if (Object.prototype.hasOwnProperty.call(proto, '__irohaAppendHooked')) { return; }
        proto.__irohaAppendHooked = true;
        const append = proto.appendBuffer;
        proto.appendBuffer = function (data) {
          if (this.__irohaAudio) {
            window.__irohaAppends++;
            try { keep(storeFor(this), data); } catch (e) { window.__irohaKeepError = String(e && e.message || e); }
          }
          return append.apply(this, arguments);
        };
      }
      function hookChain(object) {
        let proto = Object.getPrototypeOf(object);
        while (proto && !Object.prototype.hasOwnProperty.call(proto, 'appendBuffer')) { proto = Object.getPrototypeOf(proto); }
        hookAppend(proto);
      }
      function hookSources(M) {
        if (!M || !M.prototype || Object.prototype.hasOwnProperty.call(M.prototype, '__irohaHooked')) { return; }
        M.prototype.__irohaHooked = true;
        const add = M.prototype.addSourceBuffer;
        if (typeof add !== 'function') { return; }
        M.prototype.addSourceBuffer = function (mime) {
          const buffer = add.apply(this, arguments);
          // ManagedMediaSource inherits MediaSource's: wrapped twice, seen once.
          if (!buffer || buffer.__irohaSeen) { return buffer; }
          buffer.__irohaSeen = true;
          try { hookChain(buffer); } catch (e) {}
          try {
            (window.__irohaMimes = window.__irohaMimes || []).push(String(mime).slice(0, 48));
            if (window.__irohaMimes.length > 6) { window.__irohaMimes.shift(); }
            if (/^audio\\//i.test(String(mime))) { buffer.__irohaAudio = /webm/i.test(String(mime)) ? 'webm' : 'mp4'; }
          } catch (e) {}
          return buffer;
        };
      }
      hookSources(window.MediaSource);
      hookSources(window.ManagedMediaSource);
      hookAppend(window.SourceBuffer && window.SourceBuffer.prototype);
      hookAppend(window.ManagedSourceBuffer && window.ManagedSourceBuffer.prototype);

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
                   '; buffers made: ' + ((window.__irohaMimes || []).join(' | ') || 'none') +
                   '; audio appends seen: ' + (window.__irohaAppends || 0) +
                   (window.__irohaKeepError ? '; keep error: ' + window.__irohaKeepError : '') + ')' };
        }
        const store = best.store;
        let size = store.init.length;
        for (let i = best.first; i <= best.last; i++) { size += store.frags[i].data.length; }
        const out = new Uint8Array(size);
        out.set(store.init);
        let offset = store.init.length;
        for (let i = best.first; i <= best.last; i++) { out.set(store.frags[i].data, offset); offset += store.frags[i].data.length; }
        return { data: base64(out), first: store.frags[best.first].t, kind: store.kind || 'mp4' };
      };
    })();
    """

    /// Styles the page down to the video and reports on it.
    static let controllerScript = """
    (function () {
      if (window.irohaPlayer) { return; }
      const css = [
        'html, body { background: #000 !important; overflow: hidden !important; }',
        // Nothing of the page but the player: its header and banners
        // flashed white as the page opened, before the player was found.
        'body { visibility: hidden !important; }',
        '.iroha-player { visibility: visible !important; }',
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
      // A report that says nothing new (paused, an ad's countdown aside) is
      // skipped, with one every two seconds anyway so the app never misses
      // a change.
      let lastReport = '', lastReportAt = 0;
      function post(message) {
        const report = JSON.stringify(message);
        const now = Date.now();
        if (report === lastReport && now - lastReportAt < 2000) { return; }
        lastReport = report; lastReportAt = now;
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

      function draw(v, width, canvas, quality) {
        if (!v || !v.videoWidth) { return null; }
        const scale = Math.min(1, width / v.videoWidth);
        const c = canvas || document.createElement('canvas');
        const w = Math.round(v.videoWidth * scale), h = Math.round(v.videoHeight * scale);
        if (c.width !== w) { c.width = w; }
        if (c.height !== h) { c.height = h; }
        c.getContext('2d').drawImage(v, 0, 0, w, h);
        try { return c.toDataURL('image/jpeg', quality || 0.8); } catch (e) { return null; }
      }
      // The miniplayer asks many times a second: one canvas, lighter JPEG.
      let miniCanvas = null;
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
        miniFrame: function (width) {
          if (!miniCanvas) { miniCanvas = document.createElement('canvas'); }
          return draw(video(), width, miniCanvas, 0.6);
        },
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

        // Plays the line once at normal speed for its GIF frames or
        // screenshot. (Its audio can't be recorded here: WebKit gives Web
        // Audio silence for this player, and routing the video through Web
        // Audio muted it. The audio comes from the buffer copy instead.)
        record: async function (start, end, fps, width, wantAudio, wantFrames, stillTime) {
          const v = video();
          if (!v) { return { error: 'no video' }; }
          const back = v.currentTime, wasPaused = v.paused, rate = v.playbackRate;
          v.pause();
          v.playbackRate = 1;
          await seekTo(v, start);
          unmute(v);
          const frames = [];
          let still = null, next = start;
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
            await wait(15);
          }
          v.pause();
          if (still === null && stillTime !== null) { still = draw(v, 960); }
          v.playbackRate = rate;
          await seekTo(v, back);
          if (!wasPaused) { v.play().catch(function () {}); }
          return { audio: null, frames: frames, still: still };
        }
      };
    })();
    """
}
