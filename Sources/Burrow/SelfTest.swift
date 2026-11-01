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

            check("a new window starts at Home", b.location == .home && b.crumbs.map(\.title) == ["Home"])
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
            check("the Sort menu shows the column and order", b.sortColumn == "Size" && !b.sortAscending)
            b.sortAscending = true
            check("Ascending flips the order back", b.sortAscending && ["Documents", "Photos"].contains(names().first ?? ""))
            b.sort(by: "Name")

            // Selection
            b.selectAll()
            check("select all", b.selection.count == b.rows.count)
            b.selection = [url("readme.txt")!]
            b.invertSelection()
            check("invert selection", b.selection.count == b.rows.count - 1 && !b.selection.contains(url("readme.txt")!))
            b.click(url("Documents")!, command: false, shift: false)
            b.click(url("file10.txt")!, command: false, shift: true)
            check("shift-click selects a range in the icon view", b.selection.count == 4, "\(b.selectedItems.map(\.name))")
            b.click(url("todo.md")!, command: true, shift: false)
            check("cmd-click adds one", b.selection.count == 5)
            b.selection = []

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
            b.go(.folder(URL.homeDirectory.path + "/Documents"))
            check("folders in your home show your name, not the disk", b.crumbs.map(\.title) == ["This Mac", NSUserName(), "Documents"])
            b.go(path: "home")
            check("the address bar takes Home", b.location == .home)

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
            b.renaming = nil
            await b.newTextDocument()
            check("New > Text Document makes one and starts renaming",
                  exists("New Text Document.txt") && b.renaming?.lastPathComponent == "New Text Document.txt")
            b.renaming = nil
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

            // Undo (Ctrl+Z)
            await b.undo()
            check("Ctrl+Z brings a deleted file back from the Trash", exists("FILE-TEN.txt"))
            await b.rename(url("FILE-TEN.txt")!, to: "ten.txt")
            await b.undo()
            check("Ctrl+Z undoes a rename", exists("FILE-TEN.txt") && !exists("ten.txt"))
            let before = names().count
            await b.newFolder()
            b.renaming = nil
            await b.undo()
            check("Ctrl+Z removes a new folder", names().count == before)

            // Batch rename
            check("numbering names files like Explorer",
                  Renamer.plan([("a.jpg", false), ("b.jpg", false), ("My.Folder", true)], find: "", replace: "", base: "Trip", start: 1)
                    == ["Trip (1).jpg", "Trip (2).jpg", "Trip (3)"])
            check("find and replace ignores case",
                  Renamer.plan([("Report-OLD.txt", false)], find: "old", replace: "new", base: "", start: 1) == ["Report-new.txt"])
            check("a rename that would clash is refused",
                  Renamer.problem(["a", "b"], ["c", "c"], others: []) != nil
                    && Renamer.problem(["a"], ["todo.md"], others: ["todo.md", "a"]) != nil
                    && Renamer.problem(["a", "b"], ["b", "a"], others: ["a", "b"]) == nil)
            let copies = names().filter { $0.hasPrefix("readme - Copy") }
            await b.rename(copies.compactMap(url), to: ["note A.txt", "note B.txt"])
            check("batch rename renames every file", exists("note A.txt") && exists("note B.txt"))
            await b.undo()
            check("one Ctrl+Z puts every name back", copies.count == 2 && copies.allSatisfy(exists))

            // Zip
            await b.compress([url("Photos")!])
            check("Compress to ZIP makes Photos.zip", exists("Photos.zip"))
            await b.extract(url("Photos.zip")!)
            check("Extract All puts the one folder inside next to the archive", exists("Photos (2)/beach.jpg"))

            // Tags
            b.toggleTag("Red", on: [url("readme.txt")!])
            await b.settle()
            check("a tag shows on the file", b.rows.first { $0.name == "readme.txt" }?.tags == ["Red"])
            b.toggleTag("Red", on: [url("readme.txt")!])
            await b.settle()
            check("tagging again takes it off", b.rows.first { $0.name == "readme.txt" }?.tags.isEmpty == true)

            // Folder size and dual pane
            let size = await FS.size(of: root.appending(path: "Photos"))
            check("folder size adds up what is inside", size > 0)
            let w = Workspace(start: root.path)
            await w.left.settle()
            w.toggleDual()
            w.right?.go(.folder(docs.path))
            await w.right?.settle()
            w.left.selection = Set(w.left.rows.filter { $0.name == "readme.txt" }.map(\.url))
            await w.sendAcross(move: false)
            check("dual pane copies into the other pane's folder", exists("Documents/readme.txt") && exists("readme.txt"))

            // Search
            b.searchText = "report"
            await b.settle()
            check("search finds names in subfolders (crawled: /tmp is not indexed)",
                  Set(names()) == ["report-2026.pdf", "old report.txt"], "\(names())")
            b.searchText = ""
            check("clearing search shows the folder again", names().contains("Documents"))
            let apps = await FS.spotlight(URL(fileURLWithPath: "/System/Applications"), for: "calculator", hidden: false)
            check("indexed folders answer from Spotlight", apps.contains { $0.name == "Calculator.app" }, "\(apps.map(\.name))")
            b.go(.thisMac)
            b.searchText = "Desktop"
            await b.settle()
            check("searching from This Mac lists results (it used to show nothing)", b.isSearchActive && !b.rows.isEmpty)
            b.searchText = ""

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
