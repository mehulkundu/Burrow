import AppKit
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI

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
            // Dropped between rows: this folder. The table takes every drag over it,
            // so a drop modifier on the Table itself never fires.
            .dropDestination(for: URL.self) { _, urls in
                model.drop(urls, onto: nil)
            }
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: URL.self) { ids in
            ItemMenu(model: model, ids: ids)
        } primaryAction: { ids in
            model.open(ids)
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
                TagDots(tags: item.tags)
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
                // Fill the visible area so a drop anywhere lands here: the scroll
                // view itself never sees drops.
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .dropDestination(for: URL.self) { urls, _ in
                    model.drop(urls, onto: nil)
                    return true
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selection = [] }
            .contextMenu { ItemMenu(model: model, ids: []) }
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
                .overlay(alignment: .bottomTrailing) { TagDots(tags: item.tags) }
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
    @Environment(\.openWindow) private var openWindow

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
            if let folder {
                Button("Open in new tab", systemImage: "plus.square.on.square") { Tabs.open(openWindow, path: folder.path) }
            }
            Button("Quick Look", systemImage: "eye") { model.quickLook = picked.first?.url }
            if picked.count == 1, picked[0].isPackage {
                Button("Show Package Contents", systemImage: "shippingbox") { model.go(.folder(picked[0].url.path)) }
            }
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
            Button(ids.count > 1 ? "Rename \(ids.count) items…" : "Rename", systemImage: "character.cursor.ibeam") {
                model.renameSelection(ids)
            }
            Button("Delete", systemImage: "trash") { Task { await model.trash(ids) } }
            Divider()
            Menu("Tags") {
                ForEach(TagDots.standard, id: \.name) { tag in
                    Button {
                        model.toggleTag(tag.name, on: ids)
                    } label: {
                        Label(tag.name, systemImage: picked.allSatisfy { $0.tags.contains(tag.name) } ? "checkmark.circle.fill" : "circle.fill")
                    }
                    .tint(tag.color)
                }
            }
            Button("Compress to ZIP file", systemImage: "archivebox") { Task { await model.compress(ids) } }
            if picked.count == 1, picked[0].url.pathExtension.lowercased() == "zip" {
                Button("Extract All", systemImage: "arrow.up.bin") { Task { await model.extract(picked[0].url) } }
            }
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
                    if item.isFolder {
                        Thumb(url: item.url, size: 120).frame(maxWidth: .infinity)
                    } else {
                        // The preview pane: pages, pictures, text, and video, live, as Alt+P shows in Explorer.
                        Preview(url: item.url)
                            .frame(height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
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
    @State private var folderSize: Int64?

    var body: some View {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            if isFolder {
                let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
                row("Contains", count == 1 ? "1 item" : "\(count) items")
                row("Size", folderSize.map { $0.formatted(.byteCount(style: .file)) } ?? "Calculating…")
            } else if let size = values?.fileSize {
                row("Size", Int64(size).formatted(.byteCount(style: .file)))
            }
            if let date = values?.contentModificationDate { row("Modified", date.formatted(date: .abbreviated, time: .shortened)) }
            if let date = values?.creationDate { row("Created", date.formatted(date: .abbreviated, time: .shortened)) }
            row("Location", url.deletingLastPathComponent().path)
        }
        .font(.callout)
        .task(id: url) {
            folderSize = nil
            if isFolder { folderSize = await FS.size(of: url) }
        }
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

/// Finder's colored tags as small dots.
struct TagDots: View {
    let tags: [String]
    static let standard: [(name: String, color: Color)] = [
        ("Red", .red), ("Orange", .orange), ("Yellow", .yellow), ("Green", .green),
        ("Blue", .blue), ("Purple", .purple), ("Gray", .gray),
    ]

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: -3) {
                ForEach(tags, id: \.self) { tag in
                    Circle()
                        .fill(Self.standard.first { $0.name == tag }?.color ?? .secondary)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1))
                }
            }
            .help(tags.joined(separator: ", "))
        }
    }
}

/// Quick Look's own preview view, for the details panel.
struct Preview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.autostarts = false
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}

/// F2 on several files: number them like Explorer, or find and replace like the power tools.
struct BatchRenameSheet: View {
    let model: Browser
    let urls: [URL]
    @Environment(\.dismiss) private var dismiss
    @State private var numbering = true
    @State private var base = ""
    @State private var start = 1
    @State private var find = ""
    @State private var replace = ""

    var body: some View {
        let items = urls.map { url in (name: url.lastPathComponent, isFolder: model.rows.first { $0.url == url }?.isFolder ?? false) }
        let names = Renamer.plan(items, find: numbering ? "" : find, replace: replace, base: base, start: start)
        let unchanged = !numbering && find.isEmpty
        let problem = unchanged ? nil : Renamer.problem(items.map(\.name), names, others: Set(model.rows.map { $0.name.lowercased() }))
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename \(urls.count) items").font(.title3.weight(.semibold))
            Picker("", selection: $numbering) {
                Text("Name and number").tag(true)
                Text("Find and replace").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Form {
                if numbering {
                    TextField("Name", text: $base)
                    Stepper("Start at \(start)", value: $start, in: 0...9999)
                } else {
                    TextField("Find", text: $find)
                    TextField("Replace with", text: $replace)
                }
            }
            .formStyle(.grouped)
            .frame(height: 120)
            List(Array(zip(items.map(\.name), names).enumerated()), id: \.offset) { _, pair in
                HStack {
                    Text(pair.0).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Text(pair.1).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(height: 180)
            if let problem { Text(problem).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Rename") {
                    Task { await model.rename(urls, to: names) }
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(unchanged || problem != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { base = (urls.first?.deletingPathExtension().lastPathComponent) ?? "" }
    }
}
