//
//  MangaPager.swift
//  Donguri
//
//  The reader's pages side by side, UIKit's way: a paging collection view,
//  so a swipe moves with the finger and settles with the system's own
//  physics (SwiftUI's paging ScrollView stuttered while pages loaded), and
//  only the pages near the screen exist. Each cell hosts the page's
//  SwiftUI view. The page on screen is reported once a swipe settles, not
//  on every frame of it.
//
//  Zooming and turning pages don't mix: a pinch cancels a swipe that had
//  started and holds the pages still until the page is back at its normal
//  size (MangaPageScrollView does that, finding this view above it).
//

import SwiftUI
import UIKit

struct MangaPager<Content: View>: UIViewRepresentable {
    /// The slots' ids, left to right as they sit on screen.
    let ids: [String]
    @Binding var currentID: String?
    /// While a page is zoomed: no swiping to another.
    var locked = false
    @ViewBuilder let content: (String) -> Content

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
        view.isPrefetchingEnabled = true
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: Coordinator.cellID)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.onResize = { [weak coordinator = context.coordinator] in coordinator?.keepPage() }
        context.coordinator.collectionView = view
        context.coordinator.ids = ids
        return view
    }

    func updateUIView(_ view: PagerCollectionView, context: Context) {
        context.coordinator.update(parent: self)
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        static var cellID: String { "page" }

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
            view.isScrollEnabled = !parent.locked
            if parent.ids != ids {
                ids = parent.ids
                view.reloadData()
                view.layoutIfNeeded()
                scroll(to: parent.currentID, animated: false)
                return
            }
            // Visible pages take the new state (outlines, highlights).
            for case let cell in view.visibleCells {
                guard let indexPath = view.indexPath(for: cell), ids.indices.contains(indexPath.item) else { continue }
                configure(cell, id: ids[indexPath.item])
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

        private func configure(_ cell: UICollectionViewCell, id: String) {
            cell.contentConfiguration = UIHostingConfiguration {
                parent.content(id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(id)
            }
            .margins(.all, 0)
        }

        // MARK: Data source

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            ids.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.cellID, for: indexPath)
            configure(cell, id: ids[indexPath.item])
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            collectionView.bounds.size
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

/// Tells the pager when its size changes (rotation), and lets a page
/// stop a swipe when a pinch begins.
final class PagerCollectionView: UICollectionView {
    var onResize: (() -> Void)?
    private var lastSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            let first = lastSize == .zero
            lastSize = bounds.size
            if !first { onResize?() }
        }
    }

    /// A pinch on a page began: cancel any swipe in progress, settle on
    /// the page under it, and hold still while it's zoomed.
    func holdForZoom() {
        guard bounds.width > 0 else { return }
        panGestureRecognizer.isEnabled = false
        panGestureRecognizer.isEnabled = true
        let page = (contentOffset.x / bounds.width).rounded()
        setContentOffset(CGPoint(x: page * bounds.width, y: 0), animated: false)
        isScrollEnabled = false
    }

    func release() {
        isScrollEnabled = true
    }
}
