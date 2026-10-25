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

    /// Reply previews stack up, like Chance's reply pages: tapping `>>N`
    /// inside a preview pushes a new card, and the back button pops it.
    @State private var replyStack: [[Int]] = []
    private var replyPreviewIndices: [Int] { replyStack.last ?? [] }

    /// First post that's new since the last visit (unread count), for the
    /// highlight and the "new posts" jump.
    @State private var newPostsStart: Int?
    /// The board's default name in this thread, hidden when that's enabled.
    @State private var defaultName: String?
    /// スレ内検索
    @State private var postSearch = ""
    // 次スレ
    @State private var nextThread: Thread?
    @State private var nextThreadSearched = false
    @State private var findingNextThread = false

    // ID/trip → post indices, used to highlight every post from the same poster.
    @State private var idIndices: [String: [Int]] = [:]
    @State private var tripIndices: [String: [Int]] = [:]
    @State private var highlightedID: String?
    @State private var highlightedTrip: String?

    // Read-position tracking: how far the user has scrolled, and where to
    // resume to once a fresh load's rows exist.
    /// Observable on its own so that only the position pill redraws when it
    /// changes; as plain @State it redrew every row several times a second
    /// while scrolling down.
    @State private var readProgress = ReadProgress()
    private var maxSeenIndex: Int {
        get { readProgress.maxSeen }
        nonmutating set { readProgress.maxSeen = newValue }
    }
    /// The live read position. Rows report in as they appear, many per
    /// second while scrolling; writing each one to @State redrew the whole
    /// thread every time. `maxSeenIndex` is published from this at most a
    /// few times a second, and when scrolling stops.
    @State private var seen = SeenTracker()
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
    /// Open dictionary popups, as in Hoshi Reader: the first is the word
    /// tapped in a post, and each word tapped inside a popup opens another
    /// on top of it. Each popup is its own PopupView and web view.
    @State private var popups: [PopupItem] = []
    /// Dictionary stylesheets, gathered once rather than on every lookup.
    @State private var stylesCache: [String: String]?
    /// Post text styling; reading it here redraws every post when the user
    /// changes fonts or colours in 外観.
    @State private var appearance = AppearanceSettings.shared

    private static let popularThresholds = [3, 5, 10]

    @Environment(BrowseContext.self) private var browseContext: BrowseContext?
    private var browse: BrowseContext { browseContext ?? .detached }
    @Environment(\.scenePhase) private var scenePhase
    @State private var behavior = BehaviorSettings.shared

    // Auto-refresh (自動更新), for live threads.
    @State private var autoRefresh = false
    @State private var autoRefreshDecided = false
    /// When the current wait started, for the pill's countdown ring.
    @State private var refreshCycleStart = Date.now
    @State private var isOnScreen = false
    /// Set to a post to bring into view from outside the scroll reader
    /// (new posts arriving at the bottom).
    @State private var followTarget: Int?

    // Opening a thread, as Chance does it: the title and a progress bar
    // while the thread downloads and every post is prepared (text laid out,
    // the first images decoded), and only then the thread, already at the
    // right place, so the first scroll is smooth.
    @State private var showsLoadingCover = false
    @State private var preparePhase: PreparePhase = .downloading
    /// nil while the amount of work isn't known.
    @State private var prepareProgress: Double?
    /// True from parsing until the reveal; holds back the resume scroll so
    /// it happens under the cover.
    @State private var isPreparingLoad = false
    @State private var revealTarget: Int?
    @State private var prepareTotal = 0

    // Tree mode (ツリー表示), as in Chance.
    @AppStorage("donguri.threadTreeMode") private var treeMode = false
    @State private var tree = ReplyTree.empty
    @State private var treeDepth: [Int: Int] = [:]
    @State private var collapsed: Set<Int> = []

    /// Tree order only applies to the whole thread; a search or the 人気レス
    /// filter shows matching posts in thread order.
    private var showsTree: Bool {
        treeMode && popularThreshold == nil && postSearch.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Indices of the posts the list shows, in thread order. Stored rather
    /// than computed: the list, the position pill and the banners all read it
    /// on every redraw, and filtering 1000 posts each time added up.
    @State private var visibleIndices: [Int] = []

    private func recomputeVisibleIndices() {
        if showsTree {
            if tree.parent.count != posts.count {
                tree = ReplyTree(posts: posts)
            }
            let flattened = tree.flattened(collapsed: collapsed)
            visibleIndices = flattened.order
            treeDepth = flattened.depth
        } else {
            visibleIndices = Self.filteredIndices(posts: posts, popularThreshold: popularThreshold, search: postSearch)
            treeDepth = [:]
        }
    }

    private static func filteredIndices(posts: [Post], popularThreshold: Int?, search: String) -> [Int] {
        var indices = Array(posts.indices)
        if let popularThreshold {
            indices = indices.filter { Self.replyCount(of: posts[$0]) >= popularThreshold }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            indices = indices.filter {
                posts[$0].text.localizedCaseInsensitiveContains(query)
                    || posts[$0].name.localizedCaseInsensitiveContains(query)
                    || posts[$0].id == query
            }
        }
        return indices
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

    /// Posts by the highlighted ID or trip. Stored, not computed: every row
    /// asks whether it's in here on every redraw.
    @State private var highlightedIndices: Set<Int> = []
    /// Posts hidden by NG rules, worked out once per load or rule change
    /// rather than by every row on every redraw.
    @State private var ngHidden: Set<Int> = []

    private func updateHighlightedIndices() {
        if let highlightedID {
            highlightedIndices = Set(idIndices[highlightedID] ?? [])
        } else if let highlightedTrip {
            highlightedIndices = Set(tripIndices[highlightedTrip] ?? [])
        } else {
            highlightedIndices = []
        }
    }

    var body: some View {
        if let thread, let boardURL {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    threadContent(thread: thread, boardURL: boardURL, proxy: proxy)
                        .onChange(of: revealTarget) { _, newValue in
                            guard let newValue else { return }
                            revealTarget = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                withAnimation(nil) {
                                    proxy.scrollTo(newValue, anchor: .top)
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    hideLoadingCover()
                                }
                            }
                        }
                        .onChange(of: resumeIndex) { _, newValue in
                            // While a load is being prepared, the reveal does this.
                            guard let newValue, !isPreparingLoad else { return }
                            resumeIndex = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                withAnimation(nil) {
                                    proxy.scrollTo(newValue, anchor: .top)
                                }
                            }
                        }
                        .onChange(of: followTarget) { _, newValue in
                            guard let newValue else { return }
                            followTarget = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                withAnimation(.snappy) {
                                    proxy.scrollTo(newValue, anchor: .bottom)
                                }
                            }
                        }
                        .overlay {
                            popupLayer(screenSize: geometry.size,
                                       documentTitle: thread.title ?? posts.first?.threadTitle)
                        }
                }
            }
            .searchable(text: $postSearch,
                        placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "スレ内を検索")
            .themedScreen()
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
                        Haptics.play(.success)
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundStyle(isFavorite ? Color.yellow : Color.accentColor)
                    }
                    .accessibilityLabel(isFavorite ? Text("お気に入りから削除") : Text("お気に入りに追加"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    threadMenu(boardURL: boardURL, thread: thread)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    TabsToolbarButton()
                }
            }
            .fullScreenCover(item: $galleryRequest) { request in
                GalleryView(items: mediaItems,
                            initialIndex: request.startIndex,
                            initiallyShowGrid: request.showGrid,
                            onJumpToPost: { postIndex in
                                jumpToPost(postIndex)
                            },
                            sourceFrame: { item in
                                MediaFrameRegistry.shared.frame(for: item.id)
                            },
                            documentTitle: resolvedTitle,
                            onClose: {
                                withTransaction(Transaction.noAnimation) { galleryRequest = nil }
                            })
                .presentationBackground(.clear)
            }
            .task {
                WebProcessWarmer.warm()
                if !autoRefreshDecided {
                    autoRefreshDecided = true
                    autoRefresh = behavior.autoRefreshLiveBoards && Self.isLiveBoard(boardURL)
                }
                await loadThread(boardURL: boardURL, threadId: thread.id)
            }
            .task(id: autoRefreshKey) {
                await runAutoRefresh(boardURL: boardURL, threadId: thread.id)
            }
            .refreshable {
                let before = posts.count
                await loadThread(boardURL: boardURL, threadId: thread.id)
                // Say what the pull found, so an empty refresh isn't a mystery.
                guard before > 0, errorMessage == nil else { return }
                let added = posts.count - before
                if added > 0 {
                    Haptics.play(.success)
                    flashSaveFeedback(String(localized: "新着レス \(added)件"))
                } else {
                    flashSaveFeedback(String(localized: "新着はありません"))
                }
            }
            .onAppear {
                isOnScreen = true
            }
            .onDisappear {
                isOnScreen = false
                persistReadState(boardURL: boardURL, threadId: thread.id)
            }
            .onChange(of: browse.isActive) { _, isActive in
                // Switching to another tab counts as leaving the thread.
                if !isActive { persistReadState(boardURL: boardURL, threadId: thread.id) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { persistReadState(boardURL: boardURL, threadId: thread.id) }
            }
        } else {
            ContentUnavailableView("エラー：スレや板情報がありません", systemImage: "exclamationmark.triangle")
        }
    }

    // MARK: Thread content

    @ViewBuilder
    private func threadContent(thread: Thread, boardURL: String, proxy: ScrollViewProxy) -> some View {
        if !posts.isEmpty {
            ZStack(alignment: .top) {
                postList(thread: thread, boardURL: boardURL, proxy: proxy)

                if !replyPreviewIndices.isEmpty {
                    replyOverlay(proxy: proxy)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if replyPreviewIndices.isEmpty {
                    positionIndicator(proxy: proxy, boardURL: boardURL, threadId: thread.id)
                }
            }
            .animation(.snappy, value: replyStack)
            .overlay {
                if showsLoadingCover {
                    loadingCover(thread: thread, boardURL: boardURL)
                        .transition(.opacity)
                }
            }
        } else if let errorMessage {
            ContentUnavailableView {
                Label("エラーが発生しました", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
        } else {
            loadingCover(thread: thread, boardURL: boardURL)
        }
    }

    private func loadingCover(thread: Thread, boardURL: String) -> some View {
        ThreadLoadingView(title: resolvedTitle,
                          boardName: resolvedBoardName,
                          phase: preparePhase,
                          progress: prepareProgress,
                          postCount: prepareTotal > 0 ? prepareTotal : nil)
    }

    private func postList(thread: Thread, boardURL: String, proxy: ScrollViewProxy) -> some View {
        List {
            ForEach(visibleIndices, id: \.self) { index in
                postRow(index: index, thread: thread, boardURL: boardURL)
            }

            if posts.count >= 1000 || nextThread != nil {
                nextThreadRow(thread: thread, boardURL: boardURL)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(appearance.threadBackground == nil ? .automatic : .hidden)
        .background(appearance.threadBackground ?? Color.clear)
        .safeAreaInset(edge: .top) {
            bannerStack
        }
        // Scrolling the thread closes the dictionary popup.
        .onScrollPhaseChange { _, phase in
            if phase == .interacting, !popups.isEmpty {
                dismissPopup()
            }
            if phase == .idle, seen.maxSeen != maxSeenIndex {
                maxSeenIndex = seen.maxSeen
            }
        }
        .onChange(of: postSearch) { recomputeVisibleIndices() }
        .onChange(of: popularThreshold) { recomputeVisibleIndices() }
        .onChange(of: treeMode) { recomputeVisibleIndices() }
        .onChange(of: collapsed) { recomputeVisibleIndices() }
        .onChange(of: ngFilter.rules) { ngHidden = ngFilter.hiddenIndices(in: posts) }
    }

    @ViewBuilder
    private func postRow(index: Int, thread: Thread, boardURL: String) -> some View {
        let post = posts[index]
        let depth = treeDepth[index] ?? 0
        Group {
            if post.isDeleted == true {
                AbornPlaceholder(index: index, isDeletedOnServer: true)
                    .listRowBackground(Color.clear)
            } else if ngHidden.contains(index) {
                // Kept in place so >>N numbering stays correct.
                AbornPlaceholder(index: index)
                    .listRowBackground(Color.clear)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if showsReadMarker(at: index) {
                        ReadMarker()
                    }
                    postView(index: index, post: post, thread: thread, boardURL: boardURL)
                    if showsTree, tree.descendantCount.indices.contains(index), tree.descendantCount[index] > 0 {
                        collapseButton(index: index)
                    }
                }
                .listRowBackground(rowBackground(for: index))
            }
        }
        .padding(.leading, CGFloat(min(depth, 8)) * 14)
        .overlay(alignment: .leading) {
            if depth > 0 {
                TreeGuides(depth: min(depth, 8))
            }
        }
        .listRowSeparator(appearance.postSeparators && depth == 0 ? .automatic : .hidden)
        .id(index)
        .onAppear {
            noteSeen(index)
            seen.visible.insert(index)
            prefetcher.rowAppeared(index, mediaByPost: mediaByPost)
        }
        .onDisappear {
            seen.visible.remove(index)
        }
    }

    private func postView(index: Int, post: Post, thread: Thread, boardURL: String) -> some View {
        PostView(index: index,
                 post: post,
                 idCount: post.id.flatMap { idIndices[$0]?.count } ?? 0,
                 tripCount: post.trip.flatMap { tripIndices[$0]?.count } ?? 0,
                 isIDHighlighted: post.id != nil && post.id == highlightedID,
                 isTripHighlighted: post.trip != nil && post.trip == highlightedTrip,
                 onThreadRoute: { route in
                     open(route)
                 },
                 onPostReply: { postIndex in
                     dismissPopup()
                     replyStack.append([postIndex])
                 },
                 onShowReplies: { indices in
                     dismissPopup()
                     replyStack.append(indices)
                 },
                 onIDTap: { id in
                     toggleHighlightedID(id)
                 },
                 onTripTap: { trip in
                     toggleHighlightedTrip(trip)
                 },
                 onTextSelected: { selection in
                     handleTextSelection(selection)
                 },
                 onTapOutside: {
                     dismissPopup()
                 },
                 onReport: {
                     ReportService.report(
                         post: post,
                         index: index,
                         boardURL: boardURL,
                         threadId: thread.id,
                         threadTitle: thread.title ?? posts.first?.threadTitle
                     )
                 },
                 media: mediaByPost[index] ?? [],
                 onOpenMedia: { item in
                     dismissPopup()
                     openGallery(at: item)
                 },
                 textStyle: appearance.postStyle,
                 hidesName: appearance.hideDefaultNames && post.trip == nil
                    && defaultName != nil && post.name == defaultName,
                 threadTitle: index == 0 ? resolvedTitle : nil,
                 // In tree mode the replies are right there underneath.
                 showsReplyButton: !showsTree)
        // Rows whose data hasn't changed skip their body when the thread
        // redraws (a refresh, a highlight, the popup opening).
        .equatable()
    }

    /// The "read up to here" line goes above the first new post.
    private func showsReadMarker(at index: Int) -> Bool {
        guard let newPostsStart, newPostsStart > 0, index == newPostsStart else { return false }
        return !showsTree
    }

    private func collapseButton(index: Int) -> some View {
        let isCollapsed = collapsed.contains(index)
        let count = tree.descendantCount[index]
        return Button {
            Haptics.play(.selection)
            withAnimation(.snappy) {
                if isCollapsed { collapsed.remove(index) } else { collapsed.insert(index) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.bold))
                Text(isCollapsed ? String(localized: "返信\(count)件を表示") : String(localized: "返信\(count)件を折りたたむ"))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A link to another thread inside a post.
    private func open(_ route: ThreadRoute) {
        dismissPopup()
        let target = BBSMenuService.resolveBoardURL(route.boardURL)
        let sameBoard = target == boardURL
        browse.push(.thread(ThreadLink(boardURL: target,
                                       threadId: route.threadId,
                                       title: nil,
                                       boardName: sameBoard ? boardName : nil)))
    }

    private func noteSeen(_ index: Int) {
        if index == posts.count - 1, posts.count > 30, !seen.reachedEnd {
            seen.reachedEnd = true
            Haptics.play(.light)
        }
        guard index > seen.maxSeen else { return }
        seen.maxSeen = index
        let now = Date.now
        if now.timeIntervalSince(seen.lastPublished) > 0.3 {
            seen.lastPublished = now
            maxSeenIndex = index
        }
    }

    /// ID/trip highlight first, then the new-since-last-visit tint, the way
    /// Chance tints unseen posts.
    private func rowBackground(for index: Int) -> Color {
        if highlightedIndices.contains(index) {
            return Color.accentColor.opacity(0.15)
        }
        if let newPostsStart, index >= newPostsStart {
            return Color.accentColor.opacity(0.06)
        }
        return Color.clear
    }

    private func replyOverlay(proxy: ScrollViewProxy) -> some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { replyStack.removeAll() }

            ReplyPreviewCard(
                indices: replyPreviewIndices,
                posts: posts,
                idIndices: idIndices,
                tripIndices: tripIndices,
                canGoBack: replyStack.count > 1,
                onBack: { _ = replyStack.popLast() },
                onClose: { replyStack.removeAll() },
                onJump: { index in
                    replyStack.removeAll()
                    if !visibleIndices.contains(index) {
                        // The target is filtered out of the list, so there is
                        // no row to scroll to until the filters are lifted.
                        popularThreshold = nil
                        postSearch = ""
                        collapsed.removeAll()
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
                    replyStack.removeAll()
                    open(route)
                },
                onShowReplies: { indices in
                    replyStack.append(indices)
                },
                mediaByPost: mediaByPost,
                onOpenMedia: { item in
                    replyStack.removeAll()
                    openGallery(at: item)
                },
                onTextSelected: { handleTextSelection($0) },
                onTapOutside: { dismissPopup() }
            )
            .padding(.horizontal)
        }
    }

    // MARK: Position indicator

    /// Chance's thread position pill: how many posts are below, with the new
    /// ones counted in red. Tap jumps to the new posts (or the bottom); hold
    /// for top, new, bottom and refresh.
    @ViewBuilder
    private func positionIndicator(proxy: ScrollViewProxy, boardURL: String, threadId: Int) -> some View {
        let lastIndex = visibleIndices.last ?? 0

        if posts.count > 15 || autoRefresh {
            Menu {
                Button {
                    scroll(proxy, to: visibleIndices.first ?? 0)
                } label: {
                    Label("一番上へ", systemImage: "arrow.up.to.line")
                }
                if let newPostsStart {
                    Button {
                        scroll(proxy, to: newPostsStart)
                    } label: {
                        Label("新着へ（>>\(newPostsStart + 1)）", systemImage: "arrow.down")
                    }
                }
                Button {
                    scroll(proxy, to: lastIndex)
                } label: {
                    Label("一番下へ", systemImage: "arrow.down.to.line")
                }
                Divider()
                Button {
                    Task { await loadThread(boardURL: boardURL, threadId: threadId) }
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                Toggle(isOn: autoRefreshBinding) {
                    Label("自動更新（\(behavior.autoRefreshInterval)秒）", systemImage: "dot.radiowaves.left.and.right")
                }
            } label: {
                PositionPillLabel(progress: readProgress,
                                  visibleIndices: visibleIndices,
                                  newPostsStart: newPostsStart,
                                  showsTree: showsTree,
                                  autoRefresh: autoRefresh,
                                  refreshCycleStart: refreshCycleStart,
                                  refreshInterval: TimeInterval(behavior.autoRefreshInterval))
            } primaryAction: {
                Haptics.play(.light)
                let unseenNew = showsTree ? 0 : (newPostsStart.map { start in
                    Self.count(in: visibleIndices, above: max(start - 1, maxSeenIndex))
                } ?? 0)
                if unseenNew > 0, let newPostsStart, newPostsStart > maxSeenIndex {
                    scroll(proxy, to: newPostsStart)
                } else {
                    scroll(proxy, to: lastIndex)
                }
            }
            .padding(.trailing, 14)
            .padding(.bottom, 14)
        }
    }

    /// How many of the sorted `indices` are greater than `value`.
    fileprivate static func count(in indices: [Int], above value: Int) -> Int {
        var low = 0, high = indices.count
        while low < high {
            let mid = (low + high) / 2
            if indices[mid] <= value { low = mid + 1 } else { high = mid }
        }
        return indices.count - low
    }

    private func scroll(_ proxy: ScrollViewProxy, to index: Int) {
        dismissPopup()
        withAnimation(.snappy) {
            proxy.scrollTo(index, anchor: .top)
        }
    }

    // MARK: 次スレ

    private func nextThreadRow(thread: Thread, boardURL: String) -> some View {
        Button {
            if let nextThread {
                browse.push(.thread(ThreadLink(boardURL: boardURL,
                                               threadId: nextThread.id,
                                               title: nextThread.title,
                                               boardName: boardName,
                                               responseCount: nextThread.responseCount)))
            } else {
                Task { await findNextThread(boardURL: boardURL, current: thread) }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: nextThread != nil ? "arrow.right.circle.fill" : "magnifyingglass.circle")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    if let nextThread {
                        Text("次スレ")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(nextThread.title ?? String(localized: "無題"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    } else if findingNextThread {
                        Text("次スレを探しています…")
                            .font(.subheadline)
                    } else if nextThreadSearched {
                        Text("次スレが見つかりませんでした（もう一度探す）")
                            .font(.subheadline)
                    } else {
                        Text("次スレを探す")
                            .font(.subheadline)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .onAppear {
            if !nextThreadSearched, !findingNextThread {
                Task { await findNextThread(boardURL: boardURL, current: thread) }
            }
        }
    }

    private func findNextThread(boardURL: String, current: Thread) async {
        guard !findingNextThread else { return }
        findingNextThread = true
        defer {
            findingNextThread = false
            nextThreadSearched = true
        }
        guard let listing = try? await ThreadService().fetchThreads(boardURL: boardURL) else { return }
        nextThread = NextThreadFinder.find(after: current.id,
                                           title: resolvedTitle ?? "",
                                           in: listing)
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
                Toggle(isOn: autoRefreshBinding) {
                    Label("自動更新", systemImage: "dot.radiowaves.left.and.right")
                }
                Picker(selection: Binding(
                    get: { behavior.autoRefreshInterval },
                    set: { behavior.autoRefreshInterval = $0 }
                )) {
                    ForEach(BehaviorSettings.refreshIntervals, id: \.self) { seconds in
                        Text("\(seconds)秒ごと").tag(seconds)
                    }
                } label: {
                    Label("更新の間隔", systemImage: "timer")
                }
                .pickerStyle(.menu)
                Toggle(isOn: $treeMode) {
                    Label("ツリー表示", systemImage: "list.bullet.indent")
                }
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
        if !visibleIndices.contains(postIndex) {
            popularThreshold = nil
            postSearch = ""
            collapsed.removeAll()
        }
        resumeIndex = postIndex
    }

    /// Works out the thread's media and starts any whole-thread preloading
    /// the user asked for in Settings.
    /// `previousCount` is how many posts were there before; on a refresh
    /// only the new posts' media is preloaded and pinned, rather than the
    /// whole thread's again every few seconds.
    private func updateMedia(for newPosts: [Post], boardURL: String, threadId: Int, previousCount: Int) {
        let items = MediaItem.items(for: newPosts)
        mediaItems = items
        mediaByPost = Dictionary(grouping: items, by: \.postIndex)
        let isRefresh = previousCount > 0 && newPosts.count >= previousCount
        let newItems = isRefresh ? items.filter { $0.postIndex >= previousCount } : items
        if !isRefresh {
            prefetcher.reset()
        }

        let mode = MediaPrefetchMode.current
        let wantsAll = mode == .all || (mode == .allOnWiFi && !NetworkMonitor.shared.isExpensive)
        if wantsAll, !newItems.isEmpty {
            if isRefresh {
                prefetcher.prefetchMore(newItems)
            } else {
                prefetcher.prefetchAll(newItems)
            }
        }

        // A saved thread keeps its images current as it grows.
        if savedThreads.isSaved(boardURL: boardURL, threadId: threadId), !newItems.isEmpty {
            let images = newItems.filter { $0.kind == .image }.map(\.url)
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
                if !postSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                    HighlightBanner(
                        text: String(localized: "検索結果: \(visibleIndices.count)件"),
                        systemImage: "magnifyingglass"
                    ) {
                        postSearch = ""
                    }
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
            || !postSearch.trimmingCharacters(in: .whitespaces).isEmpty
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
        updateHighlightedIndices()
    }

    private func toggleHighlightedTrip(_ trip: String) {
        highlightedID = nil
        highlightedTrip = (highlightedTrip == trip) ? nil : trip
        updateHighlightedIndices()
    }

    private func clearHighlight() {
        highlightedID = nil
        highlightedTrip = nil
        highlightedIndices = []
    }

    public func loadThread(boardURL: String, threadId: Int) async {
        let cacheKey = ReadStateStore.key(boardURL: boardURL, threadId: threadId)

        // Show something immediately when we can: the copy still in memory from
        // a recent visit, or else the offline copy of a saved thread. The live
        // version replaces it once the network answers; offline, it stays.
        if posts.isEmpty, let cached = ThreadMemoryCache.shared.posts(for: cacheKey), !cached.isEmpty {
            await prepareAndApply(cached, boardURL: boardURL, threadId: threadId)
        } else if posts.isEmpty,
                  let savedPosts = savedThreads.posts(boardURL: boardURL, threadId: threadId),
                  !savedPosts.isEmpty {
            showingSavedCopy = true
            await prepareAndApply(savedPosts, boardURL: boardURL, threadId: threadId)
        }
        if posts.isEmpty {
            preparePhase = .downloading
            prepareProgress = nil
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
                if isInitialLoad {
                    await prepareAndApply(newPosts, boardURL: boardURL, threadId: threadId, afterDownload: true)
                } else {
                    apply(newPosts, boardURL: boardURL, threadId: threadId, isInitialLoad: false)
                }
            }
            savedThreads.updateIfSaved(boardURL: boardURL,
                                       threadId: threadId,
                                       title: resolvedTitle,
                                       posts: newPosts)
        } catch {
            errorMessage = String(localized: "エラーが発生しました: \(String(describing: error))")
            print("ThreadView Error: \(error)")
            hideLoadingCover()
        }
    }

    // MARK: Preparing a load

    /// Prepares every post, applies them, decodes the images that will be on
    /// screen first, then reveals the thread at its resume position.
    private func prepareAndApply(_ newPosts: [Post], boardURL: String, threadId: Int,
                                 afterDownload: Bool = false) async {
        isPreparingLoad = true
        preparePhase = .preparing
        prepareProgress = 0
        prepareTotal = newPosts.count
        // Coming from the download screen, the cover is already what's
        // showing, so it simply stays up.
        if afterDownload {
            showsLoadingCover = true
        }
        // Threads still in memory are ready almost at once; only cover the
        // screen if preparing takes long enough to notice.
        let cover = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, isPreparingLoad else { return }
            withAnimation(.easeOut(duration: 0.15)) { showsLoadingCover = true }
        }

        await warmUp(newPosts)
        apply(newPosts, boardURL: boardURL, threadId: threadId, isInitialLoad: true)

        let start = resumeIndex ?? 0
        preparePhase = .images
        prepareProgress = nil
        await preloadThumbnails(from: start)

        cover.cancel()
        isPreparingLoad = false
        if let target = resumeIndex {
            resumeIndex = nil
            revealTarget = target
        } else {
            hideLoadingCover()
        }
    }

    private func hideLoadingCover() {
        isPreparingLoad = false
        guard showsLoadingCover else { return }
        withAnimation(.easeOut(duration: 0.2)) { showsLoadingCover = false }
    }

    /// Builds each post's text (cached by PostTextFormatter, so the rows
    /// only look it up) and the other per-post work rows do, in chunks so
    /// the progress bar moves.
    private func warmUp(_ newPosts: [Post]) async {
        let style = appearance.postStyle
        let total = max(newPosts.count, 1)
        for index in newPosts.indices {
            let post = newPosts[index]
            if post.isDeleted != true {
                _ = PostTextFormatter.attributed(post.text, style: style)
                if style.detectsAsciiArt, AsciiArt.isArt(post.text) {
                    _ = AsciiArt.widestLine(post.text)
                }
                _ = PostDate.date(from: post.date)
                _ = LinkPreviewService.previewableURLs(in: post.text)
            }
            if index % 40 == 39 {
                prepareProgress = Double(index + 1) / Double(total)
                await Task.yield()
            }
        }
        prepareProgress = 1
    }

    /// Decodes the thumbnails of the first screenful from `start`, waiting
    /// at most a moment: a slow image server shouldn't hold the thread back.
    private func preloadThumbnails(from start: Int) async {
        guard !posts.isEmpty else { return }
        let end = min(start + 12, posts.count)
        guard start < end else { return }
        let items = (start..<end).flatMap { mediaByPost[$0] ?? [] }.filter { $0.kind != .unsupportedVideo }
        guard !items.isEmpty else { return }
        let size = MediaThumbnailView.rowPixelSize
        let loading = Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                for item in items {
                    group.addTask {
                        _ = await MediaStore.shared.thumbnail(for: item, maxPixelSize: size)
                    }
                }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await loading.value }
            group.addTask { try? await Task.sleep(for: .seconds(1.5)) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    /// Cheap "nothing changed" check: same length, same first and last post.
    /// A deleted post (あぼーん) changes the dat's length, so it is caught too.
    private static func samePosts(_ a: [Post], _ b: [Post]) -> Bool {
        guard a.count == b.count, let lastA = a.last, let lastB = b.last else { return false }
        return lastA.text == lastB.text && lastA.date == lastB.date && a.first?.text == b.first?.text
    }

    private func apply(_ newPosts: [Post], boardURL: String, threadId: Int, isInitialLoad: Bool) {
        let previousCount = posts.count
        posts = newPosts
        tree = showsTree || treeMode ? ReplyTree(posts: newPosts) : .empty
        recomputeVisibleIndices()
        updateMedia(for: newPosts, boardURL: boardURL, threadId: threadId, previousCount: previousCount)
        (idIndices, tripIndices) = Self.buildHighlightIndices(posts: newPosts)
        highlightedID = nil
        highlightedTrip = nil
        highlightedIndices = []
        ngHidden = ngFilter.hiddenIndices(in: newPosts)

        defaultName = Self.defaultName(in: newPosts)

        if isInitialLoad {
            maxSeenIndex = 0
            seen.maxSeen = 0
            let key = ReadStateStore.key(boardURL: boardURL, threadId: threadId)
            if let state = ReadStateStore.shared.state(for: key),
               state.lastReadCount > 0, state.lastReadCount < newPosts.count {
                newPostsStart = state.lastReadCount
            }
            // Back to where the screen was when the thread was left, or,
            // from older builds, the furthest post read. The furthest post is
            // only used when there's unread content below it: scrolling the
            // final row to the top would have nothing below to anchor against.
            if let state = ReadStateStore.shared.state(for: key), newPosts.count > 1 {
                if let top = state.lastTopIndex, top > 0, top < newPosts.count {
                    resumeIndex = top
                } else if state.lastReadIndex < newPosts.count - 1 {
                    resumeIndex = max(0, state.lastReadIndex)
                }
            }
        } else if newPosts.count > previousCount, previousCount > 0, newPostsStart == nil {
            // Posts that arrive while reading are tinted as new, too.
            newPostsStart = previousCount
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

    // MARK: Dictionary popups (Hoshi Reader's model)

    private func popupLayer(screenSize: CGSize, documentTitle: String?) -> some View {
        ZStack {
            ForEach($popups) { $popup in
                let popupId = popup.id
                PopupView(
                    userConfig: userConfig,
                    isVisible: $popup.showPopup,
                    selectionData: popup.currentSelection,
                    lookupResults: popup.lookupResults,
                    dictionaryStyles: popup.dictionaryStyles,
                    screenSize: screenSize,
                    isVertical: false,
                    isFullWidth: popup.isFullWidth,
                    topInset: UIApplication.topSafeArea,
                    bottomInset: UIApplication.bottomSafeArea,
                    coverURL: nil,
                    documentTitle: documentTitle,
                    clearSelection: popup.clearSelection,
                    onTextSelected: { selection in
                        // A word tapped inside a popup opens a child popup on
                        // top; anything already above this one closes first.
                        if let index = popups.firstIndex(where: { $0.id == popupId }) {
                            closeChildPopups(parent: index)
                        }
                        return lookUp(selection, isFullWidth: false)
                    },
                    onTapOutside: {
                        if let index = popups.firstIndex(where: { $0.id == popupId }) {
                            closeChildPopups(parent: index)
                        }
                    },
                    onSwipeDismiss: {
                        guard let index = popups.firstIndex(where: { $0.id == popupId }) else { return }
                        if index == 0 {
                            dismissPopup()
                        } else {
                            popups[index - 1].clearSelection.toggle()
                            closeChildPopups(parent: index - 1)
                        }
                    }
                )
                .zIndex(Double(100 + (popups.firstIndex(where: { $0.id == popupId }) ?? 0)))
            }
        }
    }

    /// A word tapped in a post: close any popups, then look it up.
    /// Returns how many characters matched, so the post can highlight them.
    private func handleTextSelection(_ selection: SelectionData) -> Int? {
        closePopups()
        let matched = lookUp(selection, isFullWidth: userConfig.popupFullWidth)
        if matched == nil {
            PostSelectionCenter.shared.clearAll()
        }
        return matched
    }

    /// Opens a popup for `selection` if the dictionaries know it.
    private func lookUp(_ selection: SelectionData, isFullWidth: Bool) -> Int? {
        let results = LookupEngine.shared.lookup(
            selection.text,
            maxResults: userConfig.maxResults,
            scanLength: userConfig.scanLength
        )
        guard let first = results.first else { return nil }

        let styles: [String: String]
        if let stylesCache {
            styles = stylesCache
        } else {
            var built: [String: String] = [:]
            for style in LookupEngine.shared.getStyles() {
                built[style.dictName] = style.styles
            }
            styles = built
            stylesCache = built
        }

        let popup = PopupItem(showPopup: false,
                              currentSelection: selection,
                              lookupResults: results,
                              dictionaryStyles: styles,
                              isVertical: false,
                              isFullWidth: isFullWidth,
                              clearSelection: false)
        popups.append(popup)
        // Added hidden, then faded in: the popup appears where the word is
        // rather than sliding there.
        withAnimation(.default.speed(2.2)) {
            if let index = popups.firstIndex(where: { $0.id == popup.id }) {
                popups[index].showPopup = true
            }
        }
        return first.matched.count
    }

    /// Closes every popup and clears the highlight in the post.
    private func dismissPopup() {
        PostSelectionCenter.shared.clearAll()
        closePopups()
    }

    private func closePopups() {
        guard !popups.isEmpty else { return }
        let ids = Set(popups.map(\.id))
        withAnimation(.default.speed(2.4)) {
            for index in popups.indices {
                popups[index].showPopup = false
            }
        } completion: {
            popups.removeAll { ids.contains($0.id) }
        }
    }

    private func closeChildPopups(parent: Int) {
        let ids = Set(popups.dropFirst(parent + 1).map(\.id))
        guard !ids.isEmpty else { return }
        withAnimation(.default.speed(2.4)) {
            for index in popups.indices where ids.contains(popups[index].id) {
                popups[index].showPopup = false
            }
        } completion: {
            popups.removeAll { ids.contains($0.id) }
        }
    }

    private func persistReadState(boardURL: String, threadId: Int) {
        guard !posts.isEmpty else { return }
        let key = ReadStateStore.key(boardURL: boardURL, threadId: threadId)
        ReadStateStore.shared.update(key: key,
                                     postCount: posts.count,
                                     readIndex: max(maxSeenIndex, seen.maxSeen),
                                     topIndex: topVisibleIndex)
        favorites.readStateDidChange()
    }

    /// The post at the top of the screen (in thread order, the earliest
    /// visible one; in tree order, the first in the list that's visible).
    private var topVisibleIndex: Int? {
        guard !seen.visible.isEmpty else { return nil }
        if showsTree {
            return visibleIndices.first { seen.visible.contains($0) }
        }
        return seen.visible.min()
    }

    // MARK: Auto-refresh

    private var autoRefreshBinding: Binding<Bool> {
        Binding(get: { autoRefresh },
                set: { newValue in
                    autoRefresh = newValue
                    Haptics.play(.selection)
                })
    }

    /// Restarts the refresh loop whenever something that affects it changes.
    private var autoRefreshKey: String {
        "\(autoRefresh)|\(behavior.autoRefreshInterval)|\(browse.isActive)|\(isOnScreen)|\(scenePhase == .active)"
    }

    /// 実況 boards live under directories starting with "live" (livejupiter,
    /// livenhk, …), where threads move fast enough to watch.
    private static func isLiveBoard(_ boardURL: String) -> Bool {
        guard let url = URL(string: boardURL) else { return false }
        let directory = url.pathComponents.first { $0 != "/" } ?? ""
        return directory.hasPrefix("live")
    }

    private func runAutoRefresh(boardURL: String, threadId: Int) async {
        guard autoRefresh, browse.isActive, isOnScreen, scenePhase == .active else { return }
        let interval = max(behavior.autoRefreshInterval, 5)
        while !Task.isCancelled {
            refreshCycleStart = .now
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, !posts.isEmpty else { return }
            // A finished thread won't grow; stop rather than poll it.
            if posts.count >= 1000 {
                autoRefresh = false
                return
            }
            let before = posts.count
            let lastVisible = visibleIndices.last
            let wasAtBottom = lastVisible.map { seen.visible.contains($0) } ?? false
            await loadThread(boardURL: boardURL, threadId: threadId)
            if posts.count > before {
                Haptics.play(.light)
                if behavior.followNewPosts, wasAtBottom, replyStack.isEmpty, popups.isEmpty,
                   let newLast = visibleIndices.last {
                    followTarget = newLast
                }
            }
        }
    }

    /// The board's default name is simply the most common name without a
    /// tripcode, provided it's common enough to be the default.
    private static func defaultName(in posts: [Post]) -> String? {
        var counts: [String: Int] = [:]
        for post in posts where post.trip == nil && post.isDeleted != true && !post.name.isEmpty {
            counts[post.name, default: 0] += 1
        }
        guard let top = counts.max(by: { $0.value < $1.value }) else { return nil }
        return top.value >= 3 && Double(top.value) >= Double(posts.count) * 0.3 ? top.key : nil
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
    var canGoBack = false
    var onBack: () -> Void = {}
    let onClose: () -> Void
    let onJump: (Int) -> Void
    let onThreadRoute: (ThreadRoute) -> Void
    let onShowReplies: ([Int]) -> Void
    var mediaByPost: [Int: [MediaItem]] = [:]
    var onOpenMedia: ((MediaItem) -> Void)? = nil
    /// Dictionary lookups work inside previews too.
    var onTextSelected: (SelectionData) -> Int? = { _ in nil }
    var onTapOutside: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if canGoBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("戻る"))
                }
                if indices.count == 1, let only = indices.first {
                    Text(verbatim: ">>\(only + 1)")
                        .font(.subheadline.weight(.semibold))
                } else {
                    Text("返信 \(indices.count)件")
                        .font(.subheadline.weight(.semibold))
                }
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
                                         onTextSelected: onTextSelected,
                                         onTapOutside: onTapOutside,
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

/// One post, laid out the way Chance lays out imageboard posts: a header
/// line (number, name, coloured ID, time), the thumbnail beside the text,
/// and the reply count as a button under the post.
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
    /// The name is the board's default (名無しさん etc.) and the user has
    /// chosen to hide those.
    var hidesName: Bool = false
    /// Shown above the first post, in the theme's title colour.
    var threadTitle: String? = nil
    /// The 返信N件 button under the post.
    var showsReplyButton: Bool = true

    @Environment(UserConfig.self) private var userConfig
    @State private var appearance = AppearanceSettings.shared
    @State private var behavior = BehaviorSettings.shared
    @State private var localGalleryItem: MediaItem?
    @State private var showTranslation = false

    private var replyCount: Int {
        Set(post.replies ?? []).count
    }

    var body: some View {
        let density = appearance.density
        VStack(alignment: .leading, spacing: density.spacing) {
            if let threadTitle {
                Text(threadTitle)
                    .font(.headline)
                    .foregroundStyle(titleColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            header
                // Taps on the header (outside its buttons) close the dictionary.
                .contentShape(Rectangle())
                .onTapGesture(perform: onTapOutside)

            let mediaItems = resolvedMedia
            HStack(alignment: .top, spacing: 10) {
                if !appearance.thumbnailOnRight {
                    thumbnail(mediaItems)
                }

                // Native text with its own tap-to-lookup (see PostTextView).
                PostTextView(
                    text: post.text,
                    scanNonJapaneseText: userConfig.scanNonJapaneseText,
                    style: textStyle ?? appearance.postStyle,
                    onTextSelected: onTextSelected,
                    onTapOutside: onTapOutside,
                    onPostReply: onPostReply,
                    onThreadRoute: onThreadRoute
                )

                if appearance.thumbnailOnRight {
                    thumbnail(mediaItems)
                }
            }

            // Embeds for the post's links (YouTube, X, pages…).
            if behavior.linkPreviewMode != .off {
                let links = LinkPreviewService.previewableURLs(in: post.text)
                if !links.isEmpty {
                    LinkPreviewList(urls: links, postIndex: index)
                }
            }

            if replyCount > 0, showsReplyButton {
                HStack {
                    Spacer()
                    Button {
                        onShowReplies(post.replies ?? [])
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrowshape.turn.up.left")
                            Text("返信\(replyCount)件")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, appearance.density.rowPadding)
        .contextMenu {
            if !post.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    showTranslation = true
                } label: {
                    Label("翻訳", systemImage: "translate")
                }
                Button {
                    UIPasteboard.general.string = post.text.asPlainPostText
                } label: {
                    Label("本文をコピー", systemImage: "doc.on.doc")
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
            if !post.date.isEmpty {
                Text(post.date)
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
        // Attached only once asked for: a translation modifier on every row
        // was measurable while scrolling.
        .modifier(TranslationOnDemand(isPresented: $showTranslation, text: post.text))
        .fullScreenCover(item: $localGalleryItem) { item in
            let items = resolvedMedia
            GalleryView(items: items, initialIndex: items.firstIndex(of: item) ?? 0) {
                withTransaction(Transaction.noAnimation) { localGalleryItem = nil }
            }
            .presentationBackground(.clear)
        }
    }

    @ViewBuilder
    private func thumbnail(_ mediaItems: [MediaItem]) -> some View {
        if let first = mediaItems.first {
            Button {
                open(first)
            } label: {
                MediaThumbnailView(item: first, side: appearance.thumbnailSize.side, cornerRadius: 6)
                    .overlay(alignment: .topTrailing) {
                        if mediaItems.count > 1 {
                            Text(verbatim: "+\(mediaItems.count - 1)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.black.opacity(0.6)))
                                .padding(3)
                        }
                    }
                    // Where the gallery zooms out of and back into.
                    .reportsMediaFrame(for: first.id)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(verbatim: "#\(index + 1)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)

            nameView

            if !post.email.isEmpty {
                Text(verbatim: post.email)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if let id = post.id {
                Button {
                    onIDTap(id)
                } label: {
                    IDChip(id: id, count: idCount, isHighlighted: isIDHighlighted)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 4)

            timeLabel
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var timeLabel: some View {
        if let date = PostDate.date(from: post.date) {
            HStack(spacing: 4) {
                Text(verbatim: PostDate.shortLabel(for: date))
                if appearance.showRelativeTime {
                    Text(verbatim: PostDate.relativeLabel(for: date))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        } else if !post.date.isEmpty {
            Text(verbatim: post.date)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var nameView: some View {
        if let trip = post.trip {
            Button {
                onTripTap(trip)
            } label: {
                Text(.init(hidesName ? "◆" + trip : post.name))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isTripHighlighted ? Color.accentColor : nameColor)
            }
            .buttonStyle(.plain)
        } else if !hidesName {
            Text(.init(post.name))
                .font(.caption.weight(.semibold))
                .foregroundStyle(nameColor)
        }
    }

    private var nameColor: Color {
        appearance.palette.map { Color(uiColor: $0.text) } ?? .primary
    }

    private var titleColor: Color {
        appearance.palette.map { Color(uiColor: $0.title) } ?? .primary
    }

    private var resolvedMedia: [MediaItem] {
        media ?? MediaItem.items(in: post, at: index)
    }

    private func open(_ item: MediaItem) {
        if let onOpenMedia {
            onOpenMedia(item)
        } else {
            withTransaction(Transaction.noAnimation) { localGalleryItem = item }
        }
    }
}

/// A poster ID in its hashed colour, with how many posts it has made.
private struct IDChip: View {
    let id: String
    let count: Int
    let isHighlighted: Bool

    var body: some View {
        let colors = IDColor.colors(for: id)
        HStack(spacing: 2) {
            Text(verbatim: id)
            if count > 1 {
                Text(verbatim: "(\(count))")
                    .opacity(0.8)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(colors.foreground)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(colors.background))
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)
            }
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

enum PreparePhase {
    case downloading, preparing, images
}

/// What shows while a thread opens: its title, board and a progress bar.
private struct ThreadLoadingView: View {
    let title: String?
    let boardName: String
    let phase: PreparePhase
    let progress: Double?
    let postCount: Int?

    @State private var appearance = AppearanceSettings.shared

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            if let title {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(appearance.palette.map { Color(uiColor: $0.title) } ?? .primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            if !boardName.isEmpty {
                Text(boardName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            LoadingBar(progress: progress)
                .frame(width: 180, height: 4)
                .padding(.top, 8)
            Text(phaseText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background.ignoresSafeArea())
    }

    private var phaseText: String {
        switch phase {
        case .downloading:
            return String(localized: "スレを読み込み中…")
        case .preparing:
            if let postCount, let progress {
                return String(localized: "準備中 \(Int(Double(postCount) * progress))/\(postCount)")
            }
            return String(localized: "準備中…")
        case .images:
            return String(localized: "画像を読み込み中…")
        }
    }

    private var background: Color {
        appearance.threadBackground ?? Color(uiColor: .systemBackground)
    }
}

/// A thin bar: filled to `progress`, or a sliding segment when unknown.
private struct LoadingBar: View {
    let progress: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                if let progress {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(geometry.size.width * progress, geometry.size.height))
                        .animation(.easeOut(duration: 0.15), value: progress)
                } else {
                    TimelineView(.animation) { context in
                        let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                        let segment = geometry.size.width * 0.35
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: segment)
                            .offset(x: (geometry.size.width + segment) * cycle - segment)
                    }
                }
            }
            .clipShape(Capsule())
        }
    }
}

/// "ここまで読んだ": where the last visit stopped.
private struct ReadMarker: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.6))
                .frame(height: 1.5)
            Text("ここまで読んだ")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
            Rectangle()
                .fill(Color.accentColor.opacity(0.6))
                .frame(height: 1.5)
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Vertical lines down the left of a nested post, one per level, as
/// Chance draws its tree.
private struct TreeGuides: View {
    let depth: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<depth, id: \.self) { level in
                Rectangle()
                    .fill(Color.accentColor.opacity(level == depth - 1 ? 0.45 : 0.18))
                    .frame(width: 2)
                    .frame(width: 14, alignment: .center)
            }
        }
        .padding(.vertical, 2)
        .allowsHitTesting(false)
    }
}

/// A small ring filling up until the next automatic refresh.
private struct RefreshCountdown: View {
    let start: Date
    let interval: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let progress = min(max(context.date.timeIntervalSince(start) / interval, 0), 1)
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
            }
            .frame(width: 13, height: 13)
        }
        .accessibilityLabel(Text("自動更新中"))
    }
}

/// Not observable on purpose; see `ThreadView.seen`.
private final class SeenTracker {
    var maxSeen = 0
    var lastPublished = Date.distantPast
    /// Rows on screen right now.
    var visible = Set<Int>()
    /// The end of the thread has been reached this visit (for the haptic).
    var reachedEnd = false
}

extension PostView: Equatable {
    /// The data a row draws. The callbacks are left out: they only reach
    /// back into ThreadView, whose state they read when called.
    static func == (lhs: PostView, rhs: PostView) -> Bool {
        lhs.index == rhs.index
            && lhs.post == rhs.post
            && lhs.idCount == rhs.idCount
            && lhs.tripCount == rhs.tripCount
            && lhs.isIDHighlighted == rhs.isIDHighlighted
            && lhs.isTripHighlighted == rhs.isTripHighlighted
            && lhs.media == rhs.media
            && lhs.textStyle?.key == rhs.textStyle?.key
            && lhs.hidesName == rhs.hidesName
            && lhs.threadTitle == rhs.threadTitle
            && lhs.showsReplyButton == rhs.showsReplyButton
            && (lhs.onReport == nil) == (rhs.onReport == nil)
    }
}

private struct TranslationOnDemand: ViewModifier {
    @Binding var isPresented: Bool
    let text: String

    func body(content: Content) -> some View {
        if isPresented {
            content.translationPresentation(isPresented: $isPresented, text: text.cachedPlainPostText)
        } else {
            content
        }
    }
}

/// How far the reader has got. See `ThreadView.readProgress`.
@Observable
private final class ReadProgress {
    var maxSeen = 0
}

/// The position pill's counts. A view of its own so that the read position
/// changing redraws only this.
private struct PositionPillLabel: View {
    let progress: ReadProgress
    let visibleIndices: [Int]
    let newPostsStart: Int?
    let showsTree: Bool
    let autoRefresh: Bool
    let refreshCycleStart: Date
    let refreshInterval: TimeInterval

    var body: some View {
        let maxSeen = progress.maxSeen
        // In tree order the indices aren't sorted, so there's no "below".
        let below = showsTree ? 0 : ThreadView.count(in: visibleIndices, above: maxSeen)
        let unseenNew = showsTree ? 0 : (newPostsStart.map { start in
            ThreadView.count(in: visibleIndices, above: max(start - 1, maxSeen))
        } ?? 0)
        HStack(spacing: 6) {
            if autoRefresh {
                RefreshCountdown(start: refreshCycleStart, interval: refreshInterval)
            }
            if unseenNew > 0 {
                Text(verbatim: "\(unseenNew)")
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.red))
            }
            if below > 0 {
                Text(verbatim: "\(below)")
                    .foregroundStyle(.secondary)
            }
            Image(systemName: below > 0 ? "arrow.down" : "checkmark")
                .foregroundStyle(.secondary)
        }
        .font(.footnote.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}
