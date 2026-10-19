//
//  NextThreadFinder.swift
//  Donguri
//
//  Finds a full thread's 次スレ (continuation) in its board's listing, the
//  way Chance suggests "New … thread" at the end of a finished thread.
//  Series threads keep their title and bump a number (Part 37 → Part 38,
//  ★5 → ★6), so titles are compared with the numbers and decorations
//  stripped out.
//

import Foundation

nonisolated enum NextThreadFinder {
    static func find(after currentID: Int, title: String, in threads: [Thread]) -> Thread? {
        let target = normalized(title)
        guard !target.isEmpty else { return nil }

        var best: (thread: Thread, score: Double)?
        for candidate in threads where candidate.id > currentID {
            guard let candidateTitle = candidate.title else { continue }
            let score = similarity(target, normalized(candidateTitle))
            guard score >= 0.6 else { continue }
            if let current = best {
                // Higher score wins; on a tie, the closest successor.
                if score > current.score || (score == current.score && candidate.id < current.thread.id) {
                    best = (candidate, score)
                }
            } else {
                best = (candidate, score)
            }
        }
        return best?.thread
    }

    /// The title without digits, part markers, brackets, stars and spaces.
    static func normalized(_ title: String) -> String {
        var text = title.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? title
        text = text.lowercased()
        for marker in ["part", "その", "スレ"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        let removable = CharacterSet.decimalDigits
            .union(.whitespacesAndNewlines)
            .union(.punctuationCharacters)
            .union(.symbols)
            .union(CharacterSet(charactersIn: "★☆■□◆◇●○【】［］「」『』〈〉《》（）"))
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { !removable.contains($0) }))
    }

    /// 1 for identical, otherwise how much of the longer title the two share
    /// from the start.
    static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let shared = zip(a, b).prefix { $0 == $1 }.count
        return Double(shared) / Double(max(a.count, b.count))
    }
}
