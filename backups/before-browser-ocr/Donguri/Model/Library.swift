//
//  Library.swift
//  Donguri
//
//  The user's own collection: favorite boards and threads, browsing history,
//  and threads saved for offline reading.
//

import Foundation

/// A board pinned to the top of the board menu.
struct FavoriteBoard: Codable, Identifiable, Hashable {
    var boardName: String
    var url: String
    var directoryName: String

    var id: String { url }

    init(boardName: String, url: String, directoryName: String) {
        self.boardName = boardName
        self.url = url
        self.directoryName = directoryName
    }

    init(_ board: BBSMenu.CategoryContent) {
        self.init(boardName: board.boardName, url: board.url, directoryName: board.directoryName)
    }

    /// `BoardView` takes the menu's own type, so favorites rebuild one. The
    /// ordering fields only matter inside the menu and are never read here.
    var categoryContent: BBSMenu.CategoryContent {
        BBSMenu.CategoryContent(categoryOrder: 0,
                                boardName: boardName,
                                url: url,
                                directoryName: directoryName,
                                category: 0,
                                categoryName: "")
    }
}

/// A thread pinned to the top of the board menu.
struct FavoriteThread: Codable, Identifiable, Hashable {
    var boardURL: String
    var boardName: String
    var threadId: Int
    var title: String
    /// Reply count the last time Donguri saw this thread, either in a board
    /// listing or by opening it. Compared against the read position to show
    /// how many replies are new.
    var responseCount: Int
    /// Set once the thread is missing from its board's subject.txt, i.e. it
    /// has filled up or aged out (dat落ち). It can still be opened from the
    /// archive, but it will not grow any more.
    var isArchived: Bool = false
    var addedAt: Date = .now

    var id: String { ReadStateStore.key(boardURL: boardURL, threadId: threadId) }

    var thread: Thread {
        Thread(id: threadId, title: title, responseCount: responseCount)
    }

    var link: ThreadLink {
        ThreadLink(boardURL: boardURL, threadId: threadId, title: title,
                   boardName: boardName, responseCount: responseCount)
    }
}

/// One thread the user has opened, most recent visit first.
struct HistoryEntry: Codable, Identifiable, Hashable {
    var boardURL: String
    var boardName: String
    var threadId: Int
    var title: String
    var responseCount: Int
    var lastViewed: Date

    var id: String { ReadStateStore.key(boardURL: boardURL, threadId: threadId) }

    var thread: Thread {
        Thread(id: threadId, title: title, responseCount: responseCount)
    }

    var link: ThreadLink {
        ThreadLink(boardURL: boardURL, threadId: threadId, title: title,
                   boardName: boardName, responseCount: responseCount)
    }
}

/// What the saved-threads list needs to know about a thread on disk, without
/// loading its posts.
struct SavedThreadInfo: Codable, Identifiable, Hashable {
    var boardURL: String
    var boardName: String
    var threadId: Int
    var title: String
    var postCount: Int
    var savedAt: Date
    /// Name of the JSON file inside the saved-threads folder.
    var fileName: String

    var id: String { ReadStateStore.key(boardURL: boardURL, threadId: threadId) }

    var thread: Thread {
        Thread(id: threadId, title: title, responseCount: postCount)
    }

    var link: ThreadLink {
        ThreadLink(boardURL: boardURL, threadId: threadId, title: title,
                   boardName: boardName, responseCount: postCount)
    }
}

/// The file written for one saved thread.
struct SavedThread: Codable {
    var info: SavedThreadInfo
    var posts: [Post]
}

enum BoardNames {
    /// Something to show for a board when its real name isn't known, e.g. a
    /// thread reached by following a link from another thread. 5ch board URLs
    /// end in the board's directory (`https://egg.5ch.io/software/`).
    static func fallback(for boardURL: String) -> String {
        guard let url = URL(string: boardURL) else { return boardURL }
        return url.pathComponents.first { $0 != "/" } ?? (url.host ?? boardURL)
    }
}
