//
//  YouTubeHomeView.swift
//  Donguri
//
//  YouTube, natively: the home feed, subscriptions, history and 後で見る of
//  the signed-in account, search, and channels. Videos open in いろは's
//  player, where their subtitles can be mined. Videos on the phone (Files)
//  open there too.
//

import SwiftUI
import WebKit
import UniformTypeIdentifiers

@Observable
final class YouTubeFeedModel {
    /// Kept for the app's lifetime, so switching to ウェブ and back keeps
    /// the feed and scroll position.
    static let shared = YouTubeFeedModel()
    enum Source: Hashable {
        case feed(YouTubeClient.Feed)
        case search(String)
        case channel(id: String, name: String)
    }

    var source: Source = .feed(.home)
    private(set) var videos: [YTVideo] = []
    private(set) var continuation: String?
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var error: String?
    private(set) var signedIn = false
    private(set) var checkedSignIn = false

    /// Each tab's last page, so switching between ホーム, 登録チャンネル and
    /// the rest is instant; one older than this is fetched again.
    private struct Page {
        var videos: [YTVideo]
        var continuation: String?
        var loadedAt: Date
    }
    @ObservationIgnored private var pages: [Source: Page] = [:]
    private static let freshFor: TimeInterval = 5 * 60

    /// After signing in or switching accounts: every tab belongs to someone
    /// else now.
    func reload() async {
        pages.removeAll()
        await load(source)
    }

    func checkSignIn() async {
        signedIn = await YouTubeClient.shared.refreshSignInState()
        checkedSignIn = true
    }

    func load(_ source: Source) async {
        let switching = self.source != source
        self.source = source
        if switching {
            if let page = pages[source] {
                videos = page.videos
                continuation = page.continuation
                error = nil
                if Date.now.timeIntervalSince(page.loadedAt) < Self.freshFor { return }
            } else {
                // A spinner, not the previous tab's videos, until it loads.
                videos = []
                continuation = nil
            }
        }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let page: YTFeedPage
            switch source {
            case .feed(let feed): page = try await YouTubeClient.shared.feed(feed)
            case .search(let query): page = try await YouTubeClient.shared.search(query)
            case .channel(let id, _): page = try await YouTubeClient.shared.channel(id)
            }
            guard self.source == source else { return }
            videos = page.videos
            continuation = page.continuation
            pages[source] = Page(videos: page.videos, continuation: page.continuation, loadedAt: .now)
            if page.videos.isEmpty {
                error = signedIn || !Self.needsAccount(source)
                    ? String(localized: "動画が見つかりませんでした")
                    : String(localized: "ログインすると表示されます")
            }
        } catch {
            guard self.source == source else { return }
            videos = []
            self.error = String(localized: "読み込めませんでした")
        }
    }

    func loadMore() async {
        guard let token = continuation, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let isSearch: Bool
        if case .search = source { isSearch = true } else { isSearch = false }
        let current = source
        guard let page = try? await YouTubeClient.shared.more(token, isSearch: isSearch), source == current else { return }
        let known = Set(videos.map(\.id))
        videos += page.videos.filter { !known.contains($0.id) }
        continuation = page.continuation
        pages[current]?.videos = videos
        pages[current]?.continuation = continuation
    }

    static func needsAccount(_ source: Source) -> Bool {
        if case .feed(let feed) = source { return feed != .home }
        return false
    }
}

struct YouTubeHomeView: View {
    @State private var model = YouTubeFeedModel.shared
    @State private var navigator = AppNavigator.shared
    @State private var query = ""
    @State private var showsSignIn = false
    @State private var showsAccounts = false
    @State private var importingVideo = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                // Each presentation on its own view: two on one view fight.
                .sheet(isPresented: $showsSignIn, onDismiss: {
                    YouTubeClient.shared.reset()
                    Task {
                        await model.checkSignIn()
                        await model.reload()
                    }
                }) {
                    YouTubeSignInView()
                }
            chips
                .sheet(isPresented: $showsAccounts) {
                    YouTubeAccountsView(onAddAccount: {
                        showsAccounts = false
                        Task {
                            try? await Task.sleep(for: .milliseconds(500))
                            showsSignIn = true
                        }
                    }, onChange: {
                        Task { await model.reload() }
                    })
                }
            Divider()
            content
        }
        .task {
            if let channel = navigator.youTubeChannel {
                navigator.youTubeChannel = nil
                if !model.checkedSignIn { await model.checkSignIn() }
                await model.load(.channel(id: channel.id, name: channel.name))
            } else if !model.checkedSignIn {
                await model.checkSignIn()
                await model.load(model.source)
            }
        }
        .onChange(of: navigator.youTubeChannel) { _, channel in
            guard let channel else { return }
            navigator.youTubeChannel = nil
            Task { await model.load(.channel(id: channel.id, name: channel.name)) }
        }
        .fileImporter(isPresented: $importingVideo, allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                AppNavigator.shared.playVideo(.file(url))
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("YouTubeを検索", text: $query)
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit {
                        let trimmed = query.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        if let url = URL(string: trimmed), let id = YouTubeClient.videoID(in: url) {
                            AppNavigator.shared.playVideo(.youtube(id: id, title: nil))
                            return
                        }
                        Task { await model.load(.search(trimmed)) }
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Menu {
                Button {
                    importingVideo = true
                } label: {
                    Label("ファイルの動画を開く", systemImage: "folder")
                }
                if model.signedIn {
                    Button {
                        showsAccounts = true
                    } label: {
                        Label("アカウントを切り替え", systemImage: "person.2.circle")
                    }
                    Button {
                        showsSignIn = true
                    } label: {
                        Label("アカウントを追加", systemImage: "person.crop.circle.badge.plus")
                    }
                } else {
                    Button {
                        showsSignIn = true
                    } label: {
                        Label("ログイン", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            } label: {
                Image(systemName: model.signedIn ? "person.crop.circle.fill" : "person.crop.circle")
                    .font(.title2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(String(localized: "ホーム"), source: .feed(.home))
                chip(String(localized: "登録チャンネル"), source: .feed(.subscriptions))
                chip(String(localized: "履歴"), source: .feed(.history))
                chip(String(localized: "後で見る"), source: .feed(.watchLater))
                if case .search(let text) = model.source {
                    chipLabel(text, systemImage: "magnifyingglass", selected: true)
                }
                if case .channel(_, let name) = model.source {
                    chipLabel(name, systemImage: "person.crop.square", selected: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func chip(_ title: String, source: YouTubeFeedModel.Source) -> some View {
        Button {
            searchFocused = false
            Task { await model.load(source) }
        } label: {
            chipLabel(title, systemImage: nil, selected: model.source == source)
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(_ title: String, systemImage: String?, selected: Bool) -> some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(verbatim: title).lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(selected ? Color(.systemBackground) : Color.primary)
        .background(Capsule().fill(selected ? Color.primary : Color.secondary.opacity(0.15)))
    }

    @ViewBuilder
    private var content: some View {
        if model.loading, model.videos.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.videos.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "play.rectangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                if let error = model.error {
                    Text(error)
                        .foregroundStyle(.secondary)
                }
                if !model.signedIn {
                    Text("YouTubeにログインすると、ホームや登録チャンネル、履歴がここに並びます。検索はログインしなくても使えます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("ログイン") { showsSignIn = true }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("再読み込み") { Task { await model.load(model.source) } }
                        .buttonStyle(.bordered)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
            List {
                ForEach(model.videos) { video in
                    Button {
                        searchFocused = false
                        AppNavigator.shared.playVideo(.youtube(id: video.id, title: video.title))
                    } label: {
                        YouTubeVideoRow(video: video, compact: false)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 10, trailing: 12))
                    .contextMenu {
                        if let channelID = video.channelID, let name = video.channel {
                            Button {
                                Task { await model.load(.channel(id: channelID, name: name)) }
                            } label: {
                                Label("チャンネルを見る", systemImage: "person.crop.square")
                            }
                        }
                        if model.signedIn {
                            Button {
                                Task {
                                    if (try? await YouTubeClient.shared.setWatchLater(true, videoID: video.id)) != nil {
                                        Haptics.play(.success)
                                    } else {
                                        Haptics.play(.warning)
                                    }
                                }
                            } label: {
                                Label("後で見るに追加", systemImage: "clock")
                            }
                        }
                        Button {
                            AppNavigator.shared.openInBrowser(video.watchURL, allowNativePlayer: false)
                        } label: {
                            Label("ブラウザで開く", systemImage: "safari")
                        }
                    }
                    .onAppear {
                        // A few rows early, so the next page is usually
                        // there before the end is reached.
                        if model.videos.suffix(5).contains(where: { $0.id == video.id }) {
                            Task { await model.loadMore() }
                        }
                    }
                }
                if model.loadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await model.load(model.source) }
            .onChange(of: model.source) {
                // A different tab starts at its top.
                if let first = model.videos.first?.id { proxy.scrollTo(first, anchor: .top) }
            }
            }
        }
    }
}

/// A video in a feed: big thumbnail (or a small one beside the text).
struct YouTubeVideoRow: View {
    let video: YTVideo
    var compact: Bool

    var body: some View {
        if compact {
            HStack(alignment: .top, spacing: 10) {
                thumbnail
                    .frame(width: 150)
                details
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                thumbnail
                details
            }
        }
    }

    private var thumbnail: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let url = video.thumbnail {
                    // Decoded for the size shown: the narrow rows beside a
                    // video need far fewer pixels than the feed's.
                    VideoThumbnail(url: url, maxPixelSize: compact ? 360 : 720)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let duration = video.duration {
                    Text(verbatim: duration)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.75)))
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: video.title)
                .font(compact ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(.primary)
            let byline = [video.channel, video.meta].compactMap { $0 }.joined(separator: " · ")
            if !byline.isEmpty {
                Text(verbatim: byline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A thumbnail through the app's image cache, decoded at a size that
/// stays sharp across the screen.
private struct VideoThumbnail: View {
    let url: URL
    let maxPixelSize: CGFloat
    @State private var image: UIImage?

    init(url: URL, maxPixelSize: CGFloat = 720) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        _image = State(initialValue: MediaStore.shared.memoryImage(for: url, maxPixelSize: maxPixelSize))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            guard image == nil else { return }
            let loaded = await MediaStore.shared.image(for: url, maxPixelSize: maxPixelSize)
            // Cached ones are there from the start; a downloaded one fades in.
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

/// Google's sign-in page, in a web view sharing the browser's cookies,
/// so signing in here signs in everywhere in the app.
struct YouTubeSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var signedIn = false

    /// YouTube's own mobile sign-in link: Google's sign-in, then back
    /// through youtube.com/signin, which is what sets YouTube's cookies.
    /// Google's account chooser (every signed-in account, plus "use
    /// another account"), then back through youtube.com/signin, which is
    /// what sets YouTube's cookies.
    private static let signInURL = URL(string: "https://accounts.google.com/AccountChooser?service=youtube&hl=ja&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Dm%26hl%3Dja%26next%3Dhttps%253A%252F%252Fm.youtube.com%252F")!

    var body: some View {
        NavigationStack {
            SignInWebView(url: Self.signInURL) {
                signedIn = true
                // A moment to see it worked.
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    dismiss()
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(Text("YouTubeにログイン"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if signedIn {
                    Label("ログインしました", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 40)
                }
            }
        }
    }
}

private struct SignInWebView: UIViewRepresentable {
    let url: URL
    let onSignedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Google refuses sign-in from browsers it doesn't recognise.
        webView.customUserAgent = SafariUserAgent.mobile
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onSignedIn: () -> Void
        private var reported = false

        init(onSignedIn: @escaping () -> Void) {
            self.onSignedIn = onSignedIn
        }

        /// Back on YouTube with its session cookies: done.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !reported, let host = webView.url?.host, host.hasSuffix("youtube.com") else { return }
            Task {
                let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                let signedIn = cookies.contains { $0.domain.hasSuffix("youtube.com") && ["SAPISID", "__Secure-3PAPISID", "LOGIN_INFO"].contains($0.name) }
                if signedIn, !reported {
                    reported = true
                    onSignedIn()
                }
            }
        }

        // Google opens some steps in a new window; keep them here.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}

/// The accounts and channels signed in to this session, to choose which
/// one the YouTube screen and player use.
struct YouTubeAccountsView: View {
    var onAddAccount: () -> Void
    var onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [YouTubeAccount] = []
    @State private var loading = true
    @State private var failed = false
    @State private var selectedID = YouTubeAccount.current?.id
    @State private var switching: String?

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if failed || accounts.isEmpty {
                    Text("アカウントを読み込めませんでした")
                        .foregroundStyle(.secondary)
                }
                let groups = Dictionary(grouping: accounts, by: { $0.email ?? "" })
                ForEach(groups.keys.sorted(), id: \.self) { email in
                    Section {
                        ForEach(groups[email] ?? []) { account in
                            Button {
                                Task {
                                    switching = account.id
                                    await YouTubeClient.shared.select(account)
                                    switching = nil
                                    selectedID = account.id
                                    Haptics.play(.success)
                                    onChange()
                                    dismiss()
                                }
                            } label: {
                                row(account)
                            }
                            .buttonStyle(.plain)
                            .disabled(switching != nil)
                        }
                    } header: {
                        if !email.isEmpty { Text(verbatim: email) }
                    }
                }
                Section {
                    // YouTube's own switcher, for anything the list above
                    // can't do. Whatever is chosen there applies here too.
                    NavigationLink {
                        YouTubePageView(url: URL(string: "https://m.youtube.com/channel_switcher")!)
                            .navigationTitle(Text("YouTubeで切り替える"))
                            .navigationBarTitleDisplayMode(.inline)
                            .onDisappear {
                                // YouTube's switcher sets the identity in the
                                // cookies; drop the app's own choice so it doesn't
                                // pull the other way.
                                YouTubeAccount.current = nil
                                YouTubeClient.shared.reset()
                                onChange()
                            }
                    } label: {
                        Label("YouTubeで切り替える", systemImage: "arrow.left.arrow.right.circle")
                    }
                    Button {
                        onAddAccount()
                    } label: {
                        Label("アカウントを追加", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
            .navigationTitle(Text("アカウント"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ account: YouTubeAccount) -> some View {
        HStack(spacing: 12) {
            Group {
                if let photo = account.photo {
                    RemoteThumbnail(url: photo)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: account.name)
                    .font(.body.weight(.semibold))
                if let byline = account.byline {
                    Text(verbatim: byline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if switching == account.id {
                ProgressView()
            } else if isChosen(account) {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private func isChosen(_ account: YouTubeAccount) -> Bool {
        if let selectedID { return selectedID == account.id }
        return account.isSelected
    }

    private func load() async {
        loading = true
        do {
            accounts = try await YouTubeClient.shared.accounts()
            failed = false
        } catch {
            failed = true
        }
        loading = false
    }
}

/// A YouTube page in a web view sharing the app's cookies.
struct YouTubePageView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = SafariUserAgent.mobile
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
