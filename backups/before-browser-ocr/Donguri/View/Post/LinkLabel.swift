//
//  LinkLabel.swift
//  Donguri
//
//  Short, readable names for links in posts: "Imgur", "X @user",
//  "YouTube", "Wikipedia: 東京", "5ch: <thread title>" instead of a long
//  URL. Worked out from the URL alone, with no network request, so it's
//  instant and doesn't contact sites you never tapped. Copying a post's
//  text still copies the real URLs.
//

import UIKit

enum LinkLabel {
    enum Kind {
        case link, image, video, thread

        var symbolName: String {
            switch self {
            case .link: "link"
            case .image: "photo"
            case .video: "play.rectangle"
            case .thread: "text.bubble"
            }
        }
    }

    private static let maxLength = 34
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "avif"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 2000
        return cache
    }()

    private final class Box {
        let label: String
        let kind: Kind
        init(label: String, kind: Kind) {
            self.label = label
            self.kind = kind
        }
    }

    static func describe(_ url: URL) -> (label: String, kind: Kind) {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return (cached.label, cached.kind) }
        var result = make(url)
        if result.label.count > maxLength {
            result.label = String(result.label.prefix(maxLength - 1)) + "…"
        }
        cache.setObject(Box(label: result.label, kind: result.kind), forKey: key)
        return result
    }

    private static func make(_ url: URL) -> (label: String, kind: Kind) {
        guard var host = url.host?.lowercased() else { return (url.absoluteString, .link) }
        for prefix in ["www.", "m.", "mobile.", "sp."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        let path = url.pathComponents.filter { $0 != "/" }
        let ext = url.pathExtension.lowercased()
        let mediaKind: Kind = imageExtensions.contains(ext) ? .image : videoExtensions.contains(ext) ? .video : .link

        // Another 5ch thread: its title if it's been opened before.
        if let route = ThreadRoute.parse(url) {
            let key = ReadStateStore.key(boardURL: route.boardURL, threadId: route.threadId)
            if let title = HistoryStore.shared.entries.first(where: { $0.id == key })?.title {
                return ("5ch: " + title, .thread)
            }
            let board = path.count >= 3 ? path[path.count - 2] : BoardNames.fallback(for: route.boardURL)
            return ("5ch /\(board)/", .thread)
        }

        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

        switch true {
        case matches("imgur.com"):
            return ("Imgur", mediaKind == .link ? .image : mediaKind)
        case matches("x.com"), matches("twitter.com"), matches("fxtwitter.com"), matches("vxtwitter.com"), matches("fixupx.com"):
            if host.hasPrefix("pbs.") || host.hasPrefix("video.") { return ("X", mediaKind) }
            if let user = path.first, !["i", "search", "hashtag", "home"].contains(user) { return ("X @" + user, .link) }
            return ("X", .link)
        case matches("twimg.com"):
            return ("X", mediaKind == .link ? .image : mediaKind)
        case matches("youtube.com"), matches("youtu.be"):
            return (path.first == "shorts" ? "YouTube Shorts" : "YouTube", .video)
        case matches("nicovideo.jp"), matches("nico.ms"):
            return ("ニコニコ動画", .video)
        case matches("tiktok.com"):
            return ("TikTok", .video)
        case matches("twitch.tv"):
            return ("Twitch", .video)
        case matches("wikipedia.org"):
            if path.first == "wiki", let article = path.last, path.count >= 2 {
                return ("Wikipedia: " + (article.removingPercentEncoding ?? article).replacingOccurrences(of: "_", with: " "), .link)
            }
            return ("Wikipedia", .link)
        case matches("bsky.app"):
            if path.first == "profile", path.count >= 2 { return ("Bluesky @" + path[1], .link) }
            return ("Bluesky", .link)
        case matches("instagram.com"):
            return ("Instagram", .link)
        case matches("reddit.com"):
            if path.first == "r", path.count >= 2 { return ("Reddit r/" + path[1], .link) }
            return ("Reddit", .link)
        case matches("github.com"):
            if path.count >= 2 { return ("GitHub: \(path[0])/\(path[1])", .link) }
            return ("GitHub", .link)
        case matches("pixiv.net"):
            return ("pixiv", .link)
        case matches("amazon.co.jp"), matches("amazon.com"), matches("amzn.to"), matches("amzn.asia"):
            return ("Amazon", .link)
        case matches("news.yahoo.co.jp"):
            return ("Yahoo!ニュース", .link)
        case matches("nhk.or.jp"):
            return ("NHK", .link)
        case matches("google.com") && path.first == "maps", matches("goo.gl") && path.first == "maps":
            return ("Google マップ", .link)
        case matches("5ch.io"), matches("5ch.net"):
            return ("5ch", .link)
        default:
            // The site itself, and a hint that there's more after it.
            return (path.isEmpty ? host : host + "/…", mediaKind)
        }
    }

    /// The link drawn in a post: a small symbol, then the short label.
    static func attributed(for url: URL, attributes: [NSAttributedString.Key: Any],
                           font: UIFont, color: UIColor) -> NSAttributedString {
        let (label, kind) = describe(url)
        let result = NSMutableAttributedString()
        let configuration = UIImage.SymbolConfiguration(pointSize: font.pointSize * 0.8, weight: .medium)
        if let symbol = UIImage(systemName: kind.symbolName, withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal) {
            let attachment = NSTextAttachment(image: symbol)
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - symbol.size.height) / 2,
                                       width: symbol.size.width, height: symbol.size.height)
            let symbolString = NSMutableAttributedString(attachment: attachment)
            symbolString.addAttributes(attributes, range: NSRange(location: 0, length: symbolString.length))
            result.append(symbolString)
            result.append(NSAttributedString(string: "\u{2009}", attributes: attributes))
        }
        result.append(NSAttributedString(string: label, attributes: attributes))
        return result
    }
}
