//
//  MangaSearchView.swift
//  Donguri
//
//  One search across every installed source at once, as Aidoku and Mihon
//  do it: each source's first page of results in its own row, filled in as
//  the source answers (a few sources at a time, none allowed to hold the
//  rest up for long), sources with results first. Books in the Manga
//  folder whose titles match come first of all.
//

import SwiftUI
import AidokuRunner

struct MangaSearchView: View {
    @State private var sources = MangaSources.shared
    @State private var local = LocalMangaLibrary.shared
    @State private var query = ""
    @State private var submitted = ""
    @State private var results: [String: SourceResult] = [:]
    @State private var searchTask: Task<Void, Never>?
    @AppStorage("iroha.manga.searchHistory") private var historyData = Data()

    private enum SourceResult: Sendable {
        case loading
        case found([AidokuRunner.Manga])
        case failed(String)

        var entries: [AidokuRunner.Manga] {
            if case .found(let entries) = self { entries } else { [] }
        }
    }

    /// Sources asked at the same time; more made slow ones slower still.
    private static let concurrency = 4
    private static let timeout: Duration = .seconds(25)

    private var history: [String] {
        (try? JSONDecoder().decode([String].self, from: historyData)) ?? []
    }

    private var localMatches: [LocalSeries] {
        guard !submitted.isEmpty else { return [] }
        return local.series.filter { series in
            series.title.localizedCaseInsensitiveContains(submitted)
                || series.volumes.contains { $0.title.localizedCaseInsensitiveContains(submitted) }
        }
    }

    /// Sources with results first, then those still searching, then the
    /// rest; each group in name order.
    private var ordered: [AidokuRunner.Source] {
        sources.installedSources.sorted { a, b in
            rank(a.key) < rank(b.key)
        }
    }

    private func rank(_ key: String) -> Int {
        switch results[key] {
        case .found(let entries) where !entries.isEmpty: 0
        case .loading: 1
        case .found: 2
        case .failed: 3
        case nil: 4
        }
    }

    private var searching: Int {
        results.values.filter { if case .loading = $0 { true } else { false } }.count
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if submitted.isEmpty {
                    startContent
                } else {
                    if !localMatches.isEmpty {
                        localRow
                    } else if sources.installed.isEmpty {
                        ContentUnavailableView.search(text: submitted)
                            .padding(.top, 40)
                    }
                    ForEach(ordered, id: \.key) { source in
                        sourceRow(source)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(Text("すべてのソースを検索"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("タイトル"))
        .onSubmit(of: .search) { search(query) }
        .toolbar {
            if searching > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("\(searching)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            await sources.loadInstalled()
            await local.scanIfNeeded()
        }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: Pieces

    @ViewBuilder
    private var startContent: some View {
        if sources.installed.isEmpty {
            ContentUnavailableView {
                Label("ソースがありません", systemImage: "puzzlepiece.extension")
            } description: {
                Text("Aidoku のソースリストを追加して、そこからソースをインストールしてください。")
            }
            .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(sources.installed.count)個のソースと端末のマンガを検索します。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !history.isEmpty {
                    HStack {
                        Text("最近の検索")
                            .font(.headline)
                        Spacer()
                        Button("消去") { historyData = Data() }
                            .font(.subheadline)
                    }
                    .padding(.top, 8)
                    ForEach(history, id: \.self) { item in
                        Button {
                            query = item
                            search(item)
                        } label: {
                            Label(item, systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var localRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("この端末")
                .font(.headline)
                .padding(.horizontal, 16)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(localMatches) { series in
                        NavigationLink(value: MangaRoute.localSeries(series.id)) {
                            ResultCard(title: series.title,
                                       saved: MangaLibrary.shared.isSaved(local: series.id)) {
                                LocalCover(volume: series.volumes.first)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            LibraryMenuItems(target: .local(seriesID: series.id, title: series.title))
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func sourceRow(_ source: AidokuRunner.Source) -> some View {
        let result = results[source.key]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: source.name)
                    .font(.headline)
                if !source.languages.isEmpty {
                    Text(verbatim: source.languages.prefix(3).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if case .found(let entries) = result, !entries.isEmpty {
                    NavigationLink(value: MangaRoute.sourceSearch(source.key, submitted)) {
                        Label("もっと見る", systemImage: "chevron.right")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal, 16)

            switch result {
            case .loading, nil:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("検索中…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
            case .failed(let message):
                HStack(spacing: 8) {
                    Text(verbatim: message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("再試行") { searchOne(source, query: submitted) }
                        .font(.subheadline)
                }
                .padding(.horizontal, 16)
            case .found(let entries) where entries.isEmpty:
                Text("見つかりませんでした")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            case .found(let entries):
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, manga in
                            NavigationLink(value: MangaRoute.manga(source: source.key, manga: manga)) {
                                ResultCard(title: manga.title,
                                           saved: MangaLibrary.shared.isSaved(source: source.key, manga: manga.key)) {
                                    MangaCover(url: manga.cover, sourceKey: source.key)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                LibraryMenuItems(target: .source(key: source.key, manga: manga))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: Searching

    private func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        submitted = trimmed
        results = [:]
        guard !trimmed.isEmpty else { return }
        remember(trimmed)
        let all = sources.installedSources
        for source in all { results[source.key] = .loading }
        searchTask = Task {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func add() {
                    guard next < all.count else { return }
                    let source = all[next]
                    next += 1
                    group.addTask { await run(source, query: trimmed) }
                }
                for _ in 0..<min(Self.concurrency, all.count) { add() }
                for await _ in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    add()
                }
            }
        }
    }

    private func searchOne(_ source: AidokuRunner.Source, query: String) {
        results[source.key] = .loading
        Task { await run(source, query: query) }
    }

    /// One source's first page, or why there isn't one. A source that
    /// takes too long is given up on, so it can't hold the others back.
    private func run(_ source: AidokuRunner.Source, query: String) async {
        let outcome: SourceResult = await withTaskGroup(of: SourceResult?.self) { group in
            group.addTask {
                do {
                    let page = try await source.getSearchMangaList(query: query, page: 1, filters: [])
                    return .found(page.entries)
                } catch {
                    return .failed(Self.message(for: error))
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.timeout)
                return Task.isCancelled ? nil : .failed(String(localized: "時間がかかりすぎました"))
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failed(String(localized: "時間がかかりすぎました"))
        }
        // A newer search has replaced this one.
        guard submitted == query else { return }
        results[source.key] = outcome
    }

    private nonisolated static func message(for error: Error) -> String {
        if let error = error as? SourceError {
            return switch error {
            case .unimplemented: String(localized: "このソースは検索に対応していません")
            default: String(localized: "検索できませんでした")
            }
        }
        return UserFacingError.message(for: error)
    }

    private func remember(_ text: String) {
        var items = history.filter { $0 != text }
        items.insert(text, at: 0)
        historyData = (try? JSONEncoder().encode(Array(items.prefix(12)))) ?? Data()
    }
}

/// A cover with its title under it, for the rows of results.
private struct ResultCard<Cover: View>: View {
    let title: String
    var saved = false
    @ViewBuilder let cover: () -> Cover

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            cover()
                .frame(width: 96, height: 144)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if saved {
                        Image(systemName: "bookmark.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Circle().fill(Color.accentColor))
                            .padding(4)
                    }
                }
            Text(verbatim: title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 96, alignment: .leading)
        }
    }
}
