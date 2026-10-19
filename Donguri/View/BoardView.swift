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

    @AppStorage("donguri.threadSortOrder") private var sortOrderRaw = ThreadSortOrder.board.rawValue

    private var sortOrder: ThreadSortOrder {
        ThreadSortOrder(rawValue: sortOrderRaw) ?? .board
    }

    private var displayedThreads: [Thread] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? threads : threads.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(query)
        }
        return sortOrder.sorted(matching, now: loadedAt)
    }

    var body: some View {
        if let board {
            Group {
                if !threads.isEmpty {
                    let shown = displayedThreads
                    List {
                        if shown.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                                .listRowSeparator(.hidden)
                        }
                        ForEach(shown) { thread in
                            let isFavorite = favorites.isFavorite(boardURL: board.url, threadId: thread.id)
                            NavigationLink {
                                ThreadView(thread: thread, boardURL: board.url, boardName: board.boardName)
                            } label: {
                                ThreadRowView(thread: thread,
                                              boardURL: board.url,
                                              momentum: thread.momentum(now: loadedAt),
                                              isFavorite: isFavorite)
                            }
                            .padding(.vertical, 4)
                            .contextMenu {
                                favoriteThreadButton(thread: thread, board: board, isFavorite: isFavorite)
                            }
                            .swipeActions(edge: .leading) {
                                favoriteThreadButton(thread: thread, board: board, isFavorite: isFavorite)
                                    .tint(.yellow)
                            }
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
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("並び替え", selection: $sortOrderRaw) {
                            ForEach(ThreadSortOrder.allCases) { order in
                                Label(order.title, systemImage: order.systemImage)
                                    .tag(order.rawValue)
                            }
                        }
                    } label: {
                        Image(systemName: sortOrder == .board
                              ? "arrow.up.arrow.down.circle"
                              : "arrow.up.arrow.down.circle.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    let isFavorite = favorites.isFavorite(boardURL: board.url)
                    Button {
                        favorites.toggle(board: board)
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundStyle(isFavorite ? Color.yellow : Color.accentColor)
                    }
                    .accessibilityLabel(isFavorite ? Text("お気に入りから削除") : Text("お気に入りに追加"))
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

    private func favoriteThreadButton(thread: Thread, board: BBSMenu.CategoryContent, isFavorite: Bool) -> some View {
        Button {
            favorites.toggle(boardURL: board.url,
                             boardName: board.boardName,
                             threadId: thread.id,
                             title: thread.title ?? String(localized: "無題"),
                             responseCount: thread.responseCount)
        } label: {
            if isFavorite {
                Label("お気に入りから削除", systemImage: "star.slash")
            } else {
                Label("お気に入りに追加", systemImage: "star")
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
