//
//  LocalMangaViews.swift
//  Donguri
//
//  The マンガ tab's ローカル section: the series in the Manga folder (Files
//  app › いろは › Manga), importing books into it, and web addresses that
//  serve mokuro volumes, browsed folder by folder.
//

import SwiftUI
import UniformTypeIdentifiers

struct LocalHomeList: View {
    @State private var library = LocalMangaLibrary.shared
    @State private var mokuro = MokuroLibrary.shared
    @State private var importing = false
    @State private var addingRemote = false
    @State private var newRemote = ""
    @State private var message: String?
    @State private var working = false
    @Environment(\.scenePhase) private var scenePhase

    private static let importTypes: [UTType] = [
        .folder, .zip, .pdf, .image, .epub,
        UTType(filenameExtension: "cbz") ?? .zip,
        UTType(filenameExtension: "mokuro") ?? .json
    ]

    var body: some View {
        List {
            Section {
                if library.series.isEmpty && !library.isScanning {
                    Text("CBZ・ZIP・PDF・EPUB・画像フォルダ・画像を読めます。ファイル App の「このiPhone内 › いろは › Manga」に入れるか、ここから読み込んでください。フォルダはシリーズになり、同じ名前の .mokuro ファイルがあればその文字を使います。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(library.series) { series in
                    NavigationLink(value: MangaRoute.localSeries(series.id)) {
                        HStack(spacing: 12) {
                            LocalCover(volume: series.volumes.first)
                                .frame(width: 44, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: series.title)
                                    .lineLimit(2)
                                Group {
                                    if series.volumes.count == 1 {
                                        Text(verbatim: series.volumes[0].kind == .folder
                                             ? String(localized: "フォルダ") : series.volumes[0].url.pathExtension.uppercased())
                                    } else {
                                        Text("\(series.volumes.count)冊")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await library.delete(series) }
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
                Button {
                    importing = true
                } label: {
                    if working {
                        HStack {
                            ProgressView()
                            Text("読み込み中…")
                        }
                    } else {
                        Label("ファイルから読み込む", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(working)
            } header: {
                HStack {
                    Text("この端末")
                    if library.isScanning && library.series.isEmpty {
                        ProgressView().controlSize(.mini)
                    }
                }
            }

            Section {
                ForEach(mokuro.remotes, id: \.self) { url in
                    NavigationLink(value: MangaRoute.mokuroRemote(name: url.host() ?? url.absoluteString, url: url)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: url.host() ?? url.absoluteString)
                            Text(verbatim: url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            mokuro.removeRemote(url)
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
                Button {
                    newRemote = ""
                    addingRemote = true
                } label: {
                    Label("ウェブのライブラリを追加", systemImage: "plus")
                }
            } header: {
                Text(verbatim: "mokuro（ウェブ）")
            } footer: {
                Text("mokuro の巻（.mokuro と画像フォルダ）を公開しているフォルダのURL。ディレクトリ一覧のページか .mokuro ファイルを指定できます。")
            }
        }
        .refreshable { await library.scan() }
        .task { await library.scan() }
        // Books dropped into the folder from the Files app meanwhile.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await library.scan() } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes,
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await importItems(urls) }
        }
        .alert(Text("ウェブのライブラリを追加"), isPresented: $addingRemote) {
            TextField(text: $newRemote) { Text(verbatim: "https://…") }
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("追加") {
                if mokuro.addRemote(newRemote) == nil {
                    message = String(localized: "URLが正しくありません")
                }
            }
            Button("キャンセル", role: .cancel) {}
        }
        .alert(Text(verbatim: message ?? ""), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func importItems(_ urls: [URL]) async {
        working = true
        defer { working = false }
        do {
            _ = try await library.importItems(urls)
        } catch {
            message = error.localizedDescription
        }
    }
}

/// A book's first page as its cover.
struct LocalCover: View {
    let volume: LocalVolume?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.15))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let volume {
                Image(systemName: volume.kind.systemImage)
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: volume?.id) {
            guard let volume else { return }
            image = await LocalCovers.cover(for: volume)
        }
    }
}

enum LocalCovers {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 150
        return cache
    }()

    static func cover(for volume: LocalVolume) async -> UIImage? {
        if let cached = cache.object(forKey: volume.id as NSString) { return cached }
        let book = LocalBook(volume: volume)
        guard (try? await book.open()) != nil,
              let page = try? await book.image(at: 0, maxPixel: 400) else { return nil }
        let thumbnail = await page.byPreparingThumbnail(ofSize: CGSize(width: 132, height: 192)) ?? page
        cache.setObject(thumbnail, forKey: volume.id as NSString)
        return thumbnail
    }
}

struct LocalSeriesView: View {
    let seriesID: String
    @State private var library = LocalMangaLibrary.shared
    @State private var reading = MangaLibrary.shared

    private var series: LocalSeries? { library.series(id: seriesID) }

    var body: some View {
        List {
            if let series {
                ForEach(series.volumes) { volume in
                    Button {
                        MangaReaderPresenter.shared.request = .local(series, start: volume)
                    } label: {
                        HStack(spacing: 12) {
                            LocalCover(volume: volume)
                                .frame(width: 44, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: volume.title)
                                    .foregroundStyle(reading.isFinished(volume.unitID) ? .secondary : .primary)
                                    .lineLimit(2)
                                HStack(spacing: 6) {
                                    Text(verbatim: volume.kind == .folder ? String(localized: "フォルダ") : volume.url.pathExtension.uppercased())
                                    if volume.sidecar != nil {
                                        Text(verbatim: "mokuro")
                                    }
                                    if !reading.isFinished(volume.unitID), reading.page(for: volume.unitID) > 0 {
                                        Text("\(reading.page(for: volume.unitID) + 1)ページ目")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await library.delete(volume) }
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle(Text(verbatim: series?.title ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await library.scan() }
    }
}

struct MokuroRemoteView: View {
    let name: String
    let url: URL
    @State private var entries: [MokuroRemoteEntry]?
    @State private var error: String?
    @State private var reading = MangaLibrary.shared

    private var volumes: [(name: String, url: URL)] {
        (entries ?? []).compactMap {
            if case .volume(let name, let url) = $0 { (name, url) } else { nil }
        }
    }

    var body: some View {
        List {
            if let error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: error)
                        .foregroundStyle(.secondary)
                    Button("再試行") { Task { await load() } }
                }
            } else if entries == nil {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if entries?.isEmpty == true {
                Text("mokuro の巻もフォルダも見つかりませんでした")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries ?? []) { entry in
                switch entry {
                case .folder(let name, let url):
                    NavigationLink(value: MangaRoute.mokuroRemote(name: name, url: url)) {
                        Label {
                            Text(verbatim: name)
                        } icon: {
                            Image(systemName: "folder")
                        }
                    }
                case .volume(let volumeName, let volumeURL):
                    let unit = "mokuro-web\u{1F}\(volumeURL.absoluteString)"
                    Button {
                        MangaReaderPresenter.shared.request = .remote(title: name, volumes: volumes, start: volumeURL)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: volumeName)
                                    .foregroundStyle(reading.isFinished(unit) ? .secondary : .primary)
                                if !reading.isFinished(unit), reading.page(for: unit) > 0 {
                                    Text("\(reading.page(for: unit) + 1)ページ目")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "book")
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .navigationTitle(Text(verbatim: name))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            if entries == nil { await load() }
        }
    }

    private func load() async {
        error = nil
        if url.pathExtension.lowercased() == "mokuro" {
            entries = [.volume(name: url.deletingPathExtension().lastPathComponent, url: url)]
            return
        }
        do {
            entries = try await MokuroRemote.list(url)
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }
}
