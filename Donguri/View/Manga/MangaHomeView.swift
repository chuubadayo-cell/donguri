//
//  MangaHomeView.swift
//  Donguri
//
//  The マンガ tab: the library (manga saved from sources), the installed
//  sources, and local books (the Manga folder, and mokuro on the web).
//  Every screen opens the reader through MangaReaderPresenter, which this
//  tab presents over everything.
//

import SwiftUI
import AidokuRunner

/// Opens the reader from anywhere in the tab.
@Observable
final class MangaReaderPresenter {
    static let shared = MangaReaderPresenter()
    var request: ReaderRequest?
    private init() {}
}

enum MangaRoute: Hashable {
    case source(String)
    case manga(source: String, manga: AidokuRunner.Manga)
    case localSeries(String)
    case mokuroRemote(name: String, url: URL)
    case manageSources
}

struct MangaHomeView: View {
    private enum Section: String, CaseIterable {
        case library, sources, local
    }

    @State private var presenter = MangaReaderPresenter.shared
    @State private var sources = MangaSources.shared
    @AppStorage("iroha.manga.section") private var section: Section = .library
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case .library: MangaLibraryList()
                case .sources: InstalledSourcesList()
                case .local: LocalHomeList()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker(selection: $section) {
                    Text("ライブラリ").tag(Section.library)
                    Text("ソース").tag(Section.sources)
                    Text("ローカル").tag(Section.local)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle(Text("マンガ"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MangaRoute.self) { route in
                switch route {
                case .source(let key): SourceBrowseView(sourceKey: key)
                case .manga(let source, let manga): MangaDetailView(sourceKey: source, manga: manga)
                case .localSeries(let id): LocalSeriesView(seriesID: id)
                case .mokuroRemote(let name, let url): MokuroRemoteView(name: name, url: url)
                case .manageSources: ManageSourcesView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel(Text("リーダーの設定"))
                }
            }
            // On the stack's content: the reader's cover is on the stack.
            .sheet(isPresented: $showsSettings) {
                MangaReaderSettingsView()
            }
            .background(FullSwipeBack())
        }
        .task {
            await sources.loadInstalled()
        }
        .fullScreenCover(item: $presenter.request) { request in
            MangaReaderView(request: request) {
                withTransaction(Transaction.noAnimation) { presenter.request = nil }
            }
            .presentationBackground(.black)
        }
    }
}

// MARK: - Library

private struct MangaLibraryList: View {
    @State private var library = MangaLibrary.shared

    var body: some View {
        if library.saved.isEmpty {
            ContentUnavailableView {
                Label("ライブラリは空です", systemImage: "books.vertical")
            } description: {
                Text("ソースで見つけたマンガを保存すると、ここに並びます。")
            }
        } else {
            ScrollView {
                MangaGrid(items: library.saved.map { ($0.sourceKey, $0.manga) })
                    .padding(16)
            }
        }
    }
}

/// Covers in a grid, each opening its manga.
struct MangaGrid: View {
    let items: [(source: String, manga: AidokuRunner.Manga)]
    var onAppearLast: (() -> Void)?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)], spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                NavigationLink(value: MangaRoute.manga(source: item.source, manga: item.manga)) {
                    VStack(alignment: .leading, spacing: 6) {
                        MangaCover(url: item.manga.cover, sourceKey: item.source)
                            .aspectRatio(2 / 3, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(verbatim: item.manga.title)
                            .font(.caption.weight(.medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
                .onAppear {
                    if index == items.count - 1 { onAppearLast?() }
                }
            }
        }
    }
}

/// A manga's cover, asked for the way its source asks for images.
struct MangaCover: View {
    let url: String?
    let sourceKey: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.15))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "book.closed")
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: url) {
            guard let url, let link = URL(string: url) else { return }
            image = await MangaCovers.image(for: link, source: MangaSources.shared.installed[sourceKey])
        }
    }
}

enum MangaCovers {
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 200
        return cache
    }()

    static func image(for url: URL, source: AidokuRunner.Source?) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        var request = URLRequest(url: url)
        if let source, source.features.providesImageRequests,
           let custom = try? await source.getImageRequest(url: url.absoluteString, context: nil) {
            request = custom
        }
        guard let image = await load(MangaSources.prepared(request)) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    @concurrent
    private nonisolated static func load(_ request: URLRequest) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let image = UIImage(data: data) else { return nil }
        return image.preparingThumbnail(of: CGSize(width: 300, height: 450)) ?? image
    }
}
