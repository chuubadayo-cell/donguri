//
//  OpenInIroha.swift
//  Donguri
//
//  Opening links from other apps here. iOS doesn't let an app take over
//  x.com or youtube.com links (only the sites themselves can choose an
//  app), so this is offered two other ways:
//
//  - the Shortcuts action いろはで開く, which a share-sheet shortcut can
//    run on any link (X posts open in the X tab signed in, YouTube in the
//    player, anything else in the browser);
//  - the link donguri://open?url=…, for anything that can open a URL.
//

import AppIntents
import Foundation

struct OpenInIrohaIntent: AppIntent {
    static let title: LocalizedStringResource = "いろはで開く"
    static let description = IntentDescription("X・YouTube・ウェブのリンクをいろはで開きます。共有シートのショートカットから使えます。")
    static let openAppWhenRun = true

    @Parameter(title: "リンク")
    var url: URL

    init() {}

    init(url: URL) {
        self.url = url
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        OpenInIroha.open(url)
        return .result()
    }
}

nonisolated struct IrohaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenInIrohaIntent(),
                    phrases: ["\(.applicationName)でリンクを開く"],
                    shortTitle: "いろはで開く",
                    systemImageName: "link")
    }
}

enum OpenInIroha {
    /// A web link from outside the app, opened where it belongs.
    static func open(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        AppNavigator.shared.openInBrowser(url)
    }

    /// donguri://open?url=https%3A%2F%2Fx.com%2F…
    static func handle(_ url: URL) -> Bool {
        guard url.host == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: value) else { return false }
        open(target)
        return true
    }
}
