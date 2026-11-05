//
//  YouTubeModels.swift
//  Donguri
//
//  What いろは knows about YouTube videos, feeds and subtitles, and the
//  parsing of YouTube's own (InnerTube) responses into it. YouTube's JSON
//  changes shape often, so the parsing walks the whole response looking
//  for the few kinds of item it understands, rather than following one
//  exact path.
//

import Foundation

nonisolated struct YTVideo: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let title: String
    var channel: String?
    var channelID: String?
    var duration: String?
    /// Views and age, already formatted by YouTube ("12万 回視聴 · 3 日前").
    var meta: String?
    var thumbnail: URL?
    /// YouTube's own 興味なし for this video in this feed (its menu's
    /// feedback token), when the feed offers one.
    var notInterestedToken: String?

    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
}

nonisolated struct YTFeedPage: Sendable {
    var videos: [YTVideo] = []
    var continuation: String?
}

/// The watch page's data beyond the player: what to watch next, and the
/// signed-in account's like and subscription for this video.
nonisolated struct YTWatchNext: Sendable {
    var page: YTFeedPage
    var liked: Bool?
    var likeCount: Int?
    var subscribed: Bool?
    var subscriberText: String?
    /// Where the comments start, and how many there are ("1,234").
    var commentsToken: String?
    var commentCount: String?
}

/// A comment or a reply.
nonisolated struct YTComment: Identifiable, Hashable, Sendable {
    let id: String
    var author: String
    var authorPhoto: URL?
    var text: String
    var published: String?
    var likes: String?
    var replyCount: Int = 0
    /// Loads this comment's replies.
    var repliesToken: String?
}

nonisolated struct YTCommentPage: Sendable {
    var comments: [YTComment] = []
    var continuation: String?
}

nonisolated struct YTCaptionTrack: Hashable, Sendable, Identifiable {
    let baseURL: String
    let languageCode: String
    let name: String
    let isAutomatic: Bool
    var id: String { baseURL }
}

nonisolated struct YTPlayerInfo: Sendable {
    let videoID: String
    var title: String
    var channel: String
    var channelID: String?
    var duration: Double
    var hlsURL: URL?
    var captionTracks: [YTCaptionTrack]
    /// For the transcript panel's endpoint, which needs no token.
    var transcriptParams: String?
    var isLive: Bool
    var playable: Bool
    var reason: String?
    var viewCount: String?
    var description: String?
    /// The day it was published, from the page's microformat.
    var publishDate: Date? = nil
}

/// One subtitle line.
nonisolated struct SubtitleCue: Identifiable, Hashable, Sendable {
    let id: Int
    var start: Double
    var end: Double
    var text: String

    var timeLabel: String {
        let total = Int(start)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Parsing

nonisolated enum YTParse {
    /// Text from YouTube's text objects: `simpleText`, `runs`, or the newer
    /// view models' `content`.
    static func text(_ node: Any?) -> String? {
        guard let dictionary = node as? [String: Any] else { return node as? String }
        if let simple = dictionary["simpleText"] as? String { return simple }
        if let runs = dictionary["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        if let content = dictionary["content"] as? String { return content }
        return nil
    }

    static func url(_ string: String?) -> URL? {
        guard var string, !string.isEmpty else { return nil }
        if string.hasPrefix("//") { string = "https:" + string }
        return URL(string: string)
    }

    /// The best thumbnail in a `{thumbnails: [{url, width}]}` object.
    static func thumbnail(_ node: Any?) -> URL? {
        guard let dictionary = node as? [String: Any],
              let list = (dictionary["thumbnails"] ?? dictionary["sources"]) as? [[String: Any]] else { return nil }
        // Big enough for a full-width card, not the 1280px one.
        let sorted = list.sorted { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }
        let pick = sorted.first { ($0["width"] as? Int ?? 0) >= 320 } ?? sorted.last
        return url(pick?["url"] as? String)
    }

    /// Every video and the last continuation token in a browse or search
    /// response.
    static func feed(_ json: Any) -> YTFeedPage {
        var page = YTFeedPage()
        var seen = Set<String>()
        walk(json, page: &page, seen: &seen)
        return page
    }

    private static let videoRendererKeys = [
        "videoRenderer", "gridVideoRenderer", "compactVideoRenderer",
        "videoWithContextRenderer", "playlistVideoRenderer", "playlistPanelVideoRenderer",
    ]

    /// Ads, Shorts shelves and the like that would only add noise.
    private static let skippedKeys: Set<String> = [
        "adSlotRenderer", "reelShelfRenderer", "promotedSparklesWebRenderer",
        "statementBannerRenderer", "brandVideoShelfRenderer", "searchPyvRenderer",
    ]

    private static func walk(_ node: Any, page: inout YTFeedPage, seen: inout Set<String>) {
        if let array = node as? [Any] {
            for child in array { walk(child, page: &page, seen: &seen) }
            return
        }
        guard let dictionary = node as? [String: Any] else { return }
        for key in videoRendererKeys {
            if let renderer = dictionary[key] as? [String: Any] {
                if let video = video(fromRenderer: renderer), seen.insert(video.id).inserted {
                    page.videos.append(video)
                }
                return
            }
        }
        if let lockup = dictionary["lockupViewModel"] as? [String: Any] {
            if let video = video(fromLockup: lockup), seen.insert(video.id).inserted {
                page.videos.append(video)
            }
            return
        }
        if let item = dictionary["continuationItemRenderer"] as? [String: Any] {
            if let token = continuationToken(item) { page.continuation = token }
            return
        }
        for (key, value) in dictionary where !skippedKeys.contains(key) {
            if value is [Any] || value is [String: Any] {
                walk(value, page: &page, seen: &seen)
            }
        }
    }

    private static func continuationToken(_ item: [String: Any]) -> String? {
        if let endpoint = item["continuationEndpoint"] as? [String: Any],
           let command = endpoint["continuationCommand"] as? [String: Any],
           let token = command["token"] as? String {
            return token
        }
        // Some pages put it behind a button.
        return firstValue(forKey: "token", in: item) as? String
    }

    static func video(fromRenderer renderer: [String: Any]) -> YTVideo? {
        guard let id = renderer["videoId"] as? String,
              let title = text(renderer["title"]) ?? text(renderer["headline"]) else { return nil }
        // Upcoming premieres and live streams have no length; still fine.
        let owner = renderer["ownerText"] ?? renderer["shortBylineText"] ?? renderer["longBylineText"]
        var channelID: String?
        if let runs = (owner as? [String: Any])?["runs"] as? [[String: Any]],
           let endpoint = runs.first?["navigationEndpoint"] as? [String: Any],
           let browse = endpoint["browseEndpoint"] as? [String: Any] {
            channelID = browse["browseId"] as? String
        }
        var duration = text(renderer["lengthText"])
        if duration == nil, let overlays = renderer["thumbnailOverlays"] as? [[String: Any]] {
            for overlay in overlays {
                if let status = overlay["thumbnailOverlayTimeStatusRenderer"] as? [String: Any],
                   let label = text(status["text"]) {
                    duration = label
                    break
                }
            }
        }
        let views = text(renderer["shortViewCountText"]) ?? text(renderer["viewCountText"])
        let published = text(renderer["publishedTimeText"])
        let meta = [views, published].compactMap { $0 }.joined(separator: " · ")
        return YTVideo(id: id, title: title, channel: text(owner), channelID: channelID,
                       duration: duration, meta: meta.isEmpty ? nil : meta,
                       thumbnail: thumbnail(renderer["thumbnail"]),
                       notInterestedToken: notInterestedToken(in: renderer["menu"] ?? renderer))
    }

    static func video(fromLockup lockup: [String: Any]) -> YTVideo? {
        guard let id = lockup["contentId"] as? String else { return nil }
        let type = lockup["contentType"] as? String ?? ""
        guard type.isEmpty || type.contains("VIDEO") else { return nil }
        guard let metadata = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any],
              let title = text(metadata["title"]) else { return nil }

        var parts: [[String]] = []
        if let content = (metadata["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any],
           let rows = content["metadataRows"] as? [[String: Any]] {
            for row in rows {
                let texts = (row["metadataParts"] as? [[String: Any]] ?? []).compactMap { text($0["text"]) }
                if !texts.isEmpty { parts.append(texts) }
            }
        }
        let channel = parts.first?.first
        let meta = parts.dropFirst().flatMap { $0 }.joined(separator: " · ")

        var thumb: URL?
        if let image = lockup["contentImage"] as? [String: Any],
           let model = image["thumbnailViewModel"] as? [String: Any] {
            thumb = thumbnail(model["image"])
        }
        let badge = firstValue(forKey: "thumbnailBadgeViewModel", in: lockup) as? [String: Any]
        return YTVideo(id: id, title: title, channel: channel, channelID: nil,
                       duration: badge.flatMap { $0["text"] as? String },
                       meta: meta.isEmpty ? nil : meta, thumbnail: thumb,
                       notInterestedToken: notInterestedToken(in: metadata["menuButton"] ?? lockup))
    }

    /// The feedback token behind a video menu's 興味なし. Older renderers
    /// carry a `menuServiceItemRenderer` with the NOT_INTERESTED icon; the
    /// newer lockups a `listItemViewModel` in a sheet, known by its icon or
    /// its title.
    static func notInterestedToken(in node: Any, depth: Int = 0) -> String? {
        guard depth < 30 else { return nil }
        if let array = node as? [Any] {
            for child in array {
                if let token = notInterestedToken(in: child, depth: depth + 1) { return token }
            }
            return nil
        }
        guard let dictionary = node as? [String: Any] else { return nil }
        if let item = dictionary["menuServiceItemRenderer"] as? [String: Any],
           (item["icon"] as? [String: Any])?["iconType"] as? String == "NOT_INTERESTED",
           let token = firstValue(forKey: "feedbackToken", in: item) as? String {
            return token
        }
        if let item = dictionary["listItemViewModel"] as? [String: Any] {
            let title = ((item["title"] as? [String: Any])?["content"] as? String) ?? ""
            let icon = (firstValue(forKey: "imageName", in: item) as? String) ?? ""
            if icon == "NOT_INTERESTED" || ["興味なし", "Not interested"].contains(title),
               let token = firstValue(forKey: "feedbackToken", in: item) as? String {
                return token
            }
        }
        for value in dictionary.values where value is [Any] || value is [String: Any] {
            if let token = notInterestedToken(in: value, depth: depth + 1) { return token }
        }
        return nil
    }

    /// Depth-first search for a key anywhere below `node`.
    static func firstValue(forKey key: String, in node: Any, depth: Int = 0) -> Any? {
        guard depth < 40 else { return nil }
        if let dictionary = node as? [String: Any] {
            if let value = dictionary[key] { return value }
            for value in dictionary.values {
                if let found = firstValue(forKey: key, in: value, depth: depth + 1) { return found }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let found = firstValue(forKey: key, in: value, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    /// Every value for `key` below `node`.
    static func allValues(forKey key: String, in node: Any, into results: inout [Any], depth: Int = 0) {
        guard depth < 60 else { return }
        if let dictionary = node as? [String: Any] {
            for (name, value) in dictionary {
                if name == key { results.append(value) } else {
                    allValues(forKey: key, in: value, into: &results, depth: depth + 1)
                }
            }
        } else if let array = node as? [Any] {
            for value in array { allValues(forKey: key, in: value, into: &results, depth: depth + 1) }
        }
    }

    // MARK: Page scraping

    /// The JSON object assigned to `name` in a page's inline script
    /// (`var ytInitialPlayerResponse = {...};`).
    static func embeddedJSON(named name: String, in html: String) -> Any? {
        guard let range = html.range(of: name) else { return nil }
        guard let open = html[range.upperBound...].firstIndex(of: "{") else { return nil }
        // Only whitespace and `=` may sit between the name and the object.
        let between = html[range.upperBound..<open]
        guard between.allSatisfy({ $0 == " " || $0 == "=" || $0 == "\n" }) else {
            // The first mention wasn't the assignment; look further on.
            let rest = String(html[range.upperBound...])
            return embeddedJSON(named: name, in: rest)
        }
        guard let object = balancedObject(in: html, from: open) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(object.utf8))
    }

    /// The `{…}` starting at `start`, minding strings and escapes.
    private static func balancedObject(in text: String, from start: String.Index) -> Substring? {
        var depth = 0
        var inString = false
        var escaped = false
        let utf8 = text.utf8
        var position = start.samePosition(in: utf8) ?? utf8.startIndex
        while position < utf8.endIndex {
            let byte = utf8[position]
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 {
                    return text[start..<utf8.index(after: position)]
                }
            }
            position = utf8.index(after: position)
        }
        return nil
    }

    static func playerInfo(from response: [String: Any], videoID: String, html: String?) -> YTPlayerInfo {
        let details = response["videoDetails"] as? [String: Any] ?? [:]
        let streaming = response["streamingData"] as? [String: Any] ?? [:]
        let status = response["playabilityStatus"] as? [String: Any] ?? [:]
        let statusName = status["status"] as? String ?? "OK"

        var tracks: [YTCaptionTrack] = []
        if let captions = response["captions"] as? [String: Any],
           let renderer = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
           let list = renderer["captionTracks"] as? [[String: Any]] {
            for track in list {
                guard let base = track["baseUrl"] as? String else { continue }
                let code = track["languageCode"] as? String ?? ""
                tracks.append(YTCaptionTrack(baseURL: base.hasPrefix("/") ? "https://www.youtube.com" + base : base,
                                             languageCode: code,
                                             name: text(track["name"]) ?? code,
                                             isAutomatic: (track["kind"] as? String) == "asr"))
            }
        }

        var params: String?
        if let html, let match = html.firstMatch(of: /"getTranscriptEndpoint":\{"params":"([^"]+)"/) {
            params = String(match.1)
        }

        return YTPlayerInfo(
            videoID: videoID,
            title: details["title"] as? String ?? "",
            channel: details["author"] as? String ?? "",
            channelID: details["channelId"] as? String,
            duration: Double(details["lengthSeconds"] as? String ?? "") ?? 0,
            hlsURL: url(streaming["hlsManifestUrl"] as? String),
            captionTracks: tracks,
            transcriptParams: params,
            isLive: (details["isLive"] as? Bool) == true,
            playable: statusName == "OK",
            reason: (status["reason"] as? String) ?? text(status["messages"]),
            viewCount: details["viewCount"] as? String,
            description: details["shortDescription"] as? String,
            publishDate: publishDate(response)
        )
    }

    /// "2024-05-01" or "2024-05-01T09:00:00-07:00": only the day is used.
    private static func publishDate(_ response: [String: Any]) -> Date? {
        guard let microformat = (response["microformat"] as? [String: Any])?["playerMicroformatRenderer"] as? [String: Any],
              let raw = (microformat["publishDate"] as? String) ?? (microformat["uploadDate"] as? String),
              raw.count >= 10 else { return nil }
        let parts = raw.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // MARK: Comments

    /// Comments from a `next` continuation, in either of YouTube's shapes:
    /// `commentViewModel`s whose details sit in the response's entity
    /// store (`commentEntityPayload`), or the older `commentRenderer`s.
    static func comments(_ json: Any) -> YTCommentPage {
        var page = YTCommentPage()
        var entities: [String: [String: Any]] = [:]
        var payloads: [Any] = []
        allValues(forKey: "commentEntityPayload", in: json, into: &payloads)
        for case let payload as [String: Any] in payloads {
            if let key = payload["key"] as? String { entities[key] = payload }
        }
        var lists: [Any] = []
        allValues(forKey: "continuationItems", in: json, into: &lists)
        var seen = Set<String>()
        for case let items as [[String: Any]] in lists {
            for item in items {
                if let thread = item["commentThreadRenderer"] as? [String: Any] {
                    guard var comment = threadComment(thread, entities: entities) else { continue }
                    if let replies = thread["replies"] {
                        comment.repliesToken = firstValue(forKey: "token", in: replies) as? String
                    }
                    if seen.insert(comment.id).inserted { page.comments.append(comment) }
                } else if let model = item["commentViewModel"] as? [String: Any],
                          let comment = viewModelComment(model, entities: entities) {
                    if seen.insert(comment.id).inserted { page.comments.append(comment) }
                } else if let renderer = item["commentRenderer"] as? [String: Any],
                          let comment = rendererComment(renderer) {
                    if seen.insert(comment.id).inserted { page.comments.append(comment) }
                } else if let more = item["continuationItemRenderer"] {
                    page.continuation = firstValue(forKey: "token", in: more) as? String
                }
            }
        }
        return page
    }

    private static func threadComment(_ thread: [String: Any], entities: [String: [String: Any]]) -> YTComment? {
        if let wrapper = thread["commentViewModel"] as? [String: Any] {
            let model = wrapper["commentViewModel"] as? [String: Any] ?? wrapper
            return viewModelComment(model, entities: entities)
        }
        if let renderer = firstValue(forKey: "commentRenderer", in: thread) as? [String: Any] {
            return rendererComment(renderer)
        }
        return nil
    }

    private static func viewModelComment(_ model: [String: Any], entities: [String: [String: Any]]) -> YTComment? {
        guard let key = model["commentKey"] as? String, let payload = entities[key] else { return nil }
        let properties = payload["properties"] as? [String: Any] ?? [:]
        let author = payload["author"] as? [String: Any] ?? [:]
        let toolbar = payload["toolbar"] as? [String: Any] ?? [:]
        let text = (properties["content"] as? [String: Any])?["content"] as? String ?? ""
        guard !text.isEmpty else { return nil }
        let likes = (toolbar["likeCountNotliked"] as? String)?.trimmingCharacters(in: .whitespaces)
        let replies = (toolbar["replyCount"] as? String).flatMap { Int($0.filter(\.isNumber)) } ?? 0
        return YTComment(id: properties["commentId"] as? String ?? (model["commentId"] as? String ?? key),
                         author: author["displayName"] as? String ?? "",
                         authorPhoto: url(author["avatarThumbnailUrl"] as? String),
                         text: text,
                         published: properties["publishedTime"] as? String,
                         likes: (likes?.isEmpty ?? true) || likes == "0" ? nil : likes,
                         replyCount: replies)
    }

    private static func rendererComment(_ renderer: [String: Any]) -> YTComment? {
        guard let text = self.text(renderer["contentText"]), !text.isEmpty else { return nil }
        let thumbnails = (renderer["authorThumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let likes = self.text(renderer["voteCount"])
        return YTComment(id: renderer["commentId"] as? String ?? UUID().uuidString,
                         author: self.text(renderer["authorText"]) ?? "",
                         authorPhoto: url(thumbnails?.last?["url"] as? String),
                         text: text,
                         published: self.text(renderer["publishedTimeText"]),
                         likes: (likes?.isEmpty ?? true) ? nil : likes,
                         replyCount: renderer["replyCount"] as? Int ?? 0)
    }

    // MARK: Subtitles

    /// YouTube's json3 caption format.
    static func json3Cues(_ data: Data) -> [SubtitleCue]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else { return nil }
        // Automatic captions time every word; rebuild those as sentences.
        let wordTimed = events.contains { event in
            (event["segs"] as? [[String: Any]])?.contains { $0["tOffsetMs"] != nil } ?? false
        }
        if wordTimed, let lines = sentenceCues(events), !lines.isEmpty {
            return lines
        }
        var cues: [SubtitleCue] = []
        for event in events {
            guard let segments = event["segs"] as? [[String: Any]] else { continue }
            // Automatic captions add a lone newline event between lines.
            if (event["aAppend"] as? Int) == 1 { continue }
            let text = segments.compactMap { $0["utf8"] as? String }.joined()
                .replacingOccurrences(of: "\u{200B}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = Double(event["tStartMs"] as? Int ?? 0) / 1000
            let duration = Double(event["dDurationMs"] as? Int ?? 2000) / 1000
            cues.append(SubtitleCue(id: cues.count, start: start, end: start + duration, text: text))
        }
        return SubtitleParser.tidy(cues)
    }

    /// Every word of automatic json3 captions with its own time, regrouped
    /// into sentence-sized lines (`CaptionSentences`).
    private static func sentenceCues(_ events: [[String: Any]]) -> [SubtitleCue]? {
        var words: [CaptionSentences.Piece] = []
        let starts = events.compactMap { event -> Double? in
            guard event["segs"] != nil, (event["aAppend"] as? Int) != 1 else { return nil }
            return Double(event["tStartMs"] as? Int ?? 0) / 1000
        }
        var eventIndex = 0
        for event in events {
            guard let segments = event["segs"] as? [[String: Any]], (event["aAppend"] as? Int) != 1 else { continue }
            let eventStart = Double(event["tStartMs"] as? Int ?? 0) / 1000
            var eventEnd = eventStart + Double(event["dDurationMs"] as? Int ?? 2000) / 1000
            // Rolling windows overlap; a window's words end when the next starts.
            if eventIndex + 1 < starts.count { eventEnd = min(eventEnd, max(starts[eventIndex + 1], eventStart)) }
            eventIndex += 1
            let timed = segments.map { segment -> (Double, String) in
                let offset = Double(segment["tOffsetMs"] as? Int ?? 0) / 1000
                let text = (segment["utf8"] as? String ?? "").replacingOccurrences(of: "\u{200B}", with: "")
                return (eventStart + offset, text)
            }
            for (index, word) in timed.enumerated() {
                guard !word.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let end = index + 1 < timed.count ? timed[index + 1].0 : eventEnd
                words.append(CaptionSentences.Piece(start: word.0, end: max(end, word.0 + 0.05), text: word.1))
            }
        }
        guard !words.isEmpty else { return nil }
        return CaptionSentences.lines(from: words)
    }

    /// The older XML formats (srv3 `<p t= d=>`, and `<text start= dur=>`).
    static func xmlCues(_ string: String) -> [SubtitleCue]? {
        var cues: [SubtitleCue] = []
        for match in string.matches(of: /<p t="(\d+)"(?: d="(\d+)")?[^>]*>([\s\S]*?)<\/p>/) {
            let start = (Double(match.1) ?? 0) / 1000
            let duration = (Double(match.2.map(String.init) ?? "2000") ?? 2000) / 1000
            let text = SubtitleParser.stripTags(String(match.3))
            if !text.isEmpty { cues.append(SubtitleCue(id: cues.count, start: start, end: start + duration, text: text)) }
        }
        if cues.isEmpty {
            for match in string.matches(of: /<text start="([\d.]+)"(?: dur="([\d.]+)")?[^>]*>([\s\S]*?)<\/text>/) {
                let start = Double(match.1) ?? 0
                let duration = Double(match.2.map(String.init) ?? "2") ?? 2
                let text = SubtitleParser.stripTags(String(match.3))
                if !text.isEmpty { cues.append(SubtitleCue(id: cues.count, start: start, end: start + duration, text: text)) }
            }
        }
        return cues.isEmpty ? nil : SubtitleParser.tidy(cues)
    }

    /// The transcript panel's response.
    static func transcriptCues(_ json: Any) -> [SubtitleCue]? {
        var segments: [Any] = []
        allValues(forKey: "transcriptSegmentRenderer", in: json, into: &segments)
        var cues: [SubtitleCue] = []
        for case let segment as [String: Any] in segments {
            let start = Double(segment["startMs"] as? String ?? "") ?? 0
            let end = Double(segment["endMs"] as? String ?? "") ?? start + 2000
            guard let text = text(segment["snippet"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            cues.append(SubtitleCue(id: cues.count, start: start / 1000, end: end / 1000, text: text))
        }
        return cues.isEmpty ? nil : SubtitleParser.tidy(cues)
    }
}

// MARK: - Subtitle files

nonisolated enum SubtitleParser {
    /// SRT, WebVTT or ASS/SSA, told apart by their contents.
    static func parse(_ data: Data) -> [SubtitleCue]? {
        let string = decode(data)
        if string.contains("[Events]") || string.contains("Dialogue:") {
            return ass(string)
        }
        return srtOrVTT(string)
    }

    private static func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        if let sjis = String(data: data, encoding: .shiftJIS) { return sjis }
        return String(decoding: data, as: UTF8.self)
    }

    private static func srtOrVTT(_ string: String) -> [SubtitleCue]? {
        let normalized = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = timestamp(parts[0]),
                  let end = timestamp(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? parts[1]) else { continue }
            let text = stripTags(lines[(timingIndex + 1)...].joined(separator: "\n"))
            guard !text.isEmpty else { continue }
            cues.append(SubtitleCue(id: cues.count, start: start, end: end, text: text))
        }
        return cues.isEmpty ? nil : tidy(cues)
    }

    /// `00:01:02,345`, `01:02.345` or `1:02:03.45`.
    static func timestamp(_ raw: String) -> Double? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let pieces = cleaned.split(separator: ":").map(String.init)
        guard (2...3).contains(pieces.count) else { return nil }
        var seconds = 0.0
        for piece in pieces {
            guard let value = Double(piece) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    private static func ass(_ string: String) -> [SubtitleCue]? {
        var format: [String] = []
        var cues: [SubtitleCue] = []
        for rawLine in string.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Format:"), format.isEmpty || line.contains("Text") {
                format = line.dropFirst("Format:".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard line.hasPrefix("Dialogue:") else { continue }
            let fieldCount = max(format.count, 10)
            let fields = line.dropFirst("Dialogue:".count)
                .split(separator: ",", maxSplits: fieldCount - 1, omittingEmptySubsequences: false)
                .map(String.init)
            let startIndex = format.firstIndex(of: "Start") ?? 1
            let endIndex = format.firstIndex(of: "End") ?? 2
            let textIndex = format.firstIndex(of: "Text") ?? fields.count - 1
            guard fields.count > max(startIndex, endIndex, textIndex),
                  let start = timestamp(fields[startIndex]),
                  let end = timestamp(fields[endIndex]) else { continue }
            var text = fields[textIndex]
            text = text.replacing(/\{[^}]*\}/, with: "")
            text = text.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cues.append(SubtitleCue(id: cues.count, start: start, end: end, text: text))
        }
        return cues.isEmpty ? nil : tidy(cues)
    }

    static func stripTags(_ string: String) -> String {
        var text = string.replacing(/<[^>]+>/, with: "")
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sorted, numbered, and with no line running into the next (rolling
    /// automatic captions overlap; one line at a time reads better).
    static func tidy(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var sorted = cues.sorted { $0.start < $1.start }
        // Identical lines repeated back to back (some rips) become one.
        var merged: [SubtitleCue] = []
        for cue in sorted {
            if let last = merged.last, last.text == cue.text, cue.start - last.end < 0.3 {
                merged[merged.count - 1].end = max(last.end, cue.end)
            } else {
                merged.append(cue)
            }
        }
        sorted = merged
        for index in sorted.indices {
            sorted[index] = SubtitleCue(id: index, start: sorted[index].start,
                                        end: sorted[index].end, text: sorted[index].text)
            if index + 1 < sorted.count, sorted[index].end > sorted[index + 1].start,
               sorted[index + 1].start > sorted[index].start {
                sorted[index].end = sorted[index + 1].start
            }
        }
        return sorted
    }
}

// MARK: - Accounts

/// A Google account or one of its channels (brand accounts), as YouTube's
/// account switcher lists them. Requests made "as" it carry its index in
/// the browser session (X-Goog-AuthUser) and, for a channel, its page ID.
nonisolated struct YouTubeAccount: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var byline: String?
    var email: String?
    var photo: URL?
    var authUser: Int
    var pageID: String?
    var isSelected: Bool = false
    /// YouTube's own link for switching to this account or channel. Visiting
    /// it is how the site switches: it sets the session's active identity.
    var signinURL: String?

    var id: String { "\(authUser)|\(pageID ?? "")" }

    private static let key = "iroha.youtube.account"

    /// The account the app uses. Nil is YouTube's default for the session.
    static var current: YouTubeAccount? {
        get {
            UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(YouTubeAccount.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    static func parse(_ json: Any) -> [YouTubeAccount] {
        var accounts: [YouTubeAccount] = []
        collect(json, email: nil, authUser: nil, into: &accounts)
        var seen = Set<String>()
        return accounts.filter { seen.insert($0.id).inserted }
    }

    private static func collect(_ node: Any, email: String?, authUser: Int?, into accounts: inout [YouTubeAccount]) {
        if let array = node as? [Any] {
            for child in array { collect(child, email: email, authUser: authUser, into: &accounts) }
            return
        }
        guard let dictionary = node as? [String: Any] else { return }

        // A section per Google account, headed by its address.
        if let section = dictionary["accountSectionListRenderer"] as? [String: Any] {
            var sectionEmail = email
            if let header = YTParse.firstValue(forKey: "googleAccountHeaderRenderer", in: section["header"] ?? [:]) as? [String: Any] {
                sectionEmail = YTParse.text(header["email"]) ?? sectionEmail
            }
            collect(section["contents"] ?? [], email: sectionEmail, authUser: authUser, into: &accounts)
            return
        }

        if let item = dictionary["accountItem"] as? [String: Any] {
            var account = YouTubeAccount(name: YTParse.text(item["accountName"]) ?? "",
                                         byline: YTParse.text(item["channelHandle"]) ?? YTParse.text(item["accountByline"]),
                                         email: email,
                                         photo: YTParse.thumbnail(item["accountPhoto"]),
                                         authUser: authUser ?? 0,
                                         pageID: nil,
                                         isSelected: item["isSelected"] as? Bool ?? false)
            var tokens: [Any] = []
            YTParse.allValues(forKey: "supportedTokens", in: item, into: &tokens)
            for case let list as [[String: Any]] in tokens {
                for token in list {
                    if let page = token["pageIdToken"] as? [String: Any], let id = page["pageId"] as? String {
                        account.pageID = id
                    }
                    if let signin = token["accountSigninToken"] as? [String: Any],
                       let url = signin["signinUrl"] as? String {
                        account.signinURL = url
                        if let match = url.firstMatch(of: /authuser=(\d+)/), let index = Int(match.1) {
                            account.authUser = index
                        }
                    }
                }
            }
            if !account.name.isEmpty { accounts.append(account) }
            return
        }

        for value in dictionary.values where value is [Any] || value is [String: Any] {
            collect(value, email: email, authUser: authUser, into: &accounts)
        }
    }
}
