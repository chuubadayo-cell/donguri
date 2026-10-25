//
//  BBSMenuView.swift
//  Donguri
//
//  Created by John Connery on 6/16/26.
//

import SwiftUI

struct BBSMenuView: View {
    @State private var menu: BBSMenu?
    @State private var errorMessage: String?
    @State private var searchText: String = ""

    var body: some View {
        List {
            // The library sits above the board menu and doesn't depend on
            // it, so favorites, history and saved threads stay reachable
            // when the menu can't load (e.g. offline).
            if searchText.isEmpty {
                Section {
                    NavigationLink(value: BrowseRoute.search("")) {
                        Label("スレタイ検索（全板）", systemImage: "magnifyingglass")
                    }
                    .themedRow()
                }

                FavoriteBoardsSection()
            }

            if let menu {
                Section {
                    ForEach(filteredMenuList(menu)) { category in
                        CategoryDisclosureView(category: category, searchText: searchText)
                            .themedRow()
                    }
                } header: {
                    if searchText.isEmpty {
                        Text("板一覧")
                    }
                }
            } else if let errorMessage {
                Section {
                    ContentUnavailableView {
                        Label("読み込めませんでした", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("再試行") {
                            self.errorMessage = nil
                            Task { await loadMenu() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .themedRow()
                }
            } else {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("しばらくお待ちください...")
                        Spacer()
                    }
                    .padding(.vertical, 24)
                }
            }
        }
        .listStyle(.insetGrouped)
        // Attached to the stack's root rather than the stack itself, so
        // boards pushed on top can have a search field of their own.
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "フィルタ"
        )
        .refreshable {
            await loadMenu()
            await FavoritesStore.shared.refreshThreadCounts()
        }
        .navigationTitle("５ちゃんねる")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                TabsToolbarButton()
            }
        }
        .themedScreen()
        .task {
            await loadMenu()
            await FavoritesStore.shared.refreshThreadCounts()
        }
    }

    private func filteredMenuList(_ menu: BBSMenu) -> [BBSMenu.MenuList] {
        guard !searchText.isEmpty else { return menu.menuList }
        return menu.menuList.filter {
            $0.categoryContent.contains(where: { $0.boardName.localizedCaseInsensitiveContains(searchText) })
        }
    }

    private func loadMenu() async {
        let service = BBSMenuService()
        // Show the saved menu straight away; the fresh one replaces it.
        if menu == nil {
            menu = service.cachedBBSMenu()
        }
        do {
            errorMessage = nil
            let newMenu = try await service.fetchBBSMenu()
            menu = newMenu
        } catch {
            // With a saved menu on screen, being offline isn't worth an error.
            if menu == nil, !UserFacingError.isCancellation(error) {
                errorMessage = UserFacingError.message(for: error)
            }
            print("BBSMenuView Error: \(error)")
        }
    }
}

struct CategoryDisclosureView: View {
    let category: BBSMenu.MenuList
    let searchText: String

    @State private var favorites = FavoritesStore.shared

    var filteredCategoryContent: [BBSMenu.CategoryContent] {
        guard !searchText.isEmpty else { return category.categoryContent }
        return category.categoryContent.filter {
            $0.boardName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        DisclosureGroup() {
            ForEach(filteredCategoryContent) { board in
                let isFavorite = favorites.isFavorite(boardURL: board.url)
                NavigationLink(value: BrowseRoute.board(FavoriteBoard(board))) {
                    HStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .foregroundStyle(Color.accentColor)
                        Text(board.boardName)
                            .foregroundStyle(.primary)
                        if isFavorite {
                            Spacer()
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                        }
                    }
                }
                .themedRow()
                .contextMenu {
                    FavoriteBoardButton(board: board, isFavorite: isFavorite)
                    BoardTabButtons(board: FavoriteBoard(board))
                }
                .swipeActions(edge: .trailing) {
                    FavoriteBoardButton(board: board, isFavorite: isFavorite)
                        .tint(.yellow)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(category.categoryName)
                    .font(.headline)
                Chip(text: "\(filteredCategoryContent.count)", tint: .secondary, filled: false)
            }
        }
    }
}

struct FavoriteBoardButton: View {
    let board: BBSMenu.CategoryContent
    let isFavorite: Bool

    var body: some View {
        Button {
            FavoritesStore.shared.toggle(board: board)
        } label: {
            if isFavorite {
                Label("お気に入りから削除", systemImage: "star.slash")
            } else {
                Label("お気に入りに追加", systemImage: "star")
            }
        }
    }
}

/// "Open in a new tab" for a board.
struct BoardTabButtons: View {
    let board: FavoriteBoard
    @Environment(BrowseContext.self) private var browseContext: BrowseContext?
    private var browse: BrowseContext { browseContext ?? .detached }

    var body: some View {
        Section {
            Button {
                browse.openInNewTab(.board(board), inBackground: false)
            } label: {
                Label("新しいタブで開く", systemImage: "plus.square.on.square")
            }
            Button {
                browse.openInNewTab(.board(board), inBackground: true)
            } label: {
                Label("バックグラウンドで開く", systemImage: "square.on.square.dashed")
            }
        }
    }
}

#Preview {
    BBSMenuView()
}
