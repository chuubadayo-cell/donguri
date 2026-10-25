//
//  LinkPreviewCard.swift
//  Donguri
//
//  Embedded previews under a post for the links in it: YouTube (plays in
//  the app), tweets (text, author, images into the gallery), ニコニコ動画,
//  and any page with preview tags. Each card has a fixed height from the
//  moment the row is laid out, so nothing jumps when a preview arrives.
//

import SwiftUI
import WebKit

/// The cards for one post.
struct LinkPreviewList: View {
    let urls: [URL]
    let postIndex: Int

    var body: some View {
        VStack(spacing: 6) {
            ForEach(urls, id: \.self) { url in
                LinkPreviewCard(url: url, postIndex: postIndex)
            }
        }
    }
}

struct LinkPreviewCard: View {
    let url: URL
    let postIndex: Int

    private enum Phase {
        case loading, needsTap, loaded(LinkPreview), failed
    }

    @State private var phase: Phase = .loading
    @State private var behavior = BehaviorSettings.shared
    @State private var appearance = AppearanceSettings.shared
    @State private var playerVideoID: PlayerItem?
    @State private var galleryItem: MediaItem?
    @Environment(\.openURL) private var openURL

    private struct PlayerItem: Identifiable {
        let id: String
        let url: URL
        let title: String?
    }

    private var kind: LinkPreview.Kind { LinkPreviewService.kind(of: url) }
    private var height: CGFloat { kind == .tweet ? 132 : 78 }

    var body: some View {
        content
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture(perform: tap)
            .contextMenu {
                Button {
                    openURL(url)
                } label: {
                    Label("Safariで開く", systemImage: "safari")
                }
                Button {
                    UIPasteboard.general.url = url
                } label: {
                    Label("リンクをコピー", systemImage: "link")
                }
                ShareLink(item: url) {
                    Label("共有", systemImage: "square.and.arrow.up")
                }
            }
            .task(id: url) {
                await start()
            }
            .sheet(item: $playerVideoID) { item in
                YouTubePlayerSheet(videoID: item.id, url: item.url, title: item.title)
            }
            .fullScreenCover(item: $galleryItem) { item in
                let items = tweetMedia
                GalleryView(items: items, initialIndex: items.firstIndex(of: item) ?? 0) {
                    withTransaction(Transaction.noAnimation) { galleryItem = nil }
                }
                .presentationBackground(.clear)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            placeholder(caption: nil)
                .redacted(reason: .placeholder)
        case .needsTap:
            placeholder(caption: String(localized: "タップでプレビューを表示"))
        case .failed:
            placeholder(caption: url.host)
        case .loaded(let preview):
            if preview.kind == .tweet {
                tweetCard(preview)
            } else {
                mediaCard(preview)
            }
        }
    }

    // MARK: Cards

    private func placeholder(caption: String?) -> some View {
        let label = LinkLabel.describe(url)
        return HStack(spacing: 10) {
            Image(systemName: label.kind.symbolName)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(label.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }

    /// YouTube, ニコニコ動画 and pages: picture on the left, words on the right.
    private func mediaCard(_ preview: LinkPreview) -> some View {
        let isVideo = preview.kind == .youtube || preview.kind == .niconico
        return HStack(spacing: 10) {
            if let thumbnail = preview.thumbnailURL {
                RemoteThumbnail(url: thumbnail)
                    .frame(width: isVideo ? 104 : 78, height: isVideo ? 58 : 58)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        if isVideo {
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.5))
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: siteSymbol(preview.kind))
                    Text(preview.siteName ?? url.host ?? "")
                        .lineLimit(1)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(siteColor(preview.kind))
                Text(preview.title ?? "")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let secondLine = preview.subtitle ?? preview.detail ?? preview.text {
                    Text(secondLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }

    private func tweetCard(_ preview: LinkPreview) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let avatar = preview.avatarURL {
                        RemoteThumbnail(url: avatar)
                            .frame(width: 20, height: 20)
                            .clipShape(Circle())
                    }
                    Text(preview.title ?? "")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(preview.subtitle ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(verbatim: "𝕏")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text(preview.text ?? "")
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(preview.detail == nil ? 5 : 4)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if let detail = preview.detail {
                    Text(detail)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let first = tweetMedia.first {
                Button {
                    withTransaction(Transaction.noAnimation) { galleryItem = first }
                } label: {
                    RemoteThumbnail(url: preview.thumbnailURL ?? first.url)
                        .frame(width: 86, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            if first.isVideo {
                                Image(systemName: "play.circle.fill")
                                    .font(.title2)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.5))
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if tweetMedia.count > 1 {
                                Text(verbatim: "+\(tweetMedia.count - 1)")
                                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(.black.opacity(0.6)))
                                    .padding(3)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
    }

    /// A tweet's images and videos, for the gallery.
    private var tweetMedia: [MediaItem] {
        guard case .loaded(let preview) = phase, preview.kind == .tweet else { return [] }
        let images = preview.images.map { MediaItem(url: $0, postIndex: postIndex, kind: .image) }
        let videos = preview.videos.map { MediaItem(url: $0, postIndex: postIndex, kind: .video) }
        return images + videos
    }

    private var cardBackground: Color {
        appearance.palette.map { Color(uiColor: $0.bar) } ?? Color.primary.opacity(0.05)
    }

    private func siteSymbol(_ kind: LinkPreview.Kind) -> String {
        switch kind {
        case .youtube, .niconico: "play.rectangle.fill"
        case .tweet: "bubble.left"
        case .page: "globe"
        }
    }

    private func siteColor(_ kind: LinkPreview.Kind) -> Color {
        switch kind {
        case .youtube: .red
        case .niconico: .primary
        default: .secondary
        }
    }

    // MARK: Loading and taps

    private func start() async {
        let service = LinkPreviewService.shared
        if let cached = await service.cached(url) {
            phase = .loaded(cached)
            return
        }
        if await service.hasFailed(url) {
            phase = .failed
            return
        }
        guard behavior.linkPreviewMode.loadsAutomatically else {
            phase = .needsTap
            return
        }
        await load()
    }

    private func load() async {
        phase = .loading
        if let preview = await LinkPreviewService.shared.preview(for: url) {
            withAnimation(.easeOut(duration: 0.2)) { phase = .loaded(preview) }
        } else {
            phase = .failed
        }
    }

    private func tap() {
        switch phase {
        case .needsTap:
            Task { await load() }
        case .loading:
            break
        case .failed:
            ExternalLinks.open(url)
        case .loaded(let preview):
            if preview.kind == .youtube, behavior.openLinksInApp {
                // In the browser, its subtitles can be mined.
                ExternalLinks.open(url)
            } else if preview.kind == .youtube, let id = preview.videoID {
                playerVideoID = PlayerItem(id: id, url: url, title: preview.title)
            } else {
                ExternalLinks.open(url)
            }
        }
    }
}

/// A remote image, through the app's image cache.
struct RemoteThumbnail: View {
    let url: URL

    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: url) {
                let item = MediaItem(url: url, postIndex: 0, kind: .image)
                if let cached = MediaStore.shared.memoryImage(for: url, maxPixelSize: MediaThumbnailView.rowPixelSize) {
                    image = cached
                    return
                }
                image = await MediaStore.shared.thumbnail(for: item, maxPixelSize: MediaThumbnailView.rowPixelSize)
            }
    }
}

/// YouTube, played in the app (in its privacy-enhanced embed).
struct YouTubePlayerSheet: View {
    let videoID: String
    let url: URL
    let title: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                YouTubePlayerView(videoID: videoID)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let title {
                    Text(title)
                        .font(.headline)
                        .padding(.horizontal, 4)
                }
                Button {
                    openURL(url)
                } label: {
                    Label("YouTubeで開く", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("YouTube")
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
        .presentationDragIndicator(.visible)
    }
}

private struct YouTubePlayerView: UIViewRepresentable {
    let videoID: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        let safeID = videoID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        // YouTube refuses to play embeds that arrive with no referrer
        // ("error 153"), hence the base URL and referrer policy.
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="https://www.youtube-nocookie.com/embed/\(safeID)?playsinline=1&autoplay=1&rel=0"
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
          referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
