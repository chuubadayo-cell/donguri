//
//  ContentView.swift
//  Donguri
//
//  Created by John Connery on 6/14/26.
//

import SwiftUI

/// Tabs along the bottom, as in Chance: browse boards (with browser tabs of
/// its own), saved threads, the browser, manga, and the dictionary (whose
/// gear opens settings).
struct ContentView: View {
    @State private var navigator = AppNavigator.shared
    @State private var favorites = FavoritesStore.shared
    @State private var appearance = AppearanceSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsSettings = false

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

            MangaHomeView()
                .tabItem { Label("マンガ", systemImage: "book.pages") }
                .tag(RootTab.manga)

            NavigationStack {
                DictionarySearchView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                showsSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityLabel(Text("設定"))
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            ScanPhotoButton()
                        }
                    }
            }
            .tabItem { Label("辞書", systemImage: "character.book.closed.ja") }
            .tag(RootTab.dictionary)
        }
        // On its own view, apart from the scanner's cover.
        .background {
            Color.clear
                .sheet(isPresented: $showsSettings) {
                    SettingsView(showsCloseButton: true)
                }
        }
        .modifier(ThemedTabBar(palette: appearance.palette))
        .overlay {
            NavigatorToast()
        }
        // The video player sits over the tabs rather than being presented,
        // so it can shrink to the miniplayer and keep playing.
        .overlay {
            if let item = navigator.videoRequest {
                VideoPlayerView(item: item,
                                minimized: navigator.videoMinimized,
                                onMinimize: { navigator.minimizeVideo() },
                                onExpand: { navigator.expandVideo() },
                                onClose: { navigator.closeVideo() })
                    .id(item.id)
                    // Closing animates inside the player (VideoPlayerView.close);
                    // only opening slides in from here.
                    .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .identity))
            }
        }
        .animation(.snappy(duration: 0.3), value: navigator.videoRequest?.id)
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
            // 履歴 moved into the 保存 tab, and 設定 out of the tab bar.
            if navigator.rootTab == .history {
                navigator.rootTab = .saved
            } else if navigator.rootTab == .settings {
                navigator.rootTab = .dictionary
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
