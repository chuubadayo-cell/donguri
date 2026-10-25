//
//  YouTubeClient.swift
//  Donguri
//
//  Talks to YouTube the way its own website does (the "InnerTube" API),
//  signed in with the cookies the browser tab already has: the home feed,
//  subscriptions, history, search, and for each video its player data and
//  subtitles.
//
//  Video plays natively from the HLS stream YouTube gives Safari, which
//  needs no extra tokens. Subtitles come from the caption track if YouTube
//  hands it over, else from the transcript panel, else from YouTube's own
//  player run in a hidden web view (CaptionSniffer).
//

import Foundation
import WebKit
import CryptoKit

@MainActor
final class YouTubeClient {
    static let shared = YouTubeClient()

    /// Desktop Safari: YouTube gives Safari HLS streams, which AVPlayer
    /// plays directly.
    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
    private static let origin = "https://www.youtube.com"

    private struct Config {
        var apiKey: String?
        var clientVersion: String
        var visitorData: String?
        var loggedIn: Bool
    }

    private var config: Config?
    private var configLoadedAt = Date.distantPast
    private let session: URLSession

    enum Feed: String, CaseIterable, Identifiable {
        case home, subscriptions, history, watchLater
        var id: String { rawValue }

        var browseID: String {
            switch self {
            case .home: "FEwhat_to_watch"
            case .subscriptions: "FEsubscriptions"
            case .history: "FEhistory"
            case .watchLater: "VLWL"
            }
        }
    }

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    // MARK: Account

    private func cookies() async -> [HTTPCookie] {
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return all.filter { $0.domain.hasSuffix("youtube.com") }
    }

    var isSignedIn: Bool { config?.loggedIn ?? false }

    /// Forgets the cached page config, after signing in or out.
    func reset() {
        config = nil
    }

    private func loadConfig() async throws -> Config {
        if let config, Date.now.timeIntervalSince(configLoadedAt) < 3600 { return config }
        let html = try await page(URL(string: "https://www.youtube.com/?hl=ja&gl=JP")!)
        func value(_ key: String) -> String? {
            guard let range = html.range(of: "\"\(key)\":\"") else { return nil }
            let rest = html[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        let loaded = Config(apiKey: value("INNERTUBE_API_KEY"),
                            clientVersion: value("INNERTUBE_CLIENT_VERSION") ?? "2.20251020.01.00",
                            visitorData: value("VISITOR_DATA"),
                            loggedIn: html.contains("\"LOGGED_IN\":true"))
        config = loaded
        configLoadedAt = .now
        return loaded
    }

    /// Signed in if Google's session cookies for YouTube are there. The
    /// page's own LOGGED_IN flag is also asked, but it depends on how the
    /// page is served, so the cookies decide.
    func refreshSignInState() async -> Bool {
        config = nil
        let jar = await cookies()
        let names = Set(jar.map(\.name))
        let hasSession = names.contains("SAPISID") || names.contains("__Secure-3PAPISID") || names.contains("LOGIN_INFO")
        let pageSaysSignedIn = (try? await loadConfig())?.loggedIn ?? false
        print("[iroha] YouTube sign-in: cookies=\(hasSession) page=\(pageSaysSignedIn) (\(jar.count) cookies)")
        if hasSession, var config, !config.loggedIn {
            config.loggedIn = true
            self.config = config
        }
        return hasSession || pageSaysSignedIn
    }

    // MARK: Requests

    private func page(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("ja,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        await addCookies(to: &request)
        let (data, _) = try await session.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }

    private func addCookies(to request: inout URLRequest) async {
        let jar = await cookies()
        var header = jar.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        // Skips the cookie-consent interstitial where it applies.
        if !jar.contains(where: { $0.name == "SOCS" }) {
            header += (header.isEmpty ? "" : "; ") + "SOCS=CAI"
        }
        request.setValue(header, forHTTPHeaderField: "Cookie")
        if let auth = Self.authorization(jar) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        }
    }

    /// The SAPISIDHASH header YouTube's site sends when signed in.
    private static func authorization(_ jar: [HTTPCookie]) -> String? {
        func cookie(_ name: String) -> String? { jar.first { $0.name == name }?.value }
        let timestamp = Int(Date.now.timeIntervalSince1970)
        func hash(_ secret: String) -> String {
            let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(secret) \(origin)".utf8))
            return "\(timestamp)_" + digest.map { String(format: "%02x", $0) }.joined()
        }
        var parts: [String] = []
        if let sapisid = cookie("SAPISID") ?? cookie("__Secure-3PAPISID") {
            parts.append("SAPISIDHASH \(hash(sapisid))")
        }
        if let first = cookie("__Secure-1PAPISID") { parts.append("SAPISID1PHASH \(hash(first))") }
        if let third = cookie("__Secure-3PAPISID") { parts.append("SAPISID3PHASH \(hash(third))") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func innertube(_ endpoint: String, body: [String: Any]) async throws -> Data {
        let config = try await loadConfig()
        var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/\(endpoint)")!
        var query = [URLQueryItem(name: "prettyPrint", value: "false")]
        if let key = config.apiKey { query.append(URLQueryItem(name: "key", value: key)) }
        components.queryItems = query

        var client: [String: Any] = [
            "clientName": "WEB",
            "clientVersion": config.clientVersion,
            "hl": "ja",
            "gl": "JP",
            "userAgent": Self.userAgent,
            "browserName": "Safari",
            "browserVersion": "18.5",
            "osName": "Macintosh",
            "osVersion": "10_15_7",
            "platform": "DESKTOP",
        ]
        if let visitor = config.visitorData { client["visitorData"] = visitor }
        var payload = body
        payload["context"] = ["client": client, "user": ["lockedSafetyMode": false]]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(config.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
        request.setValue("ja,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let visitor = config.visitorData { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        await addCookies(to: &request)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            print("[iroha] InnerTube \(endpoint) HTTP \(http.statusCode): \(String(decoding: data.prefix(300), as: UTF8.self))")
            throw URLError(.badServerResponse)
        }
        print("[iroha] InnerTube \(endpoint) \(data.count) bytes")
        return data
    }

    // MARK: Feeds

    func feed(_ feed: Feed) async throws -> YTFeedPage {
        let data = try await innertube("browse", body: ["browseId": feed.browseID])
        return try await Self.parseFeed(data)
    }

    func search(_ query: String) async throws -> YTFeedPage {
        let data = try await innertube("search", body: ["query": query])
        return try await Self.parseFeed(data)
    }

    func channel(_ channelID: String) async throws -> YTFeedPage {
        // The channel's 動画 tab.
        let data = try await innertube("browse", body: ["browseId": channelID, "params": "EgZ2aWRlb3PyBgQKAjoA"])
        return try await Self.parseFeed(data)
    }

    /// The next page of a feed or search.
    func more(_ token: String, isSearch: Bool) async throws -> YTFeedPage {
        let data = try await innertube(isSearch ? "search" : "browse", body: ["continuation": token])
        return try await Self.parseFeed(data)
    }

    /// Videos to watch next.
    func related(_ videoID: String) async throws -> YTFeedPage {
        let data = try await innertube("next", body: ["videoId": videoID])
        var page = try await Self.parseFeed(data)
        page.videos.removeAll { $0.id == videoID }
        return page
    }

    @concurrent
    private nonisolated static func parseFeed(_ data: Data) async throws -> YTFeedPage {
        let json = try JSONSerialization.jsonObject(with: data)
        return YTParse.feed(json)
    }

    // MARK: Videos

    func playerInfo(_ videoID: String) async throws -> YTPlayerInfo {
        var components = URLComponents(string: "https://www.youtube.com/watch")!
        components.queryItems = [
            URLQueryItem(name: "v", value: videoID),
            URLQueryItem(name: "hl", value: "ja"),
            URLQueryItem(name: "gl", value: "JP"),
            URLQueryItem(name: "has_verified", value: "1"),
            URLQueryItem(name: "bpctr", value: "9999999999"),
        ]
        let html = try await page(components.url!)
        var info = await Self.parsePlayer(html: html, videoID: videoID)
        if info?.hlsURL == nil || info?.playable == false {
            // The player endpoint, asked directly as Safari.
            if let data = try? await innertube("player", body: ["videoId": videoID, "contentCheckOk": true, "racyCheckOk": true]),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                var fromAPI = YTParse.playerInfo(from: json, videoID: videoID, html: nil)
                if fromAPI.hlsURL != nil || info == nil {
                    fromAPI.transcriptParams = info?.transcriptParams
                    info = fromAPI
                }
            }
        }
        guard let info else { throw URLError(.cannotParseResponse) }
        print("[iroha] player \(videoID): playable=\(info.playable) hls=\(info.hlsURL != nil) tracks=\(info.captionTracks.count) reason=\(info.reason ?? "-")")
        return info
    }

    @concurrent
    private nonisolated static func parsePlayer(html: String, videoID: String) async -> YTPlayerInfo? {
        guard let response = YTParse.embeddedJSON(named: "ytInitialPlayerResponse", in: html) as? [String: Any] else {
            return nil
        }
        return YTParse.playerInfo(from: response, videoID: videoID, html: html)
    }

    // MARK: Subtitles

    /// A caption track, by whichever route works for this video.
    func subtitles(for info: YTPlayerInfo, track: YTCaptionTrack?) async -> [SubtitleCue]? {
        if let track, let cues = await timedText(track) { return cues }
        // The transcript panel (the video's default track).
        if track == nil || track == Self.defaultTrack(in: info.captionTracks),
           let params = info.transcriptParams,
           let data = try? await innertube("get_transcript", body: ["params": params]),
           let json = try? JSONSerialization.jsonObject(with: data),
           let cues = YTParse.transcriptCues(json) {
            return cues
        }
        // YouTube's own player, which can get past its token check.
        guard let track else { return nil }
        return await CaptionSniffer.captions(videoID: info.videoID, languageCode: track.languageCode,
                                             automatic: track.isAutomatic)
    }

    private func timedText(_ track: YTCaptionTrack) async -> [SubtitleCue]? {
        guard var components = URLComponents(string: track.baseURL) else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name != "fmt" }
        items.append(URLQueryItem(name: "fmt", value: "json3"))
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        await addCookies(to: &request)
        guard let (data, _) = try? await session.data(for: request), !data.isEmpty else { return nil }
        return YTParse.json3Cues(data) ?? YTParse.xmlCues(String(decoding: data, as: UTF8.self))
    }

    /// Japanese written by a person, else Japanese automatic captions,
    /// else the first track.
    static func defaultTrack(in tracks: [YTCaptionTrack]) -> YTCaptionTrack? {
        let japanese = tracks.filter { $0.languageCode.hasPrefix("ja") }
        return japanese.first { !$0.isAutomatic } ?? japanese.first ?? tracks.first { !$0.isAutomatic } ?? tracks.first
    }

    static func videoID(in url: URL) -> String? {
        LinkPreviewService.youTubeID(in: url)
    }
}

// MARK: - Captions through YouTube's own player

/// Some caption tracks only answer requests carrying a token that
/// YouTube's player makes at run time. This loads the video's page in a
/// hidden web view, turns captions on through the player, and keeps the
/// caption data the player fetches.
@MainActor
final class CaptionSniffer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[SubtitleCue]?, Never>?
    private let videoID: String
    private let languageCode: String
    private let automatic: Bool
    private static var running: Set<CaptionSniffer> = []

    private init(videoID: String, languageCode: String, automatic: Bool) {
        self.videoID = videoID
        self.languageCode = languageCode
        self.automatic = automatic
    }

    static func captions(videoID: String, languageCode: String, automatic: Bool) async -> [SubtitleCue]? {
        let sniffer = CaptionSniffer(videoID: videoID, languageCode: languageCode, automatic: automatic)
        running.insert(sniffer)
        defer { running.remove(sniffer) }
        return await sniffer.run()
    }

    /// Watches the page's own requests for caption data.
    private static let hook = """
    (function () {
      function report(url, text) {
        try { webkit.messageHandlers.irohaCaptions.postMessage({ url: String(url), text: text }); } catch (e) {}
      }
      const fetchOriginal = window.fetch;
      window.fetch = function (input, init) {
        const url = typeof input === 'string' ? input : (input && input.url) || '';
        const result = fetchOriginal.apply(this, arguments);
        if (url.indexOf('/api/timedtext') >= 0) {
          result.then(function (r) { return r.clone().text(); }).then(function (t) { report(url, t); }).catch(function () {});
        }
        return result;
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__irohaURL = url;
        return open.apply(this, arguments);
      };
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function () {
        const xhr = this;
        if (String(xhr.__irohaURL || '').indexOf('/api/timedtext') >= 0) {
          xhr.addEventListener('load', function () {
            try { report(xhr.__irohaURL, xhr.responseText); } catch (e) {}
          });
        }
        return send.apply(this, arguments);
      };
    })();
    """

    private func run() async -> [SubtitleCue]? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            configuration.allowsInlineMediaPlayback = true
            let controller = configuration.userContentController
            controller.addUserScript(WKUserScript(source: Self.hook, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: .page))
            controller.add(WeakMessageHandler(self), contentWorld: .page, name: "irohaCaptions")
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 360), configuration: configuration)
            webView.customUserAgent = YouTubeClient.userAgent
            webView.navigationDelegate = self
            self.webView = webView
            webView.load(URLRequest(url: URL(string: "https://www.youtube.com/watch?v=\(videoID)&hl=ja")!))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.finish(nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Turn captions on in the requested language; the player then
        // fetches them, and the hook above hears it.
        let script = """
        (function () {
          let tries = 0;
          const timer = setInterval(function () {
            tries++;
            const p = document.getElementById('movie_player');
            if (!p || !p.setOption) { if (tries > 40) clearInterval(timer); return; }
            try { p.mute && p.mute(); } catch (e) {}
            try { p.loadModule && p.loadModule('captions'); } catch (e) {}
            let list = [];
            try { list = p.getOption('captions', 'tracklist') || []; } catch (e) {}
            if (!list.length && tries < 40) { return; }
            clearInterval(timer);
            const wanted = list.find(function (t) { return t.languageCode === '\(languageCode)' && (\(automatic) ? t.kind === 'asr' : t.kind !== 'asr'); })
              || list.find(function (t) { return t.languageCode === '\(languageCode)'; }) || list[0];
            try { p.setOption('captions', 'track', wanted || { languageCode: '\(languageCode)' }); } catch (e) {}
            try { p.playVideo && p.playVideo(); setTimeout(function () { p.pauseVideo && p.pauseVideo(); }, 1500); } catch (e) {}
          }, 250);
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let text = body["text"] as? String, !text.isEmpty else { return }
        let cues = YTParse.json3Cues(Data(text.utf8)) ?? YTParse.xmlCues(text)
        if let cues, !cues.isEmpty { finish(cues) }
    }

    private func finish(_ cues: [SubtitleCue]?) {
        guard let continuation else { return }
        self.continuation = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
        continuation.resume(returning: cues)
    }
}

/// Script message handlers are retained by WebKit; this keeps that from
/// becoming a cycle.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
