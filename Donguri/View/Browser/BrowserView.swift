//
//  BrowserView.swift
//  Donguri
//
//  The ブラウザ tab, after MaruReader's browser: an ordinary web browser
//  (logins stay, ads blocked) with a dictionary mode where tapping a word
//  looks it up, OCR for text in images, and on YouTube a subtitle bar and
//  a transcript to mine from.
//

import SwiftUI
import WebKit

struct BrowserView: View {
    @AppStorage(BrowserMode.defaultsKey) private var mode = BrowserMode.youtube.rawValue

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode.animation(.snappy(duration: 0.22))) {
                Text(verbatim: "YouTube").tag(BrowserMode.youtube.rawValue)
                Text(verbatim: "X").tag(BrowserMode.x.rawValue)
                Text("ウェブ").tag(BrowserMode.web.rawValue)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, mode == BrowserMode.youtube.rawValue ? 2 : 0)

            Group {
                switch BrowserMode(rawValue: mode) ?? .youtube {
                case .youtube:
                    YouTubeHomeView()
                case .x:
                    WebPane(model: BrowserModel.x)
                        .id("x")
                case .web:
                    WebPane(model: BrowserModel.shared)
                        .id("web")
                }
            }
            .transition(.opacity)
        }
        .themedScreen()
    }
}

/// A web view with the browser's tools: the address bar, dictionary mode,
/// reading text in the page, bookmarks. The ウェブ tab and X each have one.
private struct WebPane: View {
    @Bindable var model: BrowserModel
    @State private var behavior = BehaviorSettings.shared
    @State private var japaneseOnly = XScripts.japaneseOnly
    @State private var shareHost = XScripts.shareHost
    @State private var searchingX = false
    @State private var xQuery = ""
    @Environment(UserConfig.self) private var userConfig
    @FocusState private var addressFocused: Bool
    @State private var showsTranscript = false
    @State private var showsBookmarks = false
    @State private var bookmarks = BookmarkStore.shared
    @State private var scanning = false
    @AppStorage(BrowserMode.defaultsKey) private var mode = BrowserMode.youtube.rawValue
    /// From the bottom of the page to the bottom of the window: the
    /// toolbar, the tab bar and the home indicator. Popups stay above it.
    @State private var bottomChrome: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // X is kept plain: no address bar, just the load progress.
            if model.site == .x {
                progressLine
            } else {
                addressBar
            }

            ZStack {
                BrowserWebView(webView: model.webView)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .global).maxY
                    } action: { pageBottom in
                        let window = UIApplication.shared.connectedScenes
                            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.height }.first ?? pageBottom
                        bottomChrome = max(0, window - pageBottom)
                    }
                    .opacity(model.showsStartPage ? 0 : 1)
                if model.showsStartPage {
                    if model.site == .x {
                        // X's timeline is on its way.
                        ProgressView()
                    } else {
                        BrowserStartPage(open: open)
                    }
                }
            }

            if model.isWatchPage, model.showsCaptionBar {
                CaptionBar(model: model)
            }

            toolbar
        }
        .overlay {
            PopupStackLayer(stack: model.popups, bottomInset: bottomChrome)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Label(toast, systemImage: "link")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .padding(.bottom, bottomChrome + 16)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.toast)
        .sheet(isPresented: $showsTranscript) {
            TranscriptView(model: model)
        }
        .background {
            // On its own view: two presentations on one view fight.
            Color.clear.sheet(isPresented: $showsBookmarks) {
                BookmarksView { url in
                    showsBookmarks = false
                    open(url)
                }
            }
        }
        .onAppear {
            model.userConfig = userConfig
            model.startIfNeeded()
        }
    }

    /// A start-page site or a bookmark. YouTube's home goes to the YouTube
    /// tab; anything else loads here.
    private func open(_ url: URL) {
        addressFocused = false
        if url.host?.contains("youtube.com") == true, url.path.count <= 1 {
            mode = BrowserMode.youtube.rawValue
        } else {
            model.load(url)
        }
    }

    // MARK: Address bar

    private var addressBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: model.url?.scheme == "https" ? "lock.fill" : "globe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("検索またはURL", text: $model.addressText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.webSearch)
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit {
                            model.go(model.addressText)
                        }
                        .onChange(of: addressFocused) { _, focused in
                            model.isEditingAddress = focused
                        }
                    if addressFocused, !model.addressText.isEmpty {
                        Button {
                            model.addressText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    } else if !addressFocused, let url = model.url, !model.showsStartPage {
                        let saved = bookmarks.contains(url)
                        Button {
                            bookmarks.toggle(url: url, title: model.title)
                            Haptics.play(saved ? .light : .success)
                        } label: {
                            Image(systemName: saved ? "star.fill" : "star")
                                .foregroundStyle(saved ? Color.yellow : Color.secondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(saved ? Text("ブックマークから削除") : Text("ブックマークに追加"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if addressFocused {
                    Button("キャンセル") {
                        addressFocused = false
                    }
                } else {
                    Button {
                        if model.isLoading { model.webView.stopLoading() } else { model.webView.reload() }
                    } label: {
                        Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                    }
                    .disabled(model.showsStartPage)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Load progress
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * model.progress)
                    .opacity(model.isLoading ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: model.progress)
            }
            .frame(height: 2)
        }
        .background(.bar)
    }

    // MARK: Toolbar

    private var progressLine: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geometry.size.width * model.progress)
                .opacity(model.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: model.progress)
        }
        .frame(height: 2)
    }

    /// X's own bottom bar is hidden; its home and search are here instead.
    private var xButtons: some View {
        Group {
            Button {
                model.xHome()
                Haptics.play(.selection)
            } label: {
                Image(systemName: "house")
            }
            .accessibilityLabel(Text("ホーム"))
            Spacer()
            Button {
                xQuery = ""
                searchingX = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel(Text("検索"))
            .alert("Xで検索", isPresented: $searchingX) {
                TextField("キーワード", text: $xQuery)
                Button("キャンセル", role: .cancel) {}
                Button("検索") { model.xSearch(xQuery) }
            } message: {
                if japaneseOnly {
                    Text("日本語の投稿だけを探します")
                }
            }
            Spacer()
            // The account's own lists; X's own way there is hidden.
            Menu {
                Button {
                    model.xHomeFeed(following: false)
                } label: {
                    Label("おすすめ", systemImage: "sparkles")
                }
                Button {
                    model.xHomeFeed(following: true)
                } label: {
                    Label("フォロー中の投稿", systemImage: "person.2.wave.2")
                }
                Section {
                    Button {
                        model.xOpen(.following)
                    } label: {
                        Label("フォロー中のアカウント", systemImage: "person.2")
                    }
                    Button {
                        model.xOpen(.followers)
                    } label: {
                        Label("フォロワー", systemImage: "person.3")
                    }
                    Button {
                        model.xOpen(.likes)
                    } label: {
                        Label("いいねした投稿", systemImage: "heart")
                    }
                    Button {
                        model.xOpen(.profile)
                    } label: {
                        Label("プロフィール", systemImage: "person.crop.circle")
                    }
                }
            } label: {
                Image(systemName: "person.crop.circle")
            }
            .accessibilityLabel(Text("アカウント"))
            Spacer()
        }
    }

    private var toolbar: some View {
        HStack {
            Button {
                model.webView.goBack()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!model.canGoBack)
            Spacer()
            if model.site == .x {
                xButtons
            } else {
                Button {
                    model.webView.goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!model.canGoForward)
                Spacer()
            }
            // Dictionary mode: taps look words up instead of following links.
            Button {
                model.lookupMode.toggle()
                Haptics.play(.selection)
            } label: {
                Image(systemName: model.lookupMode ? "character.book.closed.fill.ja" : "character.book.closed.ja")
                    .foregroundStyle(model.lookupMode ? Color.white : Color.accentColor)
                    .padding(6)
                    .background(Circle().fill(model.lookupMode ? Color.accentColor : Color.clear))
            }
            .accessibilityLabel(Text("辞書モード"))
            Spacer()
            Button {
                Task { await scanPage() }
            } label: {
                if scanning {
                    ProgressView()
                } else {
                    Image(systemName: "text.viewfinder")
                }
            }
            .disabled(model.showsStartPage || scanning)
            .accessibilityLabel(Text("画面の文字を読み取る"))
            Spacer()
            if model.isWatchPage {
                Button {
                    model.playCurrentVideoInApp()
                } label: {
                    Image(systemName: "play.rectangle.on.rectangle")
                }
                .accessibilityLabel(Text("アプリのプレーヤーで再生"))
                Spacer()
                Button {
                    showsTranscript = true
                } label: {
                    Image(systemName: "captions.bubble")
                }
                .accessibilityLabel(Text("字幕"))
                Spacer()
            }
            menu
        }
        .font(.title3)
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var menu: some View {
        Menu {
            if let url = model.url, !model.showsStartPage {
                ShareLink(item: url) {
                    Label("共有", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.url = url
                } label: {
                    Label("リンクをコピー", systemImage: "link")
                }
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label("Safariで開く", systemImage: "safari")
                }
                Divider()
            }
            if model.isWatchPage {
                Toggle(isOn: $model.showsCaptionBar) {
                    Label("字幕バーを表示", systemImage: "captions.bubble")
                }
            }
            if model.site == .x {
                Toggle(isOn: Binding(get: { japaneseOnly },
                                     set: { japaneseOnly = $0; model.setJapaneseOnly($0) })) {
                    Label("日本語の投稿だけ表示", systemImage: "character.ja")
                }
                Picker(selection: Binding(get: { shareHost }, set: { shareHost = $0; XScripts.shareHost = $0 })) {
                    ForEach(XScripts.shareHosts, id: \.self) { host in
                        Text(verbatim: host).tag(host)
                    }
                } label: {
                    Label("コピーするリンク", systemImage: "link")
                }
                .pickerStyle(.menu)
            }
            Toggle(isOn: Binding(get: { behavior.contentBlocking },
                                 set: { model.setBlocking($0) })) {
                Label("広告をブロック", systemImage: "hand.raised")
            }
            Divider()
            Button {
                showsBookmarks = true
            } label: {
                Label("ブックマーク", systemImage: "book")
            }
            Button {
                model.goHome()
            } label: {
                if model.site == .x {
                    Label("ホーム", systemImage: "house")
                } else {
                    Label("スタートページ", systemImage: "house")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    /// Reads the text on screen: the page as an image, into the scanner.
    private func scanPage() async {
        scanning = true
        defer { scanning = false }
        model.popups.closeAll()
        if let image = await model.snapshot() {
            AppNavigator.shared.scan(image, title: model.title)
        }
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Where the browser starts: sites worth reading or watching.
private struct BrowserStartPage: View {
    var open: (URL) -> Void
    @State private var store = BookmarkStore.shared

    private struct Site: Identifiable {
        let name: String
        let url: String
        let symbol: String
        let color: Color
        var id: String { url }
    }

    private let sites = [
        Site(name: "YouTube", url: "https://m.youtube.com/", symbol: "play.rectangle.fill", color: .red),
        Site(name: "Google", url: "https://www.google.co.jp/", symbol: "magnifyingglass", color: .blue),
        Site(name: "Yahoo!ニュース", url: "https://news.yahoo.co.jp/", symbol: "newspaper.fill", color: .purple),
        Site(name: "NHK", url: "https://www3.nhk.or.jp/news/", symbol: "tv.fill", color: .gray),
        Site(name: "NEWS WEB EASY", url: "https://www3.nhk.or.jp/news/easy/", symbol: "textformat.size", color: .orange),
        Site(name: "Wikipedia", url: "https://ja.wikipedia.org/", symbol: "book.closed.fill", color: .brown),
        Site(name: "ニコニコ動画", url: "https://sp.nicovideo.jp/", symbol: "play.tv.fill", color: .pink),
        Site(name: "pixiv", url: "https://www.pixiv.net/", symbol: "paintpalette.fill", color: .cyan),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("ブラウザ")
                    .font(.largeTitle.weight(.bold))
                    .padding(.top, 24)
                if !store.bookmarks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ブックマーク")
                            .font(.headline)
                        ForEach(store.bookmarks.prefix(8)) { bookmark in
                            Button {
                                if let url = URL(string: bookmark.url) { open(url) }
                            } label: {
                                BookmarkRow(bookmark: bookmark)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    withAnimation { store.remove(bookmark) }
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 14)], spacing: 18) {
                    ForEach(sites) { site in
                        Button {
                            if let url = URL(string: site.url) { open(url) }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: site.symbol)
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .frame(width: 56, height: 56)
                                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(site.color.gradient))
                                Text(verbatim: site.name)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("下の辞書ボタンで辞書モードに。ページの語をタップすると調べられます。", systemImage: "character.book.closed.ja")
                    Label("文字読み取りボタンで、画像の中の文字も調べられます。", systemImage: "text.viewfinder")
                    Label("YouTubeでは字幕(CC)をオンにすると、字幕をタップして調べたり、Ankiに追加したりできます。", systemImage: "captions.bubble")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
        }
    }
}

/// A bookmark: a letter badge for the site, the title and the address.
private struct BookmarkRow: View {
    let bookmark: Bookmark

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: String(bookmark.host.prefix(1)).uppercased())
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: bookmark.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(verbatim: bookmark.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// The same colour for a site every time.
    private var color: Color {
        let palette: [Color] = [.red, .orange, .green, .teal, .blue, .indigo, .purple, .pink, .brown]
        let sum = bookmark.host.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }
}

/// Every bookmark: tap to open, swipe to delete, drag to reorder.
private struct BookmarksView: View {
    var open: (URL) -> Void
    @State private var store = BookmarkStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Bookmark?
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.bookmarks.isEmpty {
                    ContentUnavailableView("ブックマークはありません",
                                           systemImage: "star",
                                           description: Text("ページを開いて、アドレスバーの☆をタップすると追加できます。"))
                } else {
                    List {
                        ForEach(store.bookmarks) { bookmark in
                            Button {
                                if let url = URL(string: bookmark.url) { open(url) }
                            } label: {
                                BookmarkRow(bookmark: bookmark)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    newTitle = bookmark.title
                                    renaming = bookmark
                                } label: {
                                    Label("名前を変更", systemImage: "pencil")
                                }
                                Button {
                                    UIPasteboard.general.string = bookmark.url
                                } label: {
                                    Label("リンクをコピー", systemImage: "link")
                                }
                                Button(role: .destructive) {
                                    withAnimation { store.remove(bookmark) }
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { store.remove(atOffsets: $0) }
                        .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(Text("ブックマーク"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.bookmarks.isEmpty { EditButton() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .alert("名前を変更", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("名前", text: $newTitle)
                Button("キャンセル", role: .cancel) { renaming = nil }
                Button("保存") {
                    if let renaming { store.rename(renaming, to: newTitle) }
                    renaming = nil
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The subtitle on screen, tappable for lookups.
private struct CaptionBar: View {
    let model: BrowserModel
    @Environment(UserConfig.self) private var userConfig
    @State private var appearance = AppearanceSettings.shared

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let caption = model.currentCaption {
                PostTextView(text: caption.text,
                             scanNonJapaneseText: userConfig.scanNonJapaneseText,
                             style: appearance.postStyle,
                             onTextSelected: { selection in
                                 model.prepareCaptionLookup(into: model.popups)
                                 return model.popups.replace(with: selection, userConfig: userConfig)
                             },
                             onTapOutside: { model.popups.closeAll() },
                             onPostReply: { _ in },
                             onThreadRoute: { _ in })
                    .id(caption.id)
            } else {
                Text("字幕(CC)をオンにすると、ここに字幕が出ます")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Every subtitle line: the whole track when YouTube gives it, otherwise
/// the lines seen so far. Tap the time to jump there, a word to look it up.
private struct TranscriptView: View {
    let model: BrowserModel
    @Environment(UserConfig.self) private var userConfig
    @Environment(\.dismiss) private var dismiss
    @State private var appearance = AppearanceSettings.shared
    @State private var popups = PopupStack()
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if !model.transcriptIsFull {
                        Section {
                            Button {
                                Task { await loadFull() }
                            } label: {
                                HStack {
                                    Label("字幕をすべて読み込む", systemImage: "text.badge.plus")
                                    if loading {
                                        Spacer()
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(loading)
                        } footer: {
                            if failed {
                                Text("この動画の字幕は一度に読み込めませんでした。字幕(CC)をオンにして再生すると、表示された字幕がここに記録されます。")
                            } else {
                                Text("今は再生中に表示された字幕だけが並んでいます。")
                            }
                        }
                    }
                    if model.captions.isEmpty {
                        Text("まだ字幕がありません")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.captions) { line in
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                model.seek(to: line.time)
                                Haptics.play(.selection)
                            } label: {
                                Text(verbatim: line.timeLabel)
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 46, alignment: .leading)
                            }
                            .buttonStyle(.borderless)
                            PostTextView(text: line.text,
                                         scanNonJapaneseText: userConfig.scanNonJapaneseText,
                                         style: appearance.postStyle,
                                         onTextSelected: { selection in
                                             model.prepareCaptionLookup(into: popups)
                                             return popups.replace(with: selection, userConfig: userConfig)
                                         },
                                         onTapOutside: { popups.closeAll() },
                                         onPostReply: { _ in },
                                         onThreadRoute: { _ in })
                        }
                        .id(line.id)
                        .listRowBackground(line.id == model.currentCaption?.id ? Color.accentColor.opacity(0.1) : nil)
                    }
                }
                .listStyle(.plain)
                .onAppear {
                    if let current = model.currentCaption?.id {
                        proxy.scrollTo(current, anchor: .center)
                    }
                }
            }
            .overlay {
                PopupStackLayer(stack: popups)
            }
            .navigationTitle(Text("字幕"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("閉じる"))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private func loadFull() async {
        loading = true
        failed = !(await model.fetchTranscript())
        loading = false
    }
}
