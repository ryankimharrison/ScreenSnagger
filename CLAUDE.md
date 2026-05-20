# CLAUDE.md — ScreenSnag

## Project

Native macOS menu bar app that intercepts screenshots, OCR-renames them, copies to clipboard, and optionally saves to a user-chosen folder or auto-deletes. Single-file Swift/SwiftUI app targeting macOS 26+ (Tahoe).

## Tech Stack

- Swift 5.10+
- SwiftUI with `MenuBarExtra(style: .window)`
- macOS 26.0 (Tahoe) minimum deployment target — uses Liquid Glass (`.glassEffect()`)
- Vision framework for OCR rename
- `DispatchSourceFileSystemObject` (kqueue) directory watcher on the active save folder
- `SMAppService` for launch-at-login
- `NSPasteboard` for clipboard (PNG + TIFF written to a single `NSPasteboardItem`)
- Unsandboxed (requires `defaults write` and `killall SystemUIServer`)

No third-party dependencies. No SPM packages. No CocoaPods. **No notifications** — intentionally removed; clipboard + recents are the only user-facing feedback.

## Project Layout

```
ScreenSnag/
├── CLAUDE.md              ← you are here
├── project.yml            ← XcodeGen spec (generates .xcodeproj)
├── setup.sh               ← run this first: installs XcodeGen, generates project
├── Sources/
│   └── ScreenSnagApp.swift   ← entire app (single file)
└── Resources/
    ├── Info.plist
    └── ScreenSnag.entitlements
```

## Build

### First time setup
```bash
chmod +x setup.sh
./setup.sh
```
This installs XcodeGen (if missing) via Homebrew and generates `ScreenSnag.xcodeproj`.

### Build & run
```bash
xcodebuild -project ScreenSnag.xcodeproj -scheme ScreenSnag -configuration Debug build
```

Or open `ScreenSnag.xcodeproj` in Xcode and hit ⌘R.

### Clean build
```bash
xcodebuild -project ScreenSnag.xcodeproj -scheme ScreenSnag clean
```

## Architecture

Everything is in `ScreenSnagApp.swift`. One file. Sections:

1. **App entry** — `MenuBarExtra` with `.window` style
2. **AppDelegate** — disables macOS's floating screenshot thumbnail on launch, re-applies save-mode defaults after the thumbnail-disable killall, starts the directory watcher, registers login item on first launch, restores the thumbnail on terminate
3. **ScreenshotEntry** — `Identifiable, Codable` model (filename, URL, date, thumbnail). Thumbnail is excluded from Codable and regenerated from disk on load
4. **ScreenshotManager** — `ObservableObject`, the brain:
   - Watches the active save directory (Desktop in auto-delete mode, chosen folder in save mode) via `DispatchSourceFileSystemObject` with `eventMask: [.write, .extend, .rename, .delete]`. NSMetadataQuery is intentionally NOT used — Spotlight indexing was unreliable for some users (`mdutil` reported "unknown indexing state")
   - File diffing: snapshot of folder contents on watcher (re)start, diff against current contents on every event, only files starting with `Screenshot`/`Screen Shot` and ending in `.png`/`.jpg`/`.jpeg` are processed
   - Two modes: `.autoDelete` (clipboard + delete file 2s later) and `.saveToFolder` (redirect macOS screenshot location)
   - Defensive move: in save mode, if a file lands anywhere other than `outputDirectory`, it's moved there before processing — covers cases where `defaults write … location` didn't fully propagate
   - OCR rename via `VNRecognizeTextRequest` (`.fast`, no language correction, top 3 results slugified). After rename, both pre- and post-rename paths get inserted into `knownPaths` to prevent double-processing
   - Thumbnail generation via `NSImage` scaling
   - Recents persisted to UserDefaults as JSON (`recentScreenshots.v1` key) — survive app restarts and folder changes; thumbnails rehydrated from disk on load; missing files pruned on `pruneStaleRecents()` (called from MenuBarView's `.onAppear`)
   - `SMAppService.mainApp` for login item
   - `defaults write com.apple.screencapture location` redirects screenshot save path; `defaults write com.apple.screencapture show-thumbnail -bool false` disables the floating preview (so files land in the chosen folder instantly with no temp-dir staging)
5. **DirectoryWatcher** — small wrapper around `DispatchSource.makeFileSystemObjectSource` over an `O_EVTONLY` file descriptor; cancels cleanly on `deinit`
6. **Views** — `MenuBarView`, `SettingToggle`, `ModeRow`, `RecentRow`

## Key Behaviors

- **Auto-delete mode**: clipboard is always on (no toggle shown), file deleted 2s after clipboard copy, no recents added. Watches `~/Desktop`
- **Save mode**: clipboard is optional ("Also copy to clipboard" toggle), folder picker shown, new entries added to recents. Watches the chosen folder
- **Recents persist across mode switches AND app restarts** — old save-mode entries remain visible in auto-delete mode; stored as JSON in UserDefaults under `recentScreenshots.v1`
- **Recents**: collapsible, 3 collapsed / 10 expanded, real thumbnails, dedup by file path, deleted files pruned on popover open. Click → reveal in Finder (`activateFileViewerSelecting`). Drag → `NSItemProvider`
- **Recents survive folder changes**: each entry stores an absolute file path, so changing the save folder doesn't invalidate prior recents
- **Recents prune on delete**: clicking a recent whose underlying file is gone (manually deleted, Trash emptied) removes the entry instead of silently doing nothing; `pruneStaleRecents()` is also called on popover open
- **Launch-at-login**: user preference is persisted in `launchAtLoginPref` (defaults to ON for new installs). `reconcileLaunchAtLogin()` runs on every launch and re-registers if the system lost the registration (e.g. app moved, fresh DerivedData path, denied prompt). Uses `SMAppService.mainApp.register()` — works for installed apps in `/Applications` without entitlements
- **OCR rename**: only on generic `Screenshot...` / `Screen Shot...` filenames, skips window captures (already named well)
- **Info hint**: "Screenshots are copied to clipboard then deleted" shown in auto-delete mode, wraps to two lines if needed
- **Thumbnail disable**: macOS's floating bottom-right preview is turned off so the file lands in the save folder immediately (no temp-dir → final-location move). Restored on app quit

## Clipboard write

Done via a single `NSPasteboardItem` carrying both `.png` and `.tiff` data:

```swift
let item = NSPasteboardItem()
item.setData(pngData, forType: .png)
item.setData(tiffData, forType: .tiff)
pb.clearContents()
pb.writeObjects([item])
```

The older `pb.writeObjects([NSImage])` pattern doesn't reliably populate Clipboard API consumers (Google Docs, etc.) — they need raw `image/png` bytes.

## Signing

Unsigned for development. Right-click → Open on first launch to bypass Gatekeeper.
SMAppService login item works with development signing identity.

## Constraints

- Do not introduce third-party dependencies
- Do not sandbox the app (needs `defaults write` and `killall SystemUIServer`)
- Do not split into multiple Swift files — keep everything in `ScreenSnagApp.swift`
- Do not add a notifications subsystem — explicitly removed
- Menu bar icon: `camera.viewfinder` (SF Symbols)
- Popover width: 280pt, Liquid Glass (`.glassEffect(in: .rect(cornerRadius: 12))`) on each section container (Mode Selection, Preferences, Recently Saved). No popover-wide material
- `LSUIElement = true` in Info.plist (no dock icon)
- Use `Color(nsColor: .tertiaryLabelColor)` / `Color(nsColor: .quaternaryLabelColor)` for label colors — SwiftUI's `Color` has no `.tertiaryLabel`/`.quaternaryLabel` members
