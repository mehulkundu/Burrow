import AppKit

/// Self-test for agents: runs the real file actions on a sample folder in
/// /tmp, prints PASS or FAIL per check, and quits with exit code 0 or 1.
///   APP_STORE=/tmp/Burrow-self Burrow --selftest   (tools/selftest.sh)
/// It uses its own pins and its own pasteboard, so your clipboard and Quick access stay as they are.
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    /// Read by AppDelegate.applicationWillTerminate.
    static var exitCode: Int32 = 0
    private static var started = false
    private static var failures = 0
    private static var count = 0

    static func runIfRequested() {
        guard requested, !started else { return }
        started = true
        // Print each line at once, so a crash keeps the lines before it.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let root = Fixture.make() else {
            print("SELFTEST refused: set APP_STORE to a folder in /tmp")
            finish(code: 1)
            return
        }
        Task {
            let suite = "com.mehul.burrow.selftest"
            UserDefaults().removePersistentDomain(forName: suite)
            let prefs = Prefs(defaults: UserDefaults(suiteName: suite)!)
            let b = Browser(prefs: prefs, pasteboard: NSPasteboard(name: .init(suite)))
            let docs = root.appending(path: "Documents")
            func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appending(path: path).path) }
            @MainActor func names() -> [String] { b.rows.map(\.name) }
            @MainActor func url(_ name: String) -> URL? { b.rows.first { $0.name == name }?.url }

            b.go(.folder(root.path))
            await b.settle()
            check("folders come first", Array(names().prefix(2)) == ["Documents", "Photos"], "\(names())")
            check("names sort like Explorer: file2 before file10",
                  (names().firstIndex(of: "file2.txt") ?? 99) < (names().firstIndex(of: "file10.txt") ?? 0))
            check("hidden items are hidden", !names().contains(".hidden-config"))
            prefs.showHidden = true
            b.resort()
            check("hidden items show when turned on", names().contains(".hidden-config"))
            prefs.showHidden = false
            b.resort()

            b.sort(by: "Size")
            check("sort by size puts the biggest file first, folders last",
                  ["readme.txt", "file10.txt"].contains(names().first ?? "") && ["Documents", "Photos"].contains(names().last ?? ""),
                  "\(names())")
            b.sort(by: "Name")

            // Ctrl+C, Ctrl+V in the same folder
            b.copy([url("readme.txt")!], cut: false)
            await b.paste()
            check("paste into the same folder makes '- Copy'", exists("readme - Copy.txt"))
            await b.paste()
            check("a second paste makes '- Copy (2)'", exists("readme - Copy (2).txt"))
            check("the pasted file is selected", b.selectedItems.map(\.name) == ["readme - Copy (2).txt"], "\(b.selectedItems.map(\.name))")

            // Ctrl+X, then Ctrl+V in another folder
            b.copy([url("todo.md")!], cut: true)
            check("cut items are marked", Clip.shared.cut.count == 1)
            b.go(.folder(docs.path))
            await b.settle()
            await b.paste()
            check("cut and paste moves the file", exists("Documents/todo.md") && !exists("todo.md"))
            check("the cut mark clears after paste", Clip.shared.cut.isEmpty)
            await b.paste()
            check("cut items paste only once", !exists("Documents/todo (2).md"))

            // Navigation
            b.goBack()
            await b.settle()
            check("Back returns to the folder", b.location == .folder(root.path))
            b.goForward()
            await b.settle()
            check("Forward goes into Documents again", b.location == .folder(docs.path))
            b.goUp()
            await b.settle()
            check("Up goes to the parent", b.location == .folder(root.path))
            b.go(.folder("/"))
            b.goUp()
            check("Up from the drive goes to This Mac", b.location == .thisMac)
            b.go(path: "~")
            check("the address bar takes ~", b.location == .folder(URL.homeDirectory.path))
            b.go(path: root.path + "/nope")
            check("a wrong path shows an error", b.alert != nil)
            b.alert = nil
            check("crumbs start at This Mac", b.crumbs.first?.title == "This Mac")

            // Rename, new folder, folder into itself
            b.go(.folder(root.path))
            await b.settle()
            await b.rename(url("file10.txt")!, to: "file-ten.txt")
            check("rename works", exists("file-ten.txt") && !exists("file10.txt"))
            await b.rename(url("file-ten.txt")!, to: "readme.txt")
            check("rename onto a taken name is refused", b.alert != nil && exists("file-ten.txt"))
            b.alert = nil
            await b.rename(url("file-ten.txt")!, to: "FILE-TEN.txt")
            check("rename that only changes case works", names().contains("FILE-TEN.txt"))
            await b.newFolder()
            check("new folder is named 'New folder' and starts renaming",
                  exists("New folder") && b.renaming?.lastPathComponent == "New folder")
            b.renaming = nil
            await b.newFolder()
            check("a second new folder is 'New folder (2)'", exists("New folder (2)"))
            b.copy([url("Documents")!], cut: true)
            b.go(.folder(docs.appending(path: "Archive").path))
            await b.settle()
            await b.paste()
            check("a folder can't be pasted into itself", b.alert != nil && exists("Documents/Archive"))
            b.alert = nil

            // Drag onto a folder on the same drive moves
            b.go(.folder(root.path))
            await b.settle()
            b.drop([url("file2.txt")!], onto: url("Photos"))
            try? await Task.sleep(for: .milliseconds(500))
            check("dragging onto a folder on the same drive moves", exists("Photos/file2.txt") && !exists("file2.txt"))

            // Delete goes to the Trash
            await b.settle()
            await b.trash([url("FILE-TEN.txt")!])
            check("Delete moves to the Trash", !exists("FILE-TEN.txt"))

            // Search
            b.searchText = "report"
            await b.settle()
            check("search finds names in subfolders", Set(names()) == ["report-2026.pdf", "old report.txt"], "\(names())")
            b.searchText = ""
            check("clearing search shows the folder again", names().contains("Documents"))

            // Quick access
            prefs.togglePin(docs.path)
            let reopened = Prefs(defaults: UserDefaults(suiteName: suite)!)
            check("pins are saved", reopened.pins.contains(docs.path))
            prefs.togglePin(docs.path)
            check("unpin removes it", !prefs.pins.contains(docs.path))

            UserDefaults().removePersistentDomain(forName: suite)
            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    static func finish(code: Int32) {
        exitCode = code
        NSApp.terminate(nil)
    }
}
