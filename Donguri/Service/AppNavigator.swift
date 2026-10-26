//
//  AppNavigator.swift
//  Donguri
//
//  Where the user is: the selected root tab, and Chance-style browser tabs
//  in the 板 tab. Each browser tab is its own navigation stack, kept as a
//  list of routes so it can be switched to, opened in the background, and
//  restored at the next launch.
//

import SwiftUI

/// A thread to open, with whatever is known about it up front.
struct ThreadLink: Hashable, Codable {
    var boardURL: String
    var threadId: Int
    var title: String?
    var boardName: String?
    /// -1 when unknown (e.g. a thread reached from a link in another).
    var responseCount: Int = -1

    var thread: Thread {
        Thread(id: threadId, title: title, responseCount: responseCount)
    }

    var key: String { ReadStateStore.key(boardURL: boardURL, threadId: threadId) }
}

/// One screen in a navigation stack.
enum BrowseRoute: Hashable, Codable {
    case board(FavoriteBoard)
    case thread(ThreadLink)
    /// スレタイ検索, with the query to start from.
    case search(String)
}

enum RootTab: String {
    case boards, saved, history, browser, dictionary, settings
}

/// One Chance-style tab: a navigation stack inside the 板 tab.
struct BrowserTab: Identifiable, Codable, Hashable {
    var id = UUID()
    var path: [BrowseRoute] = []

    /// What the switcher shows for the tab: its top screen.
    var title: String {
        switch path.last {
        case .board(let board): board.boardName
        case .thread(let link): link.title ?? String(localized: "無題")
        case .search(let query): query.isEmpty ? String(localized: "スレタイ検索") : query
        case nil: String(localized: "板一覧")
        }
    }

    var subtitle: String? {
        switch path.last {
        case .thread(let link):
            link.boardName ?? HistoryStore.shared.knownBoardName(for: link.boardURL)
        case .board: String(localized: "板")
        case .search: String(localized: "スレタイ検索")
        case nil: nil
        }
    }

    var systemImage: String {
        switch path.last {
        case .thread: "text.bubble"
        case .board: "rectangle.stack"
        case .search: "magnifyingglass"
        case nil: "list.bullet"
        }
    }
}

@Observable
final class AppNavigator {
    static let shared = AppNavigator()

    private static let tabsKey = "donguri.browserTabs"
    private static let currentTabKey = "donguri.currentBrowserTab"
    private static let rootTabKey = "donguri.rootTab"
    /// Tabs whose screens stay alive (scroll position and all) while
    /// another tab is showing. Older ones are rebuilt when switched back to.
    private static let liveTabLimit = 6

    var rootTab: RootTab {
        didSet { UserDefaults.standard.set(rootTab.rawValue, forKey: Self.rootTabKey) }
    }

    private(set) var tabs: [BrowserTab]
    private(set) var currentTabID: UUID
    /// Most recently shown first.
    private(set) var recentTabIDs: [UUID]

    /// The tab switcher sheet.
    var showsTabSwitcher = false
    /// A short message over everything, e.g. "opened in a new tab".
    private(set) var toast: String?
    /// The image scanner, presented over everything (see ContentView).
    var scanRequest: ScanRequest?
    /// The video player, over everything (see ContentView).
    var videoRequest: VideoItem?
    /// The player shrunk to the miniplayer above the tab bar; the video
    /// keeps playing.
    var videoMinimized = false
    /// A channel for the YouTube screen to show.
    var youTubeChannel: YouTubeChannelRequest?

    private init() {
        let defaults = UserDefaults.standard
        rootTab = defaults.string(forKey: Self.rootTabKey).flatMap(RootTab.init(rawValue:)) ?? .boards
        var restored: [BrowserTab] = []
        if let data = defaults.data(forKey: Self.tabsKey),
           let decoded = try? JSONDecoder().decode([BrowserTab].self, from: data) {
            restored = decoded
        }
        if restored.isEmpty { restored = [BrowserTab()] }
        tabs = restored
        let savedCurrent = defaults.string(forKey: Self.currentTabKey).flatMap(UUID.init(uuidString:))
        let current = restored.first { $0.id == savedCurrent }?.id ?? restored[0].id
        currentTabID = current
        recentTabIDs = [current]

        // Hidden tabs are the easiest memory to give back: they rebuild from
        // their saved path (and the thread cache) when switched to.
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                   object: nil,
                                                   queue: .main) { _ in
            MainActor.assumeIsolated {
                AppNavigator.shared.releaseHiddenTabs()
            }
        }
    }

    /// Keeps only the visible tab alive.
    func releaseHiddenTabs() {
        recentTabIDs = [currentTabID]
    }

    // MARK: Tabs

    var currentTab: BrowserTab? { tabs.first { $0.id == currentTabID } }

    /// The tabs to keep on screen (one visible, the rest hidden), in tab
    /// order so their views keep their identity as the order of use changes.
    var liveTabs: [BrowserTab] {
        let live = Set(recentTabIDs.prefix(Self.liveTabLimit))
        return tabs.filter { live.contains($0.id) }
    }

    func path(for id: UUID) -> [BrowseRoute] {
        tabs.first { $0.id == id }?.path ?? []
    }

    func setPath(_ path: [BrowseRoute], for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].path != path else { return }
        tabs[index].path = path
        persist()
    }

    func pathBinding(for id: UUID) -> Binding<[BrowseRoute]> {
        Binding(get: { self.path(for: id) },
                set: { self.setPath($0, for: id) })
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        currentTabID = id
        recentTabIDs.removeAll { $0 == id }
        recentTabIDs.insert(id, at: 0)
        persist()
    }

    /// Opens a tab with `path`. A background tab is created without leaving
    /// the current screen; otherwise the 板 tab comes forward showing it.
    @discardableResult
    func openTab(path: [BrowseRoute] = [], inBackground: Bool = false) -> UUID {
        let tab = BrowserTab(path: path)
        // New tabs go next to the current one, as in a browser.
        if let index = tabs.firstIndex(where: { $0.id == currentTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        if inBackground {
            persist()
            flash(String(localized: "新しいタブで開きました"))
            Haptics.play(.light)
        } else {
            select(tab.id)
            rootTab = .boards
        }
        return tab.id
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        recentTabIDs.removeAll { $0 == id }
        if tabs.isEmpty {
            let fresh = BrowserTab()
            tabs = [fresh]
            select(fresh.id)
        } else if id == currentTabID {
            // The most recently used tab, else the neighbour.
            let next = recentTabIDs.first { recent in tabs.contains { $0.id == recent } }
                ?? tabs[min(index, tabs.count - 1)].id
            select(next)
        }
        persist()
    }

    func closeOthers(than id: UUID) {
        tabs.removeAll { $0.id != id }
        recentTabIDs = [id]
        if tabs.isEmpty {
            let fresh = BrowserTab()
            tabs = [fresh]
        }
        select(tabs[0].id)
    }

    func closeAll() {
        let fresh = BrowserTab()
        tabs = [fresh]
        recentTabIDs = []
        select(fresh.id)
    }

    func moveTabs(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Opens a web page in the ブラウザ tab. YouTube videos open in the
    /// app's own player instead, unless `allowNativePlayer` is false.
    func openInBrowser(_ url: URL, allowNativePlayer: Bool = true) {
        if allowNativePlayer, let id = YouTubeClient.videoID(in: url) {
            playVideo(.youtube(id: id, title: nil))
            return
        }
        if !allowNativePlayer { BrowserModel.shared.allowWebPlayback(for: url) }
        UserDefaults.standard.set(BrowserMode.web.rawValue, forKey: BrowserMode.defaultsKey)
        BrowserModel.shared.load(url)
        rootTab = .browser
    }

    func playVideo(_ item: VideoItem) {
        videoMinimized = false
        videoRequest = item
    }

    func minimizeVideo() {
        guard videoRequest != nil else { return }
        videoMinimized = true
    }

    func expandVideo() {
        videoMinimized = false
    }

    func closeVideo() {
        videoRequest = nil
        videoMinimized = false
    }

    /// The YouTube screen, showing a channel's videos.
    func showYouTubeChannel(id: String, name: String) {
        // The video carries on in the miniplayer.
        minimizeVideo()
        UserDefaults.standard.set(BrowserMode.youtube.rawValue, forKey: BrowserMode.defaultsKey)
        rootTab = .browser
        youTubeChannel = YouTubeChannelRequest(id: id, name: name)
    }

    /// From a notification or anywhere outside the 板 tab: show the thread
    /// in its own tab (reusing one already showing it).
    func showThread(_ link: ThreadLink) {
        if let existing = tabs.first(where: {
            if case .thread(let open) = $0.path.last { return open.key == link.key }
            return false
        }) {
            select(existing.id)
            rootTab = .boards
            return
        }
        openTab(path: [.thread(link)])
    }

    // MARK: Toast

    func flash(_ message: String) {
        withAnimation(.snappy) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.snappy) {
                if toast == message { toast = nil }
            }
        }
    }

    // MARK: Persistence

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(tabs) {
            defaults.set(data, forKey: Self.tabsKey)
        }
        defaults.set(currentTabID.uuidString, forKey: Self.currentTabKey)
    }
}

// MARK: - Navigation actions

/// How a screen opens other screens. Each navigation stack has one: inside
/// a browser tab, `push` adds to that tab's stack (kept by AppNavigator); in
/// the 保存 and 履歴 tabs it adds to theirs. Screens read it from the
/// environment as an optional and fall back to `BrowseContext.detached`.
@Observable
final class BrowseContext {
    /// The browser tab this stack belongs to, nil outside the 板 tab.
    let tabID: UUID?
    /// The stack's path when it isn't a browser tab.
    var localPath: [BrowseRoute] = []
    /// The browser tab is the one on screen. Background tabs pause things
    /// like auto-refresh.
    var isActive = true

    /// For screens shown outside any stack (previews and the like).
    static let detached = BrowseContext(tabID: nil)

    init(tabID: UUID?) {
        self.tabID = tabID
    }

    var isBrowserTab: Bool { tabID != nil }

    var path: [BrowseRoute] {
        get {
            if let tabID { return AppNavigator.shared.path(for: tabID) }
            return localPath
        }
        set {
            if let tabID {
                AppNavigator.shared.setPath(newValue, for: tabID)
            } else {
                localPath = newValue
            }
        }
    }

    func push(_ route: BrowseRoute) {
        path.append(route)
    }

    /// Replaces the top screen, e.g. switching boards from the title.
    func replaceTop(_ route: BrowseRoute) {
        var current = path
        if current.isEmpty { current.append(route) } else { current[current.count - 1] = route }
        path = current
    }

    /// Opens `route` in a new tab, after the current screen's path so the
    /// way back is kept.
    func openInNewTab(_ route: BrowseRoute, inBackground: Bool) {
        var newPath = isBrowserTab ? path : []
        newPath.append(route)
        AppNavigator.shared.openTab(path: newPath, inBackground: inBackground)
    }
}

/// The screen for a route.
struct BrowseDestination: View {
    let route: BrowseRoute

    var body: some View {
        switch route {
        case .board(let board):
            BoardView(board: board.categoryContent)
        case .thread(let link):
            ThreadView(thread: link.thread, boardURL: link.boardURL, boardName: link.boardName)
        case .search(let query):
            ThreadSearchView(initialQuery: query)
        }
    }
}

extension View {
    /// Every navigation stack that shows boards or threads registers this.
    func browseDestinations() -> some View {
        navigationDestination(for: BrowseRoute.self) { route in
            BrowseDestination(route: route)
        }
    }
}

/// A navigation stack of routes outside the browser tabs (保存, 履歴).
struct RouteStack<Root: View>: View {
    @ViewBuilder var root: () -> Root
    @State private var context = BrowseContext(tabID: nil)

    var body: some View {
        @Bindable var context = context
        NavigationStack(path: $context.localPath) {
            root()
                .browseDestinations()
                .background(FullSwipeBack())
        }
        .environment(context)
    }
}

// MARK: - Scanning images

/// An image to read text from (a photo, a screenshot, a web page), shown
/// in the gallery with text recognition on.
struct ScanRequest: Identifiable {
    let id = UUID()
    let item: MediaItem
    let title: String?
}

extension AppNavigator {
    /// Shows `image` in the scanner over everything.
    func scan(_ image: UIImage, title: String? = nil) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        Task {
            guard let url = await MediaStore.shared.storeLocal(data) else { return }
            scanRequest = ScanRequest(item: MediaItem(url: url, postIndex: 0, kind: .image), title: title)
        }
    }
}

/// Where links tapped in posts and previews go: the ブラウザ tab, or
/// Safari if the user prefers.
enum ExternalLinks {
    static func open(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        if BehaviorSettings.shared.openLinksInApp, scheme == "http" || scheme == "https" {
            AppNavigator.shared.openInBrowser(url)
        } else {
            UIApplication.shared.open(url)
        }
    }
}

struct YouTubeChannelRequest: Equatable {
    let id: String
    let name: String
}

/// What the ブラウザ tab shows: YouTube or ordinary web pages.
enum BrowserMode: String {
    case youtube, web
    static let defaultsKey = "iroha.browser.mode"
}
