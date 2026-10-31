import AppKit
import SwiftUI

// Burrow: a file manager that works like Windows File Explorer.
//   Burrow                                     the app
//   APP_STORE=/tmp/<dir> Burrow --selftest     run the self-test in a /tmp folder, quit with 0 or 1 (tools/selftest.sh)
//   APP_STORE=/tmp/<dir> APP_SNAPSHOT=<dir> Burrow   PNGs of This Mac, a folder, and a search, light and dark (tools/snap.sh)

@main
struct BurrowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Burrow", id: "browser") {
            BrowserView()
                .frame(minWidth: 760, minHeight: 440)
        }
        .defaultSize(width: 1180, height: 720)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            SidebarCommands()
            FileCommands()
            CommandGroup(after: .sidebar) {
                Button("Show or Hide Hidden Items") { Prefs.shared.showHidden.toggle() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
            }
        }
    }
}

struct FileCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                let current = NSApp.keyWindow
                openWindow(id: "browser")
                // The new window is key on the next turn of the run loop. Tab it in.
                DispatchQueue.main.async {
                    guard let current, let new = NSApp.keyWindow, new !== current else { return }
                    current.addTabbedWindow(new, ordered: .above)
                    new.makeKeyAndOrderFront(nil)
                }
            }
            .keyboardShortcut("t")
            Button("New Folder") { Task { await Browser.active?.newFolder() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from a terminal, the process is not a foreground app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

/// A sample folder in /tmp for the self-test and snapshots. Never the real disk.
enum Fixture {
    static func make() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["APP_STORE"],
              path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") else { return nil }
        let root = URL(fileURLWithPath: path)
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        let files = ["readme.txt", "todo.md", "file2.txt", "file10.txt", ".hidden-config",
                     "Documents/report-2026.pdf", "Documents/notes.txt", "Documents/Archive/old report.txt",
                     "Photos/beach.jpg", "Photos/mountains.png"]
        for file in files {
            let url = root.appending(path: file)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(repeating: 65, count: file.count * 300).write(to: url)
        }
        return root
    }
}
