//
//  GalleryView.swift
//  Donguri
//
//  Full-screen media gallery for a thread, modelled on the gallery in Chance
//  (github.com/moffatman/chan): swipe between every image and video in the
//  thread, tap to show or hide the controls, a thumbnail strip along the
//  bottom, a grid of everything, swipe up or down to close, and a way back
//  to the post an image came from.
//

import SwiftUI
import AVKit
import UIKit

struct GalleryView: View {
    let items: [MediaItem]
    var initiallyShowGrid = false
    /// Closes the gallery and scrolls the thread to this post (an index into
    /// the thread's posts). Nil hides the "jump to post" controls.
    var onJumpToPost: ((Int) -> Void)? = nil
    /// Where an item's thumbnail is on screen, for the zoom in and out.
    var sourceFrame: ((MediaItem) -> CGRect?)? = nil
    var onClose: () -> Void

    @Environment(\.openURL) private var openURL

    @State private var currentID: String?
    @State private var showChrome = true
    @State private var showGrid = false
    @State private var isZoomed = false
    @State private var dismissProgress: CGFloat = 0
    @State private var appeared = false
    @State private var job = MediaJob()
    @State private var toast: String?

    // Zoom transition: an image that grows out of its thumbnail on opening
    // and shrinks back into it on closing, drawn over everything while the
    // real pages are hidden.
    @State private var hero: Hero?
    @State private var pagerHidden = false
    /// The black backdrop, 0 while zooming in from or out to a thumbnail.
    @State private var backdrop: Double = 1
    @State private var isClosing = false
    /// The gallery's frame in window coordinates.
    @State private var bounds: CGRect = UIScreen.main.bounds

    private struct Hero {
        var image: UIImage
        var frame: CGRect
        var cornerRadius: CGFloat
    }

    init(items: [MediaItem],
         initialIndex: Int = 0,
         initiallyShowGrid: Bool = false,
         onJumpToPost: ((Int) -> Void)? = nil,
         sourceFrame: ((MediaItem) -> CGRect?)? = nil,
         onClose: @escaping () -> Void) {
        self.items = items
        self.initiallyShowGrid = initiallyShowGrid
        self.onJumpToPost = onJumpToPost
        self.sourceFrame = sourceFrame
        self.onClose = onClose
        let start = items.indices.contains(initialIndex) ? items[initialIndex].id : items.first?.id
        _currentID = State(initialValue: start)
        _showGrid = State(initialValue: initiallyShowGrid)
    }

    private var chromeVisible: Bool {
        showChrome && !showGrid
    }

    private var currentIndex: Int {
        items.firstIndex { $0.id == currentID } ?? 0
    }

    private var current: MediaItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity((1 - dismissProgress * 0.85) * backdrop)
                .ignoresSafeArea()

            pager
                .opacity(pagerHidden ? 0 : 1)

            // Always in the hierarchy and faded rather than inserted: re-inserting
            // it on every tap rebuilt the thumbnail strip, whose thumbnails then
            // animated in from nothing and the strip jumped to re-centre.
            chrome
                .opacity(chromeVisible && !pagerHidden ? 1 : 0)
                .allowsHitTesting(chromeVisible && !pagerHidden)

            if showGrid {
                grid
                    .transition(.opacity)
            }

            statusPill

            heroLayer
        }
        .opacity(appeared ? 1 : 0)
        .statusBarHidden(!showChrome && !showGrid)
        .preferredColorScheme(.dark)
        .onAppear {
            if !zoomIn() {
                withAnimation(.easeOut(duration: 0.2)) { appeared = true }
            }
            preloadNeighbours()
        }
        .onChange(of: currentID) {
            isZoomed = false
            preloadNeighbours()
        }
    }

    // MARK: Pager

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items) { item in
                    GalleryPage(item: item,
                                isCurrent: item.id == currentID,
                                onTap: toggleChrome,
                                onZoomChange: { isZoomed = $0 },
                                onDismissProgress: { dismissProgress = $0 },
                                onDismiss: { frame in close(from: frame) })
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollIndicators(.hidden)
        .scrollDisabled(isZoomed)
        .ignoresSafeArea()
    }

    // MARK: Controls

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            thumbnailStrip
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("閉じる"))

            Spacer()

            VStack(spacing: 2) {
                Text(verbatim: "\(currentIndex + 1) / \(items.count)")
                    .font(.headline.monospacedDigit())
                if let current, onJumpToPost != nil {
                    Button {
                        jump(to: current)
                    } label: {
                        HStack(spacing: 3) {
                            Text(verbatim: ">>\(current.postIndex + 1)")
                            Image(systemName: "arrow.turn.down.left")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }

            Spacer()

            actionsMenu
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
        .background(
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    private var actionsMenu: some View {
        Menu {
            if let current {
                if current.kind != .unsupportedVideo {
                    ShareLink(item: MediaStore.shared.existingFile(for: current.url) ?? current.url) {
                        Label("共有", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        job.start(.saveToPhotos, items: [current]) { showSummary(of: $0) }
                    } label: {
                        Label("写真に保存", systemImage: "square.and.arrow.down")
                    }
                }
                Button {
                    job.start(.saveToPhotos, items: items) { showSummary(of: $0) }
                } label: {
                    Label("すべて写真に保存（\(items.count)件）", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(job.isRunning)

                Divider()

                Button {
                    UIPasteboard.general.url = current.url
                    flash(String(localized: "リンクをコピーしました"))
                } label: {
                    Label("リンクをコピー", systemImage: "link")
                }
                Button {
                    openURL(current.url)
                } label: {
                    Label("Safariで開く", systemImage: "safari")
                }
                if onJumpToPost != nil {
                    Button {
                        jump(to: current)
                    } label: {
                        Label("投稿へ移動", systemImage: "arrow.turn.down.left")
                    }
                }
            }
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showGrid = true }
            } label: {
                Label("グリッド表示", systemImage: "square.grid.3x3")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.headline)
                .frame(width: 44, height: 44)
        }
    }

    private var thumbnailStrip: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showGrid = true }
            } label: {
                Image(systemName: "square.grid.3x3")
                    .font(.headline)
                    .frame(width: 44, height: 52)
            }
            .accessibilityLabel(Text("グリッド表示"))

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(items) { item in
                            Button {
                                currentID = item.id
                            } label: {
                                MediaThumbnailView(item: item, side: 52, cornerRadius: 6)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(Color.white, lineWidth: item.id == currentID ? 2 : 0)
                                    }
                                    .opacity(item.id == currentID ? 1 : 0.6)
                                    // Selection changes snap; nothing in a
                                    // thumbnail resizes or fades with the strip.
                                    .transaction { $0.animation = nil }
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                        }
                    }
                    .padding(.trailing, 12)
                    .padding(.vertical, 2)
                }
                .onAppear {
                    proxy.scrollTo(currentID, anchor: .center)
                }
                .onChange(of: currentID) {
                    // A plain, short slide: the thumbnails themselves never
                    // animate, only the strip's position.
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(currentID, anchor: .center)
                    }
                }
            }
        }
        .frame(height: 60)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: Grid

    private var grid: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("閉じる"))

                Spacer()

                Text("メディア \(items.count)件")
                    .font(.headline)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showGrid = false }
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("1枚ずつ表示"))
            }
            .padding(.horizontal, 8)
            .foregroundStyle(.white)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 2)], spacing: 2) {
                        ForEach(items) { item in
                            Button {
                                currentID = item.id
                                withAnimation(.easeInOut(duration: 0.2)) { showGrid = false }
                            } label: {
                                MediaThumbnailView(item: item,
                                                   side: nil,
                                                   cornerRadius: 0,
                                                   pixelSize: MediaThumbnailView.gridPixelSize)
                                    .overlay(alignment: .topTrailing) {
                                        Text(verbatim: ">>\(item.postIndex + 1)")
                                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(.black.opacity(0.55)))
                                            .padding(4)
                                    }
                                    .overlay {
                                        Rectangle()
                                            .stroke(Color.white, lineWidth: item.id == currentID ? 3 : 0)
                                    }
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                            .contextMenu {
                                if onJumpToPost != nil {
                                    Button {
                                        jump(to: item)
                                    } label: {
                                        Label("投稿へ移動", systemImage: "arrow.turn.down.left")
                                    }
                                }
                                Button {
                                    job.start(.saveToPhotos, items: [item]) { showSummary(of: $0) }
                                } label: {
                                    Label("写真に保存", systemImage: "square.and.arrow.down")
                                }
                                .disabled(item.kind == .unsupportedVideo)
                            }
                        }
                    }
                }
                .onAppear {
                    proxy.scrollTo(currentID, anchor: .center)
                }
            }
        }
        .background(Color.black.opacity(0.94).ignoresSafeArea())
    }

    // MARK: Status

    @ViewBuilder
    private var statusPill: some View {
        if job.isRunning || toast != nil {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    if job.isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text(job.progressText)
                        Button {
                            job.cancel()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                    } else if let toast {
                        Text(toast)
                    }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(.black.opacity(0.75)))
                .padding(.bottom, showChrome && !showGrid ? 96 : 32)
            }
            .transition(.opacity)
        }
    }

    // MARK: Actions

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
    }

    /// Closes the gallery, zooming the image back into its thumbnail when
    /// the thumbnail is on screen. Returns true if it's zooming.
    @discardableResult
    private func close(from frame: CGRect? = nil, then action: (() -> Void)? = nil) -> Bool {
        guard !isClosing else { return false }
        isClosing = true
        if action == nil, zoomOut(from: frame) { return true }
        withAnimation(.easeIn(duration: 0.18)) { appeared = false }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            onClose()
            action?()
        }
        return false
    }

    // MARK: Zoom transition

    @ViewBuilder
    private var heroLayer: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            if let hero {
                Image(uiImage: hero.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: hero.frame.width, height: hero.frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: hero.cornerRadius, style: .continuous))
                    .position(x: hero.frame.midX - origin.x, y: hero.frame.midY - origin.y)
            }
            Color.clear
                .onAppear { bounds = proxy.frame(in: .global) }
                .onChange(of: proxy.size) { bounds = proxy.frame(in: .global) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// The image's frame when it fills the screen, as the page lays it out.
    private func fittedFrame(for size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// The best image already in memory: the full one, else the thumbnail.
    private func cachedImage(for item: MediaItem) -> UIImage? {
        MediaStore.shared.memoryImage(for: item.url, maxPixelSize: nil)
            ?? MediaStore.shared.memoryImage(for: item.url, maxPixelSize: MediaThumbnailView.rowPixelSize)
    }

    private func zoomIn() -> Bool {
        guard !initiallyShowGrid, let item = current, item.kind == .image,
              let source = sourceFrame?(item), let image = cachedImage(for: item) else { return false }
        appeared = true
        pagerHidden = true
        backdrop = 0
        hero = Hero(image: image, frame: source, cornerRadius: 6)
        // The zoom starts from whatever is in memory (often the small
        // thumbnail); swap in the full image as soon as it's ready so the
        // growing picture sharpens instead of staying soft.
        if MediaStore.shared.memoryImage(for: item.url, maxPixelSize: nil) == nil {
            Task {
                if let full = await MediaStore.shared.image(for: item.url, maxPixelSize: nil), hero != nil {
                    hero?.image = full
                }
            }
        }
        // Next frame, so the hero is first drawn over the thumbnail.
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                hero?.frame = fittedFrame(for: image.size)
                hero?.cornerRadius = 0
                backdrop = 1
            } completion: {
                pagerHidden = false
                hero = nil
            }
        }
        return true
    }

    private func zoomOut(from frame: CGRect?) -> Bool {
        guard !showGrid, !isZoomed, let item = current, item.kind == .image,
              let target = sourceFrame?(item), let image = cachedImage(for: item) else { return false }
        let start = frame ?? fittedFrame(for: image.size)
        hero = Hero(image: image, frame: start, cornerRadius: 0)
        pagerHidden = true
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            hero?.frame = target
            hero?.cornerRadius = 6
            backdrop = 0
        } completion: {
            onClose()
        }
        return true
    }

    private func jump(to item: MediaItem) {
        guard let onJumpToPost else { return }
        let postIndex = item.postIndex
        close(then: { onJumpToPost(postIndex) })
    }

    private func showSummary(of job: MediaJob) {
        flash(job.summaryText)
    }

    private func flash(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation {
                if toast == message { toast = nil }
            }
        }
    }

    /// Start loading the pages on either side, so swiping doesn't wait.
    private func preloadNeighbours() {
        let index = currentIndex
        let neighbours = [index + 1, index - 1, index + 2]
            .filter { items.indices.contains($0) }
            .map { items[$0] }
            .filter { $0.kind == .image }
        guard !neighbours.isEmpty else { return }
        Task {
            for item in neighbours {
                _ = await MediaStore.shared.image(for: item.url, maxPixelSize: nil)
            }
        }
    }
}

/// One page of the gallery.
private struct GalleryPage: View {
    let item: MediaItem
    let isCurrent: Bool
    var onTap: () -> Void
    var onZoomChange: (Bool) -> Void
    var onDismissProgress: (CGFloat) -> Void
    /// The image's frame when a swipe closes the gallery (nil for videos);
    /// true if the gallery zooms it back into its thumbnail.
    var onDismiss: (CGRect?) -> Bool

    @Environment(\.openURL) private var openURL
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        switch item.kind {
        case .image:
            imagePage
        case .video:
            GalleryVideoPage(url: item.url,
                             isCurrent: isCurrent,
                             onDismissProgress: onDismissProgress,
                             onDismiss: { _ = onDismiss(nil) })
        case .unsupportedVideo:
            messagePage(systemImage: "film",
                        text: String(localized: "WebM動画はiOSで再生できません"))
        }
    }

    @ViewBuilder
    private var imagePage: some View {
        Group {
            if let image {
                ZoomableImageView(image: image,
                                  onTap: onTap,
                                  onZoomChange: onZoomChange,
                                  onDismissProgress: onDismissProgress,
                                  onDismiss: { frame in onDismiss(frame) })
            } else if failed {
                messagePage(systemImage: "photo.badge.exclamationmark",
                            text: String(localized: "画像を読み込めませんでした"),
                            retry: true)
            } else {
                // The thumbnail, if there is one, stands in while the full
                // image loads, the way Chance does it.
                ZStack {
                    if let placeholder = MediaStore.shared.memoryImage(for: item.url,
                                                                       maxPixelSize: MediaThumbnailView.rowPixelSize) {
                        Image(uiImage: placeholder)
                            .resizable()
                            .scaledToFit()
                            .blur(radius: 6)
                            .opacity(0.6)
                    }
                    ProgressView()
                        .tint(.white)
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
            }
        }
        .task(id: "\(item.id)#\(attempt)") {
            if image != nil { return }
            failed = false
            if let cached = MediaStore.shared.memoryImage(for: item.url, maxPixelSize: nil) {
                image = cached
                return
            }
            let loaded = await MediaStore.shared.image(for: item.url, maxPixelSize: nil)
            image = loaded
            failed = loaded == nil
        }
    }

    private func messagePage(systemImage: String, text: String, retry: Bool = false) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.largeTitle)
            Text(text)
                .font(.subheadline)
            HStack(spacing: 12) {
                if retry {
                    Button("再試行") {
                        attempt += 1
                    }
                    .buttonStyle(.bordered)
                }
                Button("Safariで開く") {
                    openURL(item.url)
                }
                .buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// A video page: plays while it's the current page, pauses otherwise. A
/// vertical swipe closes the gallery, as on image pages.
private struct GalleryVideoPage: View {
    let url: URL
    let isCurrent: Bool
    var onDismissProgress: (CGFloat) -> Void
    var onDismiss: () -> Void

    @State private var player: AVPlayer?
    @State private var dragOffset: CGFloat = 0
    @State private var dragIsDismiss: Bool?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
            }
        }
        .offset(y: dragOffset)
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { value in
                    // Decide once, from the first movement, whether this is
                    // a close swipe; a page swipe never moves the video.
                    if dragIsDismiss == nil {
                        dragIsDismiss = abs(value.translation.height) > abs(value.translation.width) * 2.2
                    }
                    guard dragIsDismiss == true else { return }
                    dragOffset = value.translation.height
                    onDismissProgress(min(abs(dragOffset) / 140, 1))
                }
                .onEnded { value in
                    defer { dragIsDismiss = nil }
                    guard dragIsDismiss == true else { return }
                    if abs(dragOffset) > 140 || abs(value.predictedEndTranslation.height) > 400 {
                        player?.pause()
                        onDismissProgress(1)
                        onDismiss()
                    } else {
                        withAnimation(.snappy) { dragOffset = 0 }
                        onDismissProgress(0)
                    }
                }
        )
        .task(id: url) {
            // Play the downloaded copy when there is one.
            let source = MediaStore.shared.existingFile(for: url) ?? url
            let newPlayer = AVPlayer(url: source)
            player = newPlayer
            if isCurrent { newPlayer.play() }
        }
        .onChange(of: isCurrent) {
            if isCurrent { player?.play() } else { player?.pause() }
        }
        .onDisappear {
            player?.pause()
        }
    }
}
