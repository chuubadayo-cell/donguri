//
//  CaptionSentences.swift
//  Donguri
//
//  YouTube's automatic captions come as a rolling window of words cut at
//  arbitrary points, so one line often ends mid-phrase and the next starts
//  with its tail. This rebuilds them as sentence-sized lines: it joins the
//  words back up and breaks where the speaker pauses or a sentence ends,
//  keeping lines short enough to read and mine.
//

import Foundation

nonisolated enum CaptionSentences {
    /// A word (or, for sources without word timings, a caption chunk).
    struct Piece {
        var start: Double
        var end: Double
        var text: String
    }

    /// A pause this long ends a line whatever the words say.
    static let pauseBreak = 0.75
    /// Sentence-final punctuation.
    private static let terminators: Set<Character> = ["。", "！", "？", "!", "?", "…", "．"]
    /// Japanese endings that often close a sentence; a pause after one is a
    /// better place to break than a pause after anything else.
    private static let endings = ["です", "ます", "でした", "ました", "ません", "でしょう", "ください",
                                  "ない", "よね", "よ", "ね", "な", "か", "た", "だ", "の", "けど", "から", "って", "わ"]
    /// Words that belong to the end of the line before them.
    private static let leading: Set<String> = ["ので", "のに", "けど", "から", "が", "を", "に", "は", "で", "と", "て", "って",
                                  "ね", "よ", "な", "た", "の", "し", "ん"]

    /// Lines from timed pieces, in order.
    static func lines(from input: [Piece]) -> [SubtitleCue] {
        let pieces = input.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        guard !pieces.isEmpty else { return [] }
        let spaced = usesSpaces(pieces)
        let maxLength = spaced ? 84 : 34
        let minLength = spaced ? 12 : 5
        let maxDuration = 8.0

        func gap(after index: Int) -> Double {
            index + 1 < pieces.count ? max(0, pieces[index + 1].start - pieces[index].end) : .infinity
        }
        func endsSentence(_ index: Int) -> Bool {
            let text = pieces[index].text.trimmingCharacters(in: .whitespaces)
            return text.last.map { terminators.contains($0) } ?? false
        }
        /// How good a place the gap after `index` is to break a line.
        func score(_ index: Int) -> Double {
            var value = min(gap(after: index), 2)
            if endsSentence(index) { value += 2 }
            let text = pieces[index].text.trimmingCharacters(in: .whitespaces)
            if !spaced {
                if endings.contains(where: { text.hasSuffix($0) }) { value += 0.25 }
                if text == "て" || text == "で" { value += 0.15 }
                // Never start a line with a particle or a clause's tail.
                if index + 1 < pieces.count {
                    let next = pieces[index + 1].text.trimmingCharacters(in: .whitespaces)
                    // (Automatic captions split words, so particles stand alone.)
                    if leading.contains(next) { value -= 0.6 }
                }
            }
            if spaced, text.hasSuffix(",") { value += 0.5 }
            return value
        }
        func length(_ range: Range<Int>) -> Int {
            join(pieces[range].map(\.text), spaced: spaced).count
        }

        var lines: [Range<Int>] = []
        var lineStart = 0
        var index = 0
        while index < pieces.count {
            let current = lineStart..<(index + 1)
            let isLast = index == pieces.count - 1
            let long = length(current) > maxLength
                || pieces[index].end - pieces[lineStart].start > maxDuration
            if long, current.count > 1 {
                // Too long: break at the best place inside it that leaves
                // neither side tiny.
                var best = index - 1
                var bestScore = -1.0
                for candidate in lineStart..<index {
                    let left = length(lineStart..<(candidate + 1))
                    let right = length((candidate + 1)..<(index + 1))
                    guard left >= minLength || candidate == index - 1 else { continue }
                    var value = score(candidate)
                    if right < minLength { value -= 1 }
                    // Prefer balanced halves a little.
                    value -= abs(Double(left - right)) / Double(maxLength) * 0.3
                    if value > bestScore { bestScore = value; best = candidate }
                }
                lines.append(lineStart..<(best + 1))
                lineStart = best + 1
                continue  // Re-check the remainder with the same `index`.
            }
            let pause = gap(after: index)
            let atEnd = endsSentence(index) || pause >= pauseBreak
            if isLast || (atEnd && (length(current) >= minLength || pause >= 2)) {
                lines.append(current)
                lineStart = index + 1
            }
            index += 1
        }

        var cues: [SubtitleCue] = []
        for range in lines {
            let text = join(pieces[range].map(\.text), spaced: spaced)
            guard !text.isEmpty else { continue }
            let start = pieces[range.lowerBound].start
            var end = pieces[range.upperBound - 1].end
            // A line stays up a moment after its last word, but never into
            // the next line.
            end += 0.35
            if range.upperBound < pieces.count { end = min(end, pieces[range.upperBound].start) }
            cues.append(SubtitleCue(id: cues.count, start: start, end: max(end, start + 0.3), text: text))
        }
        return cues
    }

    /// Regroups cues that came without word timings (the transcript panel,
    /// XML captions) by treating each one as a piece.
    static func regroup(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        let regrouped = lines(from: cues.map { Piece(start: $0.start, end: $0.end, text: $0.text) })
        return regrouped.isEmpty ? cues : regrouped
    }

    private static func usesSpaces(_ pieces: [Piece]) -> Bool {
        let sample = pieces.prefix(200).map(\.text).joined()
        let letters = sample.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return true }
        let cjk = letters.filter { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
        return Double(cjk.count) / Double(letters.count) < 0.3
    }

    /// Words joined as they're written: json3 words carry their own leading
    /// spaces, chunks don't, and Japanese has none.
    private static func join(_ texts: [String], spaced: Bool) -> String {
        var result = ""
        for raw in texts {
            let text = raw.replacingOccurrences(of: "\n", with: " ")
            if spaced, !result.isEmpty, !result.hasSuffix(" "), !text.hasPrefix(" ") {
                result += " "
            }
            if !spaced {
                result += text.trimmingCharacters(in: .whitespaces)
            } else {
                result += text
            }
        }
        return result.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
