//
//  ThreadSearchService.swift
//  Donguri
//
//  スレタイ検索. Two ways:
//   - 全板: 5ch's own search (find.5ch.io), which covers every board and
//     past threads too. It's an HTML page, so it's parsed defensively: each
//     result is a link to the thread whose text is "title (count)", then a
//     link to its board, then the time of the last post and posts per day.
//   - お気に入り・最近の板: the boards the user reads, searched directly from
//     their subject.txt. Works even if the 5ch search is down or changes.
//

import Foundation

struct ThreadSearchResult: Identifiable, Hashable {
    var link: ThreadLink
    /// Last post, as find.5ch.io reports it.
    var lastPost: Date?
    /// Posts per day.
    var momentum: Double?
    /// From the archive (過去ログ); it won't grow any more.
    var isArchived: Bool

    var id: String { link.key }
}

enum ThreadSearchScope: String, CaseIterable, Identifiable {
    case all, myBoards
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: String(localized: "全板")
        case .myBoards: String(localized: "お気に入り・最近の板")
        }
    }
}

enum ThreadSearchSort: String, CaseIterable, Identifiable {
    case relevance, momentum, latest, newest, replies
    var id: String { rawValue }
    var title: String {
        switch self {
        case .relevance: String(localized: "検索順")
        case .momentum: String(localized: "勢い順")
        case .latest: String(localized: "最新の書込順")
        case .newest: String(localized: "新しい順")
        case .replies: String(localized: "レス数順")
        }
    }
    var systemImage: String {
        switch self {
        case .relevance: "list.bullet"
        case .momentum: "flame"
        case .latest: "clock"
        case .newest: "sparkles"
        case .replies: "message"
        }
    }

    func sorted(_ results: [ThreadSearchResult]) -> [ThreadSearchResult] {
        switch self {
        case .relevance:
            results
        case .momentum:
            results.sorted { ($0.momentum ?? -1) > ($1.momentum ?? -1) }
        case .latest:
            results.sorted { ($0.lastPost ?? .distantPast) > ($1.lastPost ?? .distantPast) }
        case .newest:
            results.sorted { $0.link.threadId > $1.link.threadId }
        case .replies:
            results.sorted { $0.link.responseCount > $1.link.responseCount }
        }
    }
}

struct ThreadSearchService {
    static func webURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://find.5ch.io/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    /// 全板検索 through find.5ch.io.
    func searchAllBoards(_ query: String) async throws -> [ThreadSearchResult] {
        guard let url = Self.webURL(for: query) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("ja,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let raw = await Task.detached(priority: .userInitiated) {
            let html = String(data: data, encoding: .utf8) ?? ShiftJIS.decode(data) ?? ""
            return FindResultParser.parse(html)
        }.value
        let now = Date.now
        return raw.map { item in
            let link = ThreadLink(boardURL: BBSMenuService.resolveBoardURL(item.boardURL),
                                  threadId: item.threadId, title: item.title,
                                  boardName: item.boardName, responseCount: item.count ?? -1)
            let momentum = item.rate ?? link.thread.momentum(now: now)
            return ThreadSearchResult(link: link, lastPost: item.lastPost, momentum: momentum,
                                      isArchived: item.isArchived)
        }
    }

    /// Searches the subject.txt of the user's boards.
    func searchBoards(_ boards: [FavoriteBoard], query: String) async -> [ThreadSearchResult] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let now = Date.now
        var results: [ThreadSearchResult] = []
        await withTaskGroup(of: (FavoriteBoard, [Thread]).self) { group in
            for board in boards {
                group.addTask {
                    let threads = (try? await ThreadService().fetchThreads(boardURL: board.url)) ?? []
                    return (board, threads)
                }
            }
            for await (board, threads) in group {
                for thread in threads {
                    let title = thread.title ?? ""
                    guard terms.allSatisfy({ title.localizedCaseInsensitiveContains($0) }) else { continue }
                    let link = ThreadLink(boardURL: board.url, threadId: thread.id, title: thread.title,
                                          boardName: board.boardName, responseCount: thread.responseCount)
                    results.append(ThreadSearchResult(link: link, lastPost: nil,
                                                      momentum: thread.momentum(now: now),
                                                      isArchived: false))
                }
            }
        }
        return results.sorted { ($0.momentum ?? -1) > ($1.momentum ?? -1) }
    }

    /// Favorite boards, then boards of recently read threads.
    static func myBoards() -> [FavoriteBoard] {
        var seen = Set<String>()
        var boards: [FavoriteBoard] = []
        for board in FavoritesStore.shared.boards where seen.insert(board.url).inserted {
            boards.append(board)
        }
        for entry in HistoryStore.shared.entries where seen.insert(entry.boardURL).inserted {
            boards.append(FavoriteBoard(boardName: entry.boardName, url: entry.boardURL,
                                        directoryName: BoardNames.fallback(for: entry.boardURL)))
            if boards.count >= 24 { break }
        }
        return boards
    }
}

/// Pulls results out of find.5ch.io's HTML. Deliberately loose: it keys
/// on link targets (thread URLs, board URLs) rather than class names, so
/// small layout changes don't break it.
nonisolated enum FindResultParser {
    struct Item: Sendable {
        var boardURL: String
        var threadId: Int
        var title: String
        var count: Int?
        var boardName: String?
        var lastPost: Date?
        var rate: Double?
        var isArchived: Bool
    }

    private static let jst: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return calendar
    }()

    static func parse(_ html: String) -> [Item] {
        let anchor = #/(?is)<a\s[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>/#
        let threadPath = #/^https?://([^/]+)/test/read\.cgi/([^/]+)/(\d+)/?/#
        let boardPath = #/^https?://([^/]+)/([^/]+)/?$/#

        var items: [Item] = []
        var seen = Set<String>()
        var current: Item?
        var currentEnd: String.Index?

        func finish(upTo end: String.Index) {
            guard var item = current, let start = currentEnd else { return }
            if start < end {
                let tail = stripTags(String(html[start..<end]))
                if item.lastPost == nil { item.lastPost = date(in: tail) }
                if item.rate == nil, let match = tail.firstMatch(of: #/([\d.,]+)\s*/\s*日/#) {
                    item.rate = Double(match.1.replacingOccurrences(of: ",", with: ""))
                }
            }
            let key = "\(item.boardURL)|\(item.threadId)"
            if seen.insert(key).inserted { items.append(item) }
            current = nil
            currentEnd = nil
        }

        for match in html.matches(of: anchor) {
            var href = String(match.1).replacingOccurrences(of: "&amp;", with: "&")
            if href.hasPrefix("//") { href = "https:" + href }

            if let thread = href.firstMatch(of: threadPath), let threadId = Int(thread.3) {
                finish(upTo: match.range.lowerBound)
                let host = String(thread.1)
                let directory = String(thread.2)
                var title = stripTags(String(match.2)).trimmingCharacters(in: .whitespacesAndNewlines)
                var count: Int?
                if let counted = title.firstMatch(of: #/^(.*?)\s*[（(](\d+)[)）]\s*$/#) {
                    title = String(counted.1)
                    count = Int(counted.2)
                }
                guard !title.isEmpty, host.contains(".5ch.") else { continue }
                current = Item(boardURL: "https://\(host)/\(directory)/",
                               threadId: threadId,
                               title: title,
                               count: count,
                               boardName: nil,
                               lastPost: nil,
                               rate: nil,
                               isArchived: host.hasPrefix("kako."))
                currentEnd = match.range.upperBound
            } else if current != nil, current?.boardName == nil,
                      let board = href.firstMatch(of: boardPath),
                      String(board.1).contains(".5ch.") {
                let name = stripTags(String(match.2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { current?.boardName = name }
                // Text after the board link holds the date and rate.
                if let start = currentEnd, start < match.range.lowerBound {
                    let between = stripTags(String(html[start..<match.range.lowerBound]))
                    if current?.count == nil, let counted = between.firstMatch(of: #/[（(](\d+)[)）]/#) {
                        current?.count = Int(counted.1)
                    }
                }
                currentEnd = match.range.upperBound
            }
        }
        finish(upTo: html.endIndex)
        return items
    }

    private static func stripTags(_ html: String) -> String {
        html.replacing(#/<[^>]*>/#, with: " ")
            .htmlDecoded
            .replacing(#/\s+/#, with: " ")
    }

    private static func date(in text: String) -> Date? {
        guard let match = text.firstMatch(of: #/(\d{4})[年/\-](\d{1,2})[月/\-](\d{1,2})日?\D{0,6}?(\d{1,2}):(\d{2})/#) else {
            return nil
        }
        var components = DateComponents()
        components.year = Int(match.1)
        components.month = Int(match.2)
        components.day = Int(match.3)
        components.hour = Int(match.4)
        components.minute = Int(match.5)
        return jst.date(from: components)
    }
}
