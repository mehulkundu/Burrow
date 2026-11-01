import AppKit
import CoreServices

/// Where a window is: Home, the This Mac page, or a folder path (no trailing slash).
enum Location: Hashable {
    case home
    case thisMac
    case folder(String)
}

nonisolated struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isFolder: Bool
    /// Apps and other bundles: they open like files, and Show Package Contents goes in.
    let isPackage: Bool
    let isHidden: Bool
    /// Finder tags, shown as colored dots.
    let tags: [String]
    /// -1 for folders, so they sort before every file.
    let size: Int64
    let modified: Date
    let kind: String
    var id: URL { url }
}

/// File system work, off the main thread.
nonisolated enum FS {
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
                                          .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .tagNamesKey]

    static func item(_ url: URL) -> FileItem? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        // Apps and other packages open like files, as an .exe does on Windows.
        var isFolder = v.isDirectory == true && v.isPackage != true
        if v.isSymbolicLink == true, let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) {
            isFolder = target.isDirectory == true && target.isPackage != true
        }
        return FileItem(url: url, name: url.lastPathComponent, isFolder: isFolder, isPackage: v.isPackage == true,
                        isHidden: v.isHidden == true, tags: v.tagNames ?? [],
                        size: v.isDirectory == true ? -1 : Int64(v.fileSize ?? 0),
                        modified: v.contentModificationDate ?? .distantPast, kind: v.localizedTypeDescription ?? "")
    }

    @concurrent static func list(_ dir: URL) async throws -> [FileItem] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys).compactMap(item)
    }

    @concurrent static func subfolders(_ path: String, hidden: Bool) async -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys)) ?? []
        return items.compactMap(item).filter { $0.isFolder && (hidden || !$0.isHidden) }
            .map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { (path as NSString).appendingPathComponent($0) }
    }

    /// Copies or moves each item into `dest`. Never overwrites: a name that
    /// is taken gets " (2)", and a copy into its own folder gets " - Copy".
    /// Returns the names it created and the errors it hit.
    @concurrent static func transfer(_ urls: [URL], to dest: URL, move: Bool) async -> (done: [Moved], errors: [String]) {
        let fm = FileManager.default
        let destPath = dest.resolvingSymlinksInPath().path
        var done: [Moved] = [], errors: [String] = []
        for src in urls {
            let srcPath = src.resolvingSymlinksInPath().path
            let sameFolder = (srcPath as NSString).deletingLastPathComponent == destPath
            if srcPath == destPath || (move && sameFolder) { continue }
            if destPath.hasPrefix(srcPath + "/") {
                errors.append("The destination folder is inside the folder \"\(src.lastPathComponent)\".")
                continue
            }
            let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let target = uniqueURL(in: dest, name: src.lastPathComponent, isFolder: isDir, copy: sameFolder)
            do {
                if move { try fm.moveItem(at: src, to: target) } else { try fm.copyItem(at: src, to: target) }
                done.append(Moved(from: src, to: target))
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        return (done, errors)
    }

    /// Moves or renames, stepping through a temporary name when only the
    /// case changes (a case-insensitive disk sees the new name as taken).
    static func move(_ src: URL, to dst: URL) throws {
        if src.lastPathComponent.lowercased() == dst.lastPathComponent.lowercased(),
           src.deletingLastPathComponent() == dst.deletingLastPathComponent() {
            let temp = src.deletingLastPathComponent().appending(path: ".\(UUID().uuidString)")
            try FileManager.default.moveItem(at: src, to: temp)
            try FileManager.default.moveItem(at: temp, to: dst)
        } else {
            try FileManager.default.moveItem(at: src, to: dst)
        }
    }

    /// Reverses one recorded action. Never overwrites: a file back in its old place stops that step.
    @concurrent static func undo(_ op: FileOp) async -> [String] {
        let fm = FileManager.default
        var errors: [String] = []
        switch op {
        case .moved(let pairs), .trashed(let pairs):
            for pair in pairs.reversed() {
                let caseOnly = pair.from.path.lowercased() == pair.to.path.lowercased()
                if !caseOnly, fm.fileExists(atPath: pair.from.path) {
                    errors.append("Something named \"\(pair.from.lastPathComponent)\" is already back in its old place.")
                    continue
                }
                do { try move(pair.to, to: pair.from) } catch { errors.append(error.localizedDescription) }
            }
        case .created(let urls):
            for url in urls {
                do { try fm.trashItem(at: url, resultingItemURL: nil) } catch { errors.append(error.localizedDescription) }
            }
        }
        return errors
    }

    /// Zips items that share a folder, named like Explorer's "Compress to ZIP file".
    @concurrent static func zip(_ urls: [URL]) async -> (URL?, String?) {
        guard let first = urls.first else { return (nil, nil) }
        let dir = first.deletingLastPathComponent()
        let isDir = (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let name = urls.count > 1 ? "Archive" : isDir ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent
        let target = uniqueURL(in: dir, name: name + ".zip", isFolder: false, copy: false)
        let items = urls.filter { $0.deletingLastPathComponent() == dir }.map(\.lastPathComponent)
        let error = run("/usr/bin/zip", ["-r", "-y", "-q", "-X", target.lastPathComponent] + items, in: dir)
        return error == nil ? (target, nil) : (nil, error)
    }

    /// Extract All. A single folder or file inside lands next to the archive, as
    /// Finder does; several items go into a new folder named after the archive.
    @concurrent static func unzip(_ archive: URL) async -> (URL?, String?) {
        let fm = FileManager.default
        let dir = archive.deletingLastPathComponent()
        // Our own scratch folder next to the archive, so the final move stays on one drive.
        let scratch = dir.appending(path: ".burrow-extract-\(UUID().uuidString)")
        if let error = run("/usr/bin/ditto", ["-x", "-k", archive.path, scratch.path], in: nil) {
            try? fm.removeItem(at: scratch)
            return (nil, error)
        }
        let inside = ((try? fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" }
        do {
            if inside.count == 1 {
                let isDir = (try? inside[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                let target = uniqueURL(in: dir, name: inside[0].lastPathComponent, isFolder: isDir, copy: false)
                try fm.moveItem(at: inside[0], to: target)
                try fm.removeItem(at: scratch)
                return (target, nil)
            }
            let target = uniqueURL(in: dir, name: archive.deletingPathExtension().lastPathComponent, isFolder: true, copy: false)
            try fm.moveItem(at: scratch, to: target)
            return (target, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// Runs a command line tool; returns its error text, or nil when it worked.
    private static func run(_ tool: String, _ arguments: [String], in dir: URL?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = dir
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return error.localizedDescription }
        process.waitUntilExit()
        if process.terminationStatus == 0 { return nil }
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.isEmpty ? "\((tool as NSString).lastPathComponent) failed." : text
    }

    /// Everything inside a folder, as Properties counts it.
    @concurrent static func size(of dir: URL) async -> Int64 {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                                          options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        while !Task.isCancelled, let url = walker.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    @concurrent static func eject(_ path: String) async -> String? {
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path)) } catch { return error.localizedDescription }
        return nil
    }

    static func uniqueURL(in dir: URL, name: String, isFolder: Bool, copy: Bool) -> URL {
        let ext = isFolder ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let stem = copy ? "\(base) - Copy" : base
        let dot = ext.isEmpty ? "" : ".\(ext)"
        var candidate = dir.appending(path: stem + dot)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appending(path: "\(stem) (\(n))\(dot)")
            n += 1
        }
        return candidate
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let id = { (u: URL) in (try? u.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject }
        guard let x = id(a), let y = id(b) else { return false }
        return x.isEqual(y)
    }

    /// Spotlight's answer for names containing `query` under `root`: the Mac's
    /// search index, as Explorer uses the Windows index. Hidden files and
    /// ~/Library are left out unless hidden items are shown, as AppData is on Windows.
    @concurrent static func spotlight(_ root: URL, for query: String, hidden: Bool, contents: Bool = false) async -> [FileItem] {
        let paths = mdfind(["-onlyin", root.path] + (contents ? [query] : ["-name", query]), hidden: hidden, limit: 2000)
        return paths.compactMap { item(URL(fileURLWithPath: $0)) }.filter { hidden || !$0.isHidden }
    }

    /// Files opened in the last two weeks, newest first, for Home.
    @concurrent static func recent() async -> [RecentFile] {
        let paths = mdfind(["-onlyin", URL.homeDirectory.path, "kMDItemLastUsedDate >= $time.today(-14)"], hidden: false, limit: 500)
        let used = paths.compactMap { path -> (String, Date)? in
            guard let md = MDItemCreate(kCFAllocatorDefault, path as CFString),
                  let date = MDItemCopyAttribute(md, kMDItemLastUsedDate) as? Date else { return nil }
            return (path, date)
        }
        return used.sorted { $0.1 > $1.1 }.lazy
            .compactMap { path, date in item(URL(fileURLWithPath: path)).map { RecentFile(item: $0, used: date) } }
            .filter { !$0.item.isFolder }
            .prefix(30).map { $0 }
    }

    /// Runs mdfind and reads paths as they arrive, up to `limit`.
    private static func mdfind(_ arguments: [String], hidden: Bool, limit: Int) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let library = URL.homeDirectory.path + "/Library/"
        var paths: [String] = [], buffer = Data()
        reading: while !Task.isCancelled {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let path = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                if hidden || (!path.contains("/.") && !path.hasPrefix(library)) { paths.append(path) }
                if paths.count >= limit { break reading }
            }
        }
        if process.isRunning { process.terminate() }
        return paths
    }

    /// Names that contain `query`, anywhere under `root`, in batches as they are found.
    static func search(_ root: URL, for query: String, hidden: Bool) -> AsyncStream<[FileItem]> {
        AsyncStream { continuation in
            let task = Task.detached {
                walk(root, query, hidden) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // ponytail: walks the disk on every search, like Explorer on an unindexed
    // folder. Capped at 5,000 hits; switch to NSMetadataQuery (Spotlight) if
    // whole-disk searches need to be instant.
    private static func walk(_ root: URL, _ query: String, _ hidden: Bool, emit: ([FileItem]) -> Void) {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !hidden { options.insert(.skipsHiddenFiles) }
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options,
                                                          errorHandler: { _, _ in true }) else { return }
        var batch: [FileItem] = [], found = 0, last = ContinuousClock.now
        while found < 5000, !Task.isCancelled, let url = walker.nextObject() as? URL {
            if url.lastPathComponent.localizedStandardContains(query), let item = item(url) {
                batch.append(item)
                found += 1
            }
            if !batch.isEmpty, ContinuousClock.now - last > .milliseconds(150) {
                emit(batch)
                batch = []
                last = .now
            }
        }
        if !batch.isEmpty { emit(batch) }
    }
}

nonisolated struct RecentFile: Identifiable, Sendable {
    let item: FileItem
    let used: Date
    var id: URL { item.url }
}

nonisolated struct Volume: Identifiable, Sendable {
    let path: String
    var canEject: Bool { path.hasPrefix("/Volumes/") }
    let name: String
    let total: Int64
    let free: Int64
    var id: String { path }
}

nonisolated struct Moved: Sendable {
    let from: URL
    let to: URL
}

/// What Ctrl+Z can reverse.
nonisolated enum FileOp: Sendable {
    /// Moves and renames: each goes back.
    case moved([Moved])
    /// Copies, new items, archives: they go to the Trash.
    case created([URL])
    /// From where it was to the Trash: each comes back.
    case trashed([Moved])
}

/// One undo history for every window, as in Explorer.
@Observable final class History {
    static let shared = History()
    private(set) var ops: [FileOp] = []

    func record(_ op: FileOp) {
        ops.append(op)
        if ops.count > 100 { ops.removeFirst() }
    }

    func pop() -> FileOp? { ops.popLast() }
}

/// New names for a multi-file rename.
nonisolated enum Renamer {
    /// Find and replace when `find` has text; otherwise "base (1).ext", "base (2).ext", as
    /// Explorer does when you rename several files at once.
    static func plan(_ items: [(name: String, isFolder: Bool)], find: String, replace: String, base: String, start: Int) -> [String] {
        if !find.isEmpty {
            return items.map { $0.name.replacingOccurrences(of: find, with: replace, options: .caseInsensitive) }
        }
        return items.enumerated().map { index, item in
            let ext = item.isFolder ? "" : (item.name as NSString).pathExtension
            return "\(base) (\(start + index))" + (ext.isEmpty ? "" : ".\(ext)")
        }
    }

    /// Why a plan can't run, or nil when it can.
    static func problem(_ old: [String], _ new: [String], others: Set<String>) -> String? {
        if new.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) { return "Every name needs at least one character." }
        if new.contains(where: { $0.contains("/") || $0.contains(":") }) { return "A file name can't contain / or :." }
        if Set(new.map { $0.lowercased() }).count != new.count { return "Two files would get the same name." }
        let taken = others.subtracting(old.map { $0.lowercased() })
        if let clash = new.first(where: { taken.contains($0.lowercased()) }) { return "\"\(clash)\" is already in this folder." }
        return nil
    }
}

enum Places {
    struct Folder: Identifiable {
        let title: String
        let path: String
        var id: String { path }
    }

    /// What Windows shows under This PC, plus Home and Applications.
    static var userFolders: [Folder] {
        let home = URL.homeDirectory.path
        return ["Desktop", "Documents", "Downloads", "Music", "Pictures", "Movies"]
            .map { Folder(title: $0, path: home + "/" + $0) }
            + [Folder(title: "Applications", path: "/Applications"), Folder(title: NSUserName(), path: home)]
    }

    static func volumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return Volume(path: url.path, name: v?.volumeLocalizedName ?? url.lastPathComponent,
                          total: Int64(v?.volumeTotalCapacity ?? 0), free: v?.volumeAvailableCapacityForImportantUsage ?? 0)
        }
    }

    static var iCloudDrive: String? {
        let path = URL.homeDirectory.path + "/Library/Mobile Documents/com~apple~CloudDocs"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func name(_ path: String) -> String {
        FileManager.default.displayName(atPath: path)
    }
}

/// Settings every window shares: Favorites, hidden items, the view, the details pane.
@Observable final class Prefs {
    static let shared = Prefs(defaults: .standard)
    @ObservationIgnored let defaults: UserDefaults

    var pins: [String] { didSet { defaults.set(pins, forKey: "pins") } }
    var showHidden: Bool { didSet { defaults.set(showHidden, forKey: "showHidden") } }
    /// Large icons instead of Details.
    var iconView: Bool { didSet { defaults.set(iconView, forKey: "iconView") } }
    var showDetails: Bool { didSet { defaults.set(showDetails, forKey: "showDetails") } }
    /// The navigation pane on the left (View > Show > Navigation pane in Explorer).
    var showSidebar: Bool { didSet { defaults.set(showSidebar, forKey: "showSidebar") } }
    /// Panel widths, set by dragging their edges.
    var sidebarWidth: Double { didSet { defaults.set(sidebarWidth, forKey: "sidebarWidth") } }
    var detailsWidth: Double { didSet { defaults.set(detailsWidth, forKey: "detailsWidth") } }
    /// Search inside files too, as Explorer does in indexed folders.
    var searchContents: Bool { didSet { defaults.set(searchContents, forKey: "searchContents") } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let home = URL.homeDirectory.path
        pins = defaults.stringArray(forKey: "pins")
            ?? ["Desktop", "Downloads", "Documents", "Pictures", "Music", "Movies"].map { home + "/" + $0 }
        showHidden = defaults.bool(forKey: "showHidden")
        iconView = defaults.bool(forKey: "iconView")
        showDetails = defaults.bool(forKey: "showDetails")
        showSidebar = defaults.object(forKey: "showSidebar") as? Bool ?? true
        sidebarWidth = defaults.object(forKey: "sidebarWidth") as? Double ?? 236
        detailsWidth = defaults.object(forKey: "detailsWidth") as? Double ?? 270
        searchContents = defaults.bool(forKey: "searchContents")
    }

    func togglePin(_ path: String) {
        if let i = pins.firstIndex(of: path) { pins.remove(at: i) } else { pins.append(path) }
    }
}

/// Items cut with Ctrl+X, shown dimmed until they are pasted.
@Observable final class Clip {
    static let shared = Clip()
    var cut: Set<URL> = []
    /// The pasteboard's change count when we cut. A newer copy anywhere cancels the cut.
    var changeCount = -1
}

/// One window or tab: where it is, what it lists, and every action on it.
@Observable final class Browser {
    static weak var active: Browser?
    @ObservationIgnored weak var window: NSWindow?
    let prefs: Prefs
    @ObservationIgnored let pasteboard: NSPasteboard

    private(set) var location: Location = .home
    private(set) var rows: [FileItem] = []
    private(set) var recent: [RecentFile] = []
    private(set) var loadError: String?
    private(set) var isSearching = false
    private(set) var status: String?
    var selection = Set<URL>()
    var sortOrder = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard)] { didSet { resort() } }
    var searchText = "" { didSet { if searchText != oldValue { search() } } }
    var renaming: URL?
    /// Several files picked for one rename (F2 with more than one selected).
    var batchRenaming: [URL]?
    /// The file Quick Look shows (Space).
    var quickLook: URL?
    var editingAddress = false
    /// Bumped to move focus to the search field.
    var focusSearch = 0
    var alert: String?

    private var items: [FileItem] = [] { didSet { resort() } }
    private var results: [FileItem]? { didSet { resort() } }
    @ObservationIgnored private var back: [Location] = []
    @ObservationIgnored private var forward: [Location] = []
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var pendingSelect: Set<String> = []
    @ObservationIgnored private var pendingRename = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchedPath: String?
    @ObservationIgnored private var typed = ""
    @ObservationIgnored private var typedAt = Date.distantPast
    @ObservationIgnored private var anchor: URL?
    /// Columns in the icon grid, for the arrow keys. The grid sets it.
    @ObservationIgnored var gridColumns = 1

    init(prefs: Prefs = .shared, pasteboard: NSPasteboard = .general) {
        self.prefs = prefs
        self.pasteboard = pasteboard
    }

    var folder: URL? {
        if case .folder(let path) = location { URL(fileURLWithPath: path) } else { nil }
    }

    var title: String {
        switch location {
        case .home: "Home"
        case .thisMac: "This Mac"
        case .folder(let path): Places.name(path)
        }
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoUp: Bool { folder != nil }
    var canGoForward: Bool { !forward.isEmpty }
    var isSearchActive: Bool { results != nil }
    var searchPrompt: String { "Search \(title)" }

    var selectedItems: [FileItem] { rows.filter { selection.contains($0.url) } }

    /// This Mac, then your home folder or the drive, then each folder down to here.
    var crumbs: [(title: String, location: Location)] {
        if location == .home { return [("Home", .home)] }
        var out: [(String, Location)] = [("This Mac", .thisMac)]
        guard let dir = folder else { return out }
        let home = URL.homeDirectory.path
        if dir.path == home || dir.path.hasPrefix(home + "/") {
            out.append((NSUserName(), .folder(home)))
            var path = home
            for part in dir.path.dropFirst(home.count).split(separator: "/") {
                path += "/" + part
                out.append((String(part), .folder(path)))
            }
            return out
        }
        var volume = (try? dir.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path ?? "/"
        // /Users sits on the Data volume, but its path starts at /.
        if volume != "/", !dir.path.hasPrefix(volume) { volume = "/" }
        out.append((Places.name(volume), .folder(volume)))
        var path = volume
        for part in dir.path.dropFirst(volume.count).split(separator: "/") {
            path = (path as NSString).appendingPathComponent(String(part))
            out.append((String(part), .folder(path)))
        }
        return out
    }

    // MARK: Navigation

    func go(_ location: Location) {
        guard location != self.location else { return reload() }
        back.append(self.location)
        forward.removeAll()
        show(location)
    }

    /// The address bar: a path, ~, or "This Mac". A file opens in its app.
    func go(path text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.caseInsensitiveCompare("Home") == .orderedSame { return go(.home) }
        if text.isEmpty || text.caseInsensitiveCompare("This Mac") == .orderedSame { return go(.thisMac) }
        let path = ((text as NSString).expandingTildeInPath as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            alert = "Can't find \"\(text)\". Check the spelling and try again."
            return
        }
        if isDir.boolValue { go(.folder(path)) } else { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(location)
        show(previous)
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(location)
        show(next)
    }

    /// Up from a drive goes to This Mac, as up from C:\ goes to This PC.
    func goUp() {
        guard let dir = folder else { return }
        let isVolume = (try? dir.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
        go(isVolume ? .thisMac : .folder(dir.deletingLastPathComponent().path))
    }

    /// Opens at a place without adding to Back, for a new window or tab.
    func start(at location: Location) { show(location) }

    private func show(_ location: Location) {
        self.location = location
        selection = []
        renaming = nil
        editingAddress = false
        searchText = ""
        items = []
        loadError = nil
        reload()
    }

    func reload() {
        loadTask = Task { await list() }
    }

    /// Lists again and returns once the newest listing is in, even when the
    /// folder watcher started another one meanwhile.
    func load() async {
        reload()
        await waitForListing()
    }

    /// Waits for the listing and search in flight. For the self-test and snapshots.
    func settle() async {
        await waitForListing()
        await searchTask?.value
    }

    private func waitForListing() async {
        while let task = loadTask {
            await task.value
            if task == loadTask { return }
        }
    }

    /// Lists the folder. The newest call wins when several overlap.
    private func list() async {
        loadGeneration += 1
        let generation = loadGeneration
        guard let dir = folder else {
            watcher?.cancel()
            watcher = nil
            watchedPath = nil
            items = []
            if location == .home {
                let files = await FS.recent()
                if generation == loadGeneration { recent = files }
            }
            return
        }
        do {
            let list = try await FS.list(dir)
            guard generation == loadGeneration else { return }
            items = list
            loadError = nil
        } catch {
            guard generation == loadGeneration else { return }
            items = []
            loadError = error.localizedDescription
        }
        if !pendingSelect.isEmpty {
            let picked = rows.filter { pendingSelect.contains($0.name) }.map(\.url)
            selection = Set(picked)
            if pendingRename { renaming = picked.first }
            pendingSelect = []
            pendingRename = false
        } else {
            selection.formIntersection(rows.map(\.url))
        }
        watch(dir)
    }

    /// Lists again when something changes the folder, as Explorer does.
    private func watch(_ dir: URL) {
        guard dir.path != watchedPath else { return }
        watcher?.cancel()
        watchedPath = dir.path
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { @Sendable [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        source.setCancelHandler { @Sendable in Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    /// Folders first, as Explorer does, and last when the sort is reversed.
    func resort() {
        let visible = (results ?? items).filter { prefs.showHidden || !$0.isHidden }
        let sorted = visible.sorted(using: sortOrder)
        let folders = sorted.filter(\.isFolder), files = sorted.filter { !$0.isFolder }
        rows = sortOrder.first?.order == .reverse ? files + folders : folders + files
    }

    // MARK: Search

    /// Runs the search again, after a search option changes.
    func searchAgain() { search() }

    /// Explorer's search: the current folder and every subfolder (Home and
    /// This Mac search your home folder). Spotlight answers first; a folder
    /// Spotlight doesn't index is crawled instead.
    private func search() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            results = nil
            isSearching = false
            return
        }
        let root = folder ?? URL.homeDirectory
        let hidden = prefs.showHidden
        let contents = prefs.searchContents
        results = []
        selection = []
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
            let indexed = await FS.spotlight(root, for: query, hidden: hidden, contents: contents)
            if Task.isCancelled { return }
            results = indexed
            if indexed.isEmpty {
                for await batch in FS.search(root, for: query, hidden: hidden) {
                    if Task.isCancelled { return }
                    results?.append(contentsOf: batch)
                }
            }
            if !Task.isCancelled { isSearching = false }
        }
    }

    // MARK: Actions

    func open(_ urls: Set<URL>) {
        let picked = rows.filter { urls.contains($0.url) }
        if picked.count == 1, let only = picked.first, only.isFolder { return go(.folder(only.url.path)) }
        for item in picked where !item.isFolder { NSWorkspace.shared.open(item.url) }
    }

    func copy(_ urls: Set<URL>, cut: Bool) {
        let ordered = rows.map(\.url).filter(urls.contains)
        guard !ordered.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(ordered as [NSURL])
        Clip.shared.cut = cut ? Set(ordered) : []
        Clip.shared.changeCount = pasteboard.changeCount
    }

    func copyPaths(_ urls: Set<URL>) {
        let paths = rows.map(\.url).filter(urls.contains).map(\.path)
        guard !paths.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
        Clip.shared.cut = []
    }

    var canPaste: Bool {
        folder != nil && pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Files copied here or in Finder get copied; files cut here get moved.
    func paste(into dest: URL? = nil) async {
        guard let dest = dest ?? folder else { return }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        let move = !Clip.shared.cut.isEmpty && pasteboard.changeCount == Clip.shared.changeCount
        await transfer(urls, to: dest, move: move)
        if move {
            // As in Explorer, cut items paste once.
            Clip.shared.cut = []
            pasteboard.clearContents()
        }
    }

    /// Dragged files: moved within a drive, copied between drives, as Explorer does.
    func drop(_ urls: [URL], onto dest: URL?) {
        guard let dest = dest ?? folder else { return }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        let move = files.allSatisfy { FS.sameVolume($0, dest) }
        Task { await transfer(files, to: dest, move: move) }
    }

    func transfer(_ urls: [URL], to dest: URL, move: Bool) async {
        status = move ? "Moving \(urls.count) items…" : "Copying \(urls.count) items…"
        let result = await FS.transfer(urls, to: dest, move: move)
        status = nil
        if let error = result.errors.first { alert = error }
        if !result.done.isEmpty { History.shared.record(move ? .moved(result.done) : .created(result.done.map(\.to))) }
        if dest.standardizedFileURL == folder?.standardizedFileURL { pendingSelect = Set(result.done.map(\.to.lastPathComponent)) }
        await load()
    }

    func startRename(_ url: URL) {
        selection = [url]
        renaming = url
    }

    /// Ends inline rename from the text field; Enter and clicking away both land here.
    func finishRename(_ url: URL, to name: String) {
        guard renaming == url else { return }
        renaming = nil
        Task { await rename(url, to: name) }
    }

    func rename(_ url: URL, to newName: String) async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != url.lastPathComponent else { return }
        guard !name.contains("/"), !name.contains(":") else {
            alert = "A file name can't contain / or :."
            return
        }
        let target = url.deletingLastPathComponent().appending(path: name)
        let caseOnly = name.lowercased() == url.lastPathComponent.lowercased()
        if !caseOnly, FileManager.default.fileExists(atPath: target.path) {
            alert = "There is already a file with the name \"\(name)\" in this location."
            return
        }
        do {
            try FS.move(url, to: target)
        } catch {
            alert = error.localizedDescription
            return
        }
        History.shared.record(.moved([Moved(from: url, to: target)]))
        pendingSelect = [name]
        await load()
    }

    /// Makes "New folder" and starts renaming it, as Ctrl+Shift+N does.
    func newFolder() async {
        guard let dir = folder else { return }
        let url = FS.uniqueURL(in: dir, name: "New folder", isFolder: true, copy: false)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            alert = error.localizedDescription
            return
        }
        History.shared.record(.created([url]))
        pendingSelect = [url.lastPathComponent]
        pendingRename = true
        await load()
    }

    /// Makes "New Text Document.txt" and starts renaming it.
    func newTextDocument() async {
        guard let dir = folder else { return }
        let url = FS.uniqueURL(in: dir, name: "New Text Document.txt", isFolder: false, copy: false)
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            alert = "Couldn't make a file in this folder."
            return
        }
        History.shared.record(.created([url]))
        pendingSelect = [url.lastPathComponent]
        pendingRename = true
        await load()
    }

    func selectAll() { selection = Set(rows.map(\.url)) }
    func invertSelection() { selection = Set(rows.map(\.url)).subtracting(selection) }

    /// A click in the icon view: Cmd adds or removes, Shift selects a range.
    func click(_ url: URL, command: Bool, shift: Bool) {
        if shift, let anchor, let a = rows.firstIndex(where: { $0.url == anchor }),
           let b = rows.firstIndex(where: { $0.url == url }) {
            selection = Set(rows[min(a, b)...max(a, b)].map(\.url))
            return
        }
        if command {
            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
        } else {
            selection = [url]
        }
        anchor = url
    }

    /// Arrow keys in the icon view, and Home / End in both views.
    private func moveSelection(to index: (Int?) -> Int) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { selection.contains($0.url) }
        let next = min(max(index(current), 0), rows.count - 1)
        selection = [rows[next].url]
        anchor = rows[next].url
    }

    /// Moves to the Trash, the Recycle Bin of the Mac.
    func trash(_ urls: Set<URL>) async {
        var done: [Moved] = []
        for url in urls {
            var inTrash: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &inTrash)
                if let inTrash { done.append(Moved(from: url, to: inTrash as URL)) }
            } catch {
                alert = error.localizedDescription
                break
            }
        }
        if !done.isEmpty { History.shared.record(.trashed(done)) }
        Clip.shared.cut.subtract(urls)
        await load()
    }

    /// Ctrl+Z: reverses the last move, copy, rename, new item, or delete.
    func undo() async {
        guard let op = History.shared.pop() else { return }
        let errors = await FS.undo(op)
        if let error = errors.first { alert = "Couldn't undo everything. \(error)" }
        await load()
    }

    /// Renames several files in one go; Ctrl+Z puts every name back.
    func rename(_ urls: [URL], to names: [String]) async {
        let others = Set(rows.map { $0.name.lowercased() })
        if let problem = Renamer.problem(urls.map(\.lastPathComponent), names, others: others) {
            alert = problem
            return
        }
        // Through temporary names first, so swapping two names works.
        var temps: [(URL, URL)] = []
        var done: [Moved] = []
        do {
            for url in urls {
                let temp = url.deletingLastPathComponent().appending(path: ".burrow-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: url, to: temp)
                temps.append((url, temp))
            }
            for ((url, temp), name) in zip(temps, names) {
                let target = url.deletingLastPathComponent().appending(path: name)
                try FileManager.default.moveItem(at: temp, to: target)
                done.append(Moved(from: url, to: target))
            }
        } catch {
            alert = error.localizedDescription
            // Put back what is still parked under a temporary name.
            for (url, temp) in temps where FileManager.default.fileExists(atPath: temp.path) {
                try? FileManager.default.moveItem(at: temp, to: url)
            }
        }
        if !done.isEmpty { History.shared.record(.moved(done)) }
        pendingSelect = Set(done.map(\.to.lastPathComponent))
        await load()
    }

    func compress(_ urls: Set<URL>) async {
        status = "Compressing…"
        let (zip, error) = await FS.zip(rows.map(\.url).filter(urls.contains))
        status = nil
        if let error { alert = error }
        if let zip {
            History.shared.record(.created([zip]))
            pendingSelect = [zip.lastPathComponent]
        }
        await load()
    }

    func extract(_ archive: URL) async {
        status = "Extracting…"
        let (folder, error) = await FS.unzip(archive)
        status = nil
        if let error { alert = error }
        if let folder {
            History.shared.record(.created([folder]))
            pendingSelect = [folder.lastPathComponent]
        }
        await load()
    }

    /// Finder's colored tags: adds the tag, or takes it off when every item has it.
    func toggleTag(_ tag: String, on urls: Set<URL>) {
        let picked = rows.filter { urls.contains($0.url) }
        let add = !picked.allSatisfy { $0.tags.contains(tag) }
        for item in picked {
            let tags = item.tags.filter { $0 != tag } + (add ? [tag] : [])
            do { try (item.url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) } catch { alert = error.localizedDescription }
        }
        reload()
    }

    /// F2: one item renames in place; several open the multi-rename sheet.
    func renameSelection(_ urls: Set<URL>) {
        let ordered = rows.map(\.url).filter(urls.contains)
        if ordered.count == 1 { startRename(ordered[0]) } else if ordered.count > 1 { batchRenaming = ordered }
    }

    func openTerminal(_ dir: URL? = nil) {
        guard let dir = dir ?? folder,
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The Sort menu's checkmarks.
    var sortColumn: String {
        get {
            switch sortOrder.first?.keyPath {
            case \FileItem.modified: "Date modified"
            case \FileItem.kind: "Type"
            case \FileItem.size: "Size"
            default: "Name"
            }
        }
        set { sort(by: newValue) }
    }

    var sortAscending: Bool {
        get { sortOrder.first?.order != .reverse }
        set {
            guard var first = sortOrder.first else { return }
            first.order = newValue ? .forward : .reverse
            sortOrder = [first]
        }
    }

    func sort(by column: String) {
        let comparator: KeyPathComparator<FileItem> = switch column {
        case "Date modified": KeyPathComparator(\.modified, order: .reverse)
        case "Type": KeyPathComparator(\.kind)
        case "Size": KeyPathComparator(\.size, order: .reverse)
        default: KeyPathComparator(\.name, comparator: .localizedStandard)
        }
        sortOrder = [comparator]
    }

    // MARK: Keyboard

    /// Explorer's keys. Ctrl and Cmd both work. Returns true when it used the key.
    func handle(_ event: NSEvent) -> Bool {
        if event.type == .otherMouseDown {
            // The back and forward buttons on a mouse.
            if event.buttonNumber == 3 { goBack(); return true }
            if event.buttonNumber == 4 { goForward(); return true }
            return false
        }
        let responder = window?.firstResponder
        if responder is NSText { return false }  // typing in a field
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let ctrl = mods.contains(.command) || mods.contains(.control)
        let shift = mods.contains(.shift)
        let alt = mods.contains(.option)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // ponytail: the sidebar is a one-column table too; the file list is the one with columns.
        let inSidebar = ((responder as? NSTableView)?.numberOfColumns ?? 0) == 1
        let inList = !inSidebar && !rows.isEmpty
        let picked = inList ? selection : []

        switch event.keyCode {
        case 120 where mods.isEmpty || mods == [.control]:  // F2
            renameSelection(picked)
            return true
        case 49 where mods.isEmpty && inList:  // Space: Quick Look, as in Finder
            quickLook = quickLook == nil ? rows.first { picked.contains($0.url) }?.url : nil
            return quickLook != nil || !picked.isEmpty
        case 96:  // F5
            reload(); return true
        case 99:  // F3
            focusSearch += 1; return true
        case 118:  // F4
            editingAddress = true; return true
        case 36, 76:  // Return, Enter; Alt+Enter shows the details
            if alt { prefs.showDetails = true; return true }
            guard !picked.isEmpty else { return false }
            open(picked); return true
        case 115 where inList: moveSelection { _ in 0 }; return true                 // Home
        case 119 where inList: moveSelection { _ in self.rows.count - 1 }; return true  // End
        case 19 where ctrl && shift: prefs.iconView = true; return true              // Ctrl+Shift+2
        case 22 where ctrl && shift: prefs.iconView = false; return true             // Ctrl+Shift+6
        case 123...126 where inList && prefs.iconView && (mods.isEmpty || mods == [.shift]):
            let step = [123: -1, 124: 1, 125: gridColumns, 126: -gridColumns][Int(event.keyCode)] ?? 0
            moveSelection { ($0 ?? -step) + step }
            return true
        case 51, 117:  // Delete, Forward Delete
            guard !picked.isEmpty else { return false }
            Task { await trash(picked) }; return true
        case 53:  // Escape
            if isSearchActive { searchText = ""; return true }
            if !Clip.shared.cut.isEmpty { Clip.shared.cut = []; return true }
            return false
        case 123 where alt || (mods == [.command]): goBack(); return true            // Alt+Left
        case 124 where alt || (mods == [.command]): goForward(); return true         // Alt+Right
        case 126 where alt || (mods == [.command]): goUp(); return true              // Alt+Up
        case 125 where mods == [.command] && !picked.isEmpty: open(picked); return true  // Cmd+Down
        case 47 where mods == [.command, .shift]: prefs.showHidden.toggle(); return true  // Cmd+Shift+.
        default: break
        }

        if ctrl && !alt {
            switch key {
            case "z" where !History.shared.ops.isEmpty: Task { await undo() }; return true
            case "x" where !picked.isEmpty: copy(picked, cut: true); return true
            case "c" where !picked.isEmpty: shift ? copyPaths(picked) : copy(picked, cut: false); return true
            case "v" where folder != nil: Task { await paste() }; return true
            case "a" where inList: selectAll(); return true
            case "d" where !picked.isEmpty: Task { await trash(picked) }; return true
            case "n" where shift: Task { await newFolder() }; return true
            case "l": editingAddress = true; return true
            case "f", "e": focusSearch += 1; return true
            case "r": reload(); return true
            case "[": goBack(); return true
            case "]": goForward(); return true
            default: break
            }
            // Ctrl+T, Ctrl+N, Ctrl+W: the Mac menu items, through their Cmd shortcuts.
            if mods.contains(.control), !mods.contains(.command), ["t", "n", "w"].contains(key),
               let cmd = NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow,
                                          modifierFlags: event.modifierFlags.subtracting(.control).union(.command),
                                          timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                          characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: event.keyCode) {
                return NSApp.mainMenu?.performKeyEquivalent(with: cmd) == true
            }
            return false
        }
        if alt && key == "d" { editingAddress = true; return true }  // Alt+D
        if alt && key == "p" { prefs.showDetails.toggle(); return true }  // Alt+P, Alt+Shift+P

        // Type a name to jump to it.
        if inList, mods.subtracting(.shift).isEmpty, let chars = event.characters, chars.count == 1,
           chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).contains($0) }) {
            typed = Date.now.timeIntervalSince(typedAt) < 1 ? typed + chars : chars
            typedAt = .now
            if let hit = rows.first(where: { $0.name.lowercased().hasPrefix(typed.lowercased()) }) { selection = [hit.url] }
            return true
        }
        return false
    }
}
