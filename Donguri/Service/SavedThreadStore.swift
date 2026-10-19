//
//  SavedThreadStore.swift
//  Donguri
//
//  Threads saved for offline reading (オフライン保存). Each thread's posts are
//  written as JSON to Application Support/SavedThreads/; the list of saved
//  threads lives in `UserDefaults` so the saved-threads screen never has to
//  read every file just to show titles.
//
//  Only text is saved. Image thumbnails still need a connection.
//

import Foundation
import SwiftUI

@Observable
final class SavedThreadStore {
    static let shared = SavedThreadStore()

    private static let defaultsKey = "donguri.savedThreads"
    private static let folderName = "SavedThreads"

    private(set) var entries: [SavedThreadInfo]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([SavedThreadInfo].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    func isSaved(boardURL: String, threadId: Int) -> Bool {
        entries.contains { $0.boardURL == boardURL && $0.threadId == threadId }
    }

    /// Writes (or overwrites) a thread to disk.
    @discardableResult
    func save(boardURL: String, boardName: String, threadId: Int, title: String, posts: [Post]) -> Bool {
        guard !posts.isEmpty else { return false }
        let fileName = Self.fileName(boardURL: boardURL, threadId: threadId)
        let info = SavedThreadInfo(boardURL: boardURL,
                                   boardName: boardName,
                                   threadId: threadId,
                                   title: title,
                                   postCount: posts.count,
                                   savedAt: .now,
                                   fileName: fileName)
        do {
            let folder = try Self.folderURL()
            let data = try JSONEncoder().encode(SavedThread(info: info, posts: posts))
            try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
        } catch {
            print("SavedThreadStore save error: \(error)")
            return false
        }

        entries.removeAll { $0.id == info.id }
        entries.insert(info, at: 0)
        persist()
        return true
    }

    /// Keeps an already-saved thread current after it has been loaded online.
    /// Does nothing for threads the user hasn't saved, or when nothing changed.
    func updateIfSaved(boardURL: String, threadId: Int, title: String?, posts: [Post]) {
        guard let existing = entries.first(where: { $0.boardURL == boardURL && $0.threadId == threadId }),
              posts.count >= existing.postCount else { return }
        let newTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? existing.title
        guard posts.count != existing.postCount || newTitle != existing.title else { return }
        save(boardURL: boardURL, boardName: existing.boardName, threadId: threadId, title: newTitle, posts: posts)
    }

    /// The saved posts, or nil if the thread isn't saved or its file is gone.
    func posts(boardURL: String, threadId: Int) -> [Post]? {
        guard let info = entries.first(where: { $0.boardURL == boardURL && $0.threadId == threadId }),
              let folder = try? Self.folderURL() else { return nil }
        return AppFileStorage.load(SavedThread.self, from: folder.appendingPathComponent(info.fileName))?.posts
    }

    func delete(boardURL: String, threadId: Int) {
        guard let info = entries.first(where: { $0.boardURL == boardURL && $0.threadId == threadId }) else { return }
        delete(info)
    }

    func delete(atOffsets offsets: IndexSet) {
        let doomed = offsets.map { entries[$0] }
        for info in doomed {
            delete(info)
        }
    }

    /// Total size of the saved files on disk, for the saved-threads screen.
    func totalBytes() -> Int64 {
        guard let folder = try? Self.folderURL() else { return 0 }
        return entries.reduce(Int64(0)) { total, info in
            let path = folder.appendingPathComponent(info.fileName).path(percentEncoded: false)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }

    private func delete(_ info: SavedThreadInfo) {
        if let folder = try? Self.folderURL() {
            try? AppFileStorage.delete(at: folder.appendingPathComponent(info.fileName))
        }
        entries.removeAll { $0.id == info.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func folderURL() throws -> URL {
        let folder = try AppFileStorage.getAppDirectory().appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    /// `egg.5ch.io_software_1700000000.json` — readable, and unique per thread.
    private static func fileName(boardURL: String, threadId: Int) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let board = boardURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return "\(board)_\(threadId).json"
    }
}
