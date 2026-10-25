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
    static let shared = BrowserModel()

    private static let lastURLKey = "donguri.browser.lastURL"
    private static let blockerID = "iroha-blocker-v1"

    let webView: WKWebView

    // Navigation state, mirrored from the web view.
    private(set) var title = ""
    private(set) var url: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    var addressText = ""

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

    override init() {
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

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        // Safari's own user agent: Google won't let embedded browsers sign
        // in, and pages serve their normal mobile layout.
        let version = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        let short = UIDevice.current.systemVersion.split(separator: ".").prefix(2).joined(separator: ".")
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS \(version) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(short) Mobile/15E148 Safari/604.1"
        super.init()

        let bridge = BrowserBridge(model: self)
        for name in ["textSelected", "tapOutside", "scrolled", "caption"] {
            controller.add(bridge, contentWorld: BrowserScripts.world, name: name)
        }
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
                addressText = newURL?.absoluteString ?? ""
                if let newURL { UserDefaults.standard.set(newURL.absoluteString, forKey: Self.lastURLKey) }
            }
            title = webView.title ?? ""
            canGoBack = webView.canGoBack
            canGoForward = webView.canGoForward
            isLoading = webView.isLoading
            progress = webView.estimatedProgress
        }
    }

    // MARK: Loading

    /// First time the tab is shown: the ad blocker, then the last page.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        applyBlocker { [weak self] in
            guard let self, self.webView.url == nil,
                  let last = UserDefaults.standard.string(forKey: Self.lastURLKey).flatMap(URL.init(string:)) else { return }
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
        webView.stopLoading()
        // An empty page shows the start page over it.
        webView.loadHTMLString("", baseURL: nil)
        UserDefaults.standard.removeObject(forKey: Self.lastURLKey)
        url = nil
        addressText = ""
        title = ""
    }

    var showsStartPage: Bool {
        url == nil || url?.absoluteString == "about:blank"
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
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: Self.blockerID,
            encodedContentRuleList: BrowserScripts.contentRules
        ) { [weak self] list, error in
            MainActor.assumeIsolated {
                if let error { print("Ad blocker rules failed to compile: \(error)") }
                if let self, let list {
                    self.blocker = list
                    self.webView.configuration.userContentController.add(list)
                }
                completion?()
            }
        }
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

    fileprivate func textSelected(text: String, sentence: String, rect: CGRect) {
        guard let userConfig else { return }
        let inset = webView.scrollView.adjustedContentInset
        let local = CGRect(x: rect.minX + inset.left, y: rect.minY + inset.top, width: rect.width, height: rect.height)
        let windowRect = webView.convert(local, to: nil)
        popups.coverURL = nil
        popups.documentTitle = title.isEmpty ? nil : title
        let selection = SelectionData(text: text, sentence: sentence, rect: windowRect)
        if let matched = popups.replace(with: selection, userConfig: userConfig) {
            webView.evaluateJavaScript("window.hoshiSelection.highlightSelection(\(matched))",
                                       in: nil, in: BrowserScripts.world, completionHandler: nil)
        } else {
            clearPageSelection()
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
private final class BrowserBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var model: BrowserModel?

    init(model: BrowserModel) {
        self.model = model
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let model else { return }
        switch message.name {
        case "textSelected":
            guard let body = message.body as? [String: Any],
                  let text = body["text"] as? String,
                  let sentence = body["sentence"] as? String,
                  let rect = body["rect"] as? [String: Any],
                  let x = rect["x"] as? Double, let y = rect["y"] as? Double,
                  let width = rect["width"] as? Double, let height = rect["height"] as? Double else { return }
            model.textSelected(text: text, sentence: sentence, rect: CGRect(x: x, y: y, width: width, height: height))
        case "tapOutside":
            model.tappedOutside()
        case "scrolled":
            if !model.popups.isEmpty { model.tappedOutside() }
        case "caption":
            guard let body = message.body as? [String: Any], let text = body["text"] as? String else { return }
            let time = (body["time"] as? Double) ?? 0
            model.captionArrived(text, time: time)
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
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A new page: its lookup glue starts off; bring it up to date.
        guard let model else { return }
        webView.evaluateJavaScript("window.irohaLookup = \(model.lookupMode);",
                                   in: nil, in: BrowserScripts.world, completionHandler: nil)
    }
}
