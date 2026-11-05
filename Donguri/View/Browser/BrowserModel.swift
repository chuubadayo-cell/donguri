//
//  BrowserModel.swift
//  Donguri
//
//  The ブラウザ tab's single web view and everything it knows: where it
//  is, tap-to-look-up, the ad blocker, and YouTube subtitles for mining.
//  Logins stay (the default website data store keeps cookies), so signing
//  in to YouTube once is enough.
//

import SwiftUI
import WebKit

struct CaptionLine: Identifiable, Hashable {
    let id = UUID()
    let time: Double
    let text: String

    var timeLabel: String {
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

@Observable
final class BrowserModel: NSObject {
    static let shared = BrowserModel(site: .web)
    /// X (Twitter), in its own web view with the same tools.
    static let x = BrowserModel(site: .x)

    enum Site { case web, x }
    let site: Site

    private var lastURLKey: String { site == .x ? "iroha.x.lastURL" : "donguri.browser.lastURL" }
    private static let blockerID = "iroha-blocker-v2"

    let webView: WKWebView

    // Navigation state, mirrored from the web view.
    private(set) var title = ""
    private(set) var url: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    var addressText = ""
    /// While the address bar is being typed in, page changes don't
    /// overwrite it.
    @ObservationIgnored var isEditingAddress = false {
        didSet {
            // Editing shows the full address; otherwise just the site.
            if isEditingAddress != oldValue { addressText = isEditingAddress ? (url?.absoluteString ?? "") : displayAddress }
        }
    }

    /// What the address bar shows when not being edited: the site, as
    /// Safari does.
    var displayAddress: String {
        guard let url else { return "" }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Taps look words up instead of following links.
    var lookupMode = false {
        didSet { applyLookupMode() }
    }

    let popups = PopupStack()
    @ObservationIgnored var userConfig: UserConfig?

    // YouTube subtitles
    private(set) var currentCaption: CaptionLine?
    /// Subtitles seen while watching, newest last, or the whole track.
    private(set) var captions: [CaptionLine] = []
    private(set) var transcriptIsFull = false
    var showsCaptionBar = true

    var isYouTube: Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    var isWatchPage: Bool {
        isYouTube && (url?.path.hasPrefix("/watch") == true || url?.path.hasPrefix("/shorts") == true)
    }

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var blocker: WKContentRuleList?
    @ObservationIgnored private var started = false

    init(site: Site) {
        self.site = site
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true

        let controller = configuration.userContentController
        if let selectionJS = Bundle.main.url(forResource: "selection", withExtension: "js")
            .flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) {
            let settings = "window.scanNonJapaneseText = false; window.scanLength = 16;\n"
            controller.addUserScript(WKUserScript(source: settings + selectionJS,
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true,
                                                  in: BrowserScripts.world))
        }
        controller.addUserScript(WKUserScript(source: BrowserScripts.glue,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true,
                                              in: BrowserScripts.world))
        // YouTube's ads come from youtube.com itself, out of the content
        // blocker's reach; these deal with them on the page.
        if BehaviorSettings.shared.contentBlocking {
            YouTubeAdScripts.install(in: controller, world: BrowserScripts.world)
        }
        if site == .x {
            controller.addUserScript(WKUserScript(source: XScripts.source,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true,
                                                  in: BrowserScripts.world))
        }

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        // Safari's own user agent: Google won't let embedded browsers sign
        // in, and pages serve their normal mobile layout.
        webView.customUserAgent = SafariUserAgent.mobile
        super.init()

        let bridge = BrowserBridge(model: self)
        for name in ["tapOutside", "scrolled", "caption", "irohaShare"] {
            controller.add(bridge, contentWorld: BrowserScripts.world, name: name)
        }
        // Answered, so the page can highlight the word the moment the
        // lookup is done.
        controller.addScriptMessageHandler(bridge, contentWorld: BrowserScripts.world, name: "textSelected")
        webView.navigationDelegate = bridge
        webView.uiDelegate = bridge
        self.bridge = bridge

        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in self?.sync() },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in self?.sync() },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.sync() },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.sync() },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.sync() },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.sync() },
        ]
    }

    @ObservationIgnored private var bridge: BrowserBridge?
    /// Videos the user asked to watch on YouTube's site after all.
    @ObservationIgnored private var webPlaybackAllowed: Set<String> = []

    func allowWebPlayback(for url: URL) {
        if let id = YouTubeClient.videoID(in: url) { webPlaybackAllowed.insert(id) }
    }

    /// A YouTube video page opened from a link goes to the app's player,
    /// which can mine its subtitles.
    fileprivate func shouldPlayNatively(_ url: URL) -> String? {
        guard let id = YouTubeClient.videoID(in: url), !webPlaybackAllowed.contains(id) else { return nil }
        return id
    }

    /// The video on the current page, in the app's player.
    func playCurrentVideoInApp() {
        guard let url, let id = YouTubeClient.videoID(in: url) else { return }
        pauseVideo()
        AppNavigator.shared.playVideo(.youtube(id: id, title: title.isEmpty ? nil : title))
    }

    nonisolated private func sync() {
        MainActor.assumeIsolated {
            let newURL = webView.url
            if newURL?.absoluteString != url?.absoluteString {
                if newURL?.path != url?.path || newURL?.query != url?.query {
                    // A different video: its subtitles start over.
                    currentCaption = nil
                    captions = []
                    transcriptIsFull = false
                }
                url = newURL
                if !isEditingAddress { addressText = displayAddress }
                if let newURL { UserDefaults.standard.set(newURL.absoluteString, forKey: lastURLKey) }
            }
            // Only what changed: every assignment redraws whatever reads it,
            // and progress alone reports dozens of times a load.
            let newTitle = webView.title ?? ""
            if title != newTitle { title = newTitle }
            if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
            if canGoForward != webView.canGoForward { canGoForward = webView.canGoForward }
            if isLoading != webView.isLoading { isLoading = webView.isLoading }
            // Progress in 5% steps is smooth enough for a bar.
            let newProgress = (webView.estimatedProgress * 20).rounded() / 20
            if progress != newProgress { progress = newProgress }
        }
    }

    // MARK: Loading

    /// First time the tab is shown: the ad blocker, then the last page.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        applyBlocker { [weak self] in
            guard let self, self.webView.url == nil else { return }
            guard let last = UserDefaults.standard.string(forKey: self.lastURLKey).flatMap(URL.init(string:)) else {
                // X opens on its timeline; the browser on its start page.
                if self.site == .x { self.webView.load(URLRequest(url: XScripts.homeURL)) }
                return
            }
            // Restoring a video page shouldn't spring the player open.
            self.allowWebPlayback(for: last)
            self.webView.load(URLRequest(url: last))
        }
    }

    func load(_ url: URL) {
        startIfNeeded()
        webView.load(URLRequest(url: url))
    }

    /// The address bar: a URL, a host, or a search.
    func go(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            load(url)
        } else if !trimmed.contains(" "), trimmed.contains("."), let url = URL(string: "https://" + trimmed) {
            load(url)
        } else {
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            if let url = components?.url { load(url) }
        }
    }

    func goHome() {
        if site == .x {
            load(XScripts.homeURL)
            return
        }
        webView.stopLoading()
        // An empty page shows the start page over it.
        webView.loadHTMLString("", baseURL: nil)
        UserDefaults.standard.removeObject(forKey: lastURLKey)
        url = nil
        addressText = ""
        title = ""
    }

    var showsStartPage: Bool {
        url == nil || url?.absoluteString == "about:blank"
    }

    /// X's timeline: through its own (hidden) home link when the page is
    /// up, which is instant; otherwise by loading it.
    func xHome() {
        let script = "var link = document.querySelector('a[data-testid=\"AppTabBar_Home_Link\"]'); if (link) { link.click(); window.scrollTo(0, 0); true } else { false }"
        webView.evaluateJavaScript(script, in: nil, in: BrowserScripts.world) { [weak self] result in
            MainActor.assumeIsolated {
                if case .success(let value) = result, value as? Bool == true { return }
                self?.load(XScripts.homeURL)
            }
        }
    }

    /// X's pages for the signed-in account.
    enum XAccountPage {
        case following, followers, likes, profile

        fileprivate var suffix: String {
            switch self {
            case .following: "/following"
            case .followers: "/followers"
            case .likes: "/likes"
            case .profile: ""
            }
        }
    }

    /// Opens one of the account's pages.
    func xOpen(_ page: XAccountPage) {
        Task {
            var found = await xHandle()
            if found == nil { found = UserDefaults.standard.string(forKey: XScripts.handleKey) }
            if found == nil { found = await xHandleFromRedirect() }
            guard let handle = found, let url = URL(string: "https://x.com/\(handle)\(page.suffix)") else {
                showToast(String(localized: "Xのアカウント名を取得できませんでした"))
                return
            }
            UserDefaults.standard.set(handle, forKey: XScripts.handleKey)
            load(url)
        }
    }

    /// The signed-in @handle, from the page.
    private func xHandle() async -> String? {
        let result = try? await webView.callAsyncJavaScript(XScripts.handleScript, arguments: [:], in: nil, contentWorld: .page)
        guard let handle = result as? String, !handle.isEmpty else { return nil }
        return handle
    }

    /// The last resort, which needs only the session: the twid cookie holds
    /// the account's number, and x.com/i/user/<number> redirects to its
    /// profile, whose address is the handle.
    private func xHandleFromRedirect() async -> String? {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        guard let twid = cookies.first(where: { $0.name == "twid" })?.value.removingPercentEncoding,
              let id = twid.firstMatch(of: /\d+/).map({ String($0.output) }),
              let url = URL(string: "https://x.com/i/user/\(id)") else { return nil }
        load(url)
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(200))
            guard let parts = webView.url?.pathComponents, parts.count >= 2 else { continue }
            let first = parts[1]
            if first != "i", first != "home", first.wholeMatch(of: /[A-Za-z0-9_]{1,15}/) != nil { return first }
        }
        return nil
    }

    /// The timeline of accounts followed (フォロー中) or X's picks (おすすめ).
    func xHomeFeed(following: Bool) {
        let script = "window.__irohaFollowingFeed = \(following);"
        webView.evaluateJavaScript(script, in: nil, in: BrowserScripts.world) { [weak self] _ in
            MainActor.assumeIsolated { self?.xHome() }
        }
    }

    /// Searches X for the latest posts (Japanese only when the filter is
    /// on, which adds lang:ja).
    func xSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var text = trimmed
        if XScripts.japaneseOnly, !trimmed.lowercased().contains("lang:") { text += " lang:ja" }
        var components = URLComponents(string: "https://x.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "src", value: "typed_query"),
                                  URLQueryItem(name: "f", value: "live")]
        if let url = components?.url { load(url) }
    }

    /// X: only Japanese posts (and searches), or everything.
    func setJapaneseOnly(_ on: Bool) {
        XScripts.japaneseOnly = on
        webView.evaluateJavaScript(XScripts.toggleScript(on), in: nil, in: BrowserScripts.world, completionHandler: nil)
        // The new setting applies to new pages too.
        let controller = webView.configuration.userContentController
        let scripts = controller.userScripts.filter { !$0.source.contains("__irohaJapaneseOnly") }
        controller.removeAllUserScripts()
        scripts.forEach(controller.addUserScript)
        controller.addUserScript(WKUserScript(source: XScripts.source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: BrowserScripts.world))
    }

    // MARK: Ad blocker

    /// Turns the ad blocker on or off to match the setting, compiling its
    /// rules the first time.
    func applyBlocker(then completion: (() -> Void)? = nil) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        guard BehaviorSettings.shared.contentBlocking else {
            completion?()
            return
        }
        if let blocker {
            controller.add(blocker)
            completion?()
            return
        }
        // Compiled once and kept by WebKit; later launches just load it.
        WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: Self.blockerID) { [weak self] list, _ in
            MainActor.assumeIsolated {
                if let self, let list {
                    self.install(list, then: completion)
                    return
                }
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: Self.blockerID,
                    encodedContentRuleList: BrowserScripts.contentRules
                ) { [weak self] list, error in
                    MainActor.assumeIsolated {
                        if let error { print("Ad blocker rules failed to compile: \(error)") }
                        if let self, let list {
                            self.install(list, then: completion)
                        } else {
                            completion?()
                        }
                    }
                }
            }
        }
    }

    private func install(_ list: WKContentRuleList, then completion: (() -> Void)?) {
        blocker = list
        webView.configuration.userContentController.add(list)
        completion?()
    }

    func setBlocking(_ on: Bool) {
        BehaviorSettings.shared.contentBlocking = on
        applyBlocker { [weak self] in self?.webView.reload() }
    }

    // MARK: Lookup

    private func applyLookupMode() {
        popups.closeAll()
        webView.evaluateJavaScript("window.irohaLookup = \(lookupMode); window.hoshiSelection && window.hoshiSelection.clearSelection();",
                                   in: nil, in: BrowserScripts.world, completionHandler: nil)
    }

    /// Returns how many characters matched, for the page to highlight.
    fileprivate func textSelected(text: String, sentence: String, rect: CGRect, block: CGRect?) -> Int {
        guard let userConfig else { return 0 }
        let inset = webView.scrollView.adjustedContentInset
        let local = rect.offsetBy(dx: inset.left, dy: inset.top)
        let windowRect = webView.convert(local, to: nil)
        popups.coverURL = nil
        // A picture of the post or paragraph, taken when + is pressed.
        // Not for YouTube's site, whose words come from captions.
        if let block, !isYouTube {
            popups.mediaProvider = PostSnapshot.webProvider(webView: webView,
                                                            block: block.offsetBy(dx: inset.left, dy: inset.top),
                                                            focus: local,
                                                            offset: webView.scrollView.contentOffset)
        } else {
            popups.mediaProvider = nil
        }
        popups.documentTitle = title.isEmpty ? nil : title
        let selection = SelectionData(text: text, sentence: sentence, rect: windowRect)
        if let matched = popups.replace(with: selection, userConfig: userConfig) {
            return matched
        }
        clearPageSelection()
        return 0
    }

    /// A short message over the page ("link copied").
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// The copy-link button on an X post.
    fileprivate func copyShareLink(path: String) {
        guard let url = XScripts.shareLink(for: path) else { return }
        UIPasteboard.general.url = url
        UIPasteboard.general.string = url.absoluteString
        Haptics.play(.success)
        showToast(String(localized: "リンクをコピーしました"))
    }

    fileprivate func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    fileprivate func tappedOutside() {
        popups.closeAll()
        clearPageSelection()
    }

    func clearPageSelection() {
        webView.evaluateJavaScript("window.hoshiSelection && window.hoshiSelection.clearSelection()",
                                   in: nil, in: BrowserScripts.world, completionHandler: nil)
    }

    /// The page as an image, for reading its text with OCR.
    func snapshot() async -> UIImage? {
        await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: YouTube subtitles

    fileprivate func captionArrived(_ text: String, time: Double) {
        let line = CaptionLine(time: time, text: text)
        currentCaption = line
        guard !transcriptIsFull else { return }
        if captions.last?.text != text {
            captions.append(line)
            if captions.count > 2000 { captions.removeFirst(captions.count - 2000) }
        }
    }

    func pauseVideo() {
        webView.evaluateJavaScript("var v = document.querySelector('video'); if (v) { v.pause(); }",
                                   in: nil, in: BrowserScripts.world, completionHandler: nil)
    }

    func seek(to time: Double) {
        webView.evaluateJavaScript("var v = document.querySelector('video'); if (v) { v.currentTime = \(time); v.play(); }",
                                   in: nil, in: BrowserScripts.world, completionHandler: nil)
    }

    /// The current video frame, for Anki cards mined from its subtitles.
    func videoFrame() async -> UIImage? {
        let rect: CGRect? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(
                "(function(){var v=document.querySelector('video');if(!v){return null;}var r=v.getBoundingClientRect();return [r.x,r.y,r.width,r.height];})()",
                in: nil, in: BrowserScripts.world
            ) { result in
                if case .success(let value) = result, let numbers = value as? [Double], numbers.count == 4,
                   numbers[2] > 10, numbers[3] > 10 {
                    continuation.resume(returning: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let rect else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect.intersection(webView.bounds)
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Prepares a lookup in a subtitle: pause, and grab the frame for Anki.
    func prepareCaptionLookup(into stack: PopupStack) {
        pauseVideo()
        stack.documentTitle = title.isEmpty ? nil : title
        Task {
            if let frame = await videoFrame() {
                stack.coverURL = CardImage.write(frame)
            }
        }
    }

    /// Asks YouTube for the video's whole subtitle track.
    func fetchTranscript() async -> Bool {
        do {
            let result = try await webView.callAsyncJavaScript(BrowserScripts.fetchTranscript,
                                                               arguments: [:], in: nil, contentWorld: .page)
            guard let dictionary = result as? [String: Any],
                  let lines = dictionary["lines"] as? [[String: Any]], !lines.isEmpty else { return false }
            captions = lines.compactMap { line in
                guard let text = line["text"] as? String else { return nil }
                return CaptionLine(time: (line["time"] as? Double) ?? Double(line["time"] as? Int ?? 0), text: text)
            }
            transcriptIsFull = true
            return true
        } catch {
            return false
        }
    }
}

/// Delegates and script messages for the browser's web view.
private final class BrowserBridge: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
    weak var model: BrowserModel?

    init(model: BrowserModel) {
        self.model = model
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let model, message.name == "textSelected",
              let body = message.body as? [String: Any],
              let text = body["text"] as? String,
              let sentence = body["sentence"] as? String,
              let rect = body["rect"] as? [String: Any],
              let x = rect["x"] as? Double, let y = rect["y"] as? Double,
              let width = rect["width"] as? Double, let height = rect["height"] as? Double else {
            replyHandler(0, nil)
            return
        }
        var block: CGRect?
        if let b = body["block"] as? [String: Any],
           let bx = b["x"] as? Double, let by = b["y"] as? Double,
           let bw = b["width"] as? Double, let bh = b["height"] as? Double {
            block = CGRect(x: bx, y: by, width: bw, height: bh)
        }
        let matched = model.textSelected(text: text, sentence: sentence,
                                         rect: CGRect(x: x, y: y, width: width, height: height), block: block)
        replyHandler(matched, nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let model else { return }
        switch message.name {
        case "tapOutside":
            model.tappedOutside()
        case "scrolled":
            if !model.popups.isEmpty { model.tappedOutside() }
        case "caption":
            guard let body = message.body as? [String: Any], let text = body["text"] as? String else { return }
            let time = (body["time"] as? Double) ?? 0
            model.captionArrived(text, time: time)
        case "irohaShare":
            guard let body = message.body as? [String: Any], let path = body["path"] as? String else { return }
            model.copyShareLink(path: path)
        default:
            break
        }
    }

    // Links that want a new window open in this one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        // App links (mailto:, tel:, other apps) go to the system.
        if !["http", "https", "about", "data", "blob", "file"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame != false,
           navigationAction.navigationType != .backForward, navigationAction.navigationType != .reload,
           let model, let id = model.shouldPlayNatively(url) {
            decisionHandler(.cancel)
            AppNavigator.shared.playVideo(.youtube(id: id, title: nil))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A new page: its lookup glue starts off; bring it up to date.
        guard let model else { return }
        webView.evaluateJavaScript("window.irohaLookup = \(model.lookupMode);",
                                   in: nil, in: BrowserScripts.world, completionHandler: nil)
    }
}
