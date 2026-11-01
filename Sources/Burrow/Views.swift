import AppKit
import QuickLook
import SwiftUI

/// One window: one pane, or two side by side (dual pane, as in ForkLift and
/// Total Commander). The sidebar, the details panel, and the keys act on the active pane.
@Observable final class Workspace {
    let left: Browser
    private(set) var right: Browser?
    private(set) var rightActive = false
    /// Where the right pane starts on the x axis, for picking the active pane on a click.
    @ObservationIgnored var rightPaneX: CGFloat = .infinity

    init(start: String?) {
        left = Browser()
        if let start { left.start(at: .folder(start)) }
    }

    var active: Browser { rightActive ? right ?? left : left }
    var other: Browser? { right == nil ? nil : rightActive ? left : right }

    func activate(right isRight: Bool) {
        rightActive = isRight && right != nil
        Browser.active = active
    }

    func toggleDual() {
        if right == nil {
            let pane = Browser()
            pane.window = left.window
            pane.start(at: left.location)
            right = pane
            // Two panes need a wide window; grow it, staying on the screen.
            if let window = left.window, let screen = window.screen?.visibleFrame, window.frame.width < 1440 {
                var frame = window.frame
                frame.size.width = min(1440, screen.width)
                frame.origin.x = max(screen.minX, min(frame.origin.x, screen.maxX - frame.width))
                window.setFrame(frame, display: true, animate: true)
            }
        } else {
            right = nil
            activate(right: false)
        }
    }

    /// Copies or moves the active pane's selection into the other pane's folder.
    func sendAcross(move: Bool) async {
        guard let other else { return }
        guard let dest = other.folder else {
            active.alert = "Open a folder in the other pane first."
            return
        }
        let urls = active.rows.map(\.url).filter(active.selection.contains)
        guard !urls.isEmpty else { return }
        await active.transfer(urls, to: dest, move: move)
        await other.load()
    }

    /// Keys for the whole window; everything else goes to the active pane.
    func handle(_ event: NSEvent) -> Bool {
        if event.type == .leftMouseDown {
            if right != nil { activate(right: event.locationInWindow.x >= rightPaneX) }
            return false
        }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .keyDown, !(event.window?.firstResponder is NSText) {
            if mods == [.shift], event.keyCode == 96 || event.keyCode == 97, right != nil {  // Shift+F5 copy, Shift+F6 move
                Task { await sendAcross(move: event.keyCode == 97) }
                return true
            }
            if mods == [.control, .shift] || mods == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "d" {
                toggleDual()
                return true
            }
        }
        return active.handle(event)
    }
}

struct BrowserView: View {
    @State private var workspace: Workspace
    @State private var monitor: Any?
    @State private var window: NSWindow?
    @Bindable private var prefs = Prefs.shared

    init(start: String? = nil) {
        _workspace = State(initialValue: Workspace(start: start))
    }

    var body: some View {
        let active = workspace.active
        // Full-height columns, each with its own slice of the one header row:
        // navigation pane, files (one or two panes), details.
        HStack(spacing: 0) {
            if prefs.showSidebar {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        WindowButtonsGap()
                        IconButton(title: "Hide navigation pane", symbol: "sidebar.left", help: "Hide navigation pane (Ctrl+Cmd+S)") {
                            prefs.showSidebar = false
                        }
                        Spacer(minLength: 0)
                    }
                    .headerRow(window: window)
                    Sidebar(workspace: workspace)
                        .scrollContentBackground(.hidden)
                }
                .frame(width: prefs.sidebarWidth)
                .background(.regularMaterial)
                .transition(.move(edge: .leading).combined(with: .opacity))
                ResizeHandle(width: $prefs.sidebarWidth, range: 180...420, growsRight: true)
            }
            PaneView(model: workspace.left, workspace: workspace, isActive: !workspace.rightActive, leadsWindow: !prefs.showSidebar)
            if let right = workspace.right {
                Divider()
                PaneView(model: right, workspace: workspace, isActive: workspace.rightActive)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { workspace.rightPaneX = $0 }
            }
            if prefs.showDetails {
                ResizeHandle(width: $prefs.detailsWidth, range: 220...520, growsRight: false)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Details").fontWeight(.medium).foregroundStyle(.secondary).padding(.leading, 6)
                        Spacer(minLength: 0)
                        IconButton(title: "Close details", symbol: "xmark", help: "Close the details pane (Alt+Shift+P)") {
                            prefs.showDetails = false
                        }
                    }
                    .padding(.horizontal, 8)
                    .headerRow(window: window)
                    DetailsPane(model: active)
                }
                .frame(width: prefs.detailsWidth)
                .background(.regularMaterial)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: prefs.showDetails)
        .animation(.smooth(duration: 0.25), value: prefs.showSidebar)
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle(active.title)
        .background(WindowReader { found in
            window = found
            workspace.left.window = found
            workspace.right?.window = found
            Browser.active = workspace.active
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow) === window { Browser.active = workspace.active }
        }
        // Folders dropped on the Dock icon, or `open -a Burrow <folder>`, open here
        // instead of in a new window.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL { url in
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { workspace.active.go(.folder(url.path)) }
        }
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown, .leftMouseDown]) { [workspace] event in
                guard event.window === workspace.left.window else { return event }
                return workspace.handle(event) ? nil : event
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        .onChange(of: prefs.showHidden) {
            workspace.left.resort()
            workspace.right?.resort()
        }
        .task {
            SelfTest.runIfRequested()
            Snapshot.runIfRequested(model: workspace.left)
        }
    }
}

/// One file pane: glass bars floating over the files, which scroll underneath.
struct PaneView: View {
    @Bindable var model: Browser
    let workspace: Workspace
    let isActive: Bool
    /// True for the pane at the window's left edge when the navigation pane is hidden:
    /// its header makes room for the window buttons.
    var leadsWindow = false
    @FocusState private var contentFocused: Bool

    var body: some View {
        let dual = workspace.right != nil
        VStack(spacing: 0) {
            HeaderBar(model: model, highlighted: dual && isActive, leadsWindow: leadsWindow)
                .focusEffectDisabled()
            MainContent(model: model)
                .focused($contentFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) {
                    // Names on the commands only when the pane has room for them. ViewThatFits
                    // picks from the space offered, so the bar can't feed back into the layout.
                    GlassEffectContainer(spacing: 8) {
                        ViewThatFits(in: .horizontal) {
                            if !dual { CommandBar(model: model, workspace: workspace) }
                            CommandBar(model: model, workspace: workspace, compact: true)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .focusEffectDisabled()
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    StatusBar(model: model).focusEffectDisabled()
                }
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        }
            .quickLookPreview($model.quickLook, in: model.rows.map(\.url))
            .onChange(of: model.location) { contentFocused = true }
            .alert("Burrow", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
                Button("OK") {}
            } message: {
                Text(model.alert ?? "")
            }
            .sheet(isPresented: Binding(get: { model.batchRenaming != nil }, set: { if !$0 { model.batchRenaming = nil } })) {
                if let urls = model.batchRenaming { BatchRenameSheet(model: model, urls: urls) }
            }
    }
}

// MARK: Shared pieces

/// Flat button that lights up under the pointer, sitting on glass.
struct HoverStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, isOn: isOn)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let isOn: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .background {
                    Capsule().fill(isOn ? AnyShapeStyle(.tint.opacity(0.22))
                                   : AnyShapeStyle(.primary.opacity(configuration.isPressed ? 0.14 : hovering && isEnabled ? 0.08 : 0)))
                }
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}

struct IconButton: View {
    let title: String
    let symbol: String
    var help: String?
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 28)
        }
        .buttonStyle(HoverStyle(isOn: isOn))
        .help(help ?? title)
        .accessibilityLabel(title)
    }
}

/// Opens a window, then tabs it into the current one, as Ctrl+T does.
enum Tabs {
    static func open(_ openWindow: OpenWindowAction, path: String? = nil) {
        let current = NSApp.keyWindow
        if let path { openWindow(id: "browser", value: TabStart(path: path)) } else { openWindow(id: "browser") }
        // The new window is key on the next turn of the run loop.
        DispatchQueue.main.async {
            guard let current, let new = NSApp.keyWindow, new !== current else { return }
            current.addTabbedWindow(new, ordered: .above)
            new.makeKeyAndOrderFront(nil)
        }
    }
}

/// What a new tab opens. The id keeps two tabs on one folder from merging into one.
struct TabStart: Codable, Hashable {
    var path: String
    var id = UUID()
}

// MARK: Navigation pane

struct Sidebar: View {
    let workspace: Workspace
    /// Bumped when a drive comes or goes.
    @State private var drives = 0

    var body: some View {
        let model = workspace.active
        let selection = Binding<Location?>(get: { model.location }, set: { if let new = $0 { model.go(new) } })
        List(selection: selection) {
            Label("Home", systemImage: "house").tag(Location.home)
            Section("Favorites") {
                ForEach(model.prefs.pins, id: \.self) { path in
                    HStack(spacing: 6) {
                        Label { Text(Places.name(path)).lineLimit(1) } icon: { FileIcon(path: path) }
                        Spacer(minLength: 0)
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .tag(Location.folder(path))
                    .dropDestination(for: URL.self) { urls, _ in
                        model.drop(urls, onto: URL(fileURLWithPath: path))
                        return true
                    }
                    .contextMenu { PlaceMenu(model: model, path: path) }
                }
                .onMove { model.prefs.pins.move(fromOffsets: $0, toOffset: $1) }
                // Drop a folder between favorites to pin it there, as in Finder.
                .dropDestination(for: URL.self) { urls, index in
                    let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                        .map(\.path).filter { !model.prefs.pins.contains($0) }
                    model.prefs.pins.insert(contentsOf: folders, at: min(index, model.prefs.pins.count))
                }
            }
            Section("Locations") {
                Label("This Mac", systemImage: "desktopcomputer").tag(Location.thisMac)
                ForEach(Places.volumes()) { volume in
                    FolderNode(path: volume.path, title: volume.name, model: model, ejectable: volume.canEject)
                }
                if let iCloud = Places.iCloudDrive {
                    FolderNode(path: iCloud, title: "iCloud Drive", model: model)
                }
            }
            .id(drives)
        }
        .listStyle(.sidebar)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in drives += 1 }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in drives += 1 }
    }
}

/// A drive or folder in Locations. Its subfolders load when it opens.
struct FolderNode: View {
    let path: String
    var title: String?
    let model: Browser
    var ejectable = false
    @State private var open = false
    @State private var children: [String] = []

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            ForEach(children, id: \.self) { FolderNode(path: $0, model: model) }
        } label: {
            HStack(spacing: 4) {
                Label { Text(title ?? Places.name(path)).lineLimit(1) } icon: { FileIcon(path: path) }
                Spacer(minLength: 0)
                if ejectable {
                    Button("Eject \(title ?? Places.name(path))", systemImage: "eject.fill") {
                        Task { if let error = await FS.eject(path) { model.alert = error } }
                    }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
                .tag(Location.folder(path))
                .dropDestination(for: URL.self) { urls, _ in
                    model.drop(urls, onto: URL(fileURLWithPath: path))
                    return true
                }
                .contextMenu { PlaceMenu(model: model, path: path) }
        }
        .task(id: open ? (model.prefs.showHidden ? 2 : 1) : 0) {
            if open { children = await FS.subfolders(path, hidden: model.prefs.showHidden) }
        }
    }
}

/// Right-click on a folder in the navigation pane or a tile.
struct PlaceMenu: View {
    let model: Browser
    let path: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let pinned = model.prefs.pins.contains(path)
        Button("Open", systemImage: "folder") { model.go(.folder(path)) }
        Button("Open in new tab", systemImage: "plus.square.on.square") { Tabs.open(openWindow, path: path) }
        Button(pinned ? "Unpin from Favorites" : "Pin to Favorites", systemImage: pinned ? "pin.slash" : "pin") {
            model.prefs.togglePin(path)
        }
        Divider()
        Button("Copy as path", systemImage: "link") { model.copyPath(path) }
        Button("Open in Terminal", systemImage: "terminal") { model.openTerminal(URL(fileURLWithPath: path)) }
    }
}

// MARK: Header: navigation, address, search

struct HeaderBar: View {
    @Bindable var model: Browser
    var highlighted = false
    var leadsWindow = false

    var body: some View {
        HStack(spacing: 6) {
            if leadsWindow {
                WindowButtonsGap()
                IconButton(title: "Show navigation pane", symbol: "sidebar.left", help: "Show navigation pane (Ctrl+Cmd+S)") {
                    model.prefs.showSidebar = true
                }
            }
            HStack(spacing: 0) {
                IconButton(title: "Back", symbol: "chevron.left", help: "Back (Alt+Left)") { model.goBack() }
                    .disabled(!model.canGoBack)
                IconButton(title: "Forward", symbol: "chevron.right", help: "Forward (Alt+Right)") { model.goForward() }
                    .disabled(!model.canGoForward)
                IconButton(title: "Up", symbol: "arrow.up", help: "Up to the parent folder (Alt+Up)") { model.goUp() }
                    .disabled(!model.canGoUp)
                IconButton(title: "Refresh", symbol: "arrow.clockwise", help: "Refresh (F5)") { model.reload() }
            }
            AddressBar(model: model)
                .glassEffect(.regular.tint(highlighted ? .accentColor.opacity(0.18) : nil), in: .capsule)
            // The search box takes its width first; the address bar folds folders into "…" to fit.
            SearchBox(model: model)
                .frame(minWidth: 120, idealWidth: 240, maxWidth: 240)
                .glassEffect(.regular, in: .capsule)
                .layoutPriority(1)
        }
        .padding(.horizontal, 8)
        .headerRow(window: model.window)
    }
}

/// The space the close, minimize, and zoom buttons sit in.
struct WindowButtonsGap: View {
    var body: some View { Color.clear.frame(width: 72, height: 1) }
}

extension View {
    /// The one header row every column shares, centered on the window buttons' line.
    /// Empty space in it moves the window, and a double-click zooms it.
    func headerRow(window: NSWindow?) -> some View {
        frame(height: 28)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .background { TitleBarArea(window: window) }
            .focusEffectDisabled()
    }
}

/// Empty space at the top acts as the title bar: drag to move the window,
/// double-click to zoom it, as System Settings > Desktop & Dock says.
struct TitleBarArea: View {
    let window: NSWindow?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window?.performMiniaturize(nil)
                case "None": break
                default: window?.performZoom(nil)
                }
            })
    }
}

/// The strip between two panels: drag it to make the panel wider or narrower.
struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// True for the sidebar, which grows when dragged right; false for the details pane.
    let growsRight: Bool
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize(directions: .all))
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let from = start ?? width
                            start = from
                            let delta = growsRight ? drag.translation.width : -drag.translation.width
                            width = min(max(from + delta, range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in start = nil })
                    .help("Drag to resize")
            }
            // Above the column after it, so the whole grip catches the pointer.
            .zIndex(1)
    }
}

struct AddressBar: View {
    @Bindable var model: Browser
    @State private var text = ""
    @State private var copied = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            LocationIcon(location: model.location).padding(.leading, 12).padding(.trailing, 4)
            if model.editingAddress {
                TextField("Address", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onAppear {
                        text = model.folder?.path ?? model.title
                        focused = true
                    }
                    .onSubmit {
                        model.editingAddress = false
                        model.go(path: text)
                    }
                    .onExitCommand { model.editingAddress = false }
                    .onChange(of: focused) { if !focused { model.editingAddress = false } }
                    .padding(.trailing, 12)
            } else {
                // Long paths fold their first folders into "…", as Explorer does.
                let crumbs = model.crumbs
                ViewThatFits(in: .horizontal) {
                    CrumbRow(model: model, crumbs: crumbs[...])
                    if crumbs.count > 3 { CrumbRow(model: model, crumbs: crumbs.suffix(3), hidden: crumbs.dropLast(3)) }
                    if crumbs.count > 1 { CrumbRow(model: model, crumbs: crumbs.suffix(1), hidden: crumbs.dropLast(1)) }
                }
                Color.clear
                    .frame(minWidth: 24, maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { model.editingAddress = true }
                    .help("Click empty space to type a path (Ctrl+L)")
                if let path = model.folder?.path {
                    IconButton(title: "Copy path", symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy path") {
                        model.copyPath(path)
                        copied = true
                    }
                    .task(id: copied) {
                        guard copied else { return }
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
            }
        }
        .frame(height: 28)
    }
}

struct LocationIcon: View {
    let location: Location

    var body: some View {
        switch location {
        case .home: Image(systemName: "house").foregroundStyle(.secondary).frame(width: 16, height: 16)
        case .thisMac: Image(systemName: "desktopcomputer").foregroundStyle(.secondary).frame(width: 16, height: 16)
        case .folder(let path): FileIcon(path: path)
        }
    }
}

typealias Crumb = (title: String, location: Location)

struct CrumbRow: View {
    let model: Browser
    let crumbs: ArraySlice<Crumb>
    var hidden: ArraySlice<Crumb> = []
    @State private var showTree = false

    var body: some View {
        HStack(spacing: 0) {
            if let last = hidden.last {
                Button { showTree = true } label: {
                    Text("…").padding(.horizontal, 7).frame(height: 26)
                }
                .buttonStyle(HoverStyle(isOn: showTree))
                .accessibilityLabel("Earlier folders")
                .popover(isPresented: $showTree, arrowEdge: .bottom) {
                    PathTree(model: model) { showTree = false }
                }
                SubfolderMenu(model: model, parent: last.location)
            }
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 { SubfolderMenu(model: model, parent: crumbs[crumbs.startIndex + index - 1].location) }
                Button { model.go(crumb.location) } label: {
                    Text(crumb.title).padding(.horizontal, 7).frame(height: 26)
                }
                .buttonStyle(HoverStyle())
            }
            if model.isSearchActive {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                Text("Search Results in \(model.title)").padding(.horizontal, 6)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The "…" in the address bar: the whole path as a tree, This Mac at the root and here at the tip.
struct PathTree: View {
    let model: Browser
    let dismiss: () -> Void

    var body: some View {
        let crumbs = model.crumbs
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { depth, crumb in
                let here = depth == crumbs.count - 1
                Button {
                    dismiss()
                    model.go(crumb.location)
                } label: {
                    HStack(spacing: 7) {
                        LocationIcon(location: crumb.location)
                        Text(crumb.title).fontWeight(here ? .semibold : .regular)
                    }
                    .padding(.leading, TreeBranch.lead + CGFloat(depth) * TreeBranch.indent)
                    .padding(.trailing, 14)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .background { TreeBranch(depth: depth, hasChild: !here).stroke(.tertiary, lineWidth: 1) }
                }
                .buttonStyle(HoverStyle(isOn: here))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(6)
    }
}

/// The line from a folder's icon down and across to the folder inside it.
nonisolated struct TreeBranch: Shape {
    static let lead: CGFloat = 8
    static let indent: CGFloat = 20
    let depth: Int
    let hasChild: Bool

    func path(in rect: CGRect) -> Path {
        Path { p in
            let mid = rect.midY, r: CGFloat = 4
            if depth > 0 {
                // Down from the parent's icon, round the corner, stop just short of this icon.
                let x = Self.lead + CGFloat(depth - 1) * Self.indent + 8
                p.move(to: CGPoint(x: x, y: rect.minY))
                p.addLine(to: CGPoint(x: x, y: mid - r))
                p.addQuadCurve(to: CGPoint(x: x + r, y: mid), control: CGPoint(x: x, y: mid))
                p.addLine(to: CGPoint(x: x + Self.indent - 10, y: mid))
            }
            if hasChild {
                let x = Self.lead + CGFloat(depth) * Self.indent + 8
                p.move(to: CGPoint(x: x, y: mid + 10))
                p.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
        }
    }
}

/// The chevron between two crumbs: lists the subfolders of the crumb before it.
struct SubfolderMenu: View {
    let model: Browser
    let parent: Location

    var body: some View {
        Menu {
            switch parent {
            case .home, .thisMac:
                ForEach(Places.userFolders) { folder in
                    Button(folder.title) { model.go(.folder(folder.path)) }
                }
                Divider()
                ForEach(Places.volumes()) { volume in
                    Button(volume.name) { model.go(.folder(volume.path)) }
                }
            case .folder(let path):
                let subfolders = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
                ForEach(subfolders.filter { !$0.hasPrefix(".") && isDirectory(path + "/" + $0) }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { name in
                    Button(name) { model.go(.folder(path + "/" + name)) }
                }
            }
        } label: {
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .accessibilityLabel("Folders inside")
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(HoverStyle())
        .fixedSize()
    }

    private func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }
}

struct SearchBox: View {
    @Bindable var model: Browser
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField(model.searchPrompt, text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand { model.searchText = "" }
            if model.isSearching {
                ProgressView().controlSize(.small)
            }
            if !model.searchText.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { model.searchText = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Menu {
                Toggle("Search file contents", isOn: Bindable(model.prefs).searchContents)
                Toggle("Include hidden items", isOn: Bindable(model.prefs).showHidden)
            } label: {
                Image(systemName: model.prefs.searchContents ? "doc.text.magnifyingglass" : "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Search options")
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 28)
        .onChange(of: model.focusSearch) { focused = true }
        .onChange(of: model.prefs.searchContents) { model.searchAgain() }
    }
}

// MARK: Command bar

struct CommandBar: View {
    @Bindable var model: Browser
    let workspace: Workspace
    var compact = false

    var body: some View {
        let picked = model.selection
        let inFolder = model.folder != nil
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Menu {
                    Button("Folder", systemImage: "folder") { Task { await model.newFolder() } }
                    Button("Text Document", systemImage: "doc.text") { Task { await model.newTextDocument() } }
                } label: {
                    TitledIcon(title: "New", symbol: "plus.circle.fill", compact: compact)
                }
                .disabled(!inFolder)
                .help("New folder (Ctrl+Shift+N)")
                separator
                IconButton(title: "Cut", symbol: "scissors", help: "Cut (Ctrl+X)") { model.copy(picked, cut: true) }
                    .disabled(picked.isEmpty)
                IconButton(title: "Copy", symbol: "doc.on.doc", help: "Copy (Ctrl+C)") { model.copy(picked, cut: false) }
                    .disabled(picked.isEmpty)
                IconButton(title: "Paste", symbol: "doc.on.clipboard", help: "Paste (Ctrl+V)") { Task { await model.paste() } }
                    .disabled(!model.canPaste)
                IconButton(title: "Rename", symbol: "character.cursor.ibeam", help: "Rename (F2); several at once for a batch rename") {
                    model.renameSelection(picked)
                }
                .disabled(picked.isEmpty)
                if !compact {
                    ShareLink(items: model.selectedItems.map(\.url)) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 14)).frame(width: 32, height: 28)
                    }
                    .buttonStyle(HoverStyle())
                    .disabled(picked.isEmpty)
                    .help("Share")
                }
                IconButton(title: "Delete", symbol: "trash", help: "Move to Trash (Delete)") { Task { await model.trash(picked) } }
                    .disabled(picked.isEmpty)
                if !compact {
                    IconButton(title: "Undo", symbol: "arrow.uturn.backward", help: "Undo (Ctrl+Z)") { Task { await model.undo() } }
                        .disabled(History.shared.ops.isEmpty)
                }
                separator
                Menu {
                    Picker("Sort by", selection: $model.sortColumn) {
                        ForEach(["Name", "Date modified", "Type", "Size"], id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("Order", selection: $model.sortAscending) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }
                    .pickerStyle(.inline)
                } label: {
                    TitledIcon(title: "Sort", symbol: "arrow.up.arrow.down", compact: compact)
                }
                Menu {
                    Picker("Layout", selection: Bindable(model.prefs).iconView) {
                        Label("Large icons", systemImage: "square.grid.2x2").tag(true)
                        Label("Details", systemImage: "list.bullet").tag(false)
                    }
                    .pickerStyle(.inline)
                    Section("Show") {
                        Toggle("Navigation pane", isOn: Bindable(model.prefs).showSidebar)
                        Toggle("Details pane", isOn: Bindable(model.prefs).showDetails)
                        Toggle("Hidden items", isOn: Bindable(model.prefs).showHidden)
                        Toggle("Dual pane", isOn: Binding(get: { workspace.right != nil }, set: { _ in workspace.toggleDual() }))
                    }
                } label: {
                    TitledIcon(title: "View", symbol: "rectangle.grid.1x2", compact: compact)
                }
                Menu {
                    Button("Undo", systemImage: "arrow.uturn.backward") { Task { await model.undo() } }
                        .disabled(History.shared.ops.isEmpty)
                    ShareLink("Share", items: model.selectedItems.map(\.url))
                        .disabled(picked.isEmpty)
                    Divider()
                    Button("Select all", systemImage: "checkmark.circle") { model.selectAll() }
                    Button("Select none", systemImage: "circle") { model.selection = [] }
                    Button("Invert selection", systemImage: "circle.lefthalf.filled") { model.invertSelection() }
                    if let dir = model.folder {
                        Divider()
                        PlaceMenu(model: model, path: dir.path)
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14)).frame(width: 32, height: 28)
                }
                .help("See more")
            }
            .padding(4)
            .glassEffect(.regular, in: .capsule)
            .fixedSize()
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                if workspace.right != nil {
                    let toRight = !workspace.rightActive
                    IconButton(title: "Copy to other pane", symbol: toRight ? "arrow.right.doc.on.clipboard" : "arrow.left.doc.on.clipboard",
                               help: "Copy to the other pane (Shift+F5)") { Task { await workspace.sendAcross(move: false) } }
                        .disabled(picked.isEmpty)
                    IconButton(title: "Move to other pane", symbol: toRight ? "arrow.right.square" : "arrow.left.square",
                               help: "Move to the other pane (Shift+F6)") { Task { await workspace.sendAcross(move: true) } }
                        .disabled(picked.isEmpty)
                }
                IconButton(title: "Dual pane", symbol: "rectangle.split.2x1", help: "Dual pane (Ctrl+Shift+D)",
                           isOn: workspace.right != nil) { workspace.toggleDual() }
                Button { model.prefs.showDetails.toggle() } label: {
                    TitledIcon(title: "Details", symbol: "sidebar.right", compact: compact)
                }
                .buttonStyle(HoverStyle(isOn: model.prefs.showDetails))
                .help("Details pane (Alt+Shift+P)")
            }
            .padding(4)
            .glassEffect(.regular, in: .capsule)
            .fixedSize()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(HoverStyle())
    }

    private var separator: some View {
        Divider().frame(height: 18).padding(.horizontal, 6)
    }
}

/// A command with its name, or just its icon when two panes share the width.
struct TitledIcon: View {
    let title: String
    let symbol: String
    let compact: Bool

    var body: some View {
        Group {
            if compact {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 32)
            } else {
                Label(title, systemImage: symbol).padding(.horizontal, 10)
            }
        }
        .frame(height: 28)
        .accessibilityLabel(title)
    }
}

// MARK: Status bar

struct StatusBar: View {
    let model: Browser

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 10) {
                    if model.folder != nil || model.isSearchActive {
                        Text("^[\(model.rows.count) item](inflect: true)")
                    } else {
                        Text(model.title)
                    }
                    let picked = model.selectedItems
                    if !picked.isEmpty {
                        Divider().frame(height: 12)
                        let bytes = picked.filter { !$0.isFolder }.reduce(Int64(0)) { $0 + $1.size }
                        let size = bytes > 0 ? "  " + bytes.formatted(.byteCount(style: .file)) : ""
                        Text("^[\(picked.count) item](inflect: true) selected\(size)")
                    }
                    if model.isSearching {
                        Divider().frame(height: 12)
                        Text("Searching…")
                    }
                    if let status = model.status {
                        Divider().frame(height: 12)
                        Text(status)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 30)
                .glassEffect(.regular, in: .capsule)
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    IconButton(title: "Details", symbol: "list.bullet", help: "Details (Ctrl+Shift+6)", isOn: !model.prefs.iconView) {
                        model.prefs.iconView = false
                    }
                    IconButton(title: "Large icons", symbol: "square.grid.2x2", help: "Large icons (Ctrl+Shift+2)", isOn: model.prefs.iconView) {
                        model.prefs.iconView = true
                    }
                }
                .padding(2)
                .glassEffect(.regular, in: .capsule)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }
}

/// Hands the view's NSWindow to the window's panes, for the key handler.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.found = found
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {}

    final class Probe: NSView {
        var found: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found?(window) }
        }
    }
}
