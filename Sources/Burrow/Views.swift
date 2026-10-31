import AppKit
import QuickLookThumbnailing
import SwiftUI

struct BrowserView: View {
    @State private var model = Browser()
    @State private var monitor: Any?
    @FocusState private var contentFocused: Bool

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 380)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                // Clicks on the bars never leave a focus ring behind.
                Group {
                    HeaderBar(model: model)
                    CommandBar(model: model)
                }
                .focusEffectDisabled()
                Divider()
                HStack(spacing: 0) {
                    MainContent(model: model)
                        .focused($contentFocused)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.prefs.showDetails {
                        Divider()
                        DetailsPane(model: model).frame(width: 270)
                    }
                }
                Divider()
                StatusBar(model: model).focusEffectDisabled()
            }
            .ignoresSafeArea(.container, edges: .top)
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
        .onChange(of: model.location) { contentFocused = true }
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

/// Search results show wherever you search from, Home and This Mac included.
struct MainContent: View {
    let model: Browser

    var body: some View {
        if model.isSearchActive || model.folder != nil {
            if model.prefs.iconView { IconGrid(model: model) } else { FileTable(model: model) }
        } else if model.location == .home {
            HomePage(model: model)
        } else {
            ThisMacPage(model: model)
        }
    }
}

// MARK: Shared pieces

/// Flat button that lights up under the pointer, like Explorer's toolbar buttons.
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
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? AnyShapeStyle(.tint.opacity(0.18))
                              : AnyShapeStyle(.primary.opacity(configuration.isPressed ? 0.12 : hovering && isEnabled ? 0.07 : 0)))
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
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
                .frame(width: 30, height: 28)
        }
        .buttonStyle(HoverStyle(isOn: isOn))
        .help(help ?? title)
        .accessibilityLabel(title)
    }
}

/// The rounded field behind the address bar and the search box.
struct FieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quinary))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
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

/// A Quick Look thumbnail for pictures, PDFs, and videos; the file's icon otherwise.
struct Thumb: View {
    let url: URL
    let size: CGFloat
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { image = await Thumb.load(url, size: size) }
    }

    static func load(_ url: URL, size: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: 2, representationTypes: .thumbnail)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
                continuation.resume(returning: thumbnail?.cgImage)
            }
        }
    }
}

// MARK: Navigation pane

struct Sidebar: View {
    let model: Browser

    var body: some View {
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
            }
            Section("Locations") {
                Label("This Mac", systemImage: "desktopcomputer").tag(Location.thisMac)
                ForEach(Places.volumes()) { FolderNode(path: $0.path, title: $0.name, model: model) }
                if let iCloud = Places.iCloudDrive {
                    FolderNode(path: iCloud, title: "iCloud Drive", model: model)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// A drive or folder in Locations. Its subfolders load when it opens.
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
            Label { Text(title ?? Places.name(path)).lineLimit(1) } icon: { FileIcon(path: path) }
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

    var body: some View {
        let pinned = model.prefs.pins.contains(path)
        Button("Open", systemImage: "folder") { model.go(.folder(path)) }
        Button(pinned ? "Unpin from Favorites" : "Pin to Favorites", systemImage: pinned ? "pin.slash" : "pin") {
            model.prefs.togglePin(path)
        }
        Divider()
        Button("Copy as path", systemImage: "link") {
            model.pasteboard.clearContents()
            model.pasteboard.setString(path, forType: .string)
        }
        Button("Open in Terminal", systemImage: "terminal") { model.openTerminal(URL(fileURLWithPath: path)) }
    }
}

// MARK: Header: navigation, address, search

struct HeaderBar: View {
    @Bindable var model: Browser

    var body: some View {
        HStack(spacing: 2) {
            IconButton(title: "Back", symbol: "arrow.left", help: "Back (Alt+Left)") { model.goBack() }
                .disabled(!model.canGoBack)
            IconButton(title: "Forward", symbol: "arrow.right", help: "Forward (Alt+Right)") { model.goForward() }
                .disabled(!model.canGoForward)
            IconButton(title: "Up", symbol: "arrow.up", help: "Up to the parent folder (Alt+Up)") { model.goUp() }
                .disabled(!model.canGoUp)
            IconButton(title: "Refresh", symbol: "arrow.clockwise", help: "Refresh (F5)") { model.reload() }
            AddressBar(model: model).padding(.leading, 6)
            SearchBox(model: model).frame(width: 260).padding(.leading, 6)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .frame(height: 52)
        .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()) }
    }
}

struct AddressBar: View {
    @Bindable var model: Browser
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            locationIcon.padding(.leading, 10).padding(.trailing, 4)
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
                    .padding(.trailing, 10)
            } else {
                let crumbs = model.crumbs
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 { SubfolderMenu(model: model, parent: crumbs[index - 1].location) }
                    Button { model.go(crumb.location) } label: {
                        Text(crumb.title).lineLimit(1).padding(.horizontal, 6).frame(height: 24)
                    }
                    .buttonStyle(HoverStyle())
                    // The last folders keep their names; the first ones shorten first.
                    .layoutPriority(Double(index))
                }
                if model.isSearchActive {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                    Text("Search Results in \(model.title)").lineLimit(1).padding(.horizontal, 6)
                        .layoutPriority(100)
                }
                Color.clear
                    .frame(minWidth: 24, maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { model.editingAddress = true }
            }
        }
        .modifier(FieldBackground())
        .help("Click empty space to type a path (Ctrl+L)")
    }

    @ViewBuilder private var locationIcon: some View {
        switch model.location {
        case .home: Image(systemName: "house").foregroundStyle(.secondary)
        case .thisMac: Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
        case .folder(let path): FileIcon(path: path)
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
            if model.searchText.isEmpty {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            } else {
                Button("Clear search", systemImage: "xmark.circle.fill") { model.searchText = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .modifier(FieldBackground())
        .onChange(of: model.focusSearch) { focused = true }
    }
}

// MARK: Command bar

struct CommandBar: View {
    @Bindable var model: Browser

    var body: some View {
        let picked = model.selection
        let inFolder = model.folder != nil
        HStack(spacing: 2) {
            Menu {
                Button("Folder", systemImage: "folder") { Task { await model.newFolder() } }
                Button("Text Document", systemImage: "doc.text") { Task { await model.newTextDocument() } }
            } label: {
                Label("New", systemImage: "plus.circle.fill").labelStyle(.titleAndIcon).padding(.horizontal, 8).frame(height: 28)
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
            IconButton(title: "Rename", symbol: "character.cursor.ibeam", help: "Rename (F2)") {
                if let url = picked.first { model.startRename(url) }
            }
            .disabled(picked.count != 1)
            ShareLink(items: model.selectedItems.map(\.url)) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 14)).frame(width: 30, height: 28)
            }
            .buttonStyle(HoverStyle())
            .disabled(picked.isEmpty)
            .help("Share")
            IconButton(title: "Delete", symbol: "trash", help: "Move to Trash (Delete)") { Task { await model.trash(picked) } }
                .disabled(picked.isEmpty)
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
                Label("Sort", systemImage: "arrow.up.arrow.down").labelStyle(.titleAndIcon).padding(.horizontal, 8).frame(height: 28)
            }
            Menu {
                Picker("Layout", selection: Bindable(model.prefs).iconView) {
                    Label("Large icons", systemImage: "square.grid.2x2").tag(true)
                    Label("Details", systemImage: "list.bullet").tag(false)
                }
                .pickerStyle(.inline)
                Section("Show") {
                    Toggle("Details pane", isOn: Bindable(model.prefs).showDetails)
                    Toggle("Hidden items", isOn: Bindable(model.prefs).showHidden)
                }
            } label: {
                Label("View", systemImage: "rectangle.grid.1x2").labelStyle(.titleAndIcon).padding(.horizontal, 8).frame(height: 28)
            }
            Menu {
                Button("Select all", systemImage: "checkmark.circle") { model.selectAll() }
                Button("Select none", systemImage: "circle") { model.selection = [] }
                Button("Invert selection", systemImage: "circle.lefthalf.filled") { model.invertSelection() }
                if let dir = model.folder {
                    Divider()
                    PlaceMenu(model: model, path: dir.path)
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14)).frame(width: 30, height: 28)
            }
            .help("See more")
            Spacer()
            Button { model.prefs.showDetails.toggle() } label: {
                Label("Details", systemImage: "sidebar.right").labelStyle(.titleAndIcon).padding(.horizontal, 8).frame(height: 28)
            }
            .buttonStyle(HoverStyle(isOn: model.prefs.showDetails))
            .help("Details pane (Alt+Shift+P)")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(HoverStyle())
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    private var separator: some View {
        Divider().frame(height: 20).padding(.horizontal, 6)
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
            .width(min: 180, ideal: 320)
            TableColumn("Date modified", value: \.modified) { item in
                Text(item.modified.formatted(date: .numeric, time: .shortened)).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Type", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 140)
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
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: URL.self) { ids in
            ItemMenu(model: model, ids: ids)
        } primaryAction: { ids in
            model.open(ids)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.drop(urls, onto: nil)
            return true
        }
        .overlay { EmptyState(model: model) }
    }
}

struct EmptyState: View {
    let model: Browser

    var body: some View {
        if model.rows.isEmpty {
            if let error = model.loadError {
                ContentUnavailableView("Can't open this folder", systemImage: "lock", description: Text(error))
            } else if model.isSearchActive {
                if !model.isSearching {
                    ContentUnavailableView.search(text: model.searchText)
                }
            } else {
                Text("This folder is empty.").foregroundStyle(.secondary)
            }
        }
    }
}

struct NameCell: View {
    let item: FileItem
    let model: Browser

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(path: item.url.path, size: 18)
            if model.renaming == item.url {
                RenameField(item: item, model: model)
            } else {
                // The name keeps its room; the folder after it shortens first.
                Text(item.name).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                if model.isSearchActive {
                    Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: URL.homeDirectory.path, with: "~"))
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
            }
        }
        .padding(.vertical, 3)
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

// MARK: Icons view

struct IconGrid: View {
    let model: Browser
    private let tile: CGFloat = 112

    var body: some View {
        GeometryReader { geometry in
            let columns = max(1, Int((geometry.size.width - 24 + 8) / (tile + 8)))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: 8), count: columns),
                          alignment: .leading, spacing: 8) {
                    ForEach(model.rows) { IconTile(item: $0, model: model, size: tile) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selection = [] }
            .contextMenu { ItemMenu(model: model, ids: []) }
            .dropDestination(for: URL.self) { urls, _ in
                model.drop(urls, onto: nil)
                return true
            }
            .onAppear { model.gridColumns = columns }
            .onChange(of: columns) { model.gridColumns = columns }
        }
        .focusable()
        .focusEffectDisabled()
        .overlay { EmptyState(model: model) }
    }
}

struct IconTile: View {
    let item: FileItem
    let model: Browser
    let size: CGFloat
    @State private var hovering = false

    var body: some View {
        let selected = model.selection.contains(item.url)
        VStack(spacing: 6) {
            Thumb(url: item.url, size: 64)
            if model.renaming == item.url {
                RenameField(item: item, model: model)
            } else {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
            }
        }
        .padding(8)
        .frame(width: size, height: size, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.primary.opacity(hovering ? 0.06 : 0)))
        }
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 8).strokeBorder(.tint.opacity(0.5)) }
        }
        .opacity(Clip.shared.cut.contains(item.url) || item.isHidden ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            // One handler, so a single click selects at once and a double click opens.
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                model.open([item.url])
            } else {
                let flags = NSEvent.modifierFlags
                model.click(item.url, command: flags.contains(.command), shift: flags.contains(.shift))
            }
        }
        .contextMenu { ItemMenu(model: model, ids: selected ? model.selection : [item.url]) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .dropDestination(for: URL.self) { urls, _ in
            model.drop(urls, onto: item.isFolder ? item.url : nil)
            return true
        }
    }
}

/// The right-click menu, on items or on empty space.
struct ItemMenu: View {
    let model: Browser
    let ids: Set<URL>

    var body: some View {
        if ids.isEmpty {
            Menu("New") {
                Button("Folder", systemImage: "folder") { Task { await model.newFolder() } }
                Button("Text Document", systemImage: "doc.text") { Task { await model.newTextDocument() } }
            }
            Button("Paste", systemImage: "doc.on.clipboard") { Task { await model.paste() } }.disabled(!model.canPaste)
            Divider()
            Picker("View", selection: Bindable(model.prefs).iconView) {
                Text("Large icons").tag(true)
                Text("Details").tag(false)
            }
            Button("Refresh", systemImage: "arrow.clockwise") { model.reload() }
            Toggle("Show hidden items", isOn: Bindable(model.prefs).showHidden)
            Divider()
            Button("Open in Terminal", systemImage: "terminal") { model.openTerminal() }
        } else {
            let picked = model.rows.filter { ids.contains($0.url) }
            let folder = picked.count == 1 && picked[0].isFolder ? picked[0].url : nil
            Button("Open") { model.open(ids) }
            if picked.count == 1, !picked[0].isFolder {
                Menu("Open with") {
                    ForEach(NSWorkspace.shared.urlsForApplications(toOpen: picked[0].url), id: \.self) { app in
                        Button(FileManager.default.displayName(atPath: app.path)) {
                            NSWorkspace.shared.open([picked[0].url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                }
            }
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
                Button(pinned ? "Unpin from Favorites" : "Pin to Favorites", systemImage: pinned ? "pin.slash" : "pin") {
                    model.prefs.togglePin(folder.path)
                }
                Button("Open in Terminal", systemImage: "terminal") { model.openTerminal(folder) }
            }
            if model.isSearchActive {
                Button("Open file location", systemImage: "folder") {
                    if let first = picked.first { model.go(.folder(first.url.deletingLastPathComponent().path)) }
                }
            }
            Button("Show in Finder", systemImage: "finder") {
                NSWorkspace.shared.activateFileViewerSelecting(picked.map(\.url))
            }
            Divider()
            Button("Properties", systemImage: "info.circle") {
                model.selection = ids
                model.prefs.showDetails = true
            }
        }
    }
}

// MARK: Details pane

struct DetailsPane: View {
    let model: Browser

    var body: some View {
        let picked = model.selectedItems
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if picked.count == 1, let item = picked[0] as FileItem? {
                    Thumb(url: item.url, size: 150).frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text(item.kind).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("Properties").font(.headline)
                    Properties(url: item.url, isFolder: item.isFolder)
                } else if picked.count > 1 {
                    Image(systemName: "doc.on.doc").font(.system(size: 56, weight: .thin)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                    Text("\(picked.count) items selected").font(.title3.weight(.semibold))
                    let bytes = picked.filter { !$0.isFolder }.reduce(Int64(0)) { $0 + $1.size }
                    if bytes > 0 { Text(bytes.formatted(.byteCount(style: .file))).foregroundStyle(.secondary) }
                } else if let dir = model.folder {
                    FileIcon(path: dir.path, size: 96).frame(maxWidth: .infinity).padding(.vertical, 12)
                    Text(model.title).font(.title3.weight(.semibold))
                    Text("^[\(model.rows.count) item](inflect: true)").foregroundStyle(.secondary)
                    Divider()
                    Properties(url: dir, isFolder: true)
                } else {
                    Text("Select a file to see its details.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(16)
        }
    }
}

struct Properties: View {
    let url: URL
    let isFolder: Bool

    var body: some View {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            if isFolder {
                let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
                row("Contains", "^[\(count) item](inflect: true)")
            } else if let size = values?.fileSize {
                row("Size", Int64(size).formatted(.byteCount(style: .file)))
            }
            if let date = values?.contentModificationDate { row("Modified", date.formatted(date: .abbreviated, time: .shortened)) }
            if let date = values?.creationDate { row("Created", date.formatted(date: .abbreviated, time: .shortened)) }
            row("Location", url.deletingLastPathComponent().path)
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(LocalizedStringKey(value)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Home and This Mac

struct HomePage: View {
    let model: Browser

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Quick access").font(.title3.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(model.prefs.pins, id: \.self) { path in
                        PlaceTile(path: path, title: Places.name(path), model: model) {
                            Text(path.replacingOccurrences(of: URL.homeDirectory.path, with: "~"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Text("Recent").font(.title3.weight(.semibold)).padding(.top, 16)
                if model.recent.isEmpty {
                    Text("Files you open show up here.").foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Date opened").frame(width: 160, alignment: .leading)
                            Text("Location").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 6)
                        ForEach(model.recent) { RecentRow(file: $0, model: model) }
                    }
                }
            }
            .padding(20)
        }
    }
}

struct RecentRow: View {
    let file: RecentFile
    let model: Browser
    @State private var hovering = false

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                FileIcon(path: file.item.url.path, size: 18)
                Text(file.item.name).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(file.used.formatted(date: .numeric, time: .shortened)).foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            Text(file.item.url.deletingLastPathComponent().path.replacingOccurrences(of: URL.homeDirectory.path, with: "~"))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { NSWorkspace.shared.open(file.item.url) } }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(file.item.url) }
            Button("Open file location", systemImage: "folder") {
                model.go(.folder(file.item.url.deletingLastPathComponent().path))
            }
            Button("Copy as path", systemImage: "link") {
                model.pasteboard.clearContents()
                model.pasteboard.setString(file.item.url.path, forType: .string)
            }
        }
    }
}

struct ThisMacPage: View {
    let model: Browser

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Folders").font(.title3.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Places.userFolders) { folder in
                        PlaceTile(path: folder.path, title: folder.title, model: model) {
                            Text(folder.path.replacingOccurrences(of: URL.homeDirectory.path, with: "~"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Text("Devices and drives").font(.title3.weight(.semibold)).padding(.top, 16)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Places.volumes()) { volume in
                        PlaceTile(path: volume.path, title: volume.name, model: model) {
                            ProgressView(value: Double(volume.total - volume.free), total: Double(max(volume.total, 1)))
                                .tint(volume.free * 10 < volume.total ? .red : .accentColor)
                            Text("\(volume.free.formatted(.byteCount(style: .file))) free of \(volume.total.formatted(.byteCount(style: .file)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

/// A folder or drive tile. Double-click opens, as on Home and This PC.
struct PlaceTile<Detail: View>: View {
    let path: String
    let title: String
    let model: Browser
    @ViewBuilder let detail: Detail
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(path: path, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium).lineLimit(1)
                detail
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(hovering ? 0.07 : 0.03)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { model.go(.folder(path)) } }
        .contextMenu { PlaceMenu(model: model, path: path) }
        .dropDestination(for: URL.self) { urls, _ in
            model.drop(urls, onto: URL(fileURLWithPath: path))
            return true
        }
    }
}

// MARK: Status bar

struct StatusBar: View {
    let model: Browser

    var body: some View {
        HStack(spacing: 10) {
            if model.folder != nil || model.isSearchActive {
                Text("^[\(model.rows.count) item](inflect: true)")
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
            if let status = model.status { Text(status) }
            Spacer()
            IconButton(title: "Details", symbol: "list.bullet", help: "Details (Ctrl+Shift+6)", isOn: !model.prefs.iconView) {
                model.prefs.iconView = false
            }
            IconButton(title: "Large icons", symbol: "square.grid.2x2", help: "Large icons (Ctrl+Shift+2)", isOn: model.prefs.iconView) {
                model.prefs.iconView = true
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 30)
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
