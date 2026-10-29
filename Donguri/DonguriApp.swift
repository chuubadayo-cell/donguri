//
//  DonguriApp.swift
//  Donguri
//
//  Created by John Connery on 6/14/26.
//

import SwiftUI
import UserNotifications

@main
struct DonguriApp: App {
    /// Only for the screen orientations the video player asks for.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var userConfig = UserConfig()
    // Instantiated at launch (not lazily on first settings visit) so the
    // dictionaries are loaded into LookupEngine before any post is tapped.
    @State private var dictionaryManager = DictionaryManager.shared
    @State private var appearance = AppearanceSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AsciiArt.registerFont()
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(userConfig)
                // 外観: app-wide theme, accent colour and UI text.
                .preferredColorScheme(appearance.colorScheme)
                .tint(appearance.accentColor)
                .accentColor(appearance.accentColor)
                .fontDesign(appearance.uiDesign.design)
                .modifier(UITextSizeModifier(size: appearance.dynamicTypeSize))
                .task {
                    if userConfig.autoUpdateDictionaries {
                        dictionaryManager.autoUpdateDictionaries()
                    }
                    // Keep the image cache under its size limit.
                    await MediaStore.shared.trimCache()
                }
                .onOpenURL { url in
                    handleURL(url)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Favorites are checked for notifications in the background.
            if phase == .background {
                ReadStateStore.shared.flush()
                StatsStore.shared.flush()
                FavoriteWatcher.shared.schedule()
            }
        }
        .backgroundTask(.appRefresh(FavoriteWatcher.taskIdentifier)) {
            await FavoriteWatcher.shared.runBackgroundRefresh()
        }
    }

    /// AnkiMobile hands control back via the `donguri://` x-callback-url scheme
    /// registered in Donguri-Info.plist. `AnkiManager` builds these URLs when it
    /// opens Anki; this is the other half of that round trip.
    private func handleURL(_ url: URL) {
        guard url.scheme == "donguri" else { return }

        switch url.host {
        case "ankiFetch":
            // Anki has written decks/notetypes to the pasteboard for us to read.
            AnkiManager.shared.fetch()
        case "open":
            _ = OpenInIroha.handle(url)
        case "ankiSuccess":
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let expression = components.queryItems?.first(where: { $0.name == "expression" })?.value {
                AnkiManager.shared.addWord(expression)
            }
        default:
            break
        }
    }
}

/// Applies the chosen UI text size, or leaves the system's in charge.
private struct UITextSizeModifier: ViewModifier {
    let size: DynamicTypeSize?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let size {
            content.dynamicTypeSize(size)
        } else {
            content
        }
    }
}
