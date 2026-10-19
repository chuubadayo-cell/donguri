//
//  PostService.swift
//  Donguri
//
//  Created by John Connery on 6/15/26.
//

import Foundation

struct PostService {
    func fetchPosts(boardURL: String, threadId: Int) async throws -> [Post] {
        guard let datURL = URL(string: "dat/\(threadId).dat", relativeTo: URL(string: boardURL)) else {
            throw URLError(.badURL)
        }

        do {
            // Only the bytes added since the last visit are downloaded when
            // the thread is already cached (see `DatCache`).
            let data = try await DatCache.shared.fetch(datURL)
            return try await Self.parseInBackground { try PostParser.parseDat(data) }
        } catch DatCache.FetchError.notFound {
            // The thread has "dat落ち" (aged out of the live dat store). Fall back
            // to parsing the server's own read.cgi HTML page, which keeps serving
            // old threads from its archive long after the raw .dat is gone.
            do {
                return try await fetchFromArchive(boardURL: boardURL, threadId: threadId)
            } catch {
                // Archive unreachable too: whatever was cached from earlier
                // visits is better than nothing.
                if let cached = await DatCache.shared.cachedData(for: datURL) {
                    return try await Self.parseInBackground { try PostParser.parseDat(cached) }
                }
                throw error
            }
        }
    }

    /// Parsing a 1000-post thread runs thousands of regex passes; doing that
    /// on the main actor froze scrolling and the loading spinner.
    private static func parseInBackground(_ work: @escaping @Sendable () throws -> [Post]) async throws -> [Post] {
        try await Task.detached(priority: .userInitiated) {
            try work()
        }.value
    }

    /// Parses a thread's read.cgi HTML page — used once a thread's raw .dat has
    /// aged out of the live server (dat落ち), since the server still renders old
    /// threads as HTML long after the .dat itself is gone.
    private func fetchFromArchive(boardURL: String, threadId: Int) async throws -> [Post] {
        guard let boardURLComponents = URL(string: boardURL),
              let host = boardURLComponents.host else {
            throw URLError(.badURL)
        }
        let directoryName = boardURLComponents.pathComponents.first { $0 != "/" } ?? ""

        guard let url = URL(string: "https://\(host)/test/read.cgi/\(directoryName)/\(threadId)/") else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return try await Self.parseInBackground { try PostParser.parseArchive(data) }
    }
}

/// Turns raw dat / archive HTML into posts. `nonisolated` so it can run on a
/// background thread: nothing here touches UI state.
nonisolated enum PostParser {
    static let abornMarker = "あぼーん"

    static func parseDat(_ data: Data) throws -> [Post] {
        guard let postData = String(data: data, encoding: .shiftJIS) else {
            throw URLError(.cannotDecodeRawData)
        }

        // First pass: parse each line into a post, without reply back-references
        // (those require knowing about every post first, and Post is immutable).
        let parsed = postData
            .components(separatedBy: .newlines)
            .compactMap { element -> Post? in
                // Skip empty lines
                guard !element.isEmpty else { return nil }

                // Skip aborn (deleted/moderated) posts
                if element.hasPrefix(abornMarker) { return nil }

                guard let fields = datFields(element) else {
                    print("Error parsing: \(element)")
                    return nil
                }

                let name = fields.name.htmlDecoded
                let email = fields.email.htmlDecoded

                let text = fields.body.htmlDecoded.replacing(#/>>(\d+)/#) { match in
                    "[>>\(match.1)](donguri://res/\(match.1))"
                }

                let threadTitle: String? = fields.title.isEmpty ? nil :
                    fields.title
                        .components(separatedBy: "\t").first
                        .map { $0.trimmingCharacters(in: .whitespaces) }

                return Post(name: name,
                            trip: extractTrip(from: name),
                            email: email,
                            date: fields.date,
                            id: fields.id,
                            text: text,
                            threadTitle: threadTitle,
                            replies: nil,
                            imageURLs: extractImageURLs(from: text))
            }

        return attachReplies(to: parsed)
    }

    private nonisolated struct DatFields {
        var name: String
        var email: String
        var date: String
        var id: String?
        var body: String
        var title: String
    }

    /// Splits one dat line, `name<>mail<>date ID:xxx BE:yyy<>body<>title`.
    ///
    /// Plain splitting on `<>` is many times faster than the regex this used to
    /// be, which matters at 1000 lines. Lines that don't have the expected shape
    /// still go through the original regex, so the result is the same either way.
    private static func datFields(_ line: String) -> DatFields? {
        let parts = line.components(separatedBy: "<>")
        if parts.count >= 5 {
            var dateField = Substring(parts[2])
            var id: String?

            // ` BE:xxx` and ` ID:xxx` only count at the very end of the field,
            // in that order, which is what the regex accepted.
            if let range = dateField.range(of: " BE:", options: .backwards),
               isToken(dateField[range.upperBound...]) {
                dateField = dateField[..<range.lowerBound]
            }
            if let range = dateField.range(of: " ID:", options: .backwards),
               isToken(dateField[range.upperBound...]) {
                id = String(dateField[range.upperBound...])
                dateField = dateField[..<range.lowerBound]
            }

            let date = String(dateField).trimmingCharacters(in: .whitespaces)
            return DatFields(name: parts[0],
                             email: parts[1],
                             date: date,
                             id: id,
                             body: parts[3],
                             title: parts[4...].joined(separator: "<>"))
        }

        let regex = #/(.*?)<>(.*?)<>(.*?)(?:\s+ID:([^\s<>]+))?(?:\s+BE:([^\s<>]+))?<>(.*?)<>(.*)/#
        guard let match = line.wholeMatch(of: regex) else { return nil }
        return DatFields(name: String(match.1),
                         email: String(match.2),
                         date: String(match.3),
                         id: match.4.map(String.init),
                         body: String(match.6),
                         title: String(match.7))
    }

    private static func isToken(_ s: Substring) -> Bool {
        !s.isEmpty && !s.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" })
    }

    static func parseArchive(_ data: Data) throws -> [Post] {
        guard let html = String(data: data, encoding: .shiftJIS) else {
            throw URLError(.cannotDecodeRawData)
        }

        let title = html.firstMatch(of: #/<title>(.*?)<\/title>/#.dotMatchesNewlines())
            .map { String($0.1).trimmingCharacters(in: .whitespacesAndNewlines) }

        // Each post is a <div id="N" data-date="…" data-userid="ID:xxxx" data-id="N"
        // class="clear post"> …</div>; scanning for just the start markers and
        // slicing between consecutive ones avoids needing to balance nested tags.
        let postStartRegex = #/<div id="\d+" data-date="[^"]*" data-userid="([^"]*)" data-id="\d+" class="clear post">/#
        let starts = Array(html.matches(of: postStartRegex))

        let parsed: [Post] = starts.enumerated().compactMap { index, match in
            let chunkStart = match.range.upperBound
            let chunkEnd = index + 1 < starts.count ? starts[index + 1].range.lowerBound : html.endIndex
            let chunk = html[chunkStart..<chunkEnd]

            guard let nameMatch = chunk.firstMatch(of: #/<span class="postusername">(.*?)<\/span>/#),
                  let dateMatch = chunk.firstMatch(of: #/<span class="date">(.*?)<\/span>/#),
                  let contentMatch = chunk.firstMatch(of: #/<div class="post-content">(.*?)<\/div>/#) else {
                print("Error parsing archive post at index \(index)")
                return nil
            }

            let name = String(nameMatch.1).htmlDecoded

            let rawUserID = String(match.1)
            let id: String? = rawUserID.hasPrefix("ID:") ? String(rawUserID.dropFirst(3)) :
                (rawUserID.isEmpty ? nil : rawUserID)

            let text = String(contentMatch.1).htmlDecoded.replacing(#/>>(\d+)/#) { m in
                "[>>\(m.1)](donguri://res/\(m.1))"
            }

            return Post(name: name,
                        trip: extractTrip(from: name),
                        email: "",
                        date: String(dateMatch.1).htmlDecoded,
                        id: id,
                        text: text,
                        threadTitle: index == 0 ? title : nil,
                        replies: nil,
                        imageURLs: extractImageURLs(from: text))
        }

        return attachReplies(to: parsed)
    }

    /// A tripcode only exists if "◆" actually appears in the name — `split` alone
    /// returns the whole string as a single element when the separator is absent,
    /// so without this check every plain anonymous name would be misread as its
    /// own "tripcode".
    private static func extractTrip(from name: String) -> String? {
        let components = name.components(separatedBy: "◆")
        guard components.count > 1 else { return nil }
        return components.last?.split(separator: " ").first.map(String.init)
    }

    /// Second pass: figure out which posts reply to which via >>N, then rebuild
    /// the posts with `replies` populated (Post is immutable, so this can't be
    /// done in place during the first pass).
    private static func attachReplies(to posts: [Post]) -> [Post] {
        var repliesByIndex: [Int: [Int]] = [:]
        for (i, post) in posts.enumerated() where post.text.contains(">>") {
            for match in post.text.matches(of: #/>>(\d+)/#) {
                guard let n = Int(match.1) else { continue }
                let targetIndex = n - 1
                guard posts.indices.contains(targetIndex) else { continue }
                repliesByIndex[targetIndex, default: []].append(i)
            }
        }

        return posts.enumerated().map { index, post in
            Post(name: post.name,
                 trip: post.trip,
                 email: post.email,
                 date: post.date,
                 id: post.id,
                 text: post.text,
                 threadTitle: post.threadTitle,
                 replies: repliesByIndex[index],
                 imageURLs: post.imageURLs)
        }
    }

    /// Image links in a post, shown as thumbnails and in the gallery, including
    /// 5ch-style `ttps://` links. Besides
    /// plain `.jpg`/`.png` links this accepts X/Twitter's `pbs.twimg.com/media/…
    /// ?format=jpg` style, which has no extension in the path. A link only counts
    /// when the extension really ends it, so `a.jpg.html` is not an image, while
    /// Japanese text written straight after a link still is.
    static func extractImageURLs(from text: String) -> [URL] {
        guard text.contains("ttp") else { return [] }
        let regex = #/h?ttps?:\/\/[A-Za-z0-9\-._~:\/?#@!$&*+,;=%]+?(?:\.(?i:jpe?g|png|gif|webp|bmp|heic)(?:\?[A-Za-z0-9\-._~:\/?#@!$&*+,;=%]*)?|\?(?:[A-Za-z0-9\-._~:\/?#@!$&*+,;=%]*&)?format=(?i:jpe?g|png|webp)[A-Za-z0-9\-._~:\/?#@!$&*+,;=%]*)(?![A-Za-z0-9\-._~:\/?#@!$&*+,;=%])/#
        return uniqueURLs(text.matches(of: regex).map { String($0.0) })
    }

    /// Video links (`.mp4`, `.mov`, `.m4v`, `.webm`). Not stored on `Post`, so
    /// saved threads stay readable by older builds; the gallery asks for them.
    static func extractVideoURLs(from text: String) -> [URL] {
        guard text.contains("ttp") else { return [] }
        let regex = #/h?ttps?:\/\/[A-Za-z0-9\-._~:\/?#@!$&*+,;=%]+?\.(?i:mp4|mov|m4v|webm)(?:\?[A-Za-z0-9\-._~:\/?#@!$&*+,;=%]*)?(?![A-Za-z0-9\-._~:\/?#@!$&*+,;=%])/#
        return uniqueURLs(text.matches(of: regex).map { String($0.0) })
    }

    /// A link usually appears twice, as a markdown link's label and target.
    /// 5ch posters often drop the leading "h" (`ttps://…`) so the board won't
    /// auto-link it; those are restored here.
    private static func uniqueURLs(_ strings: [String]) -> [URL] {
        var seen = Set<URL>()
        return strings.compactMap { string -> URL? in
            let full = string.hasPrefix("ttp") ? "h" + string : string
            guard let url = URL(string: full), seen.insert(url).inserted else { return nil }
            return url
        }
    }
}
