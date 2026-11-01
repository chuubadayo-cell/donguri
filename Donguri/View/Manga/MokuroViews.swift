//
//  MokuroViews.swift
//  Donguri
//
//  mokuro in the マンガ tab: volumes imported from Files, grouped by
//  title, and web addresses that serve mokuro volumes, browsed folder by
//  folder.
//

import SwiftUI
import UniformTypeIdentifiers

struct MokuroHomeList: View {
    @State private var library = MokuroLibrary.shared
    @State private var importing = false
    @State private var addingRemote = false
    @State private var newRemote = ""
    @State private var message: String?
    @State private var working = false

    var body: some View {
        List {
            Section {
                if library.titles.isEmpty {
                    Text("mokuro で処理したフォルダ（.mokuro と画像フォルダ）か、それを入れた zip / cbz を読み込めます。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(library.titles, id: \.title) { entry in
                    NavigationLink(value: MangaRoute.mokuroTitle(entry.title)) {
                        HStack(spacing: 12) {
                            MokuroFirstPage(volume: entry.volumes.first)
                                .frame(width: 44, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: entry.title)
                                    .lineLimit(2)
                                Text("\(entry.volumes.count)巻")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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
                Text("この端末")
            }

            Section {
                ForEach(library.remotes, id: \.self) { url in
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
                            library.removeRemote(url)
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
                Text("ウェブ")
            } footer: {
                Text("mokuro の巻（.mokuro と画像フォルダ）を公開しているフォルダのURL。ディレクトリ一覧のページか .mokuro ファイルを指定できます。")
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.folder, .zip, UTType(filenameExtension: "cbz") ?? .zip,
                                            UTType(filenameExtension: "mokuro") ?? .json],
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
                if library.addRemote(newRemote) == nil {
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
        var total = 0
        for url in urls {
            do {
                total += try await library.importItem(at: url)
            } catch {
                message = error.localizedDescription
                return
            }
        }
        message = total == 0
            ? String(localized: "mokuro の巻が見つかりませんでした。.mokuro ファイルと同じ名前の画像フォルダが必要です。")
            : String(localized: "\(total)巻を読み込みました")
    }
}

/// A volume's first page as its cover.
private struct MokuroFirstPage: View {
    let volume: LocalMokuroVolume?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.15))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .clipped()
        .task(id: volume?.id) {
            guard let volume else { return }
            image = await Self.firstImage(in: volume.imagesURL)
        }
    }

    @concurrent
    private nonisolated static func firstImage(in folder: URL) async -> UIImage? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let first = files
            .filter({ ["jpg", "jpeg", "png", "webp", "avif"].contains($0.pathExtension.lowercased()) })
            .min(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }),
              let image = UIImage(contentsOfFile: first.path) else { return nil }
        return image.preparingThumbnail(of: CGSize(width: 132, height: 192))
    }
}

struct MokuroTitleView: View {
    let title: String
    @State private var library = MokuroLibrary.shared
    @State private var reading = MangaLibrary.shared

    private var volumes: [LocalMokuroVolume] {
        library.titles.first { $0.title == title }?.volumes ?? []
    }

    var body: some View {
        List {
            ForEach(volumes) { volume in
                let unit = "mokuro\u{1F}\(volume.id)"
                Button {
                    MangaReaderPresenter.shared.request = .local(title: title, volumes: volumes, start: volume)
                } label: {
                    HStack(spacing: 12) {
                        MokuroFirstPage(volume: volume)
                            .frame(width: 44, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: volume.volume)
                                .foregroundStyle(reading.isFinished(unit) ? .secondary : .primary)
                            if !reading.isFinished(unit), reading.page(for: unit) > 0 {
                                Text("\(reading.page(for: unit) + 1)ページ目")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .foregroundStyle(.primary)
                .swipeActions {
                    Button(role: .destructive) {
                        library.delete(volume)
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
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
