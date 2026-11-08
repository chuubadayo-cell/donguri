//
//  MangaPager.swift
//  Donguri
//
//  The reader's pages side by side, UIKit's way: a paging collection view
//  whose cells hold the page view (MangaPageScrollView) directly, with
//  nothing of SwiftUI's between the finger and the scroll views. (Hosting
//  each page's SwiftUI view in the cells kept the pages from being swiped
//  on the phone, and its redraws made panning a zoomed page jump.) Only
//  the end card is SwiftUI. The page on screen is reported once a swipe
//  settles, not on every frame of it.
//
//  Zooming and turning pages don't mix: a pinch cancels a swipe that had
//  started and holds the pages still until the page is back at its normal
//  size (holdForZoom / release, called by the page itself).
//

import SwiftUI
import UIKit

/// One screen of the pager: its pages (left to right as shown), or the
/// end card.
struct PagerSlot {
    let id: String
    let pages: [ReaderPage]
    var isEnd = false
}

/// What the pager tells the reader.
struct PagerHandlers {
    var onTap: (CGFloat) -> Void
    var onTextTap: (ReaderPage, OCRHit, CGRect) -> Void
    var onBubble: (ReaderPage, Int) -> Void
    var onZoomChange: (Bool) -> Void
    var onImage: (ReaderPage, UIImage) -> Void
}

struct MangaPager<EndCard: View>: UIViewRepresentable {
    /// Left to right as they sit on screen.
    let slots: [PagerSlot]
    @Binding var currentID: String?
    /// While a page is zoomed: no swiping to another.
    var locked = false
    let fit: MangaPageFit
    let showsBoxes: Bool
    let highlighted: OpenBubble?
    /// Changes whenever any page's text does, so the pages on screen pick
    /// it up.
    let textVersion: Int
    let pageText: (ReaderPage) -> PageText?
    let handlers: PagerHandlers
    @ViewBuilder let endCard: () -> EndCard

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> PagerCollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        let view = PagerCollectionView(frame: .zero, collectionViewLayout: layout)
        view.isPagingEnabled = true
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.backgroundColor = .clear
        view.alwaysBounceVertical = false
        view.decelerationRate = .fast
        view.register(MangaPageCell.self, forCellWithReuseIdentifier: "page")
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "end")
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.onResize = { [weak coordinator = context.coordinator] in coordinator?.keepPage() }
        context.coordinator.collectionView = view
        context.coordinator.ids = slots.map(\.id)
        return view
    }

    func updateUIView(_ view: PagerCollectionView, context: Context) {
        context.coordinator.update(parent: self)
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        var parent: MangaPager
        weak var collectionView: PagerCollectionView?
        var ids: [String] = []
        /// The slot the pager shows (or is scrolling to).
        private var shownID: String?

        init(parent: MangaPager) {
            self.parent = parent
        }

        func update(parent: MangaPager) {
            self.parent = parent
            guard let view = collectionView else { return }
            if !parent.locked, !view.isHeldForZoom { view.isScrollEnabled = true }
            if parent.locked { view.isScrollEnabled = false }
            let newIDs = parent.slots.map(\.id)
            if newIDs != ids {
                ids = newIDs
                view.reloadData()
                view.layoutIfNeeded()
                scroll(to: parent.currentID, animated: false)
                return
            }
            // The pages on screen take the new text, outlines, highlight;
            // their zoom and position are left alone.
            for cell in view.visibleCells {
                guard let cell = cell as? MangaPageCell, let indexPath = view.indexPath(for: cell),
                      parent.slots.indices.contains(indexPath.item) else { continue }
                cell.refresh(with: self)
            }
            if parent.currentID != shownID {
                let from = shownID.flatMap { ids.firstIndex(of: $0) }
                let to = parent.currentID.flatMap { ids.firstIndex(of: $0) }
                // A neighbour (a tap on the edge) slides; a jump doesn't.
                let animated = from != nil && to != nil && abs(from! - to!) == 1
                scroll(to: parent.currentID, animated: animated)
            }
        }

        private func scroll(to id: String?, animated: Bool) {
            guard let view = collectionView, let id, let index = ids.firstIndex(of: id), view.bounds.width > 0 else { return }
            shownID = id
            let offset = CGPoint(x: CGFloat(index) * view.bounds.width, y: 0)
            if view.contentOffset != offset {
                view.setContentOffset(offset, animated: animated)
            }
        }

        /// After rotating, the same page stays on screen.
        func keepPage() {
            guard let view = collectionView else { return }
            view.collectionViewLayout.invalidateLayout()
            view.layoutIfNeeded()
            scroll(to: shownID ?? parent.currentID, animated: false)
        }

        // MARK: Data source

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.slots.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let slot = parent.slots[indexPath.item]
            if slot.isEnd {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "end", for: indexPath)
                cell.contentConfiguration = UIHostingConfiguration { parent.endCard() }.margins(.all, 0)
                return cell
            }
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath) as! MangaPageCell
            cell.show(slot, with: self)
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            collectionView.bounds.size
        }

        func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                            forItemAt indexPath: IndexPath) {
            // A page swiped away is whole again when it comes back.
            (cell as? MangaPageCell)?.pageView.resetZoom(animated: false)
        }

        // MARK: Settling

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settled(scrollView) }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settled(scrollView) }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { settled(scrollView) }
        }

        private func settled(_ scrollView: UIScrollView) {
            guard scrollView.bounds.width > 0, !ids.isEmpty else { return }
            let index = min(max(Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded()), 0), ids.count - 1)
            let id = ids[index]
            shownID = id
            if parent.currentID != id { parent.currentID = id }
        }
    }
}

/// One screen of pages: loads their images, then shows them in a page
/// view, and keeps that view's zoom while text and outlines change.
final class MangaPageCell: UICollectionViewCell, MangaPageCallbacks {
    let pageView = MangaPageScrollView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let failure = UIStackView()

    private var slotID: String?
    private var pages: [ReaderPage] = []
    private var images: [String: UIImage] = [:]
    private var loadTask: Task<Void, Never>?
    private var handlers: PagerHandlers?
    private var configured: (fit: MangaPageFit, boxes: Bool, highlight: String?, texts: Int)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        pageView.callbacks = self
        pageView.isHidden = true
        pageView.frame = contentView.bounds
        pageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(pageView)

        spinner.color = .gray
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)

        let label = UILabel()
        label.text = String(localized: "画像を読み込めませんでした")
        label.textColor = .gray
        label.font = .preferredFont(forTextStyle: .subheadline)
        let retry = UIButton(configuration: .bordered())
        retry.setTitle(String(localized: "再試行"), for: .normal)
        retry.addAction(UIAction { [weak self] _ in self?.load() }, for: .primaryActionTriggered)
        failure.axis = .vertical
        failure.alignment = .center
        failure.spacing = 12
        failure.addArrangedSubview(label)
        failure.addArrangedSubview(retry)
        failure.isHidden = true
        failure.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(failure)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            failure.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            failure.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
    }

    private var pageTextLookup: ((ReaderPage) -> PageText?)?
    private var fit: MangaPageFit = .screen
    private var showsBoxes = false
    private var openBubble: OpenBubble?
    private var textVersion = 0

    func show<EndCard: View>(_ slot: PagerSlot, with coordinator: MangaPager<EndCard>.Coordinator) {
        take(coordinator)
        if slot.id != slotID {
            slotID = slot.id
            pages = slot.pages
            images = [:]
            configured = nil
            pageView.isHidden = true
            load()
        } else {
            apply()
        }
    }

    func refresh<EndCard: View>(with coordinator: MangaPager<EndCard>.Coordinator) {
        take(coordinator)
        apply()
    }

    private func take<EndCard: View>(_ coordinator: MangaPager<EndCard>.Coordinator) {
        let parent = coordinator.parent
        handlers = parent.handlers
        pageTextLookup = parent.pageText
        fit = parent.fit
        showsBoxes = parent.showsBoxes
        openBubble = parent.highlighted
        textVersion = parent.textVersion
    }

    private func load() {
        loadTask?.cancel()
        failure.isHidden = true
        for page in pages where images[page.id] == nil {
            if let cached = MangaImages.cached(page.id) {
                images[page.id] = cached
                handlers?.onImage(page, cached)
            }
        }
        if pages.allSatisfy({ images[$0.id] != nil }) {
            apply()
            return
        }
        spinner.startAnimating()
        let wanted = slotID
        loadTask = Task { [weak self] in
            guard let self else { return }
            for page in pages where images[page.id] == nil {
                do {
                    let image = try await page.load()
                    guard !Task.isCancelled, slotID == wanted else { return }
                    images[page.id] = image
                    handlers?.onImage(page, image)
                } catch {
                    guard !Task.isCancelled, slotID == wanted else { return }
                    spinner.stopAnimating()
                    failure.isHidden = false
                    return
                }
            }
            spinner.stopAnimating()
            apply()
        }
    }

    /// Hands the page view its images and the current text; it lays the
    /// pages out again only when those images or the fit change.
    private func apply() {
        let ordered = pages.compactMap { images[$0.id] }
        guard ordered.count == pages.count, !pages.isEmpty else { return }
        spinner.stopAnimating()
        let highlight = openBubble.flatMap { bubble in
            pages.firstIndex { $0.id == bubble.pageID }.map { (image: $0, box: bubble.box) }
        }
        let state = (fit: fit, boxes: showsBoxes, highlight: openBubble?.id, texts: textVersion)
        if let configured, configured == state, !pageView.isHidden { return }
        configured = state
        pageView.configure(images: ordered,
                           texts: pages.map { pageTextLookup?($0) },
                           fit: fit,
                           zoomable: true,
                           showsBoxes: showsBoxes,
                           highlighted: highlight)
        pageView.isHidden = false
    }

    // MARK: MangaPageCallbacks

    func tapped(_ fraction: CGFloat) { handlers?.onTap(fraction) }

    func textTapped(_ image: Int, _ hit: OCRHit, _ rect: CGRect) {
        guard pages.indices.contains(image) else { return }
        handlers?.onTextTap(pages[image], hit, rect)
    }

    func bubble(_ image: Int, _ block: Int, _ rect: CGRect) {
        guard pages.indices.contains(image) else { return }
        handlers?.onBubble(pages[image], block)
    }

    func zoomChanged(_ zoomed: Bool) { handlers?.onZoomChange(zoomed) }
}

/// Tells the pager when its size changes (rotation), and lets a page
/// stop a swipe when a pinch begins.
final class PagerCollectionView: UICollectionView {
    var onResize: (() -> Void)?
    private var lastSize: CGSize = .zero
    private(set) var isHeldForZoom = false

    override func layoutSubviews() {
        super.layoutSubviews()
        // The first size too: the jump to where reading stopped comes
        // before the pager has one and is refused, which left it at the
        // start of the row (right to left, the end card).
        if bounds.size != lastSize, bounds.width > 0 {
            lastSize = bounds.size
            onResize?()
        }
    }

    /// A pinch on a page began: cancel any swipe in progress, settle on
    /// the page under it, and hold still while it's zoomed.
    func holdForZoom() {
        guard bounds.width > 0 else { return }
        isHeldForZoom = true
        panGestureRecognizer.isEnabled = false
        panGestureRecognizer.isEnabled = true
        let page = (contentOffset.x / bounds.width).rounded()
        setContentOffset(CGPoint(x: page * bounds.width, y: 0), animated: false)
        isScrollEnabled = false
    }

    func release() {
        isHeldForZoom = false
        isScrollEnabled = true
    }
}
