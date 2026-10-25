//
//  ZoomableImageView.swift
//  Donguri
//
//  One gallery page's image: pinch and double-tap zoom, panning while
//  zoomed, single tap to show or hide the gallery's controls, and a vertical
//  swipe to close. Built on UIScrollView, which gets zooming physics right in
//  a way SwiftUI gestures don't, and plays animated GIFs through UIImageView.
//

import SwiftUI
import UIKit

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var onTap: () -> Void = {}
    var onZoomChange: (Bool) -> Void = { _ in }
    /// 0 at rest, 1 once the swipe is far enough to close; drives the
    /// background fade.
    var onDismissProgress: (CGFloat) -> Void = { _ in }
    /// Called with the image's frame on screen (window coordinates) when a
    /// swipe closes the gallery. Returning true means the gallery animates
    /// the image back into its thumbnail itself, so it isn't flung away.
    var onDismiss: (CGRect) -> Bool = { _ in false }
    /// Recognised text to show and make tappable (OCR), or nil.
    var ocrLines: [OCRLine]? = nil
    /// A tap on recognised text, with the character's rect in the window.
    var onTextTap: ((OCRHit, CGRect) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.callbacks = context.coordinator
        context.coordinator.parent = self
        view.display(image)
        view.ocrLines = ocrLines
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        context.coordinator.parent = self
        if view.displayedImage !== image {
            view.display(image)
        }
        if view.ocrLines != ocrLines {
            view.ocrLines = ocrLines
        }
    }

    final class Coordinator {
        var parent: ZoomableImageView?

        func tapped() { parent?.onTap() }
        func zoomChanged(_ zoomed: Bool) { parent?.onZoomChange(zoomed) }
        func dismissProgress(_ progress: CGFloat) { parent?.onDismissProgress(progress) }
        func dismissed(from frame: CGRect) -> Bool { parent?.onDismiss(frame) ?? false }
        func textTapped(_ hit: OCRHit, rect: CGRect) { parent?.onTextTap?(hit, rect) }
    }
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    weak var callbacks: ZoomableImageView.Coordinator?

    private let imageView = UIImageView()
    private(set) var displayedImage: UIImage?
    private var lastLaidOutSize: CGSize = .zero
    private var wasZoomed = false

    private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))

    /// Boxes around recognised text, drawn over the image (so they zoom
    /// with it).
    private let ocrLayer = CAShapeLayer()

    var ocrLines: [OCRLine]? {
        didSet { drawOCR() }
    }

    /// How far (in points) the image has to travel to close the gallery.
    private static let dismissDistance: CGFloat = 140

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        bouncesZoom = true

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        ocrLayer.fillColor = UIColor.systemYellow.withAlphaComponent(0.16).cgColor
        ocrLayer.strokeColor = UIColor.systemYellow.withAlphaComponent(0.75).cgColor
        ocrLayer.lineWidth = 1
        imageView.layer.addSublayer(ocrLayer)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        // No delegate on purpose: UIScrollView privately implements the
        // gesture delegate methods for its own pinch and pan, and defining
        // them here would silently override those.
        addGestureRecognizer(dismissPan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ image: UIImage) {
        displayedImage = image
        imageView.image = image
        // Animated GIFs come back from MediaStore as UIImage.animatedImage,
        // which UIImageView plays on its own.
        if image.images != nil { imageView.startAnimating() }
        zoomScale = 1
        lastLaidOutSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastLaidOutSize, bounds.width > 0, bounds.height > 0 {
            lastLaidOutSize = bounds.size
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: fittedSize())
            contentSize = imageView.frame.size
            drawOCR()
        }
        centerImage()
    }

    private func drawOCR() {
        let bounds = imageView.bounds
        ocrLayer.frame = bounds
        guard let ocrLines, bounds.width > 0 else {
            ocrLayer.path = nil
            return
        }
        let path = UIBezierPath()
        for line in ocrLines {
            let rect = denormalize(line.box, in: bounds).insetBy(dx: -2, dy: -2)
            path.append(UIBezierPath(roundedRect: rect, cornerRadius: 3))
        }
        ocrLayer.path = path.cgPath
    }

    private func denormalize(_ box: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(x: box.minX * bounds.width, y: box.minY * bounds.height,
               width: box.width * bounds.width, height: box.height * bounds.height)
    }

    private func fittedSize() -> CGSize {
        guard let image = displayedImage, image.size.width > 0, image.size.height > 0 else { return bounds.size }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    /// Keeps a smaller-than-screen image in the middle rather than the corner.
    private func centerImage() {
        let offsetX = max((bounds.width - contentSize.width) / 2, 0)
        let offsetY = max((bounds.height - contentSize.height) / 2, 0)
        imageView.center = CGPoint(x: contentSize.width / 2 + offsetX,
                                   y: contentSize.height / 2 + offsetY)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        let zoomed = zoomScale > minimumZoomScale + 0.01
        if zoomed != wasZoomed {
            wasZoomed = zoomed
            callbacks?.zoomChanged(zoomed)
        }
    }

    // MARK: Taps

    @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
        if let ocrLines, imageView.bounds.width > 0 {
            let point = recognizer.location(in: imageView)
            let normalized = CGPoint(x: point.x / imageView.bounds.width, y: point.y / imageView.bounds.height)
            if let hit = TextRecognizer.hit(at: normalized, in: ocrLines) {
                let rect = imageView.convert(denormalize(hit.characterBox, in: imageView.bounds), to: nil)
                callbacks?.textTapped(hit, rect: rect)
                return
            }
        }
        callbacks?.tapped()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height),
                 animated: true)
        }
    }

    // MARK: Swipe to close

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        // Only an unzoomed, clearly vertical swipe closes the gallery. A
        // swipe that's even somewhat sideways belongs to the pager, and so
        // does any touch while the pager is still moving.
        guard zoomScale <= minimumZoomScale + 0.01 else { return false }
        if let pager = enclosingScrollView, pager.isDragging || pager.isDecelerating {
            return false
        }
        let velocity = dismissPan.velocity(in: self)
        return abs(velocity.y) > 120 && abs(velocity.y) > abs(velocity.x) * 2.2
    }

    /// The gallery's horizontal pager (SwiftUI's ScrollView is a UIScrollView
    /// underneath), found by walking up from this page.
    private var enclosingScrollView: UIScrollView? {
        var view = superview
        while let current = view {
            if let scrollView = current as? UIScrollView { return scrollView }
            view = current.superview
        }
        return nil
    }

    @objc private func handleDismissPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        let progress = min(abs(translation.y) / Self.dismissDistance, 1)

        switch recognizer.state {
        case .changed:
            // Vertical only: following the finger sideways too is what made
            // a slightly diagonal page swipe drag and squash the image.
            imageView.transform = CGAffineTransform(translationX: 0, y: translation.y)
            callbacks?.dismissProgress(progress)
        case .ended, .cancelled:
            let velocity = recognizer.velocity(in: self).y
            let shouldClose = recognizer.state == .ended
                && (abs(translation.y) > Self.dismissDistance || abs(velocity) > 900)
            if shouldClose {
                let frame = imageView.convert(imageView.bounds, to: nil)
                callbacks?.dismissProgress(1)
                if callbacks?.dismissed(from: frame) == true {
                    // The gallery's zoom-out takes over from here.
                    imageView.alpha = 0
                } else {
                    let direction: CGFloat = translation.y >= 0 ? 1 : -1
                    UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
                        self.imageView.transform = CGAffineTransform(translationX: 0,
                                                                     y: direction * self.bounds.height)
                        self.imageView.alpha = 0
                    }
                }
            } else {
                UIView.animate(withDuration: 0.3, delay: 0,
                               usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                    self.imageView.transform = .identity
                }
                callbacks?.dismissProgress(0)
            }
        default:
            break
        }
    }
}
