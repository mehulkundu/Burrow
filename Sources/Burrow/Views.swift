import AppKit
import SwiftUI

struct BrowserView: View {
    @State private var model = Browser()
    @State private var monitor: Any?
    @FocusState private var listFocused: Bool

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 380)
        } detail: {
            VStack(spacing: 0) {
                NavBar(model: model)
                CommandBar(model: model)
                Divider()
                Group {
                    switch model.location {
                    case .thisMac: ThisMacPage(model: model)
                    case .folder: FileTable(model: model).focused($listFocused)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar(model: model)
            }
        }
        .navigationTitle(model.title)
        .background(WindowReader { window in
            model.window = window
            Browser.active = model
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow) === model.window { Browser.active = model }
        }
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { [model] event in
                guard event.window === model.window else { return event }
                return model.handle(event) ? nil : event
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        .onChange(of: model.location) { listFocused = true }
        .onChange(of: model.prefs.showHidden) { model.resort() }
        .alert("Burrow", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.alert ?? "")
        }
        .task {
            SelfTest.runIfRequested()
            Snapshot.runIfRequested(model: model)
        }
    }
}

// MARK: Navigation pane

struct Sidebar: View {
    let model: Browser
    @State private var thisMacOpen = true

    var body: some View {
        let selection = Binding<Location?>(get: { model.location }, set: { if let new = $0 { model.go(new) } })
        List(selection: selection) {
            Section("Quick access") {
                ForEach(model.prefs.pins, id: \.self) { path in
                    FolderNode(path: path, model: model)
                        .contextMenu {
                            Button("Unpin from Quick access", systemImage: "pin.slash") { model.prefs.togglePin(path) }
                            Button("Open in Terminal", systemImage: "terminal") { model.openTerminal(URL(fileURLWithPath: path)) }
                        }
                }
                .onMove { model.prefs.pins.move(fromOffsets: $0, toOffset: $1) }
            }
            Section {
                DisclosureGroup(isExpanded: $thisMacOpen) {
                    ForEach(Places.userFolders) { FolderNode(path: $0.path, title: $0.title, model: model) }
                    ForEach(Places.volumes()) { FolderNode(path: $0.path, title: $0.name, model: model) }
                } label: {
                    Label("This Mac", systemImage: "desktopcomputer").tag(Location.thisMac)
                }
            }
        }
    }
}

/// A folder in the navigation pane. Its subfolders load when it opens.
struct FolderNode: View {
    let path: String
    var title: String?
    let model: Browser
    @State private var open = false
    @State private var children: [String] = []

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            ForEach(children, id: \.self) { FolderNode(path: $0, model: model) }
        } label: {
            Label {
                Text(title ?? Places.name(path)).lineLimit(1)
            } icon: {
                FileIcon(path: path)
            }
            .tag(Location.folder(path))
            .dropDestination(for: URL.self) { urls, _ in
                model.drop(urls, onto: URL(fileURLWithPath: path))
                return true
            }
        }
        .task(id: open ? (model.prefs.showHidden ? 2 : 1) : 0) {
            if open { children = await FS.subfolders(path, hidden: model.prefs.showHidden) }
        }
    }
}

struct FileIcon: View {
    let path: String
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: size, height: size)
    }
}

// MARK: Address row

struct NavBar: View {
    @Bindable var model: Browser
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button("Back", systemImage: "arrow.left") { model.goBack() }
                .disabled(!model.canGoBack).help("Back (Alt+Left)")
            Button("Forward", systemImage: "arrow.right") { model.goForward() }
                .disabled(!model.canGoForward).help("Forward (Alt+Right)")
            Button("Up", systemImage: "arrow.up") { model.goUp() }
                .disabled(model.folder == nil).help("Up to the parent folder (Alt+Up)")
            Button("Refresh", systemImage: "arrow.clockwise") { model.reload() }
                .help("Refresh (F5)")
            AddressBar(model: model)
                .padding(.leading, 4)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.searchPrompt, text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { model.searchText = "" }
                if !model.searchText.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { model.searchText = "" }
                        .labelStyle(.iconOnly).foregroundStyle(.secondary)
                }
            }
            .fieldBox()
            .frame(width: 240)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onChange(of: model.focusSearch) { searchFocused = true }
    }
}

struct AddressBar: View {
    @Bindable var model: Browser
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if model.editingAddress {
                TextField("Address", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onAppear {
                        text = model.folder?.path ?? "This Mac"
                        focused = true
                    }
                    .onSubmit {
                        model.editingAddress = false
                        model.go(path: text)
                    }
                    .onExitCommand { model.editingAddress = false }
                    .onChange(of: focused) { if !focused { model.editingAddress = false } }
            } else {
                HStack(spacing: 2) {
                    ForEach(Array(model.crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                        }
                        Button(crumb.title) { model.go(crumb.location) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            // The last folders keep their names; the first ones shorten first.
                            .layoutPriority(Double(index))
                    }
                    Spacer(minLength: 24)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.editingAddress = true }
                .help("Click to type a path (Ctrl+L)")
            }
        }
        .fieldBox()
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// The rounded box behind the address bar and the search field.
    func fieldBox() -> some View {
        padding(.horizontal, 8)
            .frame(height: 28)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

// MARK: Command bar

struct CommandBar: View {
    let model: Browser

    var body: some View {
        let picked = model.selection
        let inFolder = model.folder != nil
        HStack(spacing: 2) {
            Button("New folder", systemImage: "folder.badge.plus") { Task { await model.newFolder() } }
                .labelStyle(.titleAndIcon).disabled(!inFolder).help("New folder (Ctrl+Shift+N)")
            Divider().frame(height: 16).padding(.horizontal, 6)
            Group {
                Button("Cut", systemImage: "scissors") { model.copy(picked, cut: true) }
                    .disabled(picked.isEmpty).help("Cut (Ctrl+X)")
                Button("Copy", systemImage: "doc.on.doc") { model.copy(picked, cut: false) }
                    .disabled(picked.isEmpty).help("Copy (Ctrl+C)")
                Button("Paste", systemImage: "doc.on.clipboard") { Task { await model.paste() } }
                    .disabled(!model.canPaste).help("Paste (Ctrl+V)")
                Button("Rename", systemImage: "character.cursor.ibeam") { if let url = picked.first { model.startRename(url) } }
                    .disabled(picked.count != 1).help("Rename (F2)")
                Button("Delete", systemImage: "trash") { Task { await model.trash(picked) } }
                    .disabled(picked.isEmpty).help("Move to Trash (Delete)")
            }
            .labelStyle(.iconOnly)
            Divider().frame(height: 16).padding(.horizontal, 6)
            Menu("Sort", systemImage: "arrow.up.arrow.down") {
                ForEach(["Name", "Date modified", "Type", "Size"], id: \.self) { column in
                    Button(column) { model.sort(by: column) }
                }
            }
            .fixedSize()
            Menu("View", systemImage: "eye") {
                Toggle("Hidden items", isOn: Bindable(model.prefs).showHidden)
            }
            .fixedSize()
            Spacer()
            if let dir = model.folder {
                let pinned = model.prefs.pins.contains(dir.path)
                Button(pinned ? "Unpin" : "Pin to Quick access", systemImage: pinned ? "pin.slash" : "pin") {
                    model.prefs.togglePin(dir.path)
                }
                .labelStyle(.titleAndIcon)
                Button("Open in Terminal", systemImage: "terminal") { model.openTerminal() }
                    .labelStyle(.iconOnly).help("Open in Terminal")
            }
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

// MARK: Details view

struct FileTable: View {
    @Bindable var model: Browser

    var body: some View {
        Table(of: FileItem.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { item in
                NameCell(item: item, model: model)
            }
            .width(min: 180, ideal: 340)
            TableColumn("Date modified", value: \.modified) { item in
                Text(item.modified.formatted(date: .numeric, time: .shortened)).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Type", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 150)
            TableColumn("Size", value: \.size) { item in
                Text(item.isFolder ? "" : item.size.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 90)
        } rows: {
            ForEach(model.rows) { item in
                TableRow(item)
                    .itemProvider { NSItemProvider(contentsOf: item.url) }
                    .dropDestination(for: URL.self) { urls in
                        model.drop(urls, onto: item.isFolder ? item.url : nil)
                    }
            }
        }
        .contextMenu(forSelectionType: URL.self) { ids in
            ItemMenu(model: model, ids: ids)
        } primaryAction: { ids in
            model.open(ids)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.drop(urls, onto: nil)
            return true
        }
        .overlay {
            if model.rows.isEmpty {
                if let error = model.loadError {
                    ContentUnavailableView("Can't open this folder", systemImage: "lock", description: Text(error))
                } else if model.isSearchActive && !model.isSearching {
                    Text("No items match your search.").foregroundStyle(.secondary)
                } else if !model.isSearchActive {
                    Text("This folder is empty.").foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct NameCell: View {
    let item: FileItem
    let model: Browser

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(path: item.url.path)
            if model.renaming == item.url {
                RenameField(item: item, model: model)
            } else {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if model.isSearchActive {
                    Text(item.url.deletingLastPathComponent().path)
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
            }
        }
        // Cut and hidden items look faded, as in Explorer.
        .opacity(Clip.shared.cut.contains(item.url) || item.isHidden ? 0.5 : 1)
    }
}

struct RenameField: View {
    let item: FileItem
    let model: Browser
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear {
                text = item.name
                focused = true
            }
            .onSubmit { model.finishRename(item.url, to: text) }
            .onExitCommand { model.renaming = nil }
            .onChange(of: focused) { if !focused { model.finishRename(item.url, to: text) } }
    }
}

/// The right-click menu, on items or on empty space.
struct ItemMenu: View {
    let model: Browser
    let ids: Set<URL>

    var body: some View {
        if ids.isEmpty {
            Button("New folder", systemImage: "folder.badge.plus") { Task { await model.newFolder() } }
            Button("Paste", systemImage: "doc.on.clipboard") { Task { await model.paste() } }.disabled(!model.canPaste)
            Divider()
            Button("Refresh", systemImage: "arrow.clockwise") { model.reload() }
            Toggle("Show hidden items", isOn: Bindable(model.prefs).showHidden)
            Divider()
            Button("Open in Terminal", systemImage: "terminal") { model.openTerminal() }
        } else {
            let picked = model.rows.filter { ids.contains($0.url) }
            let folder = picked.count == 1 && picked[0].isFolder ? picked[0].url : nil
            Button("Open") { model.open(ids) }
            Divider()
            Button("Cut", systemImage: "scissors") { model.copy(ids, cut: true) }
            Button("Copy", systemImage: "doc.on.doc") { model.copy(ids, cut: false) }
            if let folder {
                Button("Paste into folder", systemImage: "doc.on.clipboard") { Task { await model.paste(into: folder) } }
                    .disabled(!model.canPaste)
            }
            Button("Rename", systemImage: "character.cursor.ibeam") { if let url = ids.first { model.startRename(url) } }
                .disabled(ids.count != 1)
            Button("Delete", systemImage: "trash") { Task { await model.trash(ids) } }
            Divider()
            Button("Copy as path", systemImage: "link") { model.copyPaths(ids) }
            if let folder {
                let pinned = model.prefs.pins.contains(folder.path)
                Button(pinned ? "Unpin from Quick access" : "Pin to Quick access", systemImage: pinned ? "pin.slash" : "pin") {
                    model.prefs.togglePin(folder.path)
                }
                Button("Open in Terminal", systemImage: "terminal") { model.openTerminal(folder) }
            }
            Button("Show in Finder", systemImage: "finder") {
                NSWorkspace.shared.activateFileViewerSelecting(picked.map(\.url))
            }
        }
    }
}

// MARK: This Mac

struct ThisMacPage: View {
    let model: Browser
    @State private var picked: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Folders").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Places.userFolders) { folder in
                        tile(path: folder.path) {
                            Text(folder.title)
                            Text(folder.path.replacingOccurrences(of: URL.homeDirectory.path, with: "~"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Devices and drives").font(.headline).padding(.top, 12)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Places.volumes()) { volume in
                        tile(path: volume.path) {
                            Text(volume.name)
                            ProgressView(value: Double(volume.total - volume.free), total: Double(max(volume.total, 1)))
                                .tint(volume.free * 10 < volume.total ? .red : .accentColor)
                            Text("\(volume.free.formatted(.byteCount(style: .file))) free of \(volume.total.formatted(.byteCount(style: .file)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Click selects, double-click opens, as on This PC.
    private func tile(path: String, @ViewBuilder text: () -> some View) -> some View {
        HStack(spacing: 10) {
            FileIcon(path: path, size: 40)
            VStack(alignment: .leading, spacing: 3) { text() }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(picked == path ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.go(.folder(path)) }
        .onTapGesture { picked = path }
        .contextMenu {
            Button("Open") { model.go(.folder(path)) }
            let pinned = model.prefs.pins.contains(path)
            Button(pinned ? "Unpin from Quick access" : "Pin to Quick access", systemImage: pinned ? "pin.slash" : "pin") {
                model.prefs.togglePin(path)
            }
            Button("Open in Terminal", systemImage: "terminal") { model.openTerminal(URL(fileURLWithPath: path)) }
        }
    }
}

// MARK: Status bar

struct StatusBar: View {
    let model: Browser

    var body: some View {
        HStack(spacing: 16) {
            if model.folder != nil {
                Text("^[\(model.rows.count) item](inflect: true)")
            }
            let picked = model.selectedItems
            if !picked.isEmpty {
                let bytes = picked.filter { !$0.isFolder }.reduce(Int64(0)) { $0 + $1.size }
                let size = bytes > 0 ? "  " + bytes.formatted(.byteCount(style: .file)) : ""
                Text("^[\(picked.count) item](inflect: true) selected\(size)")
            }
            if model.isSearching {
                ProgressView().controlSize(.mini)
                Text("Searching…")
            }
            if let status = model.status { Text(status) }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

/// Hands the view's NSWindow to the model, for the key handler.
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
