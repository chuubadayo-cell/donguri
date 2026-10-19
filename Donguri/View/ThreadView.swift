//
//  ThreadView.swift
//  Donguri
//
//  Created by John Connery on 6/16/26.
//

import SwiftUI
import Translation

struct ThreadRoute: Hashable {
    let boardURL: String
    let threadId: Int
}

struct ThreadView: View {
    var thread: Thread?
    var boardURL: String?
    /// Shown in the library (favorites, history, saved threads). Optional
    /// because a thread reached from a link inside another thread arrives
    /// without one; `HistoryStore.knownBoardName` fills the gap.
    var boardName: String? = nil

    @State private var posts: [Post] = []
    @State private var errorMessage: String?

    @State private var threadRoute: ThreadRoute?
    @State private var replyPreviewIndices: [Int] = []

    // ID/trip → post indices, used to highlight every post from the same poster.
    @State private var idIndices: [String: [Int]] = [:]
    @State private var tripIndices: [String: [Int]] = [:]
    @State private var highlightedID: String?
    @State private var highlightedTrip: String?

    // Read-position tracking: how far the user has scrolled, and where to
    // resume to once a fresh load's rows exist.
    @State private var maxSeenIndex: Int = 0
    @State private var resumeIndex: Int?

    @State private var ngFilter = NGFilterStore.shared
    @State private var favorites = FavoritesStore.shared
    @State private var savedThreads = SavedThreadStore.shared

    /// True while the posts on screen came from the offline copy rather than
    /// the network: either the fresh load is still running, or it failed.
    @State private var showingSavedCopy = false
    /// 人気レス filter: when set, only posts with at least this many replies
    /// are listed. Hidden posts keep their place in `posts`, so `>>N` numbering
    /// and reply indices stay correct, exactly like NG filtering.
    @State private var popularThreshold: Int?
    @State private var saveFeedback: String?

    // Media: every image/video in the thread (for the gallery), the same
    // grouped by post (for each row's thumbnails), and bulk-download progress.
    @State private var mediaItems: [MediaItem] = []
    @State private var mediaByPost: [Int: [MediaItem]] = [:]
    @State private var galleryRequest: GalleryRequest?
    @State private var mediaJob = MediaJob()
    @State private var prefetcher = NearbyPrefetcher()

    // Popup dictionary
    @Environment(UserConfig.self) private var userConfig
    @State private var selectionData: SelectionData?
    @State private var lookupResults: [LookupResult] = []
    @State private var dictionaryStyles: [String: String] = [:]
    @State private var showPopup = false
    @State private var clearSelection = false
    // PopupView caches its rendered content in @State at init, so it needs a
    // fresh identity per lookup — otherwise it keeps the empty first render.
    @State private var popupGeneration = 0
    /// Post text styling; reading it here redraws every post when the user
    /// changes fonts or colours in 外観.
    @State private var appearance = AppearanceSettings.shared

    private static let popularThresholds = [3, 5, 10]

    /// Indices of the posts the list shows, in thread order.
    private var visibleIndices: [Int] {
        guard let popularThreshold else { return Array(posts.indices) }
        return posts.indices.filter { Self.replyCount(of: posts[$0]) >= popularThreshold }
    }

    /// Distinct posts replying to this one (a post quoting `>>5` twice counts once).
    private static func replyCount(of post: Post) -> Int {
        Set(post.replies ?? []).count
    }

    private var resolvedTitle: String? {
        thread?.title ?? posts.first?.threadTitle
    }

    private var resolvedBoardName: String {
        if let boardName { return boardName }
        guard let boardURL else { return "" }
        return HistoryStore.shared.knownBoardName(for: boardURL)
    }

    private var highlightedIndices: Set<Int> {
        if let highlightedID {
            return Set(idIndices[highlightedID] ?? [])
        }
        if let highlightedTrip {
            return Set(tripIndices[highlightedTrip] ?? [])
        }
        return []
    }

    var body: some View {
        if let thread, let boardURL {
            GeometryReader { geometry in
            ScrollViewReader { proxy in
                Group {
                    if !posts.isEmpty {
                        ZStack(alignment: .top) {
                            List {
                                ForEach(visibleIndices, id: \.self) { index in
                                    let post = posts[index]
                                    if post.isDeleted == true {
                                        AbornPlaceholder(index: index, isDeletedOnServer: true)
                                            .listRowBackground(Color.clear)
                                            .id(index)
                                    } else if ngFilter.hides(post) {
                                        // Kept in place so >>N numbering stays correct.
                                        AbornPlaceholder(index: index)
                                            .listRowBackground(Color.clear)
                                            .id(index)
                                    } else {
                                    PostView(index: index,
                                             post: post,
                                             idCount: post.id.flatMap { idIndices[$0]?.count } ?? 0,
                                             tripCount: post.trip.flatMap { tripIndices[$0]?.count } ?? 0,
                                             isIDHighlighted: post.id != nil && post.id == highlightedID,
                                             isTripHighlighted: post.trip != nil && post.trip == highlightedTrip,
                                             onThreadRoute: { route in
                                        threadRoute = route
                                    }, onPostReply: { postIndex in
                                        replyPreviewIndices = [postIndex]
                                    }, onShowReplies: { indices in
                                        replyPreviewIndices = indices
                                    }, onIDTap: { id in
                                        toggleHighlightedID(id)
                                    }, onTripTap: { trip in
                                        toggleHighlightedTrip(trip)
                                    }, onTextSelected: { selection in
                                        handleTextSelection(selection)
                                    }, onTapOutside: {
                                        dismissPopup()
                                    }, onReport: {
                                        ReportService.report(
                                            post: post,
                                            index: index,
                                            boardURL: boardURL,
                                            threadId: thread.id,
                                            threadTitle: thread.title ?? posts.first?.threadTitle
                                        )
                                    }, media: mediaByPost[index] ?? [],
                                       onOpenMedia: { item in
                                        openGallery(at: item)
                                    }, textStyle: appearance.postStyle)
                                    .listRowBackground(
                                        highlightedIndices.contains(index)
                                            ? Color.accentColor.opacity(0.15)
                                            : Color.clear
                                    )
                                    .id(index)
                                    .onAppear {
                                        maxSeenIndex = max(maxSeenIndex, index)
                                        prefetcher.rowAppeared(index, mediaByPost: mediaByPost)
                                    }
                                    }
                                }
                            }
                            .scrollContentBackground(appearance.threadBackground == nil ? .automatic : .hidden)
                            .background(appearance.threadBackground ?? Color.clear)
                            .safeAreaInset(edge: .top) {
                                bannerStack
                            }

                            // Reply preview popup — shown for a >>N tap (single post) or
                            // tapping a post's reply-count badge (that post's full reply list).
                            if !replyPreviewIndices.isEmpty {
                                Color.black.opacity(0.25)
                                    .ignoresSafeArea()
                                    .onTapGesture { replyPreviewIndices = [] }

                                ReplyPreviewCard(
                                    indices: replyPreviewIndices,
                                    posts: posts,
                                    idIndices: idIndices,
                                    tripIndices: tripIndices,
                                    onClose: { replyPreviewIndices = [] },
                                    onJump: { index in
                                        replyPreviewIndices = []
                                        if popularThreshold != nil && !visibleIndices.contains(index) {
                                            // The target is filtered out of the list, so there is
                                            // no row to scroll to until the filter is lifted.
                                            popularThreshold = nil
                                            Task {
                                                try? await Task.sleep(for: .milliseconds(200))
                                                withAnimation(.snappy) {
                                                    proxy.scrollTo(index, anchor: .top)
                                                }
                                            }
                                        } else {
                                            withAnimation(.snappy) {
                                                proxy.scrollTo(index, anchor: .top)
                                            }
                                        }
                                    },
                                    onThreadRoute: { route in
                                        replyPreviewIndices = []
                                        threadRoute = route
                                    },
                                    onShowReplies: { indices in
                                        replyPreviewIndices = indices
                                    },
                                    mediaByPost: mediaByPost,
                                    onOpenMedia: { item in
                                        replyPreviewIndices = []
                                        openGallery(at: item)
                                    }
                                )
                                .padding(.horizontal)
                            }
                        }
                        .animation(.snappy, value: replyPreviewIndices)
                    } else if let errorMessage {
                        ContentUnavailableView {
                            Label("エラーが発生しました", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(errorMessage)
                        }
                    } else {
                        ProgressView("しばらくお待ちください...")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .onChange(of: resumeIndex) { _, newValue in
                    guard let newValue else { return }
                    resumeIndex = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(nil) {
                            proxy.scrollTo(newValue, anchor: .top)
                        }
                    }
                }
                .overlay {
                    PopupView(
                        userConfig: userConfig,
                        isVisible: $showPopup,
                        selectionData: selectionData,
                        lookupResults: lookupResults,
                        dictionaryStyles: dictionaryStyles,
                        screenSize: geometry.size,
                        isVertical: false,
                        isFullWidth: userConfig.popupFullWidth,
                        topInset: UIApplication.topSafeArea,
                        bottomInset: UIApplication.bottomSafeArea,
                        coverURL: nil,
                        documentTitle: thread.title ?? posts.first?.threadTitle,
                        clearSelection: clearSelection,
                        onTextSelected: { handleTextSelection($0) },
                        onTapOutside: { dismissPopup() },
                        onSwipeDismiss: { dismissPopup() }
                    )
                    .id(popupGeneration)
                }
            }
            }
            .listStyle(.plain)
            .navigationTitle(thread.title ?? posts.first?.threadTitle ?? "無題")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    let isFavorite = favorites.isFavorite(boardURL: boardURL, threadId: thread.id)
                    Button {
                        favorites.toggle(boardURL: boardURL,
                                         boardName: resolvedBoardName,
                                         threadId: thread.id,
                                         title: resolvedTitle ?? String(localized: "無題"),
                                         responseCount: max(posts.count, thread.responseCount))
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundStyle(isFavorite ? Color.yellow : Color.accentColor)
                    }
                    .accessibilityLabel(isFavorite ? Text("お気に入りから削除") : Text("お気に入りに追加"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    threadMenu(boardURL: boardURL, thread: thread)
                }
            }
            .fullScreenCover(item: $galleryRequest) { request in
                GalleryView(items: mediaItems,
                            initialIndex: request.startIndex,
                            initiallyShowGrid: request.showGrid,
                            onJumpToPost: { postIndex in
                                jumpToPost(postIndex)
                            },
                            onClose: {
                                withTransaction(Transaction.noAnimation) { galleryRequest = nil }
                            })
                .presentationBackground(.clear)
            }
            .navigationDestination(item: $threadRoute) { route in
                ThreadView(
                    thread: Thread(id: route.threadId, title: nil, responseCount: -1),
                    boardURL: route.boardURL,
                    boardName: route.boardURL == boardURL ? boardName : nil
                )
            }
            .task {
                await loadThread(boardURL: boardURL, threadId: thread.id)
            }
            .refreshable {
                await loadThread(boardURL: boardURL, threadId: thread.id)
            }
            .onDisappear {
                persistReadState(boardURL: boardURL, threadId: thread.id)
            }
        } else {
            ContentUnavailableView("エラー：スレや板情報がありません", systemImage: "exclamationmark.triangle")
        }
    }

    private func threadMenu(boardURL: String, thread: Thread) -> some View {
        let isSaved = savedThreads.isSaved(boardURL: boardURL, threadId: thread.id)
        return Menu {
            Section {
                if isSaved {
                    Button {
                        saveForOffline(boardURL: boardURL, threadId: thread.id)
                    } label: {
                        Label("保存済みのコピーを更新", systemImage: "arrow.clockwise.circle")
                    }
                    .disabled(posts.isEmpty || showingSavedCopy)
                    Button(role: .destructive) {
                        savedThreads.delete(boardURL: boardURL, threadId: thread.id)
                        showingSavedCopy = false
                        flashSaveFeedback(String(localized: "オフライン保存を削除しました"))
                    } label: {
                        Label("オフライン保存を削除", systemImage: "trash")
                    }
                } else {
                    Button {
                        saveForOffline(boardURL: boardURL, threadId: thread.id)
                    } label: {
                        Label("オフライン用に保存", systemImage: "arrow.down.circle")
                    }
                    .disabled(posts.isEmpty)
                }
            }

            Section {
                Button {
                    openGallery(showGrid: true)
                } label: {
                    Label("ギャラリー（\(mediaItems.count)件）", systemImage: "square.grid.3x3")
                }
                .disabled(mediaItems.isEmpty)
                Button {
                    mediaJob.start(.download, items: mediaItems.filter { $0.kind != .unsupportedVideo }) { job in
                        flashSaveFeedback(job.summaryText)
                    }
                } label: {
                    Label("画像をすべてダウンロード", systemImage: "arrow.down.to.line")
                }
                .disabled(mediaItems.isEmpty || mediaJob.isRunning)
            }

            Section {
                Picker(selection: $popularThreshold) {
                    Label("すべてのレス", systemImage: "list.bullet")
                        .tag(Int?.none)
                    ForEach(Self.popularThresholds, id: \.self) { threshold in
                        Label("返信\(threshold)件以上", systemImage: "flame")
                            .tag(Int?.some(threshold))
                    }
                } label: {
                    Label("人気レス", systemImage: "flame")
                }
                .pickerStyle(.menu)
            }
        } label: {
            Image(systemName: isSaved ? "ellipsis.circle.fill" : "ellipsis.circle")
        }
    }

    private func saveForOffline(boardURL: String, threadId: Int) {
        let ok = savedThreads.save(boardURL: boardURL,
                                   boardName: resolvedBoardName,
                                   threadId: threadId,
                                   title: resolvedTitle ?? String(localized: "無題"),
                                   posts: posts)
        flashSaveFeedback(ok ? String(localized: "オフライン用に保存しました")
                             : String(localized: "保存できませんでした"))
        // Images come along so the thread really works offline. Videos are
        // left out: they can be hundreds of megabytes each.
        let images = mediaItems.filter { $0.kind == .image }
        if ok, !images.isEmpty {
            mediaJob.start(.pin, items: images) { job in
                flashSaveFeedback(job.summaryText)
            }
        }
    }

    // MARK: Media

    private func openGallery(at item: MediaItem) {
        guard let index = mediaItems.firstIndex(of: item) else { return }
        withTransaction(Transaction.noAnimation) {
            galleryRequest = GalleryRequest(startIndex: index, showGrid: false)
        }
    }

    private func openGallery(showGrid: Bool) {
        guard !mediaItems.isEmpty else { return }
        withTransaction(Transaction.noAnimation) {
            galleryRequest = GalleryRequest(startIndex: 0, showGrid: showGrid)
        }
    }

    /// From the gallery's "jump to post": close it and bring the post on screen.
    private func jumpToPost(_ postIndex: Int) {
        withTransaction(Transaction.noAnimation) { galleryRequest = nil }
        if popularThreshold != nil && !visibleIndices.contains(postIndex) {
            popularThreshold = nil
        }
        resumeIndex = postIndex
    }

    /// Works out the thread's media and starts any whole-thread preloading
    /// the user asked for in Settings.
    private func updateMedia(for newPosts: [Post], boardURL: String, threadId: Int) {
        let items = MediaItem.items(for: newPosts)
        mediaItems = items
        mediaByPost = Dictionary(grouping: items, by: \.postIndex)
        prefetcher.reset()

        let mode = MediaPrefetchMode.current
        let wantsAll = mode == .all || (mode == .allOnWiFi && !NetworkMonitor.shared.isExpensive)
        if wantsAll {
            prefetcher.prefetchAll(items)
        }

        // A saved thread keeps its images current as it grows.
        if savedThreads.isSaved(boardURL: boardURL, threadId: threadId) {
            let images = items.filter { $0.kind == .image }.map(\.url)
            Task.detached(priority: .utility) {
                for url in images {
                    try? await MediaStore.shared.pin(url)
                }
            }
        }
    }

    private func flashSaveFeedback(_ message: String) {
        withAnimation { saveFeedback = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation {
                if saveFeedback == message { saveFeedback = nil }
            }
        }
    }

    /// Status pills floating over the top of the list: offline copy, save
    /// confirmation, 人気レス filter, and ID/trip highlighting.
    @ViewBuilder
    private var bannerStack: some View {
        if hasBanner {
            VStack(spacing: 6) {
                if showingSavedCopy {
                    HighlightBanner(text: String(localized: "保存済みのコピーを表示中"),
                                    systemImage: "arrow.down.circle")
                }
                if mediaJob.isRunning {
                    HighlightBanner(text: mediaJob.progressText, systemImage: "arrow.down.circle") {
                        mediaJob.cancel()
                    }
                }
                if let saveFeedback {
                    HighlightBanner(text: saveFeedback, systemImage: "checkmark.circle")
                }
                if let popularThreshold {
                    HighlightBanner(
                        text: String(localized: "人気レス（返信\(popularThreshold)件以上）: \(visibleIndices.count)件"),
                        systemImage: "flame"
                    ) {
                        self.popularThreshold = nil
                    }
                }
                if let banner = highlightBannerText {
                    HighlightBanner(text: banner) {
                        clearHighlight()
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private var hasBanner: Bool {
        showingSavedCopy || mediaJob.isRunning || saveFeedback != nil
            || popularThreshold != nil || highlightBannerText != nil
    }

    private var highlightBannerText: String? {
        if let highlightedID {
            let count = idIndices[highlightedID]?.count ?? 0
            return "ID:\(highlightedID) の書き込み: \(count)件"
        }
        if let highlightedTrip {
            let count = tripIndices[highlightedTrip]?.count ?? 0
            return "◆\(highlightedTrip) の書き込み: \(count)件"
        }
        return nil
    }

    private func toggleHighlightedID(_ id: String) {
        highlightedTrip = nil
        highlightedID = (highlightedID == id) ? nil : id
    }

    private func toggleHighlightedTrip(_ trip: String) {
        highlightedID = nil
        highlightedTrip = (highlightedTrip == trip) ? nil : trip
    }

    private func clearHighlight() {
        highlightedID = nil
        highlightedTrip = nil
    }

    public func loadThread(boardURL: String, threadId: Int) async {
        let cacheKey = ReadStateStore.key(boardURL: boardURL, threadId: threadId)

        // Show something immediately when we can: the copy still in memory from
        // a recent visit, or else the offline copy of a saved thread. The live
        // version replaces it once the network answers; offline, it stays.
        if posts.isEmpty, let cached = ThreadMemoryCache.shared.posts(for: cacheKey), !cached.isEmpty {
            apply(cached, boardURL: boardURL, threadId: threadId, isInitialLoad: true)
        } else if posts.isEmpty,
                  let savedPosts = savedThreads.posts(boardURL: boardURL, threadId: threadId),
                  !savedPosts.isEmpty {
            showingSavedCopy = true
            apply(savedPosts, boardURL: boardURL, threadId: threadId, isInitialLoad: true)
        }

        let isInitialLoad = posts.isEmpty
        do {
            errorMessage = nil
            let service = PostService()
            let newPosts = try await service.fetchPosts(boardURL: boardURL, threadId: threadId)
            showingSavedCopy = false
            ThreadMemoryCache.shared.store(newPosts, for: cacheKey)
            // Re-applying identical posts would throw away every measured row
            // height and make the list reflow for nothing.
            if !Self.samePosts(posts, newPosts) {
                apply(newPosts, boardURL: boardURL, threadId: threadId, isInitialLoad: isInitialLoad)
            }
            savedThreads.updateIfSaved(boardURL: boardURL,
                                       threadId: threadId,
                                       title: resolvedTitle,
                                       posts: newPosts)
        } catch {
            errorMessage = String(localized: "エラーが発生しました: \(String(describing: error))")
            print("ThreadView Error: \(error)")
        }
    }

    /// Cheap "nothing changed" check: same length, same first and last post.
    /// A deleted post (あぼーん) changes the dat's length, so it is caught too.
    private static func samePosts(_ a: [Post], _ b: [Post]) -> Bool {
        guard a.count == b.count, let lastA = a.last, let lastB = b.last else { return false }
        return lastA.text == lastB.text && lastA.date == lastB.date && a.first?.text == b.first?.text
    }

    private func apply(_ newPosts: [Post], boardURL: String, threadId: Int, isInitialLoad: Bool) {
        posts = newPosts
        updateMedia(for: newPosts, boardURL: boardURL, threadId: threadId)
        (idIndices, tripIndices) = Self.buildHighlightIndices(posts: newPosts)
        highlightedID = nil
        highlightedTrip = nil

        if isInitialLoad {
            maxSeenIndex = 0
            let key = ReadStateStore.key(boardURL: boardURL, threadId: threadId)
            // Only resume if there's unread content below the saved position —
            // if the last visit already reached the end, scrolling the final row
            // to the top would have nothing below it to anchor against.
            if let state = ReadStateStore.shared.state(for: key),
               newPosts.count > 1,
               state.lastReadIndex < newPosts.count - 1 {
                resumeIndex = max(0, state.lastReadIndex)
            }
        }

        let title = resolvedTitle
        HistoryStore.shared.record(boardURL: boardURL,
                                   boardName: boardName,
                                   threadId: threadId,
                                   title: title,
                                   responseCount: newPosts.count)
        favorites.noteOpened(boardURL: boardURL,
                             threadId: threadId,
                             title: title,
                             responseCount: newPosts.count)
    }

    /// Runs a dictionary lookup for the tapped text and shows the popup.
    /// Returns how many characters matched, so selection.js can highlight them.
    private func handleTextSelection(_ selection: SelectionData) -> Int? {
        let results = LookupEngine.shared.lookup(
            selection.text,
            maxResults: userConfig.maxResults,
            scanLength: userConfig.scanLength
        )
        guard let first = results.first else {
            dismissPopup()
            return nil
        }

        var styles: [String: String] = [:]
        for style in LookupEngine.shared.getStyles() {
            styles[style.dictName] = style.styles
        }

        selectionData = selection
        lookupResults = results
        dictionaryStyles = styles
        popupGeneration += 1
        withAnimation(.default.speed(2.2)) {
            showPopup = true
        }
        return first.matched.count
    }

    private func dismissPopup() {
        guard showPopup else { return }
        withAnimation(.default.speed(2.4)) {
            showPopup = false
        }
        clearSelection.toggle()
        PostSelectionCenter.shared.clearAll()
    }

    private func persistReadState(boardURL: String, threadId: Int) {
        guard !posts.isEmpty else { return }
        let key = ReadStateStore.key(boardURL: boardURL, threadId: threadId)
        ReadStateStore.shared.update(key: key, postCount: posts.count, readIndex: maxSeenIndex)
        favorites.readStateDidChange()
    }

    private static func buildHighlightIndices(posts: [Post]) -> (id: [String: [Int]], trip: [String: [Int]]) {
        var byID: [String: [Int]] = [:]
        var byTrip: [String: [Int]] = [:]
        for (index, post) in posts.enumerated() {
            if let id = post.id {
                byID[id, default: []].append(index)
            }
            if let trip = post.trip {
                byTrip[trip, default: []].append(index)
            }
        }
        return (byID, byTrip)
    }
}

private struct HighlightBanner: View {
    let text: String
    var systemImage: String? = nil
    var onClear: (() -> Void)? = nil

    var body: some View {
        HStack {
            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(text)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let onClear {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .cardBackground(cornerRadius: 20)

            Spacer(minLength: 0)
        }
    }
}

/// Floating card listing the replies to a post (or a single `>>N` target),
/// each of which can itself be tapped to jump to that post in the main list.
private struct ReplyPreviewCard: View {
    let indices: [Int]
    let posts: [Post]
    let idIndices: [String: [Int]]
    let tripIndices: [String: [Int]]
    let onClose: () -> Void
    let onJump: (Int) -> Void
    let onThreadRoute: (ThreadRoute) -> Void
    let onShowReplies: ([Int]) -> Void
    var mediaByPost: [Int: [MediaItem]] = [:]
    var onOpenMedia: ((MediaItem) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(indices.count > 1 ? "返信 \(indices.count)件" : "返信")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(indices, id: \.self) { index in
                        if posts.indices.contains(index) {
                            VStack(alignment: .leading, spacing: 4) {
                                Button {
                                    onJump(index)
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(">>\(index + 1) にジャンプ")
                                        Image(systemName: "arrow.down.right.circle")
                                    }
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)

                                PostView(index: index,
                                         post: posts[index],
                                         idCount: posts[index].id.flatMap { idIndices[$0]?.count } ?? 0,
                                         tripCount: posts[index].trip.flatMap { tripIndices[$0]?.count } ?? 0,
                                         isIDHighlighted: false,
                                         isTripHighlighted: false,
                                         onThreadRoute: onThreadRoute,
                                         onPostReply: { onShowReplies([$0]) },
                                         onShowReplies: onShowReplies,
                                         onIDTap: { _ in },
                                         onTripTap: { _ in },
                                         media: mediaByPost[index],
                                         onOpenMedia: onOpenMedia)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .frame(maxHeight: 420)
        .cardBackground(cornerRadius: 14)
    }
}

struct PostView: View {
    var index: Int
    var post: Post

    var idCount: Int
    var tripCount: Int
    var isIDHighlighted: Bool
    var isTripHighlighted: Bool

    var onThreadRoute: (ThreadRoute) -> Void
    var onPostReply: (Int) -> Void
    var onShowReplies: ([Int]) -> Void
    var onIDTap: (String) -> Void
    var onTripTap: (String) -> Void
    var onTextSelected: (SelectionData) -> Int? = { _ in nil }
    var onTapOutside: () -> Void = {}
    var onReport: (() -> Void)? = nil
    /// This post's images and videos, worked out once per thread by
    /// `ThreadView`. Nil works them out here.
    var media: [MediaItem]? = nil
    /// Opens the thread's gallery at an item. Nil opens a gallery of just
    /// this post's media.
    var onOpenMedia: ((MediaItem) -> Void)? = nil

    /// Fonts and colours for the post text. Rows built without one (reply
    /// previews) read the current settings themselves.
    var textStyle: PostTextStyle? = nil

    @Environment(UserConfig.self) private var userConfig
    @State private var localGalleryItem: MediaItem?
    @State private var showTranslation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))

                if let replies = post.replies, !replies.isEmpty {
                    Button {
                        onShowReplies(replies)
                    } label: {
                        Chip(text: "\(replies.count)", systemImage: "message.fill", tint: .secondary, filled: false)
                    }
                    .buttonStyle(.plain)
                }

                nameView
            }

            // Native text with its own tap-to-lookup (see PostTextView).
            PostTextView(
                text: post.text,
                scanNonJapaneseText: userConfig.scanNonJapaneseText,
                style: textStyle ?? AppearanceSettings.shared.postStyle,
                onTextSelected: onTextSelected,
                onTapOutside: onTapOutside,
                onPostReply: onPostReply,
                onThreadRoute: onThreadRoute
            )

            let mediaItems = resolvedMedia
            if !mediaItems.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mediaItems) { item in
                            Button {
                                if let onOpenMedia {
                                    onOpenMedia(item)
                                } else {
                                    withTransaction(Transaction.noAnimation) { localGalleryItem = item }
                                }
                            } label: {
                                MediaThumbnailView(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack {
                Text(post.date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                if let id = post.id {
                    Button {
                        onIDTap(id)
                    } label: {
                        Chip(text: idCount > 1 ? "ID:\(id)(\(idCount))" : "ID:\(id)",
                             tint: isIDHighlighted ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if !post.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    showTranslation = true
                } label: {
                    Label("翻訳", systemImage: "translate")
                }
                Divider()
            }
            if let id = post.id {
                Button {
                    NGFilterStore.shared.add(kind: .id, pattern: id)
                } label: {
                    Label("このIDをNGにする", systemImage: "hand.raised")
                }
            }
            if !post.name.isEmpty {
                Button {
                    NGFilterStore.shared.add(kind: .name, pattern: post.name)
                } label: {
                    Label("この名前をNGにする", systemImage: "hand.raised")
                }
            }
            if let onReport {
                Divider()
                Button(role: .destructive, action: onReport) {
                    Label("通報する", systemImage: "flag")
                }
            }
        }
        // The system translator, as Messages and Safari present it. It wants the
        // visible text, not PostService's `[>>N](donguri://res/N)` markdown.
        .translationPresentation(isPresented: $showTranslation,
                                 text: post.text.asPlainPostText)
        .fullScreenCover(item: $localGalleryItem) { item in
            let items = resolvedMedia
            GalleryView(items: items, initialIndex: items.firstIndex(of: item) ?? 0) {
                withTransaction(Transaction.noAnimation) { localGalleryItem = nil }
            }
            .presentationBackground(.clear)
        }
    }

    private var resolvedMedia: [MediaItem] {
        media ?? MediaItem.items(in: post, at: index)
    }

    @ViewBuilder
    private var nameView: some View {
        let label = post.name + " " + (!post.email.isEmpty ? "[\(post.email)]" : "")

        if let trip = post.trip {
            Button {
                onTripTap(trip)
            } label: {
                Text(.init(label))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isTripHighlighted ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
        } else {
            Text(.init(label))
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
    }

}

/// Stands in for a post hidden by an NG rule, or deleted on the server.
/// 5ch clients call both あぼーん.
private struct AbornPlaceholder: View {
    let index: Int
    var isDeletedOnServer = false

    var body: some View {
        HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, minHeight: 18)
                .background(Circle().fill(Color.secondary.opacity(0.12)))
            Text("あぼーん")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isDeletedOnServer {
                Text("（削除されました）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    ThreadView(thread: nil, boardURL: nil)
}
