# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Build for the simulator:

```bash
xcodebuild -project Donguri.xcodeproj -scheme Donguri -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

Install and launch on a booted simulator:

```bash
xcrun simctl install booted "$(find ~/Library/Developer/Xcode/DerivedData/Donguri-*/Build/Products/Debug-iphonesimulator -maxdepth 1 -name 'Donguri.app' | head -1)" && xcrun simctl launch booted world.wumbo.Donguri
```

Re-resolve Swift package dependencies (after touching package refs in `project.pbxproj`):

```bash
xcodebuild -project Donguri.xcodeproj -scheme Donguri -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -resolvePackageDependencies
```

There is **no test target** and no lint config — the only target is the `Donguri` app.

If `xcodebuild` reports "requires Xcode, but active developer directory is a command line tools instance", prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` or run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

## Architecture

Two distinct layers live in this app, and they meet in exactly one place.

**1. The 5ch reader** (original code). A plain SwiftUI + `URLSession` stack, no third-party deps:

- `Service/BBSMenuService` fetches the board list from `menu.5ch.io/bbsmenu.json`.
- `Service/ThreadService` parses `{boardURL}/subject.txt`.
- `Service/PostService` parses `{boardURL}/dat/{id}.dat`, and on 404 (dat落ち — the thread aged out) falls back to scraping the server's `read.cgi` HTML archive. **Both sources are Shift-JIS**, not UTF-8.
- `Extensions/String+HtmlDecoding` normalises the raw dat/HTML into markdown-ish text; `>>N` reply anchors become `[>>N](donguri://res/N)` links, which `ThreadView` intercepts to drive reply previews.
- The root is a `TabView` (`ContentView`): 板 (`BrowserTabsView`), 保存 (`SavedTabView`), 履歴, 辞書 (`DictionarySearchView`), 設定. Screens are `BBSMenuView → BoardView → ThreadView`. `ThreadView` also owns reply-preview popups, ID/trip highlighting, read-position tracking (`Service/ReadStateStore`, `UserDefaults`-backed, including the post at the top of the screen so returning lands exactly there), auto-refresh and tree mode (`Service/ReplyTree`).
- **Navigation is value-based.** Every board/thread/search screen is a `BrowseRoute`, pushed with `NavigationLink(value:)` or `BrowseContext.push`; `browseDestinations()` maps routes to views. The 板 tab holds Chance-style browser tabs (`Service/AppNavigator`): each tab is a `NavigationStack` over a persisted `[BrowseRoute]`, and the few most recently used stay alive (hidden in a `ZStack`) so switching keeps scroll position. Other stacks use `RouteStack`. Views read their stack's `BrowseContext` with `@Environment(BrowseContext.self) var browseContext: BrowseContext?` (an `@Observable` object rather than an `EnvironmentKey`, to stay clear of isolated-conformance problems under default MainActor isolation). `BrowseContext.isActive` is false for hidden tabs, which pause auto-refresh.
- `FullSwipeBack` (in each stack's root background) turns on swipe-back from anywhere: iOS 26's own content pop gesture when present, else a pan sharing the edge gesture's targets. List swipe actions are therefore on the trailing edge.
- `Service/FavoriteWatcher` runs as a background app refresh (`.backgroundTask(.appRefresh("iroha.favorites.refresh"))`; the identifier is also in Info.plist's `BGTaskSchedulerPermittedIdentifiers`, with `UIBackgroundModes` `fetch`) and posts local notifications for new posts in favorites and found 次スレ. Tapping one opens the thread in a tab (`NotificationDelegate`).
- `Service/ThreadSearchService` searches thread titles across 5ch through find.5ch.io's HTML (parsed by link targets, not class names, so it survives layout changes), or across the user's own boards' subject.txt.

**2. The dictionary + Anki stack** (ported from [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader), GPL-3.0). `README.md` has a file-by-file table of what came from where. Ported files keep their original SPDX/copyright headers — preserve them.

- `Service/LookupEngine` wraps the `hoshidicts` Swift package. **It drives the package's C API (`hoshidicts_c.h`), not the C++ API that Hoshi Reader uses** — Swift's C++ interop cannot import the engine's `DictionaryQuery` (it holds a `std::vector` of a move-only, `unique_ptr`-owning type, and the importer fails synthesising a copy constructor). The C API hands out opaque handles, so that layout is never needed. `LookupEngine` copies all results into Swift value types because the C results are freed as soon as the call returns.
- `Service/DictionaryManager` handles Yomitan dictionary import/update/ordering; `Service/AnkiManager` handles mining via AnkiMobile (`x-callback-url`) or AnkiConnect (HTTP), with handlebar field templates in `Model/Anki`.
- `Service/UserConfig` is a trimmed version of Hoshi Reader's — deliberately keeps the same class name and property names so ported views' `@Environment(UserConfig.self)` code needed no rewriting.

**Where they meet — native post text.** SwiftUI `Text` has no per-character hit testing, so post text renders in `View/Post/PostTextView`, a non-selectable `UITextView` on TextKit 1 (`UITextView(usingTextLayoutManager: false)`), whose `NSLayoutManager` finds the tapped character. `PostTextScanner` in the same file is a port of `selection.js`'s scanning and sentence logic. (Posts used to be one `WKWebView` each; that was the main cause of scroll stutter and of rows needing a height estimate.)

`PostView` → `PostTextView` → tap → `PostTextScanner` finds the word and sentence → `ThreadView.handleTextSelection` → `LookupEngine.lookup` → `View/Popup/PopupView` → `PopupWebView` (renders entries with `popup.js`/`popup.css`, and still uses `selection.js` for lookups inside the popup) → `+` button → `AnkiManager.addNote`.

`popup.js`, `popup.css` and `selection.js` are copied verbatim from Hoshi Reader and are the real rendering/selection engines — prefer configuring them via the `window.*` globals that `PopupView.buildContent` sets over editing them.

## Project and dependency setup

- The Xcode project uses a **`PBXFileSystemSynchronizedRootGroup`**: any file added under `Donguri/` is picked up automatically. Do not hand-edit `project.pbxproj` to add source files or resources. `.js`/`.css` files land in the bundle root, which is what `Bundle.main.resourceURL` loading depends on.
- `project.pbxproj` edits *are* needed for package dependencies. Current deps: `hoshidicts` (branch `main`) and `ZIPFoundation`; `libzstd` comes in transitively.
- `SWIFT_OBJC_INTEROP_MODE = objcxx` is required (hoshidicts' modulemap declares `requires cplusplus`). Because that modulemap only exposes the C++ umbrella header, the C API is reached via `Donguri/Donguri-Bridging-Header.h` (`SWIFT_OBJC_BRIDGING_HEADER`).
- Deployment target is iOS 18.0 (lowered from 26.0 to run on an iPhone 13 mini), so the `if #available(iOS 26, *)` branches the ported code carries from Hoshi Reader are load-bearing — `glassEffect` and the other Liquid Glass APIs are *not* unconditionally available. `translationPresentation` (iOS 17.4+) is.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — anything called from `Task.detached` (e.g. `DictionaryImporter.import`) needs explicit `nonisolated`.

## Appearance

The thread and board UI follow Chance's (github.com/moffatman/chan): coloured ID chips hashed the same way (`IDColor`), default names hidden, reply counts as a button under each post, unseen posts tinted, a position pill (`ThreadView.positionIndicator`), stacked reply previews, and a 次スレ finder (`NextThreadFinder`). Themes `sepia` and `darkSepia` carry a `ThemePalette`; `.themedScreen()` / `.themedRow()` apply it and are no-ops for the system themes.

Themes are identified by string: a `BuiltInTheme` raw value or `custom:<uuid>` for themes made in the editor (`View/Settings/ThemeViews`). `AppearanceSettings.palette` is resolved once whenever the theme (or, with the automatic light/dark pairing, the system appearance) changes, because post rows read it constantly. ASCII art is detected per post (`View/Post/AsciiArt`) and drawn unwrapped in the bundled Saitamaar font (MS P Gothic–compatible widths, in `Fonts/`, registered at launch), sized in `PostTextView.sizeThatFits` so the widest line fits. The gallery zooms out of and back into post thumbnails using frames the thumbnails report to `MediaFrameRegistry`.

`Service/AppearanceSettings` holds three separately styled kinds of text: UI text (a `Font.Design` and a `DynamicTypeSize`, applied at the root in `DonguriApp`), post text (`PostTextStyle`: any installed family, size, line spacing, colours) and dictionary text (a font family injected as CSS ahead of `customCSS` in `PopupView`/`DictionarySearchView`; its size is `UserConfig.popupScale`).

## Gotchas that have already caused bugs

- **Do not pin `hoshidicts` to the revision Hoshi Reader uses.** That revision embeds a data file via `#embed` inside `std::to_array`, which miscompiles on Apple clang 17 ("excess elements in array initializer") — Hoshi Reader itself does not build here. `main` fixed it.
- **`Model/Dictionary.DictionaryIndex` decodes two different shapes** and must stay lenient: a Yomitan `index.json` (uses `format`, carries update URLs) and the summary hoshidicts writes after import (uses `version`, omits those URLs). A strict decode silently *deletes* every imported dictionary, because `DictionaryManager.getDictionariesFromStorage` prunes directories whose index it can't read.
- **Popups follow Hoshi Reader's model.** `ThreadView` keeps a stack of `PopupItem`s, one `PopupView` (and web view) each: a post tap closes them all and opens one; a tap inside a popup opens a child on top; swipe-dismiss closes the top one. `PopupView` caches its content in `@State` at init, so each popup needs its own identity (`ForEach` over the items does that). `WebProcessWarmer` keeps one hidden web view alive so WebKit's process is already running when the first popup opens — posts are native text, so otherwise no web view exists between lookups. (A single persistent popup was tried and dropped: it slid across the screen and showed stale entries.)
- **`DictionaryManager.shared` must be instantiated at launch** (it is, from `DonguriApp`). It is what loads dictionaries into `LookupEngine`; if it is only touched lazily by the settings screen, lookups silently return nothing until the user visits that screen.
- **Post rows size themselves synchronously.** `PostTextView.sizeThatFits` measures the text for the offered width, so there is no estimate-then-correct cycle any more (that cycle is what once made posts overlap). Links are a custom `.donguriLink` attribute, not `.link`, because `UITextView` only follows `.link` while selectable. Only one post shows a lookup highlight at a time (`PostSelectionCenter`).
- **UI strings live in two String Catalogs, and one Japanese literal in `PostService` must never join them.** `Donguri/Localizable.xcstrings` (the app's own UI) and `Donguri/Dictionaries.xcstrings` (the ported settings screens, which pass `tableName: "Dictionaries"` — that table exists in Hoshi Reader and had to be ported too, which is why those screens showed English keys before). Source language is `en`; both `en` and `ja` ship. Keys are the literals as written, so many keys are Japanese and carry an explicit `en` value — do not "fix" that by rewriting the literals. Anything that is a plain `String` rather than a `Text`/`Label` literal is invisible to the extractor and needs `String(localized:)` (see `NGRule.Kind.label`, and the `errorMessage` assignments in `BBSMenuView`/`BoardView`/`ThreadView`). **`PostService`'s `abornMarker = "あぼーん"` is dat *data*, not UI** — it matches text 5ch puts in the post body, so localizing it would break NG detection in English. Verify a change with `xcodebuild -exportLocalizations`, which is what actually runs the extractor; a plain `xcodebuild build` compiles the catalogs but never reports missing keys.
- `PostTextView` converts the tapped character's rect with `convert(rect, to: nil)`; window coordinates are what make `PopupLayout`'s positioning maths work unchanged.
- Post text is untrusted 5ch content. It is drawn as plain attributed text (`PostTextFormatter`), never as HTML; only `donguri://`, `http://` and `https://` targets become links.
- When inspecting the app's container during debugging, re-query `xcrun simctl get_app_container booted world.wumbo.Donguri data` after every reinstall — the container UUID changes, and stale paths look like "nothing was written".
