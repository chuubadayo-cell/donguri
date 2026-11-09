//
//  BBSMenuService.swift
//  Donguri
//
//  Created by John Connery on 6/14/26.
//

import Foundation

struct BBSMenuService {
    private let menuURL: URL = URL(string: "https://menu.5ch.io/bbsmenu.json")!

    /// The last menu downloaded, kept so the board list appears instantly at
    /// launch and still works offline.
    private static var cacheFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("bbsmenu.json")
    }

    func fetchBBSMenu() async throws -> BBSMenu {
        let (data, response) = try await URLSession.shared.data(from: menuURL)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let menu = try Self.decode(data)
        Self.memo = menu
        if let cacheFile = Self.cacheFile {
            try? data.write(to: cacheFile, options: .atomic)
        }
        return menu
    }

    /// The saved copy from the last successful fetch, if any.
    func cachedBBSMenu() -> BBSMenu? {
        if let memo = Self.memo { return memo }
        guard let cacheFile = Self.cacheFile,
              let data = try? Data(contentsOf: cacheFile) else { return nil }
        let menu = try? Self.decode(data)
        Self.memo = menu
        return menu
    }

    /// The last menu decoded, so lookups don't re-read the file.
    private static var memo: BBSMenu?

    /// A board's live URL. Threads found through 5ch's search can point at
    /// the archive server (kako.5ch.io), which doesn't serve dat files; the
    /// board's own server still serves its old threads through read.cgi.
    static func resolveBoardURL(_ boardURL: String) -> String {
        guard let url = URL(string: boardURL), let host = url.host, host.hasPrefix("kako."),
              let directory = url.pathComponents.first(where: { $0 != "/" }),
              let menu = BBSMenuService().cachedBBSMenu() else { return boardURL }
        for category in menu.menuList {
            if let board = category.categoryContent.first(where: { $0.directoryName == directory }) {
                return board.url
            }
        }
        return boardURL
    }

    private static func decode(_ data: Data) throws -> BBSMenu {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(BBSMenu.self, from: data)
    }
}
