//
//  ContentView.swift
//  Donguri
//
//  Created by John Connery on 6/14/26.
//

import SwiftUI

/// Tabs along the bottom, as in Chance: browse boards (with browser tabs of
/// its own), saved threads, history, the dictionary, and settings.
struct ContentView: View {
    @State private var navigator = AppNavigator.shared
    @State private var favorites = FavoritesStore.shared
    @State private var appearance = AppearanceSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    /// New replies across all favorite threads, as the 保存 tab's badge.
    private var unreadFavorites: Int {
        favorites.threads.reduce(0) { $0 + (favorites.unreadCount(for: $1) ?? 0) }
    }

    var body: some View {
        TabView(selection: $navigator.rootTab) {
            BrowserTabsView()
                .tabItem { Label("板", systemImage: "rectangle.stack") }
                .tag(RootTab.boards)

            SavedTabView()
                .tabItem { Label("保存", systemImage: "star") }
                .badge(unreadFavorites)
                .tag(RootTab.saved)

            BrowserView()
                .tabItem { Label("ブラウザ", systemImage: "safari") }
                .tag(RootTab.browser)

            NavigationStack {
                DictionarySearchView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            ScanPhotoButton()
                        }
                    }
            }
            .tabItem { Label("辞書", systemImage: "character.book.closed.ja") }
            .tag(RootTab.dictionary)

            SettingsView(showsCloseButton: false)
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(RootTab.settings)
        }
        .modifier(ThemedTabBar(palette: appearance.palette))
        .overlay {
            NavigatorToast()
        }
        // Text recognition on a photo, screenshot or web page.
        .fullScreenCover(item: $navigator.scanRequest) { request in
            GalleryView(items: [request.item],
                        documentTitle: request.title,
                        startWithOCR: true) {
                withTransaction(Transaction.noAnimation) { navigator.scanRequest = nil }
            }
            .presentationBackground(.clear)
        }
        .onAppear {
            // 履歴 moved into the 保存 tab.
            if navigator.rootTab == .history {
                navigator.rootTab = .saved
            }
        }
        // The automatic theme follows the system's light or dark mode.
        .onChange(of: colorScheme, initial: true) { _, scheme in
            appearance.systemIsDark = scheme == .dark
        }
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
