//
//  ThreadSearchView.swift
//  Donguri
//
//  スレタイ検索 across 5ch (see ThreadSearchService).
//

import SwiftUI

struct ThreadSearchView: View {
    var initialQuery: String = ""

    @State private var query = ""
    @State private var submitted = ""
    @State private var results: [ThreadSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var favorites = FavoritesStore.shared
    @AppStorage("donguri.searchScope") private var scopeRaw = ThreadSearchScope.all.rawValue
    @AppStorage("donguri.searchSort") private var sortRaw = ThreadSearchSort.relevance.rawValue
    @AppStorage("donguri.searchHistory") private var historyRaw = ""
    @Environment(\.openURL) private var openURL

    private var scope: ThreadSearchScope { ThreadSearchScope(rawValue: scopeRaw) ?? .all }
    private var sort: ThreadSearchSort { ThreadSearchSort(rawValue: sortRaw) ?? .relevance }
    private var history: [String] {
        historyRaw.split(separator: "\n").map(String.init)
    }

    var body: some View {
        List {
            Section {
                Picker("範囲", selection: $scopeRaw) {
                    ForEach(ThreadSearchScope.allCases) { scope in
                        Text(scope.title).tag(scope.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            if submitted.isEmpty {
                if !history.isEmpty {
                    Section {
                        ForEach(history, id: \.self) { item in
                            Button {
                                query = item
                                run(item)
                            } label: {
                                Label(item, systemImage: "clock.arrow.circlepath")
                                    .foregroundStyle(.primary)
                            }
                            .themedRow()
                        }
                        Button("履歴を消去", role: .destructive) {
                            historyRaw = ""
                        }
                        .themedRow()
                    } header: {
                        Text("最近の検索")
                    }
                }
                Section {
                    EmptyView()
                } footer: {
                    if scope == .all {
                        Text("5ちゃんねるの公式検索（find.5ch.io）で、すべての板と過去ログのスレタイを検索します。スペースで区切るとAND検索になります。")
                    } else {
                        Text("お気に入りの板と最近見た板のスレ一覧から検索します。")
                    }
                }
            } else if isSearching {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 30)
                .listRowBackground(Color.clear)
            } else if let errorMessage {
                Section {
                    ContentUnavailableView {
                        Label("検索できませんでした", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("再試行") { run(submitted) }
                        if scope == .all, let url = ThreadSearchService.webURL(for: submitted) {
                            Button("Safariで開く") { openURL(url) }
                        }
                    }
                }
                .listRowBackground(Color.clear)
            } else if results.isEmpty {
                ContentUnavailableView.search(text: submitted)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(sort.sorted(results)) { result in
                        NavigationLink(value: BrowseRoute.thread(result.link)) {
                            SearchResultRow(result: result)
                        }
                        .themedRow()
                        .threadContextMenu(result.link) {
                            let isFavorite = favorites.isFavorite(boardURL: result.link.boardURL,
                                                                  threadId: result.link.threadId)
                            Button {
                                favorites.toggle(boardURL: result.link.boardURL,
                                                 boardName: result.link.boardName ?? "",
                                                 threadId: result.link.threadId,
                                                 title: result.link.title ?? String(localized: "無題"),
                                                 responseCount: result.link.responseCount)
                                Haptics.play(.success)
                            } label: {
                                if isFavorite {
                                    Label("お気に入りから削除", systemImage: "star.slash")
                                } else {
                                    Label("お気に入りに追加", systemImage: "star")
                                }
                            }
                        }
                    }
                } header: {
                    Text("\(results.count)件")
                }
            }
        }
        .listStyle(.insetGrouped)
        .themedScreen()
        .searchable(text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "スレタイを検索")
        .onSubmit(of: .search) {
            run(query)
        }
        .onChange(of: scopeRaw) {
            if !submitted.isEmpty { run(submitted) }
        }
        .navigationTitle("スレタイ検索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("並び替え", selection: $sortRaw) {
                        ForEach(ThreadSearchSort.allCases) { sort in
                            Label(sort.title, systemImage: sort.systemImage).tag(sort.rawValue)
                        }
                    }
                    if scope == .all, !submitted.isEmpty, let url = ThreadSearchService.webURL(for: submitted) {
                        Divider()
                        Button {
                            openURL(url)
                        } label: {
                            Label("Safariで開く", systemImage: "safari")
                        }
                    }
                } label: {
                    Image(systemName: sort == .relevance
                          ? "arrow.up.arrow.down.circle"
                          : "arrow.up.arrow.down.circle.fill")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                TabsToolbarButton()
            }
        }
        .onAppear {
            if submitted.isEmpty, !initialQuery.isEmpty {
                query = initialQuery
                run(initialQuery)
            }
        }
    }

    private func run(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submitted = trimmed
        remember(trimmed)
        isSearching = true
        errorMessage = nil
        let scope = self.scope
        Task {
            let service = ThreadSearchService()
            do {
                let found: [ThreadSearchResult]
                switch scope {
                case .all:
                    found = try await service.searchAllBoards(trimmed)
                case .myBoards:
                    found = await service.searchBoards(ThreadSearchService.myBoards(), query: trimmed)
                }
                guard submitted == trimmed else { return }
                results = found
            } catch {
                guard submitted == trimmed else { return }
                errorMessage = error.localizedDescription
                results = []
            }
            isSearching = false
        }
    }

    private func remember(_ text: String) {
        var items = history.filter { $0 != text }
        items.insert(text, at: 0)
        historyRaw = items.prefix(15).joined(separator: "\n")
    }
}

private struct SearchResultRow: View {
    let result: ThreadSearchResult

    @State private var appearance = AppearanceSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(result.link.title ?? String(localized: "無題"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(appearance.palette.map { Color(uiColor: $0.title) } ?? .primary)
                .lineLimit(3)
            HStack(spacing: 10) {
                Text(result.link.boardName ?? BoardNames.fallback(for: result.link.boardURL))
                    .lineLimit(1)
                if result.link.responseCount >= 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrowshape.turn.up.left")
                        Text(verbatim: "\(result.link.responseCount)")
                    }
                }
                if let momentum = result.momentum {
                    HStack(spacing: 3) {
                        Image(systemName: "flame")
                        Text(verbatim: momentum.momentumLabel)
                    }
                }
                if result.isArchived {
                    Text("過去ログ")
                        .padding(.horizontal, 4)
                        .overlay(Capsule().stroke(Color.secondary.opacity(0.5), lineWidth: 1))
                }
                Spacer(minLength: 0)
                if let lastPost = result.lastPost {
                    Text(verbatim: PostDate.relativeLabel(for: lastPost))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
