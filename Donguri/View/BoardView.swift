//
//  BoardView.swift
//  Donguri
//
//  Created by John Connery on 6/16/26.
//

import SwiftUI

struct BoardView: View {
    var board: BBSMenu.CategoryContent?

    @State private var threads: [Thread] = []
    @State private var errorMessage: String?
    @State private var searchText = ""
    /// One clock for the whole list, so 勢い is computed against the same
    /// "now" for every row and the sort stays consistent while scrolling.
    @State private var loadedAt = Date.now
    @State private var favorites = FavoritesStore.shared
    @State private var ngFilter = NGFilterStore.shared
    /// Hidden threads (one by one, or by NGスレタイ) shown anyway, dimmed.
    @State private var showsHidden = false
    @State private var showsBoardSwitcher = false

    @Environment(BrowseContext.self) private var browseContext: BrowseContext?
    private var browse: BrowseContext { browseContext ?? .detached }
    @AppStorage("donguri.threadSortOrder") private var sortOrderRaw = ThreadSortOrder.board.rawValue

    private var sortOrder: ThreadSortOrder {
        ThreadSortOrder(rawValue: sortOrderRaw) ?? .board
    }

    private func matching(_ board: BBSMenu.CategoryContent) -> (shown: [Thread], hiddenCount: Int) {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        var list = query.isEmpty ? threads : threads.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(query)
        }
        var hiddenCount = 0
        if !showsHidden {
            let before = list.count
            list = list.filter { !ngFilter.hides(thread: $0, boardURL: board.url) }
            hiddenCount = before - list.count
        }
        return (sortOrder.sorted(list, now: loadedAt), hiddenCount)
    }

    var body: some View {
        if let board {
            Group {
                if !threads.isEmpty {
                    let result = matching(board)
                    let shown = result.shown
                    List {
                        if shown.isEmpty, !searchText.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                                .listRowSeparator(.hidden)
                        }
                        ForEach(shown) { thread in
                            threadRow(thread, board: board)
                        }
                        if result.hiddenCount > 0 || showsHidden {
                            Button {
                                withAnimation { showsHidden.toggle() }
                            } label: {
                                HStack {
                                    Spacer()
                                    if showsHidden {
                                        Label("非表示のスレを隠す", systemImage: "eye.slash")
                                    } else {
                                        Label("非表示のスレ \(result.hiddenCount)件を表示", systemImage: "eye")
                                    }
                                    Spacer()
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $searchText,
                                placement: .navigationBarDrawer(displayMode: .automatic),
                                prompt: "スレタイ検索")
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
            .themedScreen()
            .navigationTitle(board.boardName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Tap the board name to jump to another board.
                ToolbarItem(placement: .principal) {
                    Button {
                        showsBoardSwitcher = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(board.boardName)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down.circle.fill")
                                .font(.caption)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel(Text("板を切り替え"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("並び替え", selection: $sortOrderRaw) {
                            ForEach(ThreadSortOrder.allCases) { order in
                                Label(order.title, systemImage: order.systemImage)
                                    .tag(order.rawValue)
                            }
                        }
                        Section {
                            let isFavorite = favorites.isFavorite(boardURL: board.url)
                            Button {
                                favorites.toggle(board: board)
                                Haptics.play(.success)
                            } label: {
                                if isFavorite {
                                    Label("お気に入りから削除", systemImage: "star.slash")
                                } else {
                                    Label("お気に入りに追加", systemImage: "star")
                                }
                            }
                            Button {
                                browse.openInNewTab(.board(FavoriteBoard(board)), inBackground: false)
                            } label: {
                                Label("新しいタブで開く", systemImage: "plus.square.on.square")
                            }
                        }
                    } label: {
                        Image(systemName: sortOrder == .board
                              ? "arrow.up.arrow.down.circle"
                              : "arrow.up.arrow.down.circle.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    TabsToolbarButton()
                }
            }
            .sheet(isPresented: $showsBoardSwitcher) {
                BoardSwitcherView(currentBoardURL: board.url) { picked in
                    showsBoardSwitcher = false
                    guard picked.url != board.url else { return }
                    Haptics.play(.selection)
                    browse.replaceTop(.board(picked))
                }
            }
            .task {
                await loadBoard(board: board)
            }
            .refreshable {
                await loadBoard(board: board)
            }
        } else {
            ContentUnavailableView("エラー：板情報がありません", systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private func threadRow(_ thread: Thread, board: BBSMenu.CategoryContent) -> some View {
        let isFavorite = favorites.isFavorite(boardURL: board.url, threadId: thread.id)
        let isHidden = showsHidden && ngFilter.hides(thread: thread, boardURL: board.url)
        let link = ThreadLink(boardURL: board.url, threadId: thread.id, title: thread.title,
                              boardName: board.boardName, responseCount: thread.responseCount)
        NavigationLink(value: BrowseRoute.thread(link)) {
            ThreadRowView(thread: thread,
                          boardURL: board.url,
                          momentum: thread.momentum(now: loadedAt),
                          isFavorite: isFavorite)
                .opacity(isHidden ? 0.4 : 1)
        }
        .padding(.vertical, 4)
        .threadContextMenu(link) {
            favoriteThreadButton(thread: thread, board: board, isFavorite: isFavorite)
            hideThreadButton(thread: thread, board: board)
        }
        .swipeActions(edge: .trailing) {
            hideThreadButton(thread: thread, board: board)
                .tint(.gray)
            favoriteThreadButton(thread: thread, board: board, isFavorite: isFavorite)
                .tint(.yellow)
        }
    }

    private func favoriteThreadButton(thread: Thread, board: BBSMenu.CategoryContent, isFavorite: Bool) -> some View {
        Button {
            favorites.toggle(boardURL: board.url,
                             boardName: board.boardName,
                             threadId: thread.id,
                             title: thread.title ?? String(localized: "無題"),
                             responseCount: thread.responseCount)
            Haptics.play(.success)
        } label: {
            if isFavorite {
                Label("お気に入りから削除", systemImage: "star.slash")
            } else {
                Label("お気に入りに追加", systemImage: "star")
            }
        }
    }

    @ViewBuilder
    private func hideThreadButton(thread: Thread, board: BBSMenu.CategoryContent) -> some View {
        if ngFilter.isHidden(boardURL: board.url, threadId: thread.id) {
            Button {
                withAnimation { ngFilter.unhide(boardURL: board.url, threadId: thread.id) }
            } label: {
                Label("再表示", systemImage: "eye")
            }
        } else {
            Button {
                withAnimation {
                    ngFilter.hide(boardURL: board.url, threadId: thread.id,
                                  title: thread.title ?? String(localized: "無題"))
                }
                Haptics.play(.light)
            } label: {
                Label("非表示", systemImage: "eye.slash")
            }
        }
    }

    private func loadBoard(board: BBSMenu.CategoryContent) async {
        do {
            errorMessage = nil
            let service = ThreadService()
            let newThreads = try await service.fetchThreads(boardURL: board.url)
            loadedAt = .now
            threads = newThreads
            favorites.update(boardURL: board.url, from: newThreads)
        } catch {
            errorMessage = String(localized: "エラーが発生しました: \(String(describing: error))")
            print("BoardView Error: \(error)")
        }
    }
}

/// A thread in the board list, styled after Chance's catalog rows: the
/// title, then one line of counters (replies with new ones in red, 勢い,
/// age). Threads with nothing new since your last visit are greyed out.
struct ThreadRowView: View {
    let thread: Thread
    let boardURL: String
    var momentum: Double? = nil
    var isFavorite: Bool = false

    @State private var appearance = AppearanceSettings.shared

    private var readState: ReadState? {
        ReadStateStore.shared.state(for: ReadStateStore.key(boardURL: boardURL, threadId: thread.id))
    }

    private var unreadCount: Int? {
        guard let state = readState else { return nil }
        let unread = thread.responseCount - state.lastReadCount
        return unread > 0 ? unread : nil
    }

    /// Opened before, and nothing new since.
    private var isCaughtUp: Bool {
        readState != nil && unreadCount == nil
    }

    private var created: Date {
        Date(timeIntervalSince1970: TimeInterval(thread.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
                Text(thread.title ?? "無題")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(3)
            }

            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    Image(systemName: "arrowshape.turn.up.left")
                    Text(verbatim: "\(thread.responseCount)")
                    if let unreadCount {
                        Text(verbatim: "+\(unreadCount)")
                            .foregroundStyle(.red)
                            .fontWeight(.bold)
                    }
                }
                if thread.isFull {
                    Text("満了")
                        .padding(.horizontal, 4)
                        .overlay(Capsule().stroke(Color.secondary.opacity(0.5), lineWidth: 1))
                }
                if let momentum {
                    HStack(spacing: 3) {
                        Image(systemName: "flame")
                        Text(verbatim: momentum.momentumLabel)
                    }
                }
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                    Text(verbatim: PostDate.relativeLabel(for: created))
                }
                Spacer(minLength: 0)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .opacity(isCaughtUp ? 0.55 : 1)
        .padding(.vertical, 2)
    }

    private var titleColor: Color {
        appearance.palette.map { Color(uiColor: $0.title) } ?? .primary
    }
}

#Preview {
    BoardView(board: nil)
}
