import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// Screenshot mode for agents.
///   APP_STORE=/tmp/Burrow-test APP_SNAPSHOT=/tmp/Burrow-shots Burrow   (tools/snap.sh)
/// writes thismac, folder, search, and cut PNGs in light and dark, then quits.
enum Snapshot {
    private static var started = false

    static func runIfRequested(model: Browser) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["APP_SNAPSHOT"], !dir.isEmpty, !started else { return }
        started = true
        guard let root = Fixture.make() else {
            print("SNAPSHOT refused: set APP_STORE to a folder in /tmp")
            NSApp.terminate(nil)
            return
        }
        Task {
            // A sleeping display gives screencapture nothing. Declaring user
            // activity wakes it; the assertion keeps it on until the run quits.
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Snapshots" as CFString, kIOPMUserActiveLocal, &activity)
            var awake: IOPMAssertionID = 0
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Snapshots" as CFString, &awake)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1.5))
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                model.go(.thisMac)
                try? await Task.sleep(for: .seconds(0.8))
                capture(to: "\(dir)/thismac-\(mode).png")

                model.go(.folder(root.path))
                await model.settle()
                model.selection = Set(model.rows.filter { $0.name.hasPrefix("file") }.map(\.url))
                try? await Task.sleep(for: .seconds(0.8))
                capture(to: "\(dir)/folder-\(mode).png")

                // Only the faded look: the real pasteboard stays as the user left it.
                Clip.shared.cut = model.selection
                model.selection = []
                if let readme = model.rows.first(where: { $0.name == "readme.txt" }) { model.startRename(readme.url) }
                try? await Task.sleep(for: .seconds(0.8))
                capture(to: "\(dir)/cut-rename-\(mode).png")
                model.renaming = nil
                Clip.shared.cut = []

                model.searchText = "report"
                await model.settle()
                try? await Task.sleep(for: .seconds(0.8))
                capture(to: "\(dir)/search-\(mode).png")
            }
            print("SNAPSHOT done \(dir)")
            NSApp.terminate(nil)
        }
    }

    /// Captures the real window with screencapture, so sidebars and glass
    /// look as on screen. That needs Screen Recording permission for the app
    /// that started this one. Without it, draws the view hierarchy instead.
    private static func capture(to path: String) {
        // Another app can hide this one while snapshots run. Hidden windows cannot be captured.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else {
            print("SNAPSHOT no window")
            return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try? FileManager.default.removeItem(atPath: path)
        // The first capture of a run sometimes misses the window. Try three times.
        for _ in 1...3 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? shot.run()
            shot.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                print("SNAPSHOT \(path)")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT \(path) (fallback: no Screen Recording permission, sidebars and glass are blank)")
        }
    }
}
