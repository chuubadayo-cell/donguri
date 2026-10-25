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
    @State private var model = BrowserModel.shared
    @State private var behavior = BehaviorSettings.shared
    @Environment(UserConfig.self) private var userConfig
    @FocusState private var addressFocused: Bool
    @State private var showsTranscript = false
    @State private var scanning = false

    var body: some View {
        VStack(spacing: 0) {
            addressBar

            ZStack {
                BrowserWebView(webView: model.webView)
                    .opacity(model.showsStartPage ? 0 : 1)
                if model.showsStartPage {
                    BrowserStartPage { url in
                        addressFocused = false
                        model.load(url)
                    }
                }
            }

            if model.isWatchPage, model.showsCaptionBar {
                CaptionBar(model: model)
            }

            toolbar
        }
        .overlay {
            PopupStackLayer(stack: model.popups)
        }
        .sheet(isPresented: $showsTranscript) {
            TranscriptView(model: model)
        }
        .onAppear {
            model.userConfig = userConfig
            model.startIfNeeded()
        }
        .themedScreen()
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
                    if addressFocused, !model.addressText.isEmpty {
                        Button {
                            model.addressText = ""
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

                if addressFocused {
                    Button("キャンセル") {
                        addressFocused = false
                        model.addressText = model.url?.absoluteString ?? ""
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

    private var toolbar: some View {
        HStack {
            Button {
                model.webView.goBack()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!model.canGoBack)
            Spacer()
            Button {
                model.webView.goForward()
            } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!model.canGoForward)
            Spacer()
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
            Toggle(isOn: Binding(get: { behavior.contentBlocking },
                                 set: { model.setBlocking($0) })) {
                Label("広告をブロック", systemImage: "hand.raised")
            }
            Divider()
            Button {
                model.goHome()
            } label: {
                Label("スタートページ", systemImage: "house")
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
