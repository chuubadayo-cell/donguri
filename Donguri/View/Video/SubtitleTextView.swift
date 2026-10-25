//
//  SubtitleTextView.swift
//  Donguri
//
//  A subtitle line over the video: centred, white on a dark backing, and
//  tap-to-look-up like post text (same scanner, same highlight).
//

import SwiftUI
import UIKit

struct SubtitleTextView: UIViewRepresentable {
    let text: String
    var fontSize: CGFloat = 20
    var scanNonJapaneseText = false
    /// While a lookup popup is open the looked-up word stays highlighted.
    var lookupOpen: Bool
    var onTextSelected: (SelectionData) -> Int?
    var onTapOutside: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        textView.addGestureRecognizer(tap)
        context.coordinator.textView = textView
        context.coordinator.render()
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.parent.text != text || coordinator.parent.fontSize != fontSize
        coordinator.parent = self
        if changed {
            coordinator.render()
        } else if !lookupOpen {
            coordinator.clearHighlight()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 600
        let bounds = uiView.attributedText.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                        context: nil)
        let fitted = min(width, ceil(bounds.width) + 1)
        let size = uiView.sizeThatFits(CGSize(width: fitted, height: .greatestFiniteMagnitude))
        return CGSize(width: fitted, height: ceil(size.height))
    }

    static func attributed(_ text: String, size: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 1.05
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
            .shadow: shadow,
        ])
    }

    final class Coordinator: NSObject {
        var parent: SubtitleTextView
        weak var textView: UITextView?
        private var selectionStart: Int?

        init(parent: SubtitleTextView) {
            self.parent = parent
        }

        func render() {
            guard let textView else { return }
            textView.attributedText = SubtitleTextView.attributed(parent.text, size: parent.fontSize)
            selectionStart = nil
            textView.invalidateIntrinsicContentSize()
        }

        func clearHighlight() {
            guard let textView, selectionStart != nil else { return }
            selectionStart = nil
            textView.textStorage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: textView.textStorage.length))
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView else { return }
            let point = gesture.location(in: textView)
            guard let hit = characterIndex(at: point, in: textView) else {
                clearHighlight()
                parent.onTapOutside()
                return
            }
            if hit.index == selectionStart {
                clearHighlight()
                parent.onTapOutside()
                return
            }
            let string = textView.textStorage.string as NSString
            guard let scanned = PostTextScanner.scan(string, from: hit.index, maxLength: 16,
                                                     scanNonJapanese: parent.scanNonJapaneseText) else {
                clearHighlight()
                parent.onTapOutside()
                return
            }
            let sentence = parent.text.replacingOccurrences(of: "\n", with: "")
            let selection = SelectionData(text: scanned, sentence: sentence, rect: textView.convert(hit.rect, to: nil))
            clearHighlight()
            guard let matched = parent.onTextSelected(selection), matched > 0 else { return }
            highlight(from: hit.index, characters: matched, in: textView)
        }

        private func highlight(from offset: Int, characters: Int, in textView: UITextView) {
            let storage = textView.textStorage
            let string = storage.string
            let utf16 = string.utf16
            guard let start = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex),
                  let startIndex = start.samePosition(in: string) else { return }
            let endIndex = string.index(startIndex, offsetBy: characters, limitedBy: string.endIndex) ?? string.endIndex
            storage.addAttribute(.backgroundColor, value: UIColor.white.withAlphaComponent(0.3),
                                 range: NSRange(startIndex..<endIndex, in: string))
            selectionStart = offset
        }

        private func characterIndex(at point: CGPoint, in textView: UITextView) -> (index: Int, rect: CGRect)? {
            let layoutManager = textView.layoutManager
            let container = textView.textContainer
            guard textView.textStorage.length > 0 else { return nil }
            let glyphIndex = layoutManager.glyphIndex(for: point, in: container)
            for candidate in [glyphIndex, glyphIndex - 1, glyphIndex + 1]
            where candidate >= 0 && candidate < layoutManager.numberOfGlyphs {
                let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: candidate, length: 1), in: container)
                if rect.insetBy(dx: -2, dy: -2).contains(point) {
                    return (layoutManager.characterIndexForGlyph(at: candidate), rect)
                }
            }
            return nil
        }
    }
}
