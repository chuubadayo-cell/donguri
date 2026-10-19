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
        if let cacheFile = Self.cacheFile {
            try? data.write(to: cacheFile, options: .atomic)
        }
        return menu
    }

    /// The saved copy from the last successful fetch, if any.
    func cachedBBSMenu() -> BBSMenu? {
        guard let cacheFile = Self.cacheFile,
              let data = try? Data(contentsOf: cacheFile) else { return nil }
        return try? Self.decode(data)
    }

    private static func decode(_ data: Data) throws -> BBSMenu {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(BBSMenu.self, from: data)
    }
}
