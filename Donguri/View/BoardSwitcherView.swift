//
//  BoardSwitcherView.swift
//  Donguri
//
//  Opened by tapping a board's name: jump straight to another board without
//  going back to the board menu. Favorites first, then recently visited
//  boards, then every board (from the saved menu, so it works offline).
//

import SwiftUI

struct BoardSwitcherView: View {
    let currentBoardURL: String
    var onPick: (FavoriteBoard) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var favorites = FavoritesStore.shared
    @State private var categories: [BBSMenu.MenuList] = []
    @State private var recent: [FavoriteBoard] = []

    var body: some View {
        NavigationStack {
            List {
                let favoriteMatches = filter(favorites.boards)
                if !favoriteMatches.isEmpty {
                    Section("お気に入りの板") {
                        ForEach(favoriteMatches) { row($0, icon: "star.fill", tint: .yellow) }
                    }
                }
                let recentMatches = filter(recent)
                if !recentMatches.isEmpty {
                    Section("最近見た板") {
                        ForEach(recentMatches) { row($0, icon: "clock", tint: .secondary) }
                    }
                }
                ForEach(categories) { category in
                    let boards = filter(category.categoryContent.map { FavoriteBoard($0) })
                    if !boards.isEmpty {
                        Section(category.categoryName) {
                            ForEach(boards) { row($0, icon: "bubble.left.and.bubble.right", tint: .accentColor) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "板を検索")
            .themedScreen()
            .navigationTitle("板を切り替え")
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
            .task {
                load()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ board: FavoriteBoard, icon: String, tint: Color) -> some View {
        Button {
            onPick(board)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 22)
                Text(board.boardName)
                    .foregroundStyle(.primary)
                Spacer()
                if board.url == currentBoardURL {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedRow()
    }

    private func filter(_ boards: [FavoriteBoard]) -> [FavoriteBoard] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return boards }
        return boards.filter {
            $0.boardName.localizedCaseInsensitiveContains(query) || $0.directoryName.localizedCaseInsensitiveContains(query)
        }
    }

    private func load() {
        let menu = BBSMenuService().cachedBBSMenu()
        categories = menu?.menuList ?? []

        // Boards of recently read threads, most recent first.
        let known: [String: FavoriteBoard] = Dictionary(
            (menu?.menuList.flatMap(\.categoryContent) ?? []).map { ($0.url, FavoriteBoard($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set(favorites.boards.map(\.url))
        var boards: [FavoriteBoard] = []
        for entry in HistoryStore.shared.entries where !seen.contains(entry.boardURL) {
            seen.insert(entry.boardURL)
            let board = known[entry.boardURL] ?? FavoriteBoard(boardName: entry.boardName,
                                                              url: entry.boardURL,
                                                              directoryName: BoardNames.fallback(for: entry.boardURL))
            boards.append(board)
            if boards.count >= 8 { break }
        }
        recent = boards
    }
}
