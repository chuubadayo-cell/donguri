//
//  MangaSourceViews.swift
//  Donguri
//
//  Aidoku sources in the マンガ tab: the installed ones, adding source
//  lists and installing from them, browsing or searching a source, and a
//  manga's page with its chapters.
//

import SwiftUI
import AidokuRunner

// MARK: - Installed

struct InstalledSourcesList: View {
    @State private var sources = MangaSources.shared

    var body: some View {
        List {
            if sources.installed.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ソースがありません")
                            .font(.headline)
                        Text("Aidoku のソースリストを追加して、そこからソースをインストールしてください。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section {
                    ForEach(sources.installedSources, id: \.key) { source in
                        NavigationLink(value: MangaRoute.source(source.key)) {
                            SourceRow(name: source.name, iconURL: source.imageUrl,
                                      detail: source.languages.joined(separator: ", "))
                        }
                    }
                }
            }
            Section {
                NavigationLink(value: MangaRoute.manageSources) {
                    Label("ソースを管理", systemImage: "puzzlepiece.extension")
                }
            }
        }
    }
}

private struct SourceRow: View {
    let name: String
    let iconURL: URL?
    var detail: String = ""

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let iconURL, iconURL.isFileURL, let image = UIImage(contentsOfFile: iconURL.path) {
                    Image(uiImage: image).resizable()
                } else if let iconURL {
                    AsyncImage(url: iconURL) { image in
                        image.resizable()
                    } placeholder: {
                        Color.secondary.opacity(0.15)
                    }
                } else {
                    Image(systemName: "puzzlepiece")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                if !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Managing

struct ManageSourcesView: View {
    @State private var sources = MangaSources.shared
    @State private var addingList = false
    @State private var newListURL = ""
    @State private var filter = ""
    @State private var error: String?
    @AppStorage("iroha.manga.showNSFW") private var showNSFW = false

    private var available: [MangaSourceListing] {
        sources.availableSources.filter { listing in
            (showNSFW || !listing.isNSFW)
                && (filter.isEmpty || listing.name.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(sources.listURLs, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: sources.lists.first { $0.url == url }?.name ?? url.host() ?? url.absoluteString)
                        Text(verbatim: url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let message = sources.listErrors[url] {
                            Text(verbatim: message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            sources.removeList(url)
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
                Button {
                    newListURL = ""
                    addingList = true
                } label: {
                    Label("ソースリストを追加", systemImage: "plus")
                }
            } header: {
                Text("ソースリスト")
            }

            if !sources.installed.isEmpty {
                Section {
                    ForEach(sources.installedSources, id: \.key) { source in
                        SourceRow(name: source.name, iconURL: source.imageUrl,
                                  detail: String(localized: "バージョン \(source.version)"))
                            .swipeActions {
                                Button(role: .destructive) {
                                    sources.uninstall(source.key)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text("インストール済み")
                }
            }

            Section {
                Toggle("成人向けのソースも表示", isOn: $showNSFW)
                ForEach(available) { listing in
                    HStack {
                        SourceRow(name: listing.name, iconURL: listing.iconImageURL,
                                  detail: listing.languageList.joined(separator: ", "))
                        Spacer()
                        installButton(for: listing)
                    }
                }
            } header: {
                Text("ソース")
            }
        }
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic))
        .navigationTitle(Text("ソースを管理"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await sources.refreshLists() }
        .task { await sources.refreshLists() }
        .alert(Text("ソースリストを追加"), isPresented: $addingList) {
            TextField(text: $newListURL) { Text(verbatim: "https://…") }
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("追加") {
                let url = newListURL
                Task {
                    if !(await sources.addList(url)) {
                        error = String(localized: "ソースリストを読み込めませんでした")
                    }
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("Aidoku のソースリストのURL")
        }
        .alert(Text(verbatim: error ?? ""), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func installButton(for listing: MangaSourceListing) -> some View {
        let installed = sources.installedVersion(of: listing.id)
        if sources.installing.contains(listing.id) {
            ProgressView()
        } else if let installed, installed >= listing.version {
            Image(systemName: "checkmark")
                .foregroundStyle(.secondary)
        } else {
            Button(installed == nil ? String(localized: "入手") : String(localized: "更新")) {
                Task {
                    do {
                        try await sources.install(listing)
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

// MARK: - Browsing a source

struct SourceBrowseView: View {
    let sourceKey: String

    @State private var sources = MangaSources.shared
    @State private var listings: [AidokuRunner.Listing] = []
    @State private var listing: AidokuRunner.Listing?
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var entries: [AidokuRunner.Manga] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?
    @State private var generation = 0

    private var source: AidokuRunner.Source? { sources.installed[sourceKey] }

    var body: some View {
        ScrollView {
            if listings.count > 1, submittedQuery.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(listings, id: \.id) { item in
                            Button {
                                listing = item
                                Task { await reload() }
                            } label: {
                                Text(verbatim: item.name)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(item.id == listing?.id ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .padding(.top, 8)
            }
            if let error, entries.isEmpty {
                VStack(spacing: 12) {
                    Text(verbatim: error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("再試行") { Task { await reload() } }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 60)
                .padding(.horizontal, 24)
            }
            MangaGrid(items: entries.map { (sourceKey, $0) }) {
                if hasMore, !loading { Task { await loadMore() } }
            }
            .padding(16)
            if loading {
                ProgressView()
                    .padding()
            }
        }
        .navigationTitle(Text(verbatim: source?.name ?? sourceKey))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .onSubmit(of: .search) {
            submittedQuery = query
            Task { await reload() }
        }
        .onChange(of: query) { _, newValue in
            if newValue.isEmpty, !submittedQuery.isEmpty {
                submittedQuery = ""
                Task { await reload() }
            }
        }
        .refreshable { await reload() }
        .task {
            guard entries.isEmpty, let source else { return }
            if source.features.providesListings {
                listings = (try? await source.getListings()) ?? []
                listing = listings.first
            }
            await reload()
        }
    }

    private func reload() async {
        generation += 1
        page = 1
        entries = []
        hasMore = false
        error = nil
        await fetch(generation: generation)
    }

    private func loadMore() async {
        page += 1
        await fetch(generation: generation)
    }

    private func fetch(generation: Int) async {
        guard let source else {
            error = MangaSourceError.notInstalled.localizedDescription
            return
        }
        loading = true
        defer { loading = false }
        do {
            let result: MangaPageResult
            if submittedQuery.isEmpty, let listing, source.features.providesListings {
                result = try await source.getMangaList(listing: listing, page: page)
            } else {
                result = try await source.getSearchMangaList(query: submittedQuery.isEmpty ? nil : submittedQuery,
                                                             page: page, filters: [])
            }
            guard generation == self.generation else { return }
            let known = Set(entries.map(\.key))
            entries += result.entries.filter { !known.contains($0.key) }
            hasMore = result.hasNextPage && !result.entries.isEmpty
            if entries.isEmpty { error = String(localized: "見つかりませんでした") }
        } catch {
            guard generation == self.generation else { return }
            self.error = UserFacingError.message(for: error)
        }
    }
}

// MARK: - A manga

struct MangaDetailView: View {
    let sourceKey: String
    @State private var manga: AidokuRunner.Manga
    @State private var chapters: [AidokuRunner.Chapter] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showsFullDescription = false
    @State private var library = MangaLibrary.shared
    @State private var sources = MangaSources.shared

    init(sourceKey: String, manga: AidokuRunner.Manga) {
        self.sourceKey = sourceKey
        _manga = State(initialValue: manga)
    }

    private var source: AidokuRunner.Source? { sources.installed[sourceKey] }
    private var mangaID: String { MangaLibrary.mangaID(source: sourceKey, manga: manga.key) }

    private func unitID(_ chapter: AidokuRunner.Chapter) -> String {
        MangaLibrary.chapterID(source: sourceKey, manga: manga.key, chapter: chapter.key)
    }

    /// The chapter to carry on with: the last one opened, or the first.
    private var continueChapter: AidokuRunner.Chapter? {
        if let key = library.lastChapter(for: mangaID), let chapter = chapters.first(where: { $0.key == key }) {
            return chapter
        }
        return chapters.last { !$0.locked }
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                if let description = manga.description, !description.isEmpty {
                    Text(verbatim: description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(showsFullDescription ? nil : 4)
                        .onTapGesture { showsFullDescription.toggle() }
                }
                if let continueChapter {
                    Button {
                        open(continueChapter)
                    } label: {
                        Label {
                            Text(library.lastChapter(for: mangaID) == nil ? "読む" : "続きを読む")
                                + Text(verbatim: "  ") + Text(verbatim: continueChapter.displayTitle).foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "book")
                        }
                    }
                }
            }

            Section {
                if loading && chapters.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let error, chapters.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: error)
                            .foregroundStyle(.secondary)
                        Button("再試行") { Task { await load() } }
                    }
                }
                ForEach(chapters, id: \.key) { chapter in
                    chapterRow(chapter)
                }
            } header: {
                if !chapters.isEmpty {
                    Text("\(chapters.count)章")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(verbatim: manga.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let saved = library.isSaved(source: sourceKey, manga: manga.key)
                Button {
                    library.toggleSaved(source: sourceKey, manga: manga)
                } label: {
                    Image(systemName: saved ? "bookmark.fill" : "bookmark")
                }
                .accessibilityLabel(saved ? Text("ライブラリから外す") : Text("ライブラリに保存"))
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            MangaCover(url: manga.cover, sourceKey: sourceKey)
                .frame(width: 96, height: 144)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: manga.title)
                    .font(.headline)
                if let authors = manga.authors, !authors.isEmpty {
                    Text(verbatim: authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: source?.name ?? sourceKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let tags = manga.tags, !tags.isEmpty {
                    Text(verbatim: tags.prefix(6).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func chapterRow(_ chapter: AidokuRunner.Chapter) -> some View {
        let id = unitID(chapter)
        let finished = library.isFinished(id)
        let page = library.page(for: id)
        return Button {
            open(chapter)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: chapter.displayTitle)
                        .foregroundStyle(finished ? .secondary : .primary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let date = chapter.dateUploaded {
                            Text(date, format: .dateTime.year().month().day())
                        }
                        if let scanlators = chapter.scanlators, !scanlators.isEmpty {
                            Text(verbatim: scanlators.joined(separator: ", "))
                                .lineLimit(1)
                        }
                        if !finished, page > 0 {
                            Text("\(page + 1)ページ目")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if chapter.locked {
                    Image(systemName: "lock")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(chapter.locked)
        .foregroundStyle(.primary)
    }

    private func open(_ chapter: AidokuRunner.Chapter) {
        guard let source else { return }
        MangaReaderPresenter.shared.request = .source(source, manga: manga, chapters: chapters, start: chapter)
    }

    private func load() async {
        guard let source else {
            error = MangaSourceError.notInstalled.localizedDescription
            loading = false
            return
        }
        loading = true
        defer { loading = false }
        do {
            let updated = try await source.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: true)
            manga = updated
            chapters = updated.chapters ?? []
            error = chapters.isEmpty ? String(localized: "章がありません") : nil
            library.update(source: sourceKey, manga: updated)
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }
}
