//
//  ContentView.swift
//  Donguri
//
//  Created by John Connery on 6/14/26.
//

import SwiftUI

/// Tabs along the bottom, as in Chance: browse boards, saved threads,
/// history, the dictionary, and settings.
struct ContentView: View {
    enum RootTab: String {
        case boards, saved, history, dictionary, settings
    }

    @AppStorage("donguri.rootTab") private var selectionRaw = RootTab.boards.rawValue
    @State private var favorites = FavoritesStore.shared
    @State private var appearance = AppearanceSettings.shared

    private var selection: Binding<RootTab> {
        Binding(get: { RootTab(rawValue: selectionRaw) ?? .boards },
                set: { selectionRaw = $0.rawValue })
    }

    /// New replies across all favorite threads, as the 保存 tab's badge.
    private var unreadFavorites: Int {
        favorites.threads.reduce(0) { $0 + (favorites.unreadCount(for: $1) ?? 0) }
    }

    var body: some View {
        TabView(selection: selection) {
            BBSMenuView()
                .tabItem { Label("板", systemImage: "rectangle.stack") }
                .tag(RootTab.boards)

            SavedTabView()
                .tabItem { Label("保存", systemImage: "star") }
                .badge(unreadFavorites)
                .tag(RootTab.saved)

            NavigationStack {
                HistoryView()
            }
            .tabItem { Label("履歴", systemImage: "clock") }
            .tag(RootTab.history)

            NavigationStack {
                DictionarySearchView()
            }
            .tabItem { Label("辞書", systemImage: "character.book.closed.ja") }
            .tag(RootTab.dictionary)

            SettingsView(showsCloseButton: false)
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(RootTab.settings)
        }
        .modifier(ThemedTabBar(palette: appearance.palette))
        .task {
            await favorites.refreshThreadCounts()
        }
    }
}

private struct ThemedTabBar: ViewModifier {
    let palette: ThemePalette?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let palette {
            content
                .toolbarBackground(Color(uiColor: palette.bar), for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        } else {
            content
        }
    }
}

#Preview {
    ContentView()
}
