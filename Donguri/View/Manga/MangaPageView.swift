//
//  MangaPageView.swift
//  Donguri
//
//  One screen of the manga reader: a page or a two-page spread, fitted to
//  the screen, its width or its height, with pinch and double-tap zoom.
//  Over the pages, their text: a tap on it looks up the word (at once:
//  that tap doesn't wait to rule out a double tap), a long press picks the
//  speech bubble, and the bubbles can be outlined. Taps elsewhere report
//  where across the screen they landed, for tap-to-turn zones. A swipe
//  down closes the reader. UIScrollView underneath, as the gallery's
//  ZoomableImageView, for zoom physics SwiftUI doesn't have.
//

import SwiftUI
import UIKit

struct MangaPageView: UIViewRepresentable {
    /// Left to right as they appear (a right-to-left spread is passed with
    /// its second page first).
    let images: [UIImage]
    /// Each image's text.
    let texts: [PageText?]
    var fit: MangaPageFit = .screen
    /// Off in vertical scrolling, where the outer list scrolls.
    var zoomable = true
    var showsBoxes = false
    /// The bubble whose text is open, as (image, box).
    var highlighted: (image: Int, box: CGRect)?
    /// Where across the view (0…1) a tap off the text landed.
    var onTap: (CGFloat) -> Void = { _ in }
    var onTextTap: (Int, OCRHit, CGRect) -> Void = { _, _, _ in }
    /// A long press on a bubble: image, bubble index, bubble's rect in the window.
    var onBubble: (Int, Int, CGRect) -> Void = { _, _, _ in }
    var onZoomChange: (Bool) -> Void = { _ in }
    var onDismissProgress: (CGFloat) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MangaPageScrollView {
        let view = MangaPageScrollView()
        context.coordinator.parent = self
        view.callbacks = context.coordinator
        apply(to: view)
        return view
    }

    func updateUIView(_ view: MangaPageScrollView, context: Context) {
        context.coordinator.parent = self
        apply(to: view)
    }

    private func apply(to view: MangaPageScrollView) {
        view.configure(images: images, texts: texts, fit: fit, zoomable: zoomable,
                       showsBoxes: showsBoxes, highlighted: highlighted)
    }

    final class Coordinator {
        var parent: MangaPageView?

        func tapped(_ fraction: CGFloat) { parent?.onTap(fraction) }
        func textTapped(_ image: Int, _ hit: OCRHit, _ rect: CGRect) { parent?.onTextTap(image, hit, rect) }
        func bubble(_ image: Int, _ block: Int, _ rect: CGRect) { parent?.onBubble(image, block, rect) }
        func zoomChanged(_ zoomed: Bool) { parent?.onZoomChange(zoomed) }
        func dismissProgress(_ progress: CGFloat) { parent?.onDismissProgress(progress) }
        func dismissed() { parent?.onDismiss() }
    }
}

final class MangaPageScrollView: UIScrollView, UIScrollViewDelegate {
    weak var callbacks: MangaPageView.Coordinator?

    private let content = UIView()
    private var imageViews: [UIImageView] = []
    private var boxLayers: [CAShapeLayer] = []
    private let highlightLayer = CAShapeLayer()

    private var images: [UIImage] = []
    private var texts: [PageText?] = []
    private var lines: [[OCRLine]] = []
    private var fit: MangaPageFit = .screen
    private var zoomable = true
    private var showsBoxes = false
    private var highlighted: (image: Int, box: CGRect)?
    private var laidOutSize: CGSize = .zero
    private var wasZoomed = false

    private lazy var doubleTap: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        recognizer.numberOfTapsRequired = 2
        return recognizer
    }()
    private lazy var singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
    private lazy var textTap = UITapGestureRecognizer(target: self, action: #selector(handleTextTap(_:)))
    private lazy var longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
    private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
    private let textGate = GestureGate()

    private static let dismissDistance: CGFloat = 140

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        // A zoomed page glides as it's let go, like Photos.
        decelerationRate = .normal
        backgroundColor = .clear
        bouncesZoom = true
        addSubview(content)

        highlightLayer.fillColor = UIColor.systemYellow.withAlphaComponent(0.22).cgColor
        highlightLayer.strokeColor = UIColor.systemYellow.cgColor
        highlightLayer.lineWidth = 2

        addGestureRecognizer(doubleTap)
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
        textGate.shouldBegin = { [weak self] recognizer in
            self?.hit(at: recognizer.location(in: self?.content)) != nil
        }
        textTap.delegate = textGate
        addGestureRecognizer(textTap)
        longPress.minimumPressDuration = 0.4
        addGestureRecognizer(longPress)
        // No delegate: UIScrollView implements the gesture delegate methods
        // for its own pan and pinch.
        addGestureRecognizer(dismissPan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(images: [UIImage], texts: [PageText?], fit: MangaPageFit, zoomable: Bool,
                   showsBoxes: Bool, highlighted: (image: Int, box: CGRect)?) {
        let imagesChanged = images.count != self.images.count || zip(images, self.images).contains { $0 !== $1 }
        let layoutChanged = imagesChanged || fit != self.fit || zoomable != self.zoomable
        self.fit = fit
        self.zoomable = zoomable
        if imagesChanged {
            self.images = images
            imageViews.forEach { $0.removeFromSuperview() }
            imageViews = images.map { image in
                let view = UIImageView(image: image)
                view.contentMode = .scaleToFill
                // Smooth while shrunk below the image's own size.
                view.layer.minificationFilter = .trilinear
                content.addSubview(view)
                return view
            }
            boxLayers.forEach { $0.removeFromSuperlayer() }
            boxLayers = images.map { _ in
                let layer = CAShapeLayer()
                layer.fillColor = UIColor.systemYellow.withAlphaComponent(0.08).cgColor
                layer.strokeColor = UIColor.systemYellow.withAlphaComponent(0.7).cgColor
                layer.lineWidth = 1
                content.layer.addSublayer(layer)
                return layer
            }
            content.layer.addSublayer(highlightLayer)
        }
        if imagesChanged || texts != self.texts {
            self.texts = texts
            lines = texts.map { $0?.ocrLines() ?? [] }
            textTap.isEnabled = lines.contains { !$0.isEmpty }
        }
        self.showsBoxes = showsBoxes
        self.highlighted = highlighted
        isScrollEnabled = zoomable
        pinchGestureRecognizer?.isEnabled = zoomable
        doubleTap.isEnabled = zoomable
        dismissPan.isEnabled = zoomable
        if layoutChanged {
            laidOutSize = .zero
            setNeedsLayout()
        } else {
            drawText()
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            zoomScale = 1
            layoutPages()
        }
        center()
    }

    /// The pages side by side at one height, scaled as the fit asks.
    private func layoutPages() {
        guard !images.isEmpty else { return }
        let ratios = images.map { $0.size.width / max($0.size.height, 1) }
        let totalRatio = ratios.reduce(0, +)
        let height: CGFloat
        switch fit {
        case .screen: height = min(bounds.height, bounds.width / totalRatio)
        case .width: height = bounds.width / totalRatio
        case .height: height = bounds.height
        }
        var x: CGFloat = 0
        for (index, view) in imageViews.enumerated() {
            let width = height * ratios[index]
            view.frame = CGRect(x: x, y: 0, width: width, height: height)
            x += width
        }
        // Rounding can leave the pages a hair wider than the screen, which
        // would make the page scroll sideways instead of turning.
        if abs(x - bounds.width) < 1 { x = bounds.width }
        content.frame = CGRect(x: 0, y: 0, width: x, height: height)
        contentSize = content.frame.size
        contentOffset = .zero
        drawText()
    }

    private func center() {
        let offsetX = max((bounds.width - contentSize.width) / 2, 0)
        let offsetY = max((bounds.height - contentSize.height) / 2, 0)
        content.center = CGPoint(x: contentSize.width / 2 + offsetX, y: contentSize.height / 2 + offsetY)
    }

    private func drawText() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in boxLayers.enumerated() where index < imageViews.count {
            let frame = imageViews[index].frame
            layer.frame = content.bounds
            guard showsBoxes, let text = texts[index] else {
                layer.path = nil
                continue
            }
            let path = UIBezierPath()
            for block in text.blocks {
                path.append(UIBezierPath(roundedRect: denormalize(block.box, in: frame).insetBy(dx: -3, dy: -3), cornerRadius: 4))
            }
            layer.path = path.cgPath
        }
        highlightLayer.frame = content.bounds
        if let highlighted, imageViews.indices.contains(highlighted.image) {
            let rect = denormalize(highlighted.box, in: imageViews[highlighted.image].frame).insetBy(dx: -4, dy: -4)
            highlightLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: 5).cgPath
        } else {
            highlightLayer.path = nil
        }
        CATransaction.commit()
    }

    private func denormalize(_ box: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + box.minX * frame.width, y: frame.minY + box.minY * frame.height,
               width: box.width * frame.width, height: box.height * frame.height)
    }

    // MARK: Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { zoomable ? content : nil }

    /// Zooming holds the pages still: a pinch whose first finger had
    /// started a swipe no longer drags the next page in.
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        pager?.holdForZoom()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if scale <= minimumZoomScale + 0.01 { pager?.release() }
    }

    private var pager: PagerCollectionView? {
        var view = superview
        while let current = view {
            if let pager = current as? PagerCollectionView { return pager }
            view = current.superview
        }
        return nil
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        let zoomed = zoomScale > minimumZoomScale + 0.01
        if zoomed != wasZoomed {
            wasZoomed = zoomed
            callbacks?.zoomChanged(zoomed)
        }
    }

    // MARK: Hit testing

    /// Which page a point (in the content's space) is on, and where on it.
    private func page(at point: CGPoint) -> (index: Int, normalized: CGPoint)? {
        for (index, view) in imageViews.enumerated() where view.frame.contains(point) {
            return (index, CGPoint(x: (point.x - view.frame.minX) / view.frame.width,
                                   y: (point.y - view.frame.minY) / view.frame.height))
        }
        return nil
    }

    private func hit(at point: CGPoint) -> (index: Int, hit: OCRHit)? {
        guard let page = page(at: point), lines.indices.contains(page.index), !lines[page.index].isEmpty,
              let hit = TextRecognizer.hit(at: page.normalized, in: lines[page.index]) else { return nil }
        return (page.index, hit)
    }

    private func windowRect(_ box: CGRect, image: Int) -> CGRect {
        content.convert(denormalize(box, in: imageViews[image].frame), to: nil)
    }

    @objc private func handleTextTap(_ recognizer: UITapGestureRecognizer) {
        guard let found = hit(at: recognizer.location(in: content)) else { return }
        callbacks?.textTapped(found.index, found.hit, windowRect(found.hit.characterBox, image: found.index))
    }

    @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
        if let found = hit(at: recognizer.location(in: content)) {
            callbacks?.textTapped(found.index, found.hit, windowRect(found.hit.characterBox, image: found.index))
            return
        }
        callbacks?.tapped((recognizer.location(in: self).x - bounds.minX) / max(bounds.width, 1))
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let page = page(at: recognizer.location(in: content)),
              texts.indices.contains(page.index), let text = texts[page.index],
              let block = text.blockIndex(at: page.normalized) else { return }
        callbacks?.bubble(page.index, block, windowRect(text.blocks[block].box, image: page.index))
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = recognizer.location(in: content)
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }

    // MARK: Swipe down to close

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // At normal size a sideways drag turns the page: the page doesn't
        // take it unless it really is wider than the screen.
        if gestureRecognizer === panGestureRecognizer, zoomScale <= minimumZoomScale + 0.01,
           contentSize.width <= bounds.width + 1 {
            let velocity = panGestureRecognizer.velocity(in: self)
            if abs(velocity.x) > abs(velocity.y) { return false }
        }
        guard gestureRecognizer === dismissPan else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        // Only an unzoomed page that doesn't scroll down itself, pulled
        // clearly downward, closes the reader.
        guard zoomScale <= minimumZoomScale + 0.01, contentSize.height <= bounds.height + 1 else { return false }
        if let pager = enclosingScrollView, pager.isDragging || pager.isDecelerating { return false }
        let velocity = dismissPan.velocity(in: self)
        return velocity.y > 120 && velocity.y > abs(velocity.x) * 2.2
    }

    private var enclosingScrollView: UIScrollView? {
        var view = superview
        while let current = view {
            if let scrollView = current as? UIScrollView { return scrollView }
            view = current.superview
        }
        return nil
    }

    @objc private func handleDismissPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = max(recognizer.translation(in: self).y, 0)
        let progress = min(translation / Self.dismissDistance, 1)
        switch recognizer.state {
        case .changed:
            content.transform = CGAffineTransform(translationX: 0, y: translation)
            callbacks?.dismissProgress(progress)
        case .ended, .cancelled:
            let velocity = recognizer.velocity(in: self).y
            if recognizer.state == .ended, translation > Self.dismissDistance || velocity > 900 {
                callbacks?.dismissProgress(1)
                UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
                    self.content.transform = CGAffineTransform(translationX: 0, y: self.bounds.height)
                    self.content.alpha = 0
                } completion: { _ in
                    self.callbacks?.dismissed()
                }
            } else {
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                    self.content.transform = .identity
                }
                callbacks?.dismissProgress(0)
            }
        default:
            break
        }
    }
}

/// Lets a recognizer begin only when its test passes (text under the finger).
private final class GestureGate: NSObject, UIGestureRecognizerDelegate {
    var shouldBegin: (UIGestureRecognizer) -> Bool = { _ in false }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        shouldBegin(gestureRecognizer)
    }
}
