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

struct ThreadRowView: View {
    let thread: Thread
    let boardURL: String
    var momentum: Double? = nil
    var isFavorite: Bool = false

    private var unreadCount: Int? {
        guard let state = ReadStateStore.shared.state(
            for: ReadStateStore.key(boardURL: boardURL, threadId: thread.id)
        ) else { return nil }
        let unread = thread.responseCount - state.lastReadCount
        return unread > 0 ? unread : nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                    Text(thread.title ?? "無題")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text(
                        Date(timeIntervalSince1970: TimeInterval(thread.id))
                            .formatted(date: .numeric, time: .shortened)
                    )
                    if let momentum {
                        Image(systemName: "flame")
                            .padding(.leading, 6)
                        Text("勢い \(momentum.momentumLabel)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Chip(text: "\(thread.responseCount)",
                     systemImage: "message.fill",
                     tint: thread.isFull ? .secondary : .accentColor)
                if let unreadCount {
                    Chip(text: "+\(unreadCount)", tint: .red)
                }
            }
       }
    }
}

#Preview {
    BoardView(board: nil)
}
