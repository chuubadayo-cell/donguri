# AGENTS.md: quick start for an AI agent on this Mac

This is いろは, a personal iOS app (a fork of the Donguri 5ch reader) for Japanese immersion: 5ch threads, a YouTube player, X, a web browser, manga, and dictionary lookups with Anki mining. **Read `CLAUDE.md` before changing anything.** It holds the full architecture and a long list of gotchas that have already caused bugs.

## Rules (the owner's, always in force)

- **Personal build: never push or publish anything.** Commit locally only. The only remote is upstream Donguri. Ignore warnings about unpushed commits.
- Keep the signing settings in `project.pbxproj` as they are (team `35Q86KFL9J`, bundle id `com.chase.Donguri`). Never revert them.
- Don't delete `backups/`, `Payload/`, `Donguri.ipa` or the `.patch` files without asking.
- `Donguri/Localizable.xcstrings` may contain the owner's own uncommitted edits. Don't commit those by accident.
- UI strings are Japanese literals stored in String Catalogs. To add new ones to `Donguri/Localizable.xcstrings` with an English value, run `python3 tools/addstr.py Donguri/Localizable.xcstrings new.json`. The file `new.json` maps each Japanese string to its English text, like `{"日本語": "English"}`.
- After touching JavaScript embedded in a Swift `"""` string, run `python3 tools/check-page-scripts.py`.
- End commit messages with a `Co-Authored-By:` line naming yourself.
- How the owner likes to work: short replies; do the work and build it; then say what changed in plain words. Ask only when the choice is really theirs.

## Environment

- Swift 6.2 with default MainActor isolation, C++ interop on. The deployment target is iOS 18; the phone is an iPhone 13 mini.
- New files under `Donguri/` are picked up automatically. Don't hand-edit `project.pbxproj` to add them.
- There are no tests and no linter. A successful build is the check.
- `gh`, `node` and `timeout` are not installed.

## Build and install

Every command needs Xcode selected:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Simulator build:

```bash
xcodebuild -project Donguri.xcodeproj -scheme Donguri -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation build
```

Phone build (always Release; it uses a free account, so an install expires after 7 days and reinstalling re-signs it):

```bash
xcodebuild -project Donguri.xcodeproj -scheme Donguri -configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates -skipPackagePluginValidation build
```

Install on the phone:

```bash
xcrun devicectl device install app --device 00008150-0016492E022A401C "$(find ~/Library/Developer/Xcode/DerivedData/Donguri-*/Build/Products/Release-iphoneos -maxdepth 1 -name 'Donguri.app' | head -1)"
```

To see only what matters in the build output, pipe it through `grep -E "error:|BUILD (SUCCEEDED|FAILED)"`.

## Where things are

- `Donguri/View/Video/VideoPlayerView.swift`: the YouTube player, the miniplayer and the minimize animation (`VideoDock`, `MovingVideo`)
- `Donguri/View/Manga/`, `Donguri/Service/Manga/`: manga sources, the library, the reader (`MangaReaderView`, `MangaPager`) and OCR
- `Donguri/View/Browser/`, `Donguri/Service/YouTube/`: the browser, X and YouTube's own API (InnerTube)
- `Donguri/View/Post/`, `Donguri/Service/`: 5ch, dictionary lookup (`LookupEngine`) and Anki (`AnkiManager`)

## Limits of the simulator

Picture in Picture doesn't work there. Smoothness can only be judged on the phone, so say when something wasn't verified there.
