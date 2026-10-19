//
//  LinkPreviewService.swift
//  Donguri
//
//  Embeds for links in posts: what a YouTube video, a tweet, a ニコニコ動画
//  video or any web page is, fetched once and kept.
//   - YouTube: YouTube's own oEmbed endpoint (title, channel, thumbnail).
//   - X/Twitter: FxTwitter's API (api.fxtwitter.com), the service most
//     Discord/Telegram previews use. Unofficial; when it fails the card
//     falls back to a plain link.
//   - ニコニコ動画: Niconico's getthumbinfo API.
//   - Anything else: the page's Open Graph / Twitter Card tags.
//  Previews are cached in memory and on disk, so a thread opened again
//  shows them without asking any site again.
//

import Foundation
import CryptoKit

nonisolated struct LinkPreview: Codable, Sendable, Hashable {
    nonisolated enum Kind: String, Codable, Sendable {
        case youtube, tweet, niconico, page
    }

    var kind: Kind
    var url: URL
    var title: String?
    /// Channel, author name, or site name.
    var subtitle: String?
    /// Tweet text, or the page's description.
    var text: String?
    var thumbnailURL: URL?
    var avatarURL: URL?
    /// Tweet media: images, and videos as (video, thumbnail) pairs.
    var images: [URL] = []
    var videos: [URL] = []
    var videoThumbnails: [URL] = []
    /// "1.2万回再生", "♥ 340" …
    var detail: String?
    var siteName: String?
    /// The YouTube video id, for the in-app player.
    var videoID: String?
}

/// When previews load.
enum LinkPreviewMode: String, CaseIterable, Identifiable {
    case off
    /// Automatically on Wi-Fi; tap to load on mobile data.
    case wifi
    case always
    case tap

    static let defaultsKey = "donguri.linkPreviewMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "表示しない")
        case .wifi: String(localized: "Wi-Fi時は自動")
        case .always: String(localized: "常に自動")
        case .tap: String(localized: "タップで読み込む")
        }
    }

    /// Whether a preview may load without a tap right now.
    var loadsAutomatically: Bool {
        switch self {
        case .off, .tap: false
        case .always: true
        case .wifi: !NetworkMonitor.shared.isExpensive
        }
    }
}

actor LinkPreviewService {
    nonisolated static let shared = LinkPreviewService()

    /// Links per post that get a card.
    nonisolated static let maxPerPost = 3

    private var memory: [URL: LinkPreview] = [:]
    /// URLs that failed, so scrolling past them doesn't retry every time.
    private var failed: Set<URL> = []
    private var inFlight: [URL: Task<LinkPreview?, Never>] = [:]

    // MARK: Which links

    nonisolated(unsafe) private static let urlCache: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 3000
        return cache
    }()

    /// The links in a post worth a card, in order, without duplicates:
    /// not images or videos (those are thumbnails already), not 5ch.
    nonisolated static func previewableURLs(in text: String) -> [URL] {
        guard text.contains("ttp") else { return [] }
        let key = text as NSString
        if let cached = urlCache.object(forKey: key) as? [URL] { return cached }

        var urls: [URL] = []
        for match in text.matches(of: #/h?ttps?:\/\/[^\s<>"'\]\)]+/#) {
            var raw = String(match.0)
            if raw.hasPrefix("ttp") { raw = "h" + raw }
            guard let url = URL(string: raw), let host = url.host?.lowercased(),
                  !urls.contains(url) else { continue }
            let ext = url.pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "avif", "mp4", "mov", "m4v", "webm"].contains(ext) { continue }
            if host.contains(".5ch.") || host.hasSuffix("5ch.io") || host.hasSuffix("5ch.net") || host.hasSuffix("bbspink.com") { continue }
            if host.hasPrefix("i.imgur.") || host.hasSuffix("twimg.com") { continue }
            urls.append(url)
            if urls.count == maxPerPost { break }
        }
        urlCache.setObject(urls as NSArray, forKey: key)
        return urls
    }

    nonisolated static func kind(of url: URL) -> LinkPreview.Kind {
        if youTubeID(in: url) != nil { return .youtube }
        if tweetPath(in: url) != nil { return .tweet }
        if nicoID(in: url) != nil { return .niconico }
        return .page
    }

    // MARK: Cache

    /// Already known, without fetching (memory, then disk).
    func cached(_ url: URL) -> LinkPreview? {
        if let preview = memory[url] { return preview }
        guard let file = Self.file(for: url), let data = try? Data(contentsOf: file),
              let preview = try? JSONDecoder().decode(LinkPreview.self, from: data) else { return nil }
        memory[url] = preview
        return preview
    }

    func hasFailed(_ url: URL) -> Bool { failed.contains(url) }

    func preview(for url: URL) async -> LinkPreview? {
        if let known = cached(url) { return known }
        if failed.contains(url) { return nil }
        if let running = inFlight[url] { return await running.value }
        let task = Task { await Self.fetch(url) }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if let result {
            memory[url] = result
            if let file = Self.file(for: url), let data = try? JSONEncoder().encode(result) {
                try? data.write(to: file, options: .atomic)
            }
        } else {
            failed.insert(url)
        }
        return result
    }

    func retry(_ url: URL) {
        failed.remove(url)
    }

    func clear() {
        memory.removeAll()
        failed.removeAll()
        if let folder = Self.folder { try? FileManager.default.removeItem(at: folder) }
    }

    private nonisolated static var folder: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("LinkPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private nonisolated static func file(for url: URL) -> URL? {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(name + ".json")
    }

    // MARK: Fetching

    private nonisolated static func fetch(_ url: URL) async -> LinkPreview? {
        switch kind(of: url) {
        case .youtube: await fetchYouTube(url)
        case .tweet: await fetchTweet(url)
        case .niconico: await fetchNico(url)
        case .page: await fetchPage(url)
        }
    }

    private nonisolated struct Fetched: Sendable {
        let data: Data
        let response: HTTPURLResponse
    }

    private nonisolated static func get(_ url: URL, userAgent: String? = nil) async -> Fetched? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        request.setValue("ja,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        guard let result = try? await URLSession.shared.data(for: request),
              let http = result.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return Fetched(data: result.0, response: http)
    }

    // YouTube

    nonisolated static func youTubeID(in url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        if host.hasSuffix("youtu.be") { return path.first }
        guard host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") else { return nil }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
            return v
        }
        if path.count >= 2, ["shorts", "live", "embed", "v"].contains(path[0]) { return path[1] }
        return nil
    }

    private nonisolated static func fetchYouTube(_ url: URL) async -> LinkPreview? {
        guard let id = youTubeID(in: url) else { return nil }
        var preview = LinkPreview(kind: .youtube, url: url, siteName: "YouTube", videoID: id)
        preview.thumbnailURL = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        var components = URLComponents(string: "https://www.youtube.com/oembed")
        components?.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(id)"),
                                  URLQueryItem(name: "format", value: "json")]
        if let oembed = components?.url, let fetched = await get(oembed),
           let json = try? JSONSerialization.jsonObject(with: fetched.data) as? [String: Any] {
            preview.title = json["title"] as? String
            preview.subtitle = json["author_name"] as? String
            if let thumb = (json["thumbnail_url"] as? String).flatMap(URL.init(string:)) {
                preview.thumbnailURL = thumb
            }
        }
        // A private or deleted video has no oEmbed; still worth a card.
        if preview.title == nil { preview.title = String(localized: "YouTubeの動画") }
        return preview
    }

    // X / Twitter (FxTwitter)

    /// "user/status/123" for a tweet link.
    nonisolated static func tweetPath(in url: URL) -> (user: String, id: String)? {
        guard let host = url.host?.lowercased() else { return nil }
        let hosts = ["x.com", "twitter.com", "fxtwitter.com", "vxtwitter.com", "fixupx.com", "fixvx.com", "nitter.net"]
        guard hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        guard let statusIndex = path.firstIndex(where: { $0 == "status" || $0 == "statuses" }),
              statusIndex >= 1, path.count > statusIndex + 1 else { return nil }
        let id = String(path[statusIndex + 1].prefix { $0.isNumber })
        guard !id.isEmpty else { return nil }
        return (path[statusIndex - 1], id)
    }

    private nonisolated static func fetchTweet(_ url: URL) async -> LinkPreview? {
        guard let path = tweetPath(in: url),
              let api = URL(string: "https://api.fxtwitter.com/\(path.user)/status/\(path.id)"),
              let fetched = await get(api, userAgent: "iroha-5ch-reader (link preview)"),
              let json = try? JSONSerialization.jsonObject(with: fetched.data) as? [String: Any],
              let tweet = json["tweet"] as? [String: Any] else { return nil }

        var preview = LinkPreview(kind: .tweet, url: url, siteName: "X")
        let author = tweet["author"] as? [String: Any]
        preview.title = author?["name"] as? String
        if let handle = author?["screen_name"] as? String { preview.subtitle = "@" + handle }
        preview.avatarURL = (author?["avatar_url"] as? String).flatMap(URL.init(string:))
        preview.text = (tweet["raw_text"] as? [String: Any])?["text"] as? String ?? tweet["text"] as? String

        let media = tweet["media"] as? [String: Any]
        for photo in media?["photos"] as? [[String: Any]] ?? [] {
            if let url = (photo["url"] as? String).flatMap(URL.init(string:)) { preview.images.append(url) }
        }
        for video in media?["videos"] as? [[String: Any]] ?? [] {
            guard let url = (video["url"] as? String).flatMap(URL.init(string:)) else { continue }
            preview.videos.append(url)
            if let thumb = (video["thumbnail_url"] as? String).flatMap(URL.init(string:)) {
                preview.videoThumbnails.append(thumb)
            }
        }
        preview.thumbnailURL = preview.images.first ?? preview.videoThumbnails.first

        var details: [String] = []
        if let replies = tweet["replies"] as? Int { details.append("💬 \(compact(replies))") }
        if let retweets = tweet["retweets"] as? Int { details.append("🔁 \(compact(retweets))") }
        if let likes = tweet["likes"] as? Int { details.append("♥ \(compact(likes))") }
        if let timestamp = tweet["created_timestamp"] as? Double {
            details.append(Date(timeIntervalSince1970: timestamp).formatted(date: .numeric, time: .omitted))
        }
        preview.detail = details.isEmpty ? nil : details.joined(separator: "  ")

        // A quote-tweet with no text of its own: show what it quotes.
        if (preview.text ?? "").isEmpty, let quote = tweet["quote"] as? [String: Any] {
            preview.text = quote["text"] as? String
        }
        return preview
    }

    private nonisolated static func compact(_ number: Int) -> String {
        if number >= 10_000 {
            return String(format: "%.1f万", Double(number) / 10_000).replacingOccurrences(of: ".0万", with: "万")
        }
        return number.formatted()
    }

    // ニコニコ動画

    nonisolated static func nicoID(in url: URL) -> String? {
        guard let host = url.host?.lowercased(), host.hasSuffix("nicovideo.jp") || host.hasSuffix("nico.ms") else { return nil }
        let last = url.lastPathComponent
        guard let match = last.firstMatch(of: #/^(sm|so|nm)\d+$/#) else { return nil }
        return String(match.0)
    }

    private nonisolated static func fetchNico(_ url: URL) async -> LinkPreview? {
        guard let id = nicoID(in: url),
              let api = URL(string: "https://ext.nicovideo.jp/api/getthumbinfo/\(id)"),
              let fetched = await get(api),
              let xml = String(data: fetched.data, encoding: .utf8) else { return nil }
        func tag(_ name: String) -> String? {
            guard let start = xml.range(of: "<\(name)>"),
                  let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else { return nil }
            return String(xml[start.upperBound..<end.lowerBound]).htmlDecoded
        }
        guard let title = tag("title") else { return nil }
        var preview = LinkPreview(kind: .niconico, url: url, siteName: String(localized: "ニコニコ動画"))
        preview.title = title
        preview.subtitle = tag("user_nickname") ?? tag("ch_name")
        preview.thumbnailURL = tag("thumbnail_url").flatMap { URL(string: $0 + ".M") ?? URL(string: $0) }
        if let views = tag("view_counter").flatMap(Int.init) {
            preview.detail = String(localized: "\(compact(views))回再生")
        }
        return preview
    }

    // Any page: Open Graph

    private nonisolated static func fetchPage(_ url: URL) async -> LinkPreview? {
        // Sites serve their preview tags to link-preview crawlers.
        guard let fetched = await get(url, userAgent: "Mozilla/5.0 (compatible; facebookexternalhit/1.1; iroha)"),
              (fetched.response.mimeType ?? "text/html").contains("html") else { return nil }
        let response = fetched.response
        let head = fetched.data.prefix(400_000)
        let html = decode(Data(head), response: response)
        var meta: [String: String] = [:]
        for match in html.matches(of: #/(?is)<meta\s[^>]*>/#) {
            let tag = String(match.0)
            guard let name = attribute("property", in: tag) ?? attribute("name", in: tag),
                  let content = attribute("content", in: tag) else { continue }
            let key = name.lowercased()
            if meta[key] == nil { meta[key] = content.htmlDecoded }
        }
        let titleTag = html.firstMatch(of: #/(?is)<title[^>]*>(.*?)</title>/#).map {
            String($0.1).htmlDecoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let title = meta["og:title"] ?? meta["twitter:title"] ?? titleTag
        guard let title, !title.isEmpty else { return nil }

        var preview = LinkPreview(kind: .page, url: url)
        preview.title = title
        preview.text = meta["og:description"] ?? meta["twitter:description"] ?? meta["description"]
        preview.siteName = meta["og:site_name"] ?? url.host?.replacingOccurrences(of: "www.", with: "")
        if let image = meta["og:image"] ?? meta["og:image:url"] ?? meta["twitter:image"] ?? meta["twitter:image:src"] {
            preview.thumbnailURL = URL(string: image, relativeTo: response.url ?? url)?.absoluteURL
        }
        return preview
    }

    private nonisolated static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "(?i)\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in [2, 3] {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }

    /// Japanese sites still use Shift_JIS and EUC-JP; read the charset from
    /// the header or the page before falling back to UTF-8.
    private nonisolated static func decode(_ data: Data, response: HTTPURLResponse) -> String {
        var charset = response.textEncodingName
        if charset == nil, let sniff = String(data: data.prefix(4096), encoding: .ascii) ?? String(data: data.prefix(4096), encoding: .isoLatin1),
           let match = sniff.firstMatch(of: #/(?i)charset=["']?([A-Za-z0-9_\-]+)/#) {
            charset = String(match.1)
        }
        if let charset {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return String(data: data, encoding: .utf8) ?? ShiftJIS.decode(data) ?? String(decoding: data, as: UTF8.self)
    }
}
