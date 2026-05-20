import SwiftUI
import Cocoa
import ServiceManagement
import Vision

@main
struct ScreenSnaggerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.screenshotManager)
        } label: {
            Image(systemName: "camera.viewfinder")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let screenshotManager = ScreenshotManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply the user's thumbnail preference (default off → call disableScreenshotThumbnail).
        screenshotManager.applyScreenshotThumbnail()
        // Re-apply save-mode defaults after the thumbnail killall, so the `location` setting
        // is guaranteed to be in effect for the next screenshot.
        screenshotManager.reapplySaveMode()
        screenshotManager.startWatching()
        // Ensure macOS's login-item registration matches the user's preference. For new
        // installs the default preference is ON, so this registers the app at first launch.
        screenshotManager.reconcileLaunchAtLogin()
    }
}

// MARK: - Screenshot Entry

struct ScreenshotEntry: Identifiable, Codable {
    let id: UUID
    let filename: String
    let url: URL
    let date: Date
    var thumbnail: NSImage?

    init(filename: String, url: URL, date: Date, thumbnail: NSImage? = nil, id: UUID = UUID()) {
        self.id = id
        self.filename = filename
        self.url = url
        self.date = date
        self.thumbnail = thumbnail
    }

    private enum CodingKeys: String, CodingKey { case id, filename, url, date }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.filename = try c.decode(String.self, forKey: .filename)
        self.url = try c.decode(URL.self, forKey: .url)
        self.date = try c.decode(Date.self, forKey: .date)
        self.thumbnail = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(filename, forKey: .filename)
        try c.encode(url, forKey: .url)
        try c.encode(date, forKey: .date)
    }
}

// MARK: - Screenshot Manager

class ScreenshotManager: ObservableObject {

    enum SaveMode: String {
        case autoDelete
        case saveToFolder
    }

    @Published var copyToClipboard: Bool {
        didSet { UserDefaults.standard.set(copyToClipboard, forKey: "copyToClipboard") }
    }
    @Published var saveMode: SaveMode {
        didSet {
            UserDefaults.standard.set(saveMode.rawValue, forKey: "saveMode")
            applySaveMode()
            refreshWatcher()
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLoginPref")
            setLaunchAtLogin(launchAtLogin)
        }
    }
    @Published var showScreenshotThumbnail: Bool {
        didSet {
            UserDefaults.standard.set(showScreenshotThumbnail, forKey: "showScreenshotThumbnail")
            applyScreenshotThumbnail()
        }
    }
    @Published var ocrRenameEnabled: Bool {
        didSet { UserDefaults.standard.set(ocrRenameEnabled, forKey: "ocrRenameEnabled") }
    }
    @Published var outputDirectory: URL? {
        didSet {
            saveDirectoryPath()
            if saveMode == .saveToFolder, let dir = outputDirectory {
                setScreenshotLocation(dir)
            }
            refreshWatcher()
        }
    }
    @Published var recentScreenshots: [ScreenshotEntry] = [] {
        didSet {
            saveRecents()
            syncEntryWatchers()
        }
    }

    /// Whether clipboard copy should happen — always true in auto-delete, user toggle in save mode
    var shouldCopyToClipboard: Bool {
        saveMode == .autoDelete ? true : copyToClipboard
    }

    private var watcher: DirectoryWatcher?
    private var knownFiles: Set<String> = []
    private var knownPaths: Set<String> = []  // post-processing dedup (e.g. OCR rename)

    init() {
        self.copyToClipboard = UserDefaults.standard.object(forKey: "copyToClipboard") as? Bool ?? true
        // launchAtLogin persists user preference (not just system state), so a stale
        // registration (e.g. app moved, fresh DerivedData path) gets re-applied on the
        // next launch instead of silently dropping. Default ON for new installs.
        self.launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLoginPref") as? Bool ?? true
        // Default off: the app was designed around instant clipboard + immediate file save,
        // which requires the macOS floating thumbnail to be disabled.
        self.showScreenshotThumbnail = UserDefaults.standard.object(forKey: "showScreenshotThumbnail") as? Bool ?? false
        self.ocrRenameEnabled = UserDefaults.standard.object(forKey: "ocrRenameEnabled") as? Bool ?? true

        let modeRaw = UserDefaults.standard.string(forKey: "saveMode") ?? SaveMode.saveToFolder.rawValue
        self.saveMode = SaveMode(rawValue: modeRaw) ?? .saveToFolder

        if let path = UserDefaults.standard.string(forKey: "outputDirPath") {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                self.outputDirectory = url
            }
        }

        loadRecents()
    }

    // MARK: - Recents persistence

    private static let recentsKey = "recentScreenshots.v1"

    private func saveRecents() {
        guard let data = try? JSONEncoder().encode(recentScreenshots) else { return }
        UserDefaults.standard.set(data, forKey: Self.recentsKey)
    }

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentsKey),
              var entries = try? JSONDecoder().decode([ScreenshotEntry].self, from: data) else { return }
        // Drop entries whose underlying file is gone
        entries.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        // Rehydrate thumbnails async
        for i in entries.indices {
            entries[i].thumbnail = generateThumbnail(for: entries[i].url, size: NSSize(width: 48, height: 36))
        }
        self.recentScreenshots = entries
    }

    func pruneStaleRecents() {
        let pruned = recentScreenshots.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if pruned.count != recentScreenshots.count {
            recentScreenshots = pruned
        }
    }

    // Per-entry kqueue watchers so a recent disappears in real time when its file is
    // deleted/renamed/moved (Finder, Trash empty, `rm`, etc.) — not just on next click.
    private var entryWatchers: [UUID: DispatchSourceFileSystemObject] = [:]

    private func syncEntryWatchers() {
        let currentIDs = Set(recentScreenshots.map(\.id))

        // Tear down watchers for entries that left the list
        for id in entryWatchers.keys where !currentIDs.contains(id) {
            entryWatchers[id]?.cancel()
            entryWatchers[id] = nil
        }

        // Attach watchers to new entries
        for entry in recentScreenshots where entryWatchers[entry.id] == nil {
            guard FileManager.default.fileExists(atPath: entry.url.path) else { continue }
            let fd = open(entry.url.path, O_EVTONLY)
            guard fd != -1 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.delete, .rename],
                queue: .main
            )
            let entryID = entry.id
            source.setEventHandler { [weak self] in
                self?.recentScreenshots.removeAll { $0.id == entryID }
            }
            source.setCancelHandler { [fd] in close(fd) }
            source.resume()
            entryWatchers[entry.id] = source
        }
    }

    // MARK: - Save Mode

    func reapplySaveMode() {
        applySaveMode()
    }

    private func applySaveMode() {
        switch saveMode {
        case .saveToFolder:
            if let dir = outputDirectory {
                setScreenshotLocation(dir)
            }
        case .autoDelete:
            resetScreenshotLocation()
        }
    }

    // MARK: - Launch at Login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("ScreenSnagger: login item toggle failed — \(error)")
        }
        // Sync our @Published with the actual system state — but only if it changed.
        // Assigning to launchAtLogin always re-fires didSet (even with the same value),
        // which would re-enter setLaunchAtLogin and loop forever.
        DispatchQueue.main.async {
            let actual = SMAppService.mainApp.status == .enabled
            if self.launchAtLogin != actual {
                self.launchAtLogin = actual
            }
        }
    }

    /// Verify the login-item registration matches the user's persisted preference. Call
    /// this on every launch — covers the case where macOS lost our registration (app
    /// moved, DerivedData path changed, fresh install) but the user's preference says it
    /// should be on.
    func reconcileLaunchAtLogin() {
        let registered = SMAppService.mainApp.status == .enabled
        if launchAtLogin && !registered {
            try? SMAppService.mainApp.register()
        } else if !launchAtLogin && registered {
            try? SMAppService.mainApp.unregister()
        }
    }

    // MARK: - macOS Screenshot Location

    private func setScreenshotLocation(_ url: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "com.apple.screencapture", "location", url.path]
        try? task.run()
        task.waitUntilExit()
        restartScreencaptureUI()
    }

    private func resetScreenshotLocation() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["delete", "com.apple.screencapture", "location"]
        try? task.run()
        task.waitUntilExit()
        restartScreencaptureUI()
    }

    /// Apply the user's `showScreenshotThumbnail` preference to macOS's screencapture
    /// default. Called on launch and whenever the toggle flips.
    func applyScreenshotThumbnail() {
        if showScreenshotThumbnail {
            restoreScreenshotThumbnail()
        } else {
            disableScreenshotThumbnail()
        }
    }

    /// Disable the floating screenshot thumbnail so screenshots land in the chosen folder
    /// immediately (no temp-dir staging). Without this, clipboard copy is delayed ~5s and
    /// the temp-dir flow can race with our OCR rename.
    func disableScreenshotThumbnail() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "com.apple.screencapture", "show-thumbnail", "-bool", "false"]
        try? task.run()
        task.waitUntilExit()
        restartScreencaptureUI()
    }

    func restoreScreenshotThumbnail() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["delete", "com.apple.screencapture", "show-thumbnail"]
        try? task.run()
        task.waitUntilExit()
        restartScreencaptureUI()
    }

    private func restartScreencaptureUI() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["SystemUIServer"]
        try? task.run()
    }

    // MARK: - Directory Watcher
    //
    // NSMetadataQuery is unreliable on this user's machine (Spotlight reports an "unknown
    // indexing state" for the home directory, so kMDItemIsScreenCapture-based queries never
    // fire for new files). We use a DispatchSourceFileSystemObject directly on the folder
    // macOS is currently saving screenshots into — this gets a kernel-level notification on
    // every file create/rename in that directory.

    func startWatching() {
        refreshWatcher()
    }

    func refreshWatcher() {
        watcher?.cancel()
        let dir = activeWatchDirectory()
        knownFiles = currentFiles(in: dir)
        let w = DirectoryWatcher(url: dir) { [weak self] in
            self?.handleDirectoryChange()
        }
        w.start()
        watcher = w
    }

    private func activeWatchDirectory() -> URL {
        let desktop = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        switch saveMode {
        case .saveToFolder:
            return outputDirectory ?? desktop
        case .autoDelete:
            return desktop
        }
    }

    private func currentFiles(in dir: URL) -> Set<String> {
        return Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    private func handleDirectoryChange() {
        guard let watcher = watcher else { return }
        let current = currentFiles(in: watcher.url)
        let newFiles = current.subtracting(knownFiles)
        knownFiles = current

        for filename in newFiles {
            // macOS screenshot defaults — covers "Screenshot 2026-...", "Screen Shot 2024-...",
            // and the window-screenshot variants. Skip anything else the user dropped in.
            guard filename.hasPrefix("Screenshot") || filename.hasPrefix("Screen Shot") else { continue }
            guard filename.hasSuffix(".png") || filename.hasSuffix(".jpg") || filename.hasSuffix(".jpeg") else { continue }
            let url = watcher.url.appendingPathComponent(filename)
            handleNewScreenshot(at: url)
        }
    }

    // MARK: - Screenshot Processing

    private func handleNewScreenshot(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        // Defensive: in save mode, make sure the file ends up in the chosen folder, even if
        // macOS's `location` default didn't propagate or it landed elsewhere (e.g. Desktop).
        var workingURL = url
        if saveMode == .saveToFolder, let dir = outputDirectory {
            let parent = url.deletingLastPathComponent().standardizedFileURL.path
            let target = dir.standardizedFileURL.path
            if parent != target {
                let dest = dir.appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.moveItem(at: url, to: dest)
                    workingURL = dest
                } catch {
                    print("ScreenSnagger: move to chosen folder failed (\(url.path) → \(dest.path)): \(error)")
                }
            }
        }

        // OCR rename generic names
        let finalURL = ocrRename(workingURL)
        let displayName = finalURL.deletingPathExtension().lastPathComponent

        // Remember every path we've touched so the metadata-query re-firing for the renamed
        // file doesn't produce a duplicate recents entry.
        knownPaths.insert(workingURL.path)
        knownPaths.insert(finalURL.path)

        // Copy to clipboard
        if shouldCopyToClipboard {
            copyImageToClipboard(at: finalURL)
        }

        switch saveMode {
        case .saveToFolder:
            // Add to recents (dedup by file path so we never show the same screenshot twice)
            let thumb = generateThumbnail(for: finalURL, size: NSSize(width: 48, height: 36))
            DispatchQueue.main.async {
                if self.recentScreenshots.contains(where: { $0.url.path == finalURL.path }) {
                    return
                }
                let entry = ScreenshotEntry(
                    filename: displayName,
                    url: finalURL,
                    date: Date(),
                    thumbnail: thumb
                )
                self.recentScreenshots.insert(entry, at: 0)
                if self.recentScreenshots.count > 10 {
                    self.recentScreenshots = Array(self.recentScreenshots.prefix(10))
                }
            }

        case .autoDelete:
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                try? FileManager.default.removeItem(at: finalURL)
            }
        }
    }

    // MARK: - Clipboard

    private func copyImageToClipboard(at url: URL) {
        guard let fileData = try? Data(contentsOf: url) else {
            print("ScreenSnagger: clipboard read failed for \(url.path)")
            return
        }

        let ext = url.pathExtension.lowercased()
        let item = NSPasteboardItem()

        // Always advertise both PNG and TIFF — browsers (Google Docs) read PNG, native apps prefer TIFF.
        if ext == "png" {
            item.setData(fileData, forType: .png)
            if let bitmap = NSBitmapImageRep(data: fileData),
               let tiff = bitmap.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
        } else {
            // Treat anything else (default macOS screenshots are PNG, but be defensive) as TIFF source.
            item.setData(fileData, forType: .tiff)
            if let bitmap = NSBitmapImageRep(data: fileData),
               let png = bitmap.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
            }
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }

    // MARK: - OCR Rename

    private func ocrRename(_ url: URL) -> URL {
        guard ocrRenameEnabled else { return url }
        let filename = url.deletingPathExtension().lastPathComponent
        guard filename.hasPrefix("Screenshot") || filename.hasPrefix("Screen Shot") else {
            return url
        }

        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return url
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let results = request.results, !results.isEmpty else { return url }

        let topText = results
            .prefix(3)
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")

        let slug = slugify(topText)
        guard !slug.isEmpty else { return url }

        let ext = url.pathExtension
        let newName = String(slug.prefix(60)) + "." + ext
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)

        if FileManager.default.fileExists(atPath: newURL.path) { return url }

        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            return newURL
        } catch {
            return url
        }
    }

    private func slugify(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let cleaned = text.unicodeScalars
            .filter { allowed.contains($0) }
            .map { Character($0) }
        return String(cleaned)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
    }

    // MARK: - Thumbnail

    private func generateThumbnail(for url: URL, size: NSSize) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0)
        thumb.unlockFocus()
        return thumb
    }

    // MARK: - Directory Persistence

    private func saveDirectoryPath() {
        if let url = outputDirectory {
            UserDefaults.standard.set(url.path, forKey: "outputDirPath")
        } else {
            UserDefaults.standard.removeObject(forKey: "outputDirPath")
        }
    }

    func chooseDirectory() {
        // LSUIElement apps don't auto-activate when presenting NSOpenPanel, which leaves
        // the panel's sidebar (Favorites, iCloud, etc.) non-interactive. Force activation
        // and key-window status before runModal.
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select where screenshots should be saved"
        panel.level = .modalPanel

        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
        }
    }

    func revealInFinder(_ entry: ScreenshotEntry) {
        if FileManager.default.fileExists(atPath: entry.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        } else {
            // File got deleted (manually, by Trash empty, etc.) — drop it from recents
            // instead of silently doing nothing.
            recentScreenshots.removeAll { $0.id == entry.id }
            pruneStaleRecents()
        }
    }
}

// MARK: - Directory Watcher

final class DirectoryWatcher {
    let url: URL
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        let fd = open(url.path, O_EVTONLY)
        guard fd != -1 else {
            print("ScreenSnagger: failed to open \(url.path) for watching (errno \(errno))")
            return
        }
        self.fileDescriptor = fd

        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        s.setEventHandler { [weak self] in self?.onChange() }
        s.setCancelHandler { [fd] in close(fd) }
        s.resume()
        self.source = s
    }

    func cancel() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }

    deinit { cancel() }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @EnvironmentObject var manager: ScreenshotManager
    @State private var isHoveringQuit = false
    @State private var recentsExpanded = false
    @State private var showModeInfo = false
    @State private var showPrefsInfo = false

    private var visibleRecents: [ScreenshotEntry] {
        let limit = recentsExpanded ? 10 : 3
        return Array(manager.recentScreenshots.prefix(limit))
    }

    private var headerSubtitle: String {
        switch manager.saveMode {
        case .autoDelete:
            return "Auto-delete"
        case .saveToFolder:
            if let dir = manager.outputDirectory {
                return "Saves to \(dir.lastPathComponent) folder"
            }
            return "Saves to folder"
        }
    }

    private var modeInfoEntries: [(String, String)] {
        var entries: [(String, String)] = [
            ("Auto-delete after copy",
             "Screenshots are copied to your clipboard and then deleted from your Desktop two seconds later. Nothing is saved to disk."),
            ("Save to folder",
             "Screenshots are saved to the folder you pick. The original timestamp filename (e.g. Screenshot 2026-05-20 at 9.42 PM.png) is used unless \"Auto-rename with detected text\" is on.")
        ]
        if manager.saveMode == .saveToFolder {
            entries.append(("Also copy to clipboard",
                            "Adds the screenshot to your clipboard as soon as it's saved, so you can paste it without opening the file."))
        }
        return entries
    }

    private let prefsInfoEntries: [(String, String)] = [
        ("Launch at login",
         "Starts ScreenSnagger automatically when you log in to your Mac. The app needs to be running for any screenshot you take to be processed."),
        ("Auto-rename with detected text",
         "Uses your Mac's on-device text recognition to summarize the text in each screenshot and use it as the filename. Nothing leaves your Mac. If no readable text is found, the original name is kept."),
        ("Show floating thumbnail",
         "macOS's built-in screenshot preview that floats in the bottom-right corner. ScreenSnagger turns this off by default so screenshots are saved and copied to your clipboard instantly. Turning it on adds about a 5-second delay before the file is available.")
    ]

    @ViewBuilder
    private func sectionInfo(isOpen: Binding<Bool>, entries: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: { withAnimation(.easeInOut(duration: 0.18)) { isOpen.wrappedValue.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: isOpen.wrappedValue ? "info.circle.fill" : "info.circle")
                            .font(.system(size: 10))
                        Text(isOpen.wrappedValue ? "Hide info" : "What do these do?")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(isOpen.wrappedValue ? .accentColor : Color(nsColor: .tertiaryLabelColor))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)

            if isOpen.wrappedValue {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries, id: \.0) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.0)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.primary)
                            Text(entry.1)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {

            // Header ──
            // (prune missing files each time the popover opens so deleted screenshots fall off)
            EmptyView()
                .onAppear { manager.pruneStaleRecents() }

            // ── Header ──
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.accentColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("ScreenSnagger")
                        .font(.system(size: 13, weight: .semibold))
                    Text(headerSubtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider().padding(.horizontal, 12)

            // ── Mode Selection ──
            VStack(spacing: 0) {
                ModeRow(
                    icon: "trash",
                    label: "Auto-delete after copy",
                    isSelected: manager.saveMode == .autoDelete,
                    action: { manager.saveMode = .autoDelete }
                )

                ModeRow(
                    icon: "folder",
                    label: "Save to folder",
                    isSelected: manager.saveMode == .saveToFolder,
                    action: { manager.saveMode = .saveToFolder }
                )

                // Folder picker (save mode only)
                if manager.saveMode == .saveToFolder {
                    Button(action: { manager.chooseDirectory() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.badge.gearshape")
                                .font(.system(size: 11))
                                .foregroundColor(.accentColor)
                                .frame(width: 18)

                            if let dir = manager.outputDirectory {
                                Text(dir.lastPathComponent)
                                    .font(.system(size: 11))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text("Choose folder…")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 26)

                    // Clipboard toggle (only in save mode — auto-delete always copies)
                    SettingToggle(
                        icon: "doc.on.clipboard",
                        label: "Also copy to clipboard",
                        isOn: $manager.copyToClipboard
                    )
                }

                sectionInfo(
                    isOpen: $showModeInfo,
                    entries: modeInfoEntries
                )
            }
            .padding(.vertical, 6)
            .glassEffect(in: .rect(cornerRadius: 12))
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // ── Preferences ──
            VStack(spacing: 0) {
                SettingToggle(
                    icon: "sunrise",
                    label: "Launch at login",
                    isOn: $manager.launchAtLogin
                )
                SettingToggle(
                    icon: "text.viewfinder",
                    label: "Auto-rename with detected text",
                    isOn: $manager.ocrRenameEnabled
                )
                SettingToggle(
                    icon: "rectangle.on.rectangle",
                    label: "Show floating thumbnail",
                    isOn: $manager.showScreenshotThumbnail
                )

                sectionInfo(
                    isOpen: $showPrefsInfo,
                    entries: prefsInfoEntries
                )
            }
            .padding(.vertical, 4)
            .glassEffect(in: .rect(cornerRadius: 12))
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // ── Recent Screenshots ──
            if !manager.recentScreenshots.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) { recentsExpanded.toggle() }
                    }) {
                        HStack {
                            Text("RECENTLY SAVED")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                                .tracking(0.5)

                            Spacer()

                            if manager.recentScreenshots.count > 3 {
                                Image(systemName: recentsExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    ForEach(visibleRecents) { entry in
                        RecentRow(entry: entry) {
                            manager.revealInFinder(entry)
                        }
                    }
                }
                .padding(.bottom, 6)
                .glassEffect(in: .rect(cornerRadius: 12))
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            // ── Footer ──
            Divider().padding(.horizontal, 12)

            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack {
                    Spacer()
                    Text("Quit")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringQuit = $0 }
            .background(isHoveringQuit ? Color.primary.opacity(0.04) : .clear)
            .padding(.bottom, 4)
        }
        .frame(width: 280)
    }
}

// MARK: - Setting Toggle (checkbox style)

struct SettingToggle: View {
    let icon: String
    let label: String
    @Binding var isOn: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(isOn ? .accentColor : .secondary)
                .frame(width: 18, alignment: .center)

            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.04) : .clear)
                .padding(.horizontal, 8)
        )
    }
}

// MARK: - Mode Row (radio style)

struct ModeRow: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 18, alignment: .center)

                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.accentColor : Color(nsColor: .quaternaryLabelColor), lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.04) : .clear)
                .padding(.horizontal, 8)
        )
    }
}

// MARK: - Recent Screenshot Row

struct RecentRow: View {
    let entry: ScreenshotEntry
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if let thumb = entry.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.1))
                        .frame(width: 28, height: 20)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 9))
                                .foregroundColor(.accentColor.opacity(0.5))
                        )
                }

                Text(entry.filename)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text(entry.date, style: .time)
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag {
            NSItemProvider(contentsOf: entry.url) ?? NSItemProvider()
        }
        .onHover { isHovering = $0 }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.04) : .clear)
                .padding(.horizontal, 8)
        )
    }
}
