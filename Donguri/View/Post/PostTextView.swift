//
//  PostTextView.swift
//  Donguri
//
//  Draws a post's text natively and does tap-to-lookup on it.
//
//  Posts used to render each in its own WKWebView, so Hoshi Reader's
//  selection.js could find the tapped word. A web view per row was the
//  heaviest thing in the app: scrolling stuttered, and because a web view
//  reports its height asynchronously, rows had to be sized from an estimate
//  and corrected later. This uses a UITextView with TextKit 1 instead, which
//  finds the tapped character directly and knows its own height up front.
//
//  The lookup behaviour is selection.js's, ported: the same scan delimiters,
//  the same "only Japanese unless scanNonJapaneseText" rule, the same sentence
//  extraction with bracket balancing, and tapping the selected character
//  again dismisses the popup. selection.js itself is still used by the popup.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UIKit

struct SelectionData {
    let text: String
    let sentence: String
    let rect: CGRect
    var normalizedOffset: Int? = nil
}

extension NSAttributedString.Key {
    /// Where a link in a post goes. Not `.link`: UITextView only follows
    /// `.link` when its text is selectable, and post text deliberately isn't.
    static let donguriLink = NSAttributedString.Key("donguri.link")
}

struct PostTextView: UIViewRepresentable {
    /// The post's text as `PostService` stores it: plain text, with `>>N`
    /// anchors and HTML links as `[label](url)`.
    let text: String
    let scanNonJapaneseText: Bool
    let style: PostTextStyle
    var maxSelectionLength: Int = 16
    var onTextSelected: (SelectionData) -> Int?
    var onTapOutside: () -> Void
    var onPostReply: (Int) -> Void
    var onThreadRoute: (ThreadRoute) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        // TextKit 1, explicitly: hit testing goes through NSLayoutManager.
        let textView = UITextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.dataDetectorTypes = []
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        textView.addGestureRecognizer(tap)

        context.coordinator.textView = textView
        context.coordinator.render()
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.parent.text != text || coordinator.parent.style.key != style.key
        coordinator.parent = self
        if changed { coordinator.render() }
    }

    /// The real height for the offered width, so rows are sized correctly on
    /// the first layout pass.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        PostSelectionCenter.shared.release(coordinator)
    }

    final class Coordinator: NSObject {
        var parent: PostTextView
        weak var textView: UITextView?
        /// UTF-16 offset of the selected character, while a lookup is showing.
        private var selectionStart: Int?

        init(parent: PostTextView) {
            self.parent = parent
        }

        func render() {
            guard let textView else { return }
            textView.attributedText = PostTextFormatter.attributed(parent.text, style: parent.style)
            selectionStart = nil
            textView.invalidateIntrinsicContentSize()
        }

        func clearHighlight() {
            guard let textView, selectionStart != nil else { return }
            selectionStart = nil
            let storage = textView.textStorage
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView else { return }
            let point = gesture.location(in: textView)

            guard let hit = characterIndex(at: point, in: textView) else {
                dismiss()
                return
            }

            let storage = textView.textStorage
            if let url = storage.attribute(.donguriLink, at: hit.index, effectiveRange: nil) as? URL {
                PostSelectionCenter.shared.clearAll()
                follow(url)
                return
            }

            // Tapping the looked-up character again closes the popup.
            if hit.index == selectionStart {
                dismiss()
                return
            }

            let string = storage.string as NSString
            guard let scanned = PostTextScanner.scan(string, from: hit.index,
                                                     maxLength: parent.maxSelectionLength,
                                                     scanNonJapanese: parent.scanNonJapaneseText) else {
                dismiss()
                return
            }

            PostSelectionCenter.shared.claim(self)
            let sentence = PostTextScanner.sentence(string, around: hit.index)
            let windowRect = textView.convert(hit.rect, to: nil)
            let selection = SelectionData(text: scanned, sentence: sentence, rect: windowRect)

            clearHighlight()
            guard let matched = parent.onTextSelected(selection), matched > 0 else { return }
            highlight(from: hit.index, characters: matched, in: textView)
        }

        private func dismiss() {
            PostSelectionCenter.shared.clearAll()
            parent.onTapOutside()
        }

        private func highlight(from offset: Int, characters: Int, in textView: UITextView) {
            let storage = textView.textStorage
            let string = storage.string
            let utf16 = string.utf16
            guard let start = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex),
                  let startIndex = start.samePosition(in: string) else { return }
            let endIndex = string.index(startIndex, offsetBy: characters, limitedBy: string.endIndex) ?? string.endIndex
            let range = NSRange(startIndex..<endIndex, in: string)
            storage.addAttribute(.backgroundColor, value: parent.style.highlightColor, range: range)
            selectionStart = offset
        }

        /// The character under `point`, if the point is really on it (not in
        /// the empty space after a line), with its rect in text-view space.
        private func characterIndex(at point: CGPoint, in textView: UITextView) -> (index: Int, rect: CGRect)? {
            let layoutManager = textView.layoutManager
            let container = textView.textContainer
            guard textView.textStorage.length > 0 else { return nil }

            let inset = textView.textContainerInset
            let containerPoint = CGPoint(x: point.x - inset.left, y: point.y - inset.top)

            let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: container)
            for candidate in [glyphIndex, glyphIndex - 1, glyphIndex + 1]
            where candidate >= 0 && candidate < layoutManager.numberOfGlyphs {
                let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: candidate, length: 1),
                                                      in: container)
                if rect.insetBy(dx: -1, dy: -1).contains(containerPoint) {
                    let index = layoutManager.characterIndexForGlyph(at: candidate)
                    return (index, rect.offsetBy(dx: inset.left, dy: inset.top))
                }
            }
            return nil
        }

        private func follow(_ url: URL) {
            // Same-thread reply anchor (>>N)
            if url.scheme == "donguri", url.host == "res",
               let number = Int(url.lastPathComponent), number >= 1 {
                parent.onPostReply(number - 1)
                return
            }
            // Link to another 5ch thread
            if let route = ThreadRoute.parse(url) {
                parent.onThreadRoute(route)
                return
            }
            if url.scheme == "http" || url.scheme == "https" {
                UIApplication.shared.open(url)
            }
        }
    }
}

/// Only one post shows a lookup highlight at a time: selecting in one post,
/// or closing the popup, clears it everywhere else.
final class PostSelectionCenter {
    static let shared = PostSelectionCenter()

    private weak var owner: PostTextView.Coordinator?

    func claim(_ coordinator: PostTextView.Coordinator) {
        if let owner, owner !== coordinator { owner.clearHighlight() }
        owner = coordinator
    }

    func release(_ coordinator: PostTextView.Coordinator) {
        if owner === coordinator { owner = nil }
    }

    func clearAll() {
        owner?.clearHighlight()
        owner = nil
    }
}

extension ThreadRoute {
    /// `https://<server>.5ch.<tld>/test/read.cgi/<board>/<thread>/…`
    static func parse(_ url: URL) -> ThreadRoute? {
        guard let host = url.host, host.contains(".5ch.") else { return nil }
        let components = url.pathComponents
        guard let cgiIndex = components.firstIndex(of: "read.cgi"),
              components.count > cgiIndex + 2,
              let threadId = Int(components[cgiIndex + 2]) else { return nil }
        let directoryName = components[cgiIndex + 1]
        return ThreadRoute(boardURL: "https://\(host)/\(directoryName)/", threadId: threadId)
    }
}

// MARK: - Formatting

/// Builds the attributed string for a post: `[label](url)` links become
/// their label, bare URLs (including 5ch's `ttps://`) become links too.
enum PostTextFormatter {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 3000
        return cache
    }()

    static func attributed(_ text: String, style: PostTextStyle) -> NSAttributedString {
        let key = (style.key + "\u{1}" + text) as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let font = style.font
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = style.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping

        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.textColor,
            .paragraphStyle: paragraph,
        ]
        let result = NSMutableAttributedString()

        func appendPlain(_ string: Substring) {
            guard !string.isEmpty else { return }
            // Bare links inside plain runs.
            var cursor = string.startIndex
            for match in string.matches(of: #/h?ttps?:\/\/[^\s<>"'\]\)]+/#) {
                result.append(NSAttributedString(string: String(string[cursor..<match.range.lowerBound]),
                                                 attributes: base))
                let raw = String(match.0)
                let urlString = raw.hasPrefix("ttp") ? "h" + raw : raw
                appendLink(raw, url: URL(string: urlString))
                cursor = match.range.upperBound
            }
            result.append(NSAttributedString(string: String(string[cursor...]), attributes: base))
        }

        func appendLink(_ label: String, url: URL?) {
            var attributes = base
            if let url {
                attributes[.foregroundColor] = style.linkColor
                attributes[.donguriLink] = url
            }
            result.append(NSAttributedString(string: label, attributes: attributes))
        }

        var cursor = text.startIndex
        for match in text.matches(of: #/\[([^\]]*)\]\(([^)\s]+)\)/#) {
            appendPlain(text[cursor..<match.range.lowerBound])
            let label = String(match.1)
            let href = String(match.2)
            let allowed = href.hasPrefix("donguri://") || href.hasPrefix("http://") || href.hasPrefix("https://")
            appendLink(label, url: allowed ? URL(string: href) : nil)
            cursor = match.range.upperBound
        }
        appendPlain(text[cursor...])

        cache.setObject(result, forKey: key)
        return result
    }
}

// MARK: - Scanning (ported from selection.js)

nonisolated enum PostTextScanner {
    private static let scanDelimiters = Set("。、！？…‥「」『』（）()【】〈〉《》〔〕｛｝{}［］[]・：；:;，,.─\n\r".unicodeScalars)
    private static let sentenceDelimiters = Set("。！？.!?\n\r".unicodeScalars)
    private static let trailingSentenceChars = Set("。、！？…‥」』）)】〉》〕｝}］]".unicodeScalars)
    private static let brackets: [Character: Character] = [
        "「": "」", "『": "』", "（": "）", "(": ")", "【": "】", "〈": "〉",
        "《": "》", "〔": "〕", "｛": "｝", "{": "}", "［": "］", "[": "]",
    ]

    private static let japaneseRanges: [ClosedRange<UInt32>] = [
        0x3040...0x309F, 0x30A0...0x30FF,                        // kana
        0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF,      // CJK ideographs
        0x2A700...0x2B73F, 0x2B740...0x2B81F, 0x2B820...0x2CEAF,
        0x2CEB0...0x2EBEF, 0x30000...0x3134F, 0x31350...0x323AF,
        0x2EBF0...0x2EE5F, 0xF900...0xFAFF, 0x2F800...0x2FA1F,
        0xFF66...0xFF9F,                                          // halfwidth katakana
        0x30FB...0x30FC, 0xFF61...0xFF65,                         // kana punctuation
        0x3000...0x303F,                                          // CJK punctuation
        0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A,        // fullwidth
        0xFF01...0xFF0F, 0xFF1A...0xFF1F, 0xFF3B...0xFF3F,
        0xFF5B...0xFF60, 0xFFE0...0xFFEE,
    ]

    static func isJapanese(_ scalar: Unicode.Scalar) -> Bool {
        japaneseRanges.contains { $0.contains(scalar.value) }
    }

    static func isScanBoundary(_ scalar: Unicode.Scalar, scanNonJapanese: Bool) -> Bool {
        scalar.properties.isWhitespace
            || scalar == "\u{3000}"
            || scanDelimiters.contains(scalar)
            || (!scanNonJapanese && !isJapanese(scalar))
    }

    /// The scalar starting at UTF-16 `offset`, and its length in UTF-16 units.
    private static func scalarAt(_ string: NSString, _ offset: Int) -> (scalar: Unicode.Scalar, width: Int)? {
        guard offset >= 0, offset < string.length else { return nil }
        let unit = string.character(at: offset)
        if UTF16.isLeadSurrogate(unit), offset + 1 < string.length {
            let trail = string.character(at: offset + 1)
            if UTF16.isTrailSurrogate(trail) {
                let value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(trail) - 0xDC00)
                return Unicode.Scalar(value).map { (scalar: $0, width: 2) }
            }
        }
        return Unicode.Scalar(unit).map { (scalar: $0, width: 1) }
    }

    /// Text from `offset` up to the first boundary, at most `maxLength` UTF-16
    /// units. Nil when the tapped character is itself a boundary.
    static func scan(_ string: NSString, from offset: Int, maxLength: Int, scanNonJapanese: Bool) -> String? {
        var result = String.UnicodeScalarView()
        var position = offset
        var length = 0
        while length < maxLength, let next = scalarAt(string, position) {
            if isScanBoundary(next.scalar, scanNonJapanese: scanNonJapanese) { break }
            result.append(next.scalar)
            position += next.width
            length += next.width
        }
        return result.isEmpty ? nil : String(result)
    }

    /// The sentence containing `offset`, trimmed, with unbalanced leading
    /// opening brackets and trailing closing brackets removed.
    static func sentence(_ string: NSString, around offset: Int) -> String {
        let full = string as String
        let scalars = Array(full.unicodeScalars)
        // Map the UTF-16 offset to a scalar index.
        var utf16Count = 0
        var start = 0
        while start < scalars.count, utf16Count < offset {
            utf16Count += UTF16.width(scalars[start])
            start += 1
        }

        var lower = start
        while lower > 0, !sentenceDelimiters.contains(scalars[lower - 1]) {
            lower -= 1
        }

        var upper = start
        while upper < scalars.count {
            if sentenceDelimiters.contains(scalars[upper]) {
                upper += 1
                while upper < scalars.count, trailingSentenceChars.contains(scalars[upper]) {
                    upper += 1
                }
                break
            }
            upper += 1
        }

        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[lower..<upper])
        let sentence = String(view).trimmingCharacters(in: .whitespacesAndNewlines)
        return balanceBrackets(sentence)
    }

    private static func balanceBrackets(_ sentence: String) -> String {
        let characters = Array(sentence)
        let closers = Set(brackets.values)
        var stack: [Character] = []
        var unmatchedClose: [Character] = []

        for character in characters {
            if brackets[character] != nil {
                stack.append(character)
            } else if closers.contains(character) {
                if let last = stack.last, brackets[last] == character {
                    stack.removeLast()
                } else {
                    unmatchedClose.append(character)
                }
            }
        }

        var startSlice = 0
        while !stack.isEmpty, startSlice < characters.count - 1 {
            guard stack[0] == characters[startSlice] else { break }
            stack.removeFirst()
            startSlice += 1
        }

        var endSlice = characters.count - 1
        var endIndex = characters.count - 1
        while !unmatchedClose.isEmpty, endIndex > startSlice {
            if unmatchedClose.last == characters[endIndex] {
                unmatchedClose.removeLast()
                endSlice = endIndex - 1
            } else if !characters[endIndex].unicodeScalars.allSatisfy({ sentenceDelimiters.contains($0) }) {
                break
            }
            endIndex -= 1
        }

        guard startSlice <= endSlice else { return "" }
        return String(characters[startSlice...endSlice]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
