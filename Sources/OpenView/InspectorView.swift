import SwiftUI

/// 右侧信息栏：选中图片 → 图片信息；没选图片但选中了文件夹 → 文件夹设置
struct InspectorView: View {
    @EnvironmentObject var store: LibraryStore

    /// 栏宽只由信息栏自己决定（用户可拖动），任何面板的内容都不能把它撑宽或压窄
    var body: some View {
        panel.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var panel: some View {
        if store.selectedIDs.count > 1 {
            MultiPanel()
        } else if let item = store.selectedItem {
            ItemPanel(item: item).id(item.id)
        } else if let id = store.selectedFolderCard, let folder = store.folder(id) {
            FolderPanel(folder: folder).id(folder.id)
        } else if case .folder(let id) = store.selection, let folder = store.folder(id) {
            FolderPanel(folder: folder).id(folder.id)
        } else {
            ContentUnavailableView("未选择图片", systemImage: "photo",
                                   description: Text("选择一张图片或一个文件夹查看信息"))
        }
    }
}

// MARK: - 图片

private struct ItemPanel: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.openWindow) private var openWindow
    let item: Item

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PreviewBox { ThumbnailView(item: item) }
                        .onTapGesture(count: 2, perform: openViewer)

                    HStack(spacing: 6) {
                        EditableTitle(value: item.name, placeholder: "名称") { n in
                            store.update(item.id) { $0.name = n }
                        }
                        if !item.ext.isEmpty {
                            Text(".\(item.ext)").font(.title3).foregroundStyle(.tertiary)
                        }
                        Menu { moreMenu } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    .padding(.top, 16)

                    Properties(rows: [
                        ("尺寸", item.width > 0 ? "\(item.width) × \(item.height)" : "—"),
                        ("大小", ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)),
                        ("格式", item.ext.uppercased()),
                        ("创建", formatDate(item.btime)),
                        ("添加", formatDate(item.modificationTime)),
                    ])

                    PanelSection("标签") {
                        TagEditor(tags: item.tags, suggestions: store.allTags) { tags in
                            store.update(item.id) { $0.tags = tags }
                        }
                    }

                    if !item.palette.isEmpty {
                        PanelSection("颜色") { PaletteRow(palette: item.palette) }
                    }

                    PanelSection("文件夹") {
                        FolderMembership(folders: item.folders) { fs in
                            store.update(item.id) { $0.folders = fs }
                        }
                    }

                    PanelSection("备注") {
                        EditableText(value: item.annotation, placeholder: "添加备注…", multiline: true) { v in
                            store.update(item.id) { $0.annotation = v }
                        }
                    }

                    PanelSection("来源网址") {
                        HStack(alignment: .firstTextBaseline) {
                            EditableText(value: item.url, placeholder: "https://") { v in
                                store.update(item.id) { $0.url = v.trimmingCharacters(in: .whitespaces) }
                            }
                            if let u = URL(string: item.url), u.scheme?.hasPrefix("http") == true {
                                Link(destination: u) { Image(systemName: "arrow.up.right") }.help("在浏览器中打开")
                            }
                        }
                    }
                }
                .padding(18)
            }

            VStack(spacing: 8) {
                Button(action: openViewer) {
                    Label("打开", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) } label: {
                    Label("在访达中显示", systemImage: "folder")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.15)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .font(.callout.weight(.medium))
            .padding(18)
        }
    }

    @ViewBuilder private var moreMenu: some View {
        Button("在新窗口中打开", action: openViewer)
        Button("拷贝文件路径") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.fileURL.path, forType: .string)
        }
        Divider()
        if item.isDeleted {
            Button("从废纸篓恢复") { store.restore([item.id]) }
        } else {
            Button("移到废纸篓") { store.trash([item.id]) }
        }
    }

    private func openViewer() {
        openWindow(id: "viewer", value: ViewerTarget(path: item.fileURL.path, title: item.name))
    }
}

// MARK: - 多选

private struct MultiPanel: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        let items = store.selectedItems
        let ids = items.map(\.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 叠放的几张缩略图
                ZStack {
                    ForEach(Array(items.prefix(3).enumerated().reversed()), id: \.element.id) { i, it in
                        ThumbnailView(item: it)
                            .frame(width: 150, height: 150)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                            .rotationEffect(.degrees(Double(i) * 5))
                            .offset(x: Double(i) * 10)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)

                Text("已选择 \(items.count) 项").font(.title3.weight(.semibold)).padding(.top, 16)
                Properties(rows: [
                    ("总大小", ByteCountFormatter.string(fromByteCount: Int64(items.reduce(0) { $0 + $1.size }),
                                                    countStyle: .file)),
                ])

                PanelSection("添加标签") {
                    TagEditor(tags: [], suggestions: store.allTags) { store.addTags(ids, $0) }
                }

                PanelSection("文件夹") {
                    Menu {
                        ForEach(store.folderPaths, id: \.id) { f in
                            Button(f.path) { store.addToFolder(ids, f.id) }
                        }
                    } label: { Label("添加到文件夹", systemImage: "plus").font(.callout) }
                    .menuStyle(.borderlessButton).fixedSize()
                    if case .folder(let fid) = store.selection {
                        Button("从「\(store.folder(fid)?.name ?? "")」中移除") { store.removeFromFolder(ids, fid) }
                            .buttonStyle(.borderless).font(.callout)
                    }
                }

                PanelSection("操作") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button { ItemActions.copyToPasteboard(store: store, ids: ids) } label: {
                            Label("拷贝 \(items.count) 个文件", systemImage: "doc.on.doc")
                        }
                        Button { ItemActions.export(items) } label: { Label("导出到…", systemImage: "square.and.arrow.up") }
                        Button { ItemActions.reveal(items) } label: { Label("在访达中显示", systemImage: "folder") }
                        if store.selection == .trash {
                            Button { store.restore(ids) } label: { Label("从废纸篓恢复", systemImage: "arrow.uturn.backward") }
                        } else {
                            Button(role: .destructive) { store.trash(ids) } label: {
                                Label("移到废纸篓", systemImage: "trash")
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }
            .padding(18)
        }
    }
}

// MARK: - 文件夹

private struct FolderPanel: View {
    @EnvironmentObject var store: LibraryStore
    let folder: Folder

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PreviewBox {
                    if let cover = store.coverID(folder).flatMap(store.item) {
                        ThumbnailView(item: cover)
                    } else {
                        Image(systemName: "folder.fill").font(.system(size: 56))
                            .foregroundStyle(FolderTint.color(folder.iconColor))
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: folder.hasPassword ? "lock.fill" : "folder.fill")
                        .foregroundStyle(FolderTint.color(folder.iconColor))
                    EditableTitle(value: folder.name, placeholder: "文件夹名称") { n in
                        store.setFolder(folder.id, name: n)
                    }
                }
                .padding(.top, 16)

                Properties(rows: [
                    ("图片", "\(store.folderCounts[folder.id] ?? 0)"),
                ] + ((folder.children?.isEmpty ?? true) ? [] : [
                    ("子文件夹", "\(folder.children!.count)"),
                    ("含子文件夹", "\(store.totalCount(folder))"),
                ]) + [("路径", store.folderPath(folder.id))]
                  + (folder.hasPassword ? [("加密", "已设置密码（暂不处理）")] : []))

                PanelSection("颜色") {
                    ColorPicker8(selection: folder.iconColor) { store.setFolderColor(folder.id, $0) }
                }

                PanelSection("标签") {
                    TagEditor(tags: folder.tags, suggestions: store.allTags) { store.setFolder(folder.id, tags: $0) }
                }

                PanelSection("描述") {
                    EditableText(value: folder.description, placeholder: "添加描述…", multiline: true) {
                        store.setFolder(folder.id, description: $0)
                    }
                }
            }
            .padding(18)
        }
    }
}

// MARK: - 部件

/// 预览框：固定高度，图片等比缩放（不铺满，避免图片超出边框）
private struct PreviewBox<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// 分区：上面一条分隔线 + 标题
private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.vertical, 6)
            Text(title).font(.callout.weight(.semibold))
            content
        }
        .padding(.top, 8)
    }
}

private struct Properties: View {
    let rows: [(String, String)]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(rows, id: \.0) { k, v in
                GridRow {
                    Text(k).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    Text(v).textSelection(.enabled).lineLimit(2)
                }
            }
        }
        .font(.callout)
        .padding(.top, 14)
    }
}

/// 单行/多行文本：回车或失去焦点时提交，值没变不提交
private struct EditableText: View {
    let value: String
    let placeholder: String
    var multiline = false
    var font: Font = .body
    var allowEmpty = true
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if multiline {
                TextField(placeholder, text: $text, axis: .vertical).lineLimit(2...12)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(font)
        .focused($focused)
        .onAppear { text = value }
        .onChange(of: value) { _, v in if !focused { text = v } }
        .onSubmit(save)
        .onChange(of: focused) { _, f in if !f { save() } }
        .onDisappear(perform: save)
    }

    private func save() {
        let t = multiline ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !allowEmpty && t.isEmpty { text = value; return }
        if t != value { commit(t) }
    }
}

private struct EditableTitle: View {
    let value: String
    let placeholder: String
    let commit: (String) -> Void
    var body: some View {
        EditableText(value: value, placeholder: placeholder, font: .title3.weight(.semibold),
                     allowEmpty: false, commit: commit)
    }
}

/// 8 种文件夹颜色 + 无。每个色块是独立按钮，悬停放大并显示手形光标
private struct ColorPicker8: View {
    let selection: String?
    let choose: (String?) -> Void

    var body: some View {
        FlowLayout(spacing: 4) {   // 放不下时换行，不撑宽信息栏
            Swatch(color: nil, name: "无颜色", selected: selection == nil) { choose(nil) }
            ForEach(FolderTint.options, id: \.key) { o in
                Swatch(color: o.color, name: o.name, selected: selection == o.key) { choose(o.key) }
            }
        }
    }

    private struct Swatch: View {
        let color: Color?
        let name: String
        let selected: Bool
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                ZStack {
                    Circle().fill(color ?? Color.primary.opacity(0.08))
                    if color == nil {
                        Image(systemName: "nosign").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(color == nil ? Color.primary : .white)
                    }
                }
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.5 : 0.1), lineWidth: selected ? 2 : 1))
                .scaleEffect(hover ? 1.15 : 1)
                .animation(.easeOut(duration: 0.1), value: hover)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .onHover { h in
                hover = h
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help(name)
            .accessibilityLabel(name)
        }
    }
}

/// 图片主色（只读），点击拷贝色值
private struct PaletteRow: View {
    let palette: [[Int]]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(palette.prefix(6).enumerated()), id: \.offset) { _, c in
                let hex = c.count >= 3 ? String(format: "#%02X%02X%02X", c[0], c[1], c[2]) : ""
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hex, forType: .string)
                } label: {
                    Circle().fill(rgb(c))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("\(hex)（点击拷贝）")
            }
        }
    }
    private func rgb(_ c: [Int]) -> Color {
        guard c.count >= 3 else { return .clear }
        return Color(red: Double(c[0]) / 255, green: Double(c[1]) / 255, blue: Double(c[2]) / 255)
    }
}

/// 标签：胶囊显示，悬停出现删除；输入框回车添加（逗号分隔可一次加多个）；菜单选已有标签
private struct TagEditor: View {
    let tags: [String]
    let suggestions: [String]
    let change: ([String]) -> Void
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(tags, id: \.self) { t in
                        Chip(text: t) { change(tags.filter { $0 != t }) }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("添加标签，回车确认", text: $input)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onSubmit(add)
                let rest = suggestions.filter { !tags.contains($0) }
                Menu {
                    ForEach(rest, id: \.self) { t in Button(t) { change(tags + [t]) } }
                } label: { Image(systemName: "tag") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(rest.isEmpty)
                .help("从已有标签中选择")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }

    private func add() {
        let new = input.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !tags.contains($0) }
        input = ""
        if !new.isEmpty { change(tags + new) }
    }
}

/// 图片所属文件夹：胶囊显示，菜单添加
private struct FolderMembership: View {
    @EnvironmentObject var store: LibraryStore
    let folders: [String]
    let change: ([String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if folders.isEmpty {
                Text("未分类").font(.callout).foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(folders, id: \.self) { fid in
                        Chip(text: store.folderPath(fid), icon: "folder.fill",
                             tint: FolderTint.color(store.folder(fid)?.iconColor)) {
                            change(folders.filter { $0 != fid })
                        }
                    }
                }
            }
            Menu {
                ForEach(store.folderPaths.filter { !folders.contains($0.id) }, id: \.id) { f in
                    Button(f.path) { change(folders + [f.id]) }
                }
            } label: { Label("添加到文件夹", systemImage: "plus").font(.callout) }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }
}

private struct Chip: View {
    let text: String
    var icon: String? = nil
    var tint: Color = .secondary
    let onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).imageScale(.small).foregroundStyle(tint) }
            Text(text).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hover ? 1 : 0)
            .help("移除")
        }
        .font(.callout)
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(hover ? 0.1 : 0.06)))
        .onHover { hover = $0 }
    }
}

private func formatDate(_ ms: Double) -> String {
    guard ms > 0 else { return "—" }
    return Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .shortened)
}

/// 自动换行的横向布局
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var cur = Row()
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if !cur.indices.isEmpty && cur.width + spacing + s.width > width {
                rows.append(cur)
                cur = Row(y: cur.y + cur.height + spacing)
            }
            cur.width += (cur.indices.isEmpty ? 0 : spacing) + s.width
            cur.height = max(cur.height, s.height)
            cur.indices.append(i)
        }
        if !cur.indices.isEmpty { rows.append(cur) }
        return rows
    }
}

private extension View {
    func secondaryButton() -> some View {
        self.frame(maxWidth: .infinity).padding(.vertical, 8).padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.15)))
            .contentShape(Rectangle())
    }
}
