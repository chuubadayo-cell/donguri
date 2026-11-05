//
//  MangaLibraryViews.swift
//  Donguri
//
//  The マンガ tab's ライブラリ: titles saved from sources and series from the
//  Manga folder, most recently read first, with how far each has been read
//  as a bar under its cover, and shelves (棚) to sort them onto. A long
//  press on a title anywhere in the tab adds it to the library or moves it
//  between shelves.
//

import SwiftUI
import AidokuRunner

struct MangaLibraryList: View {
    @State private var library = MangaLibrary.shared
    @State private var local = LocalMangaLibrary.shared
    @AppStorage("iroha.manga.shelf") private var selectedShelf = ""
    @State private var editingShelves = false

    private var shownEntries: [LibraryEntry] {
        guard let shelf = UUID(uuidString: selectedShelf), library.shelves.contains(where: { $0.id == shelf }) else {
            return library.entries
        }
        return library.entries.filter { $0.shelves.contains(shelf) }
    }

    var body: some View {
        Group {
            if library.entries.isEmpty {
                ContentUnavailableView {
                    Label("ライブラリは空です", systemImage: "books.vertical")
                } description: {
                    Text("マンガやローカルのシリーズを長押しして「ライブラリに追加」を選ぶと、ここに並びます。")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        shelfBar
                        if shownEntries.isEmpty {
                            Text("この棚は空です。長押しのメニューから棚に入れられます。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 30)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)], spacing: 18) {
                            ForEach(shownEntries) { entry in
                                LibraryCell(entry: entry,
                                            progress: library.progress(of: entry, localSeries: localSeries(entry)))
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .task { await local.scanIfNeeded() }
        .sheet(isPresented: $editingShelves) {
            ShelfEditor()
        }
    }

    private func localSeries(_ entry: LibraryEntry) -> LocalSeries? {
        if case .local(let id) = entry.kind { local.series(id: id) } else { nil }
    }

    private var shelfBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(String(localized: "すべて"), id: "")
                ForEach(library.shelves) { shelf in
                    chip(shelf.name, id: shelf.id.uuidString)
                }
                Button {
                    editingShelves = true
                } label: {
                    Label(library.shelves.isEmpty ? String(localized: "棚を作る") : String(localized: "棚を編集"),
                          systemImage: library.shelves.isEmpty ? "plus" : "pencil")
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ name: String, id: String) -> some View {
        let selected = selectedShelf == id
            || (id.isEmpty && !library.shelves.contains { $0.id.uuidString == selectedShelf })
        return Button {
            selectedShelf = id
        } label: {
            Text(verbatim: name)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

/// A title's cover, name and reading progress.
private struct LibraryCell: View {
    let entry: LibraryEntry
    let progress: Double?

    var body: some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 6) {
                cover
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        if case .local = entry.kind {
                            Image(systemName: "iphone")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Circle().fill(.black.opacity(0.55)))
                                .padding(4)
                        }
                    }
                Text(verbatim: entry.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                ProgressBar(value: progress)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            LibraryMenuItems(target: target)
        }
    }

    private var route: MangaRoute {
        switch entry.kind {
        case .source(let key, let manga): .manga(source: key, manga: manga)
        case .local(let id): .localSeries(id)
        }
    }

    private var target: LibraryMenuItems.Target {
        switch entry.kind {
        case .source(let key, let manga): .source(key: key, manga: manga)
        case .local(let id): .local(seriesID: id, title: entry.title)
        }
    }

    @ViewBuilder
    private var cover: some View {
        switch entry.kind {
        case .source(let key, let manga):
            MangaCover(url: manga.cover, sourceKey: key)
        case .local(let id):
            LocalCover(volume: LocalMangaLibrary.shared.series(id: id)?.volumes.first)
        }
    }
}

/// A thin bar for how much has been read, with the percentage.
private struct ProgressBar: View {
    let value: Double?

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(Color.accentColor)
                        .frame(width: geometry.size.width * min(max(value ?? 0, 0), 1))
                }
            }
            .frame(height: 4)
            Group {
                if let value {
                    Text(verbatim: value >= 1 ? "✓" : "\(Int((value * 100).rounded()))%")
                } else {
                    Text(verbatim: "–")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 26, alignment: .trailing)
        }
    }
}

/// The long-press menu for a title: add to or remove from the library,
/// and which shelves it's on.
struct LibraryMenuItems: View {
    enum Target {
        case source(key: String, manga: AidokuRunner.Manga)
        case local(seriesID: String, title: String)
    }

    let target: Target
    @State private var library = MangaLibrary.shared

    private var entryID: String {
        switch target {
        case .source(let key, let manga): MangaLibrary.mangaID(source: key, manga: manga.key)
        case .local(let id, _): MangaLibrary.localID(id)
        }
    }

    private var saved: Bool {
        switch target {
        case .source(let key, let manga): library.isSaved(source: key, manga: manga.key)
        case .local(let id, _): library.isSaved(local: id)
        }
    }

    var body: some View {
        if saved {
            let shelves = library.entries.first { $0.id == entryID }?.shelves ?? []
            if !library.shelves.isEmpty {
                Section {
                    ForEach(library.shelves) { shelf in
                        Toggle(isOn: Binding(get: { shelves.contains(shelf.id) },
                                             set: { library.setShelf(shelf.id, on: $0, for: entryID) })) {
                            Label(shelf.name, systemImage: "books.vertical")
                        }
                    }
                } header: {
                    Text("棚")
                }
            }
            Button(role: .destructive) {
                toggle()
            } label: {
                Label("ライブラリから外す", systemImage: "bookmark.slash")
            }
        } else {
            Button {
                toggle()
                Haptics.play(.selection)
            } label: {
                Label("ライブラリに追加", systemImage: "bookmark")
            }
        }
    }

    private func toggle() {
        switch target {
        case .source(let key, let manga):
            library.toggleSaved(source: key, manga: manga)
        case .local(let id, let title):
            if let series = LocalMangaLibrary.shared.series(id: id) {
                library.toggleSaved(local: series)
            } else {
                library.toggleSaved(local: LocalSeries(id: id, title: title, volumes: []))
            }
        }
    }
}

/// Making, renaming, ordering and deleting shelves.
private struct ShelfEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var library = MangaLibrary.shared
    @State private var newName = ""
    @State private var renaming: MangaShelf?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(text: $newName) { Text("新しい棚の名前") }
                            .onSubmit(add)
                        Button("追加", action: add)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    ForEach(library.shelves) { shelf in
                        Button {
                            renameText = shelf.name
                            renaming = shelf
                        } label: {
                            Label(shelf.name, systemImage: "books.vertical")
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { offsets in
                        for index in offsets { library.deleteShelf(library.shelves[index].id) }
                    }
                    .onMove { library.moveShelves(from: $0, to: $1) }
                } footer: {
                    Text("タップで名前を変更、左にスワイプで削除、「編集」で並べ替え。棚を消してもマンガはライブラリに残ります。")
                }
            }
            .navigationTitle(Text("棚"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .alert(Text("棚の名前"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(text: $renameText) { Text("名前") }
                Button("変更") {
                    if let renaming { library.renameShelf(renaming.id, to: renameText) }
                    renaming = nil
                }
                Button("キャンセル", role: .cancel) { renaming = nil }
            }
        }
    }

    private func add() {
        if library.addShelf(newName) != nil { newName = "" }
    }
}

/// A chapter's or volume's long-press menu: read or unread, or read
/// everything up to it.
struct ReadMarkMenu: View {
    let read: Bool
    let mark: (Bool) -> Void
    let markUpTo: () -> Void

    var body: some View {
        if read {
            Button { mark(false) } label: { Label("未読にする", systemImage: "circle") }
        } else {
            Button { mark(true) } label: { Label("既読にする", systemImage: "checkmark.circle") }
        }
        Button(action: markUpTo) {
            Label("ここまで既読にする", systemImage: "checkmark.circle.badge.questionmark")
        }
    }
}

/// The series page's menu for marking every chapter or volume at once.
struct SeriesReadMenu: View {
    let units: [String]
    @State private var library = MangaLibrary.shared

    var body: some View {
        Menu {
            Button { library.setRead(units, read: true) } label: {
                Label("すべて既読にする", systemImage: "checkmark.circle.fill")
            }
            Button { library.setRead(units, read: false) } label: {
                Label("すべて未読にする", systemImage: "circle")
            }
        } label: {
            Image(systemName: "checklist")
        }
        .disabled(units.isEmpty)
        .accessibilityLabel(Text("既読の管理"))
    }
}
