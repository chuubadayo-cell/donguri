//
//  LibraryViews.swift
//  Donguri
//
//  The user's library: favorite boards (above the board menu), the 保存 tab
//  (favorite threads and offline copies) and the 履歴 tab.
//

import SwiftUI

/// Favorite boards, pinned above the board menu.
struct FavoriteBoardsSection: View {
    @State private var favorites = FavoritesStore.shared

    var body: some View {
        Section {
            ForEach(favorites.boards) { board in
                NavigationLink(value: BrowseRoute.board(board)) {
                    HStack(spacing: 10) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                        Text(board.boardName)
                            .foregroundStyle(.primary)
                    }
                }
                .themedRow()
                .contextMenu {
                    BoardTabButtons(board: board)
                    Button(role: .destructive) {
                        withAnimation { favorites.removeBoard(url: board.url) }
                    } label: {
                        Label("お気に入りから削除", systemImage: "star.slash")
                    }
                }
            }
            .onDelete { favorites.removeBoards(atOffsets: $0) }
            .onMove { favorites.moveBoards(fromOffsets: $0, toOffset: $1) }
        } header: {
            Text("お気に入りの板")
        } footer: {
            if favorites.boards.isEmpty {
                Text("板やスレを長押し、または左にスワイプすると、お気に入りに追加できます。")
            }
        }
    }
}

/// The 保存 tab, like Chance's Saved tab: favorite threads with their new
/// replies, and threads kept for offline reading.
struct SavedTabView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case favorites, offline, history
        var id: String { rawValue }
    }

    @State private var favorites = FavoritesStore.shared
    @AppStorage("donguri.savedTabSegment") private var segmentRaw = Segment.favorites.rawValue

    private var segment: Segment { Segment(rawValue: segmentRaw) ?? .favorites }

    var body: some View {
        RouteStack {
            Group {
                switch segment {
                case .favorites:
                    FavoriteThreadsList()
                case .offline:
                    SavedThreadsView()
                case .history:
                    HistoryView()
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("表示", selection: $segmentRaw) {
                    Text("お気に入り").tag(Segment.favorites.rawValue)
                    Text("オフライン保存").tag(Segment.offline.rawValue)
                    Text("履歴").tag(Segment.history.rawValue)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }
}

/// Favorite threads, refreshed for new replies when shown.
struct FavoriteThreadsList: View {
    @State private var favorites = FavoritesStore.shared

    var body: some View {
        Group {
            if favorites.threads.isEmpty {
                ContentUnavailableView("お気に入りのスレはありません",
                                       systemImage: "star",
                                       description: Text("スレの☆をタップするか、一覧でスレを右にスワイプすると追加できます。"))
            } else {
                List {
                    ForEach(favorites.threads) { favorite in
                        let link = favorite.link
                        NavigationLink(value: BrowseRoute.thread(link)) {
                            LibraryThreadRow(title: favorite.title,
                                             boardName: favorite.boardName,
                                             responseCount: favorite.responseCount,
                                             unreadCount: favorites.unreadCount(for: favorite),
                                             isArchived: favorite.isArchived)
                        }
                        .threadContextMenu(link) {
                            Button(role: .destructive) {
                                withAnimation { favorites.remove(favorite) }
                                Haptics.play(.light)
                            } label: {
                                Label("お気に入りから削除", systemImage: "star.slash")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                withAnimation { favorites.remove(favorite) }
                                Haptics.play(.light)
                            } label: {
                                Label("削除", systemImage: "star.slash")
                            }
                        }
                    }
                    .onDelete { favorites.removeThreads(atOffsets: $0) }
                    .onMove { favorites.moveThreads(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .refreshable {
                    await favorites.refreshThreadCounts()
                }
            }
        }
        .navigationTitle("お気に入り")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !favorites.threads.isEmpty {
                    // Delete several at once, or drag to reorder.
                    EditButton()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if favorites.isRefreshing {
                    ProgressView()
                }
            }
        }
        .themedScreen()
        .task {
            await favorites.refreshThreadCounts()
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
                        let link = entry.link
                        NavigationLink(value: BrowseRoute.thread(link)) {
                            LibraryThreadRow(title: entry.title,
                                             boardName: entry.boardName,
                                             detail: entry.lastViewed.formatted(.relative(presentation: .named)),
                                             responseCount: entry.responseCount)
                        }
                        .threadContextMenu(link)
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
        .themedScreen()
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
                            let link = info.link
                            NavigationLink(value: BrowseRoute.thread(link)) {
                                LibraryThreadRow(title: info.title,
                                                 boardName: info.boardName,
                                                 detail: info.savedAt.formatted(date: .numeric, time: .shortened),
                                                 responseCount: info.postCount)
                            }
                            .threadContextMenu(link)
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
        .themedScreen()
        .navigationTitle("保存したスレ")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            entries = saved.entries
            totalBytes = saved.totalBytes()
        }
    }
}
