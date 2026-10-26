//
//  PostSnapshot.swift
//  Donguri
//
//  A picture of the post a word was mined from (a 5ch post, a YouTube
//  comment, an X post or a paragraph of a page), for the card's
//  {book-cover} field. Taken only when + is pressed: a post tap just
//  remembers which row it was. A picture the card already has (an OCR'd
//  image, a video frame) wins over this.
//

import UIKit
import WebKit

enum PostSnapshot {
    static let enabledKey = "iroha.anki.postScreenshot"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Long posts are cut to this many times their width, around the word.
    private static let maxAspect: CGFloat = 1.1
    static let maxSide: CGFloat = 900

    /// The row a native post text was tapped in.
    struct Source {
        weak var row: UIView?
        weak var textView: UITextView?
        /// What the text said when tapped. Rows are reused as lists
        /// scroll; a row showing something else by now isn't pictured.
        let text: String
        /// The tapped word, in the row's coordinates.
        let focus: CGRect
    }

    /// The last post text tapped, set before its lookup runs.
    static var lastSource: Source?

    /// Called by `PostTextView` as a word is tapped.
    static func noteTap(in textView: UITextView, wordRect: CGRect) {
        let row = rowView(containing: textView)
        lastSource = Source(row: row, textView: textView, text: textView.text ?? "",
                            focus: textView.convert(wordRect, to: row))
    }

    /// A provider for `PopupStack.mediaProvider` / `PopupView`, fixed to
    /// the post tapped just now.
    static func provider() -> (() async -> CardMedia?)? {
        guard let source = lastSource else { return nil }
        return { await media(for: source) }
    }

    /// The card media for the last post tapped.
    static func currentMedia() async -> CardMedia? {
        guard let source = lastSource else { return nil }
        return await media(for: source)
    }

    private static func media(for source: Source) async -> CardMedia? {
        guard enabled, let image = render(source) else { return nil }
        let side = maxSide
        let url = await Task.detached(priority: .userInitiated) { CardImage.write(image, maxSide: side) }.value
        return url.map { CardMedia(imageURL: $0) }
    }

    /// The nearest list row, or failing that a container a few levels up.
    private static func rowView(containing view: UIView) -> UIView {
        var current: UIView? = view.superview
        var fallback: UIView = view
        var depth = 0
        while let candidate = current {
            if candidate is UICollectionViewCell || candidate is UITableViewCell { return candidate }
            if depth < 4, candidate.bounds.width <= view.bounds.width + 64 { fallback = candidate }
            if candidate is UIScrollView || candidate is UIWindow { break }
            current = candidate.superview
            depth += 1
        }
        return fallback
    }

    static func render(_ source: Source) -> UIImage? {
        guard let row = source.row, let textView = source.textView,
              row.window != nil, textView.window != nil,
              textView.text == source.text else { return nil }
        let bounds = row.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let crop = cropRect(in: bounds, focus: source.focus)
        let background = backgroundColor(of: row)
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(2, max(1, maxSide / crop.width * 1.2))
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: crop.size, format: format)
        return renderer.image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: crop.size))
            row.drawHierarchy(in: CGRect(x: -crop.minX, y: -crop.minY, width: bounds.width, height: bounds.height),
                              afterScreenUpdates: false)
        }
    }

    /// The whole row, or for a tall one a window around the word.
    static func cropRect(in bounds: CGRect, focus: CGRect) -> CGRect {
        let maxHeight = (bounds.width * maxAspect).rounded()
        guard bounds.height > maxHeight else { return bounds }
        let center = focus.isNull ? bounds.minY : focus.midY
        let top = min(max(bounds.minY, center - maxHeight / 2), bounds.maxY - maxHeight)
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: maxHeight)
    }

    /// The first opaque colour behind the row, so a clear row doesn't
    /// come out black.
    private static func backgroundColor(of view: UIView) -> UIColor {
        var current: UIView? = view
        while let candidate = current {
            if let color = candidate.backgroundColor, color.cgColor.alpha > 0.9 {
                return color.resolvedColor(with: view.traitCollection)
            }
            if let cell = candidate as? UICollectionViewCell,
               let color = cell.backgroundConfiguration?.backgroundColor, color.cgColor.alpha > 0.9 {
                return color.resolvedColor(with: view.traitCollection)
            }
            current = candidate.superview
        }
        return UIColor.systemBackground.resolvedColor(with: view.traitCollection)
    }

    // MARK: Web pages

    /// A web element's picture: `block` is the post or paragraph, `focus`
    /// the word, both in the web view's own coordinates when tapped.
    /// `offset` is the page's scroll position then; the picture is taken
    /// at + time, so a page scrolled since is allowed for.
    static func webProvider(webView: WKWebView, block: CGRect, focus: CGRect, offset: CGPoint) -> (() async -> CardMedia?)? {
        guard enabled, block.width > 20, block.height > 10 else { return nil }
        return { [weak webView] in
            guard enabled, let webView else { return nil }
            let now = webView.scrollView.contentOffset
            let shift = CGPoint(x: offset.x - now.x, y: offset.y - now.y)
            let moved = block.offsetBy(dx: shift.x, dy: shift.y)
            let movedFocus = focus.offsetBy(dx: shift.x, dy: shift.y)
            let visible = moved.intersection(webView.bounds)
            guard !visible.isNull, visible.width > 20, visible.height > 10 else { return nil }
            let rect = cropRect(in: visible, focus: movedFocus).integral
            let configuration = WKSnapshotConfiguration()
            configuration.rect = rect
            configuration.afterScreenUpdates = false
            configuration.snapshotWidth = NSNumber(value: Double(min(rect.width, maxSide / 2)))
            guard let image = try? await webView.takeSnapshot(configuration: configuration) else { return nil }
            let side = maxSide
            let url = await Task.detached(priority: .userInitiated) { CardImage.write(image, maxSide: side) }.value
            return url.map { CardMedia(imageURL: $0) }
        }
    }
}
