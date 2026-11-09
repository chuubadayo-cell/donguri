//
//  ThreadContextMenu.swift
//  Donguri
//
//  Long-press on a thread anywhere it's listed: a preview of its first and
//  latest posts (the thread is fetched for the preview, so opening it
//  afterwards is instant), and ways to open it in another tab.
//

import SwiftUI

extension View {
    /// The standard thread menu and preview. `extra` adds rows above the
    /// tab actions (favorite, hide …).
    func threadContextMenu<Extra: View>(_ link: ThreadLink,
                                        @ViewBuilder extra: @escaping () -> Extra) -> some View {
        modifier(ThreadContextMenuModifier(link: link, extra: extra))
    }

    func threadContextMenu(_ link: ThreadLink) -> some View {
        threadContextMenu(link) { EmptyView() }
    }
}

private struct ThreadContextMenuModifier<Extra: View>: ViewModifier {
    let link: ThreadLink
    let extra: () -> Extra

    @Environment(BrowseContext.self) private var browseContext: BrowseContext?
    private var browse: BrowseContext { browseContext ?? .detached }

    func body(content: Content) -> some View {
        content.contextMenu {
            extra()
            Section {
                Button {
                    browse.openInNewTab(.thread(link), inBackground: false)
                } label: {
                    Label("新しいタブで開く", systemImage: "plus.square.on.square")
                }
                Button {
                    browse.openInNewTab(.thread(link), inBackground: true)
                } label: {
                    Label("バックグラウンドで開く", systemImage: "square.on.square.dashed")
                }
            }
            Section {
                Button {
                    UIPasteboard.general.url = Self.webURL(for: link)
                } label: {
                    Label("リンクをコピー", systemImage: "link")
                }
                if let url = Self.webURL(for: link) {
                    ShareLink(item: url) {
                        Label("共有", systemImage: "square.and.arrow.up")
                    }
                }
            }
        } preview: {
            ThreadPreviewCard(link: link)
        }
    }

    static func webURL(for link: ThreadLink) -> URL? {
        guard let board = URL(string: link.boardURL), let host = board.host else { return nil }
        let directory = board.pathComponents.first { $0 != "/" } ?? ""
        return URL(string: "https://\(host)/test/read.cgi/\(directory)/\(link.threadId)/")
    }
}

/// The first post and the latest few, loaded when the preview appears.
struct ThreadPreviewCard: View {
    let link: ThreadLink

    @State private var posts: [Post]?
    @State private var failed = false
    @State private var appearance = AppearanceSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(link.title ?? posts?.first?.threadTitle ?? String(localized: "無題"))
                .font(.headline)
                .foregroundStyle(titleColor)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(link.boardName ?? HistoryStore.shared.knownBoardName(for: link.boardURL))
                if let count = posts?.count ?? (link.responseCount >= 0 ? link.responseCount : nil) {
                    Label {
                        Text(verbatim: "\(count)")
                    } icon: {
                        Image(systemName: "arrowshape.turn.up.left")
                    }
                }
                if let unread {
                    Text(verbatim: "+\(unread)")
                        .foregroundStyle(.red)
                        .fontWeight(.bold)
                }
                Spacer(minLength: 0)
                Text(verbatim: PostDate.relativeLabel(for: Date(timeIntervalSince1970: TimeInterval(link.threadId))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            Divider()

            if let posts {
                if let first = posts.first {
                    previewPost(first, index: 0, lines: 9)
                }
                let latest = Array(posts.indices.suffix(3)).filter { $0 > 0 }
                if !latest.isEmpty {
                    if let firstLatest = latest.first, firstLatest > 1 {
                        HStack {
                            Spacer()
                            Image(systemName: "ellipsis")
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                    }
                    ForEach(latest, id: \.self) { index in
                        previewPost(posts[index], index: index, lines: 3)
                    }
                }
            } else if failed {
                Label("読み込めませんでした", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .topLeading)
        .frame(maxHeight: 520, alignment: .top)
        .background(background)
        .task {
            await load()
        }
    }

    private func previewPost(_ post: Post, index: Int, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: "#\(index + 1)")
                    .fontWeight(.semibold)
                if let id = post.id {
                    let colors = IDColor.colors(for: id)
                    Text(verbatim: id)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(colors.foreground)
                        .padding(.horizontal, 3)
                        .background(RoundedRectangle(cornerRadius: 3).fill(colors.background))
                }
                Spacer(minLength: 0)
                if let date = PostDate.date(from: post.date) {
                    Text(verbatim: PostDate.relativeLabel(for: date))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 8) {
                if let media = MediaItem.items(in: post, at: index).first {
                    MediaThumbnailView(item: media, side: 48, cornerRadius: 5)
                }
                Text(post.isDeleted == true ? String(localized: "あぼーん") : post.text.asPlainPostText)
                    .font(.subheadline)
                    .foregroundStyle(textColor)
                    .lineLimit(lines)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var unread: Int? {
        guard let state = ReadStateStore.shared.state(for: link.key) else { return nil }
        let total = posts?.count ?? link.responseCount
        let unread = total - state.lastReadCount
        return unread > 0 ? unread : nil
    }

    private var background: Color {
        appearance.palette.map { Color(uiColor: $0.background) } ?? Color(uiColor: .systemBackground)
    }

    private var titleColor: Color {
        appearance.palette.map { Color(uiColor: $0.title) } ?? .primary
    }

    private var textColor: Color {
        appearance.palette.map { Color(uiColor: $0.text) } ?? .primary
    }

    private func load() async {
        if let cached = ThreadMemoryCache.shared.posts(for: link.key), !cached.isEmpty {
            posts = cached
            return
        }
        do {
            let loaded = try await PostService().fetchPosts(boardURL: link.boardURL, threadId: link.threadId)
            ThreadMemoryCache.shared.store(loaded, for: link.key)
            posts = loaded
        } catch {
            failed = true
        }
    }
}
