//
//  BackupView.swift
//  Donguri
//
//  バックアップ: everything the app keeps in its settings store (favorites,
//  history, read positions, NG rules, open tabs, themes, appearance, the
//  dictionary popup's settings…) written to one file, and read back. For
//  reinstalling, or moving to another device. Offline copies of threads,
//  images and imported dictionaries are files of their own and are not
//  included.
//

import SwiftUI
import UniformTypeIdentifiers

enum BackupService {
    static let format = "iroha-backup"
    static let version = 1

    /// Keys that only make sense on this install.
    private static let excludedKeys: Set<String> = [
        "donguri.savedThreads",       // points at files that aren't in the backup
        "lastDictionaryUpdate",
    ]
    private static let systemPrefixes = ["Apple", "NS", "AK", "com.apple", "WebKit", "PK", "MSV", "INNext"]

    static func export() throws -> Data {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: bundleID) else {
            throw CocoaError(.fileReadUnknown)
        }
        let values = domain.filter { key, _ in
            !excludedKeys.contains(key) && !systemPrefixes.contains { key.hasPrefix($0) }
        }
        let root: [String: Any] = [
            "format": format,
            "version": version,
            "created": Date.now,
            "defaults": values,
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    /// Restores a backup. Returns how many settings were written.
    @discardableResult
    static func restore(from data: Data) throws -> Int {
        let object = try PropertyListSerialization.propertyList(from: data, options: 0, format: nil)
        guard let root = object as? [String: Any],
              root["format"] as? String == format,
              let values = root["defaults"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let defaults = UserDefaults.standard
        var count = 0
        for (key, value) in values where !excludedKeys.contains(key) {
            defaults.set(value, forKey: key)
            count += 1
        }
        return count
    }

    static var defaultFileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "iroha-backup-\(formatter.string(from: .now))"
    }
}

/// The backup as a document for the system's save panel.
nonisolated struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.propertyList] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct BackupView: View {
    @State private var document: BackupDocument?
    @State private var showsExporter = false
    @State private var showsImporter = false
    @State private var confirmRestore: URL?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Button {
                    do {
                        document = BackupDocument(data: try BackupService.export())
                        showsExporter = true
                    } catch {
                        message = String(localized: "書き出せませんでした: \(error.localizedDescription)")
                    }
                } label: {
                    Label("バックアップを書き出す", systemImage: "square.and.arrow.up")
                }
                Button {
                    showsImporter = true
                } label: {
                    Label("バックアップから復元", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("お気に入り、閲覧履歴、読んだ位置、NG設定、開いているタブ、テーマ、外観や辞書ポップアップの設定などを1つのファイルに保存します。「ファイル」アプリやiCloud Driveに保存しておくと、再インストール後に復元できます。オフライン保存したスレ、画像、辞書は含まれません。")
            }
        }
        .navigationTitle("バックアップ")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $showsExporter,
                      document: document,
                      contentType: .propertyList,
                      defaultFilename: BackupService.defaultFileName) { result in
            switch result {
            case .success:
                message = String(localized: "バックアップを保存しました")
            case .failure(let error):
                message = String(localized: "書き出せませんでした: \(error.localizedDescription)")
            }
        }
        .fileImporter(isPresented: $showsImporter,
                      allowedContentTypes: [.propertyList, .data]) { result in
            if case .success(let url) = result {
                confirmRestore = url
            }
        }
        .confirmationDialog("バックアップから復元しますか？",
                            isPresented: Binding(get: { confirmRestore != nil },
                                                 set: { if !$0 { confirmRestore = nil } }),
                            titleVisibility: .visible) {
            Button("復元する", role: .destructive) {
                if let url = confirmRestore { restore(url) }
                confirmRestore = nil
            }
        } message: {
            Text("今の設定、お気に入り、履歴はバックアップの内容で置き換えられます。")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil },
                                                   set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        }
    }

    private func restore(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            try BackupService.restore(from: data)
            Haptics.play(.success)
            message = String(localized: "復元しました。アプリを一度終了して開き直すと、すべて反映されます。")
        } catch {
            message = String(localized: "このファイルは読み込めませんでした")
        }
    }
}
