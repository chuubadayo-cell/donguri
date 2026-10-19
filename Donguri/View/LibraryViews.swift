//
//  LibraryViews.swift
//  Donguri
//
//  The user's library on the board menu: favorite boards and threads, plus
//  the browsing-history and saved-threads screens.
//

import SwiftUI

/// Sections shown above the board menu.
struct LibrarySections: View {
    @State private var favorites = FavoritesStore.shared
    @State private var history = HistoryStore.shared
    @State private var saved = SavedThreadStore.shared

    var body: some View {
        if !favorites.boards.isEmpty {
            Section {
                ForEach(favorites.boards) { board in
                    NavigationLink {
                        BoardView(board: board.categoryContent)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                            Text(board.boardName)
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .onDelete { favorites.removeBoards(atOffsets: $0) }
            } header: {
                Text("お気に入りの板")
            }
        }

        if !favorites.threads.isEmpty {
            Section {
                ForEach(favorites.threads) { favorite in
                    NavigationLink {
                        ThreadView(thread: favorite.thread,
                                   boardURL: favorite.boardURL,
                                   boardName: favorite.boardName)
                    } label: {
                        LibraryThreadRow(title: favorite.title,
                                         boardName: favorite.boardName,
                                         responseCount: favorite.responseCount,
                                         unreadCount: favorites.unreadCount(for: favorite),
                                         isArchived: favorite.isArchived)
                    }
                }
                .onDelete { favorites.removeThreads(atOffsets: $0) }
            } header: {
                HStack(spacing: 6) {
                    Text("お気に入りのスレ")
                    if favorites.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
        }

        Section {
            NavigationLink {
                HistoryView()
            } label: {
                LabeledContent {
                    Text("\(history.entries.count)")
                        .monospacedDigit()
                } label: {
                    Label("閲覧履歴", systemImage: "clock.arrow.circlepath")
                }
            }
            NavigationLink {
                SavedThreadsView()
            } label: {
                LabeledContent {
                    Text("\(saved.entries.count)")
                        .monospacedDigit()
                } label: {
                    Label("保存したスレ", systemImage: "arrow.down.circle")
                }
            }
        } header: {
            Text("ライブラリ")
        } footer: {
            if favorites.boards.isEmpty && favorites.threads.isEmpty {
                Text("板やスレを長押し、または右にスワイプすると、お気に入りに追加できます。")
            }
        }
    }
}

/// A thread row for library lists, where the board isn't obvious from
/// context the way it is inside `BoardView`.
struct LibraryThreadRow: View {
    let title: String
    let boardName: String
    var detail: String? = nil
    var responseCount: Int? = nil
    var unreadCount: Int? = nil
    var isArchived: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(boardName)
                    if let detail {
                        Text(verbatim: "·")
                        Text(detail)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                if let responseCount, responseCount >= 0 {
                    Chip(text: "\(responseCount)", systemImage: "message.fill",
                         tint: isArchived ? .secondary : .accentColor)
                }
                if let unreadCount {
                    Chip(text: "+\(unreadCount)", tint: .red)
                }
                if isArchived {
                    Chip(text: String(localized: "dat落ち"), tint: .secondary, filled: false)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// 閲覧履歴: threads the user has opened, newest first.
struct HistoryView: View {
    @State private var history = HistoryStore.shared
    /// The list shows a snapshot taken when the screen appears. Opening a
    /// thread moves it to the top of the history, and reordering the rows of
    /// a List while one of them is pushed can pop the user straight back out.
    @State private var entries: [HistoryEntry] = []
    @State private var confirmClear = false

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView("閲覧履歴はありません",
                                       systemImage: "clock",
                                       description: Text("開いたスレがここに表示されます。"))
            } else {
                List {
                    ForEach(entries) { entry in
                        NavigationLink {
                            ThreadView(thread: entry.thread,
                                       boardURL: entry.boardURL,
                                       boardName: entry.boardName)
                        } label: {
                            LibraryThreadRow(title: entry.title,
                                             boardName: entry.boardName,
                                             detail: entry.lastViewed.formatted(.relative(presentation: .named)),
                                             responseCount: entry.responseCount)
                        }
                    }
                    .onDelete { offsets in
                        for entry in offsets.map({ entries[$0] }) {
                            history.remove(id: entry.id)
                        }
                        entries.remove(atOffsets: offsets)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("閲覧履歴")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("消去", role: .destructive) {
                    confirmClear = true
                }
                .disabled(entries.isEmpty)
            }
        }
        .confirmationDialog("閲覧履歴をすべて消去しますか？",
                            isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("すべて消去", role: .destructive) {
                history.clear()
                entries = []
            }
        }
        .onAppear {
            entries = history.entries
        }
    }
}

/// 保存したスレ: threads saved for offline reading.
struct SavedThreadsView: View {
    @State private var saved = SavedThreadStore.shared
    /// Snapshot, for the same reason as `HistoryView`: reopening a saved
    /// thread refreshes its copy, which moves it to the top.
    @State private var entries: [SavedThreadInfo] = []
    @State private var totalBytes: Int64 = 0

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView("保存したスレはありません",
                                       systemImage: "arrow.down.circle",
                                       description: Text("スレの右上のメニューから「オフライン用に保存」を選ぶと、電波がなくても読めます。"))
            } else {
                List {
                    Section {
                        ForEach(entries) { info in
                            NavigationLink {
                                ThreadView(thread: info.thread,
                                           boardURL: info.boardURL,
                                           boardName: info.boardName)
                            } label: {
                                LibraryThreadRow(title: info.title,
                                                 boardName: info.boardName,
                                                 detail: info.savedAt.formatted(date: .numeric, time: .shortened),
                                                 responseCount: info.postCount)
                            }
                        }
                        .onDelete { offsets in
                            for info in offsets.map({ entries[$0] }) {
                                saved.delete(boardURL: info.boardURL, threadId: info.threadId)
                            }
                            entries.remove(atOffsets: offsets)
                            totalBytes = saved.totalBytes()
                        }
                    } footer: {
                        Text("合計 \(totalBytes.formatted(.byteCount(style: .file)))・本文のみ保存（画像は保存されません）。開くたびに最新の内容に更新されます。")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("保存したスレ")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            entries = saved.entries
            totalBytes = saved.totalBytes()
        }
    }
}
