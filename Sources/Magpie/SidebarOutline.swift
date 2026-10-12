import AppKit
import SwiftUI

/// 文件夹的操作：左侧右键、网格里子文件夹卡片右键共用
@MainActor
enum FolderActions {
    /// rename 为 nil 时不显示「重命名」（只有左侧树支持行内重命名）
    static func menu(store: LibraryStore, id: String?, rename: (() -> Void)?) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(ActionMenuItem("新建文件夹") { _ = store.createFolder(in: nil) })
        if let id {
            m.addItem(ActionMenuItem("新建子文件夹") { _ = store.createFolder(in: id) })
            m.addItem(.separator())
            if let rename { m.addItem(ActionMenuItem("重命名", key: "\r", modifiers: []) { rename() }) }
            m.addItem(ActionMenuItem("删除文件夹…", key: "\u{8}") { ItemActions.confirmDeleteFolder(id, store: store) })
        }
        return m
    }
}

/// 左侧树：NSOutlineView（source list）。
/// - 拖文件夹：放到文件夹上 = 成为子文件夹；放到两行之间 = 排序/换层级；放到「文件夹」标题 = 顶层
/// - 拖图片：放到文件夹 = 移动（按住 ⌥ 为添加）；放到「废纸篓」= 移到废纸篓；放到「未分类」= 移出所有文件夹
/// - 回车重命名，⌘⌫ 删除，右键菜单
struct SidebarOutline: NSViewRepresentable {
    @EnvironmentObject var store: LibraryStore
    let filter: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let ov = SidebarOutlineView()
        ov.coordinator = c
        ov.style = .sourceList
        ov.headerView = nil
        ov.floatsGroupRows = false
        ov.rowSizeStyle = .default
        ov.autoresizesOutlineColumn = true
        ov.indentationPerLevel = 14
        let col = NSTableColumn(identifier: .init("main"))
        ov.addTableColumn(col)
        ov.outlineTableColumn = col
        ov.dataSource = c
        ov.delegate = c
        ov.registerForDraggedTypes([.magpieItem, .magpieFolder])
        ov.setDraggingSourceOperationMask(.move, forLocal: true)
        ov.draggingDestinationFeedbackStyle = .sourceList
        c.outline = ov

        let scroll = NSScrollView()
        scroll.documentView = ov
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.store = store
        c.apply(filter: filter)
    }

    // MARK: - 节点

    final class Node {
        enum Kind { case header(String), smart(SidebarSel, String, String), folder(Folder) }
        let key: String
        var kind: Kind
        var children: [Node] = []
        weak var parent: Node?
        init(key: String, kind: Kind) { self.key = key; self.kind = kind }
        var folder: Folder? { if case .folder(let f) = kind { return f }; return nil }
        var isHeader: Bool { if case .header = kind { return true }; return false }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
        weak var outline: SidebarOutlineView?
        var store: LibraryStore!
        private var cache: [String: Node] = [:]
        private var roots: [Node] = []
        private var foldersHeader: Node?
        private var expanded: Set<String> = []
        private var signature = ""
        private var syncing = false
        private var renaming: String?
        private var pendingRename: String?
        private var knownFolders: Set<String> = []

        private func node(_ key: String, _ kind: Node.Kind) -> Node {
            let n = cache[key] ?? Node(key: key, kind: kind)
            n.kind = kind
            cache[key] = n
            return n
        }

        private var stateVersion = -1

        func apply(filter: String) {
            guard let ov = outline else { return }
            // 打开了库（恢复完界面状态后）：取回这个库上次展开的节点
            if store.viewStateVersion != stateVersion {
                stateVersion = store.viewStateVersion
                expanded = store.expandedFolders
                signature = ""
                knownFolders = []
            }
            let q = filter.trimmingCharacters(in: .whitespaces)
            // 树结构、数量或筛选变化时才重建（选择变化只同步选中行）
            let sig = "\(q)|\(store.folders.hashValue)|\(store.counts.hashValue)|\(store.folderCounts.hashValue)"
            if sig != signature {
                signature = sig
                rebuild(filter: q)
                syncing = true
                ov.reloadData()
                for r in roots { ov.expandItem(r) }
                restoreExpansion(roots, all: !q.isEmpty)
                syncing = false
            }
            syncSelection()
            if let id = pendingRename, let n = cache["f:\(id)"] {
                pendingRename = nil
                DispatchQueue.main.async { self.beginRename(n) }
            }
        }

        private func rebuild(filter q: String) {
            let lib = node("h:lib", .header("素材库"))
            lib.children = [
                node("s:all", .smart(.all, "全部", "square.grid.2x2")),
                node("s:unc", .smart(.uncategorized, "未分类", "tray")),
                node("s:trash", .smart(.trash, "废纸篓", "trash")),
            ]
            let fh = node("h:folders", .header("文件夹"))
            func build(_ fs: [Folder], _ parent: Node) -> [Node] {
                fs.compactMap { f in
                    let kids = f.children ?? []
                    let n = node("f:\(f.id)", .folder(f))
                    n.parent = parent
                    n.children = build(kids, n)
                    if !q.isEmpty && !f.name.localizedCaseInsensitiveContains(q) && n.children.isEmpty { return nil }
                    return n
                }
            }
            fh.children = build(store.folders, fh)
            for c in lib.children { c.parent = lib }
            roots = [lib, fh]
            foldersHeader = fh
            // 新建的文件夹：展开它的父级，并进入重命名
            let all = Set(store.folderPaths.map(\.id))
            let added = all.subtracting(knownFolders)
            if !knownFolders.isEmpty, added.count == 1, let id = added.first {
                pendingRename = id
                var p = cache["f:\(id)"]?.parent
                while let x = p, !x.isHeader { expanded.insert(x.key); p = x.parent }
                store.setExpanded(expanded)
            }
            knownFolders = all
        }

        private func restoreExpansion(_ nodes: [Node], all: Bool) {
            guard let ov = outline else { return }
            for n in nodes where !n.children.isEmpty {
                if all || n.isHeader || expanded.contains(n.key) { ov.expandItem(n) }
                restoreExpansion(n.children, all: all)
            }
        }

        private func key(for sel: SidebarSel?) -> String? {
            switch sel {
            case .all: return "s:all"
            case .uncategorized: return "s:unc"
            case .trash: return "s:trash"
            case .folder(let id): return "f:\(id)"
            case nil: return nil
            }
        }

        private func syncSelection() {
            guard let ov = outline, let k = key(for: store.selection), let n = cache[k] else { return }
            var p = n.parent   // 选中的文件夹被折叠在里面时展开它
            while let x = p, !x.isHeader { if !ov.isItemExpanded(x) { ov.expandItem(x) }; p = x.parent }
            let row = ov.row(forItem: n)
            guard row >= 0, ov.selectedRow != row else { return }
            syncing = true
            ov.selectRowIndexes([row], byExtendingSelection: false)
            ov.scrollRowToVisible(row)
            syncing = false
        }

        // MARK: 数据源

        func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Node)?.children.count ?? roots.count
        }
        func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Node)?.children[index] ?? roots[index]
        }
        func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? Node)?.children.isEmpty ?? true)
        }
        func outlineView(_ ov: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? Node)?.isHeader ?? false }
        func outlineView(_ ov: NSOutlineView, shouldSelectItem item: Any) -> Bool { !((item as? Node)?.isHeader ?? true) }
        func outlineView(_ ov: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            !((item as? Node)?.isHeader ?? false)   // 标题行不显示折叠按钮
        }

        func outlineViewItemDidExpand(_ n: Notification) {
            if !syncing, let node = n.userInfo?["NSObject"] as? Node { expanded.insert(node.key); store.setExpanded(expanded) }
        }
        func outlineViewItemDidCollapse(_ n: Notification) {
            if !syncing, let node = n.userInfo?["NSObject"] as? Node { expanded.remove(node.key); store.setExpanded(expanded) }
        }

        func outlineViewSelectionDidChange(_ n: Notification) {
            guard !syncing, let ov = outline, let node = ov.item(atRow: ov.selectedRow) as? Node else { return }
            switch node.kind {
            case .smart(let sel, _, _): store.selection = sel
            case .folder(let f): store.selection = .folder(f.id)
            case .header: break
            }
        }

        // MARK: 行视图

        func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            if case .header(let title) = node.kind {
                let v = (ov.makeView(withIdentifier: .init("header"), owner: nil) as? NSTableCellView) ?? {
                    let v = NSTableCellView(); v.identifier = .init("header")
                    let t = NSTextField(labelWithString: ""); v.textField = t; v.addSubview(t)
                    t.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
                                                 t.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
                    return v
                }()
                v.textField?.stringValue = title
                return v
            }
            let cell = (ov.makeView(withIdentifier: SidebarCell.id, owner: nil) as? SidebarCell) ?? SidebarCell()
            switch node.kind {
            case .smart(let sel, let title, let icon):
                cell.set(title: title, icon: icon, tint: nil, count: store.counts[sel] ?? 0)
            case .folder(let f):
                cell.set(title: f.name, icon: f.hasPassword ? "lock.fill" : "folder.fill",
                         tint: f.iconColor.map { NSColor(FolderTint.color($0)) }, count: store.folderCounts[f.id] ?? 0)
            case .header: break
            }
            cell.textField?.delegate = self
            return cell
        }

        // MARK: 重命名（行内）

        func beginRename(_ node: Node) {
            guard let ov = outline, let f = node.folder else { return }
            let row = ov.row(forItem: node)
            guard row >= 0, let cell = ov.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell,
                  let tf = cell.textField else { return }
            ov.selectRowIndexes([row], byExtendingSelection: false)
            ov.scrollRowToVisible(row)
            renaming = f.id
            tf.isEditable = true
            tf.isSelectable = true
            ov.window?.makeFirstResponder(tf)
            tf.currentEditor()?.selectAll(nil)
        }

        func renameSelected() {
            guard let ov = outline, let n = ov.item(atRow: ov.selectedRow) as? Node, n.folder != nil else { return }
            beginRename(n)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField, let id = renaming else { return }
            renaming = nil
            tf.isEditable = false
            let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name.contains("/") {
                tf.stringValue = store.folder(id)?.name ?? ""
            } else if name != store.folder(id)?.name {
                store.setFolder(id, name: name)
            }
            outline?.window?.makeFirstResponder(outline)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.cancelOperation(_:)), let id = renaming {   // Esc 取消
                (control as? NSTextField)?.stringValue = store.folder(id)?.name ?? ""
                outline?.window?.makeFirstResponder(outline)
                return true
            }
            return false
        }

        // MARK: 右键与键盘

        func menu(forRow row: Int) -> NSMenu? {
            guard let ov = outline else { return nil }
            let node = row >= 0 ? ov.item(atRow: row) as? Node : nil
            if let node, let f = node.folder {
                return FolderActions.menu(store: store, id: f.id) { [weak self] in self?.beginRename(node) }
            }
            if node == nil || node?.key == "h:folders" { return FolderActions.menu(store: store, id: nil, rename: nil) }
            return nil
        }

        func deleteSelected() {
            guard let ov = outline, let f = (ov.item(atRow: ov.selectedRow) as? Node)?.folder else { return }
            ItemActions.confirmDeleteFolder(f.id, store: store)
        }

        // MARK: 拖放

        func outlineView(_ ov: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let f = (item as? Node)?.folder else { return nil }
            return ItemActions.dragFolder(f.id)
        }

        func outlineView(_ ov: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            let node = item as? Node
            if let fid = ItemActions.draggedFolderID(info) {
                // 放到「文件夹」标题或某个文件夹上 / 之间
                if node === foldersHeader || node == nil {
                    if node == nil { ov.setDropItem(foldersHeader, dropChildIndex: NSOutlineViewDropOnItemIndex) }
                    return .move
                }
                guard let target = node?.folder else { return [] }
                if index == NSOutlineViewDropOnItemIndex && target.id == fid { return [] }
                return ItemActions.canMoveFolder(fid, into: target.id, store: store) ? .move : []
            }
            let ids = ItemActions.draggedItemIDs(info)
            guard !ids.isEmpty, let node else { return [] }
            switch node.kind {
            case .folder(let f):
                if index != NSOutlineViewDropOnItemIndex { ov.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex) }
                return ItemActions.dropOperation(info, store: store, target: f.id)
            case .smart(.trash, _, _), .smart(.uncategorized, _, _):
                guard index == NSOutlineViewDropOnItemIndex else { return [] }
                return .move
            default:
                return []
            }
        }

        func outlineView(_ ov: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            let node = item as? Node
            if let fid = ItemActions.draggedFolderID(info) {
                let parent = node?.folder?.id   // nil = 顶层
                var at: Int? = index == NSOutlineViewDropOnItemIndex ? nil : index
                // 同一父级内往后挪：先摘下再插入，下标要减一
                if let i = at, let cur = cache["f:\(fid)"], cur.parent === (node ?? foldersHeader),
                   let old = cur.parent?.children.firstIndex(where: { $0 === cur }), old < i { at = i - 1 }
                store.moveFolder(fid, to: parent, at: at)
                return true
            }
            let ids = ItemActions.draggedItemIDs(info)
            guard !ids.isEmpty, let node else { return false }
            switch node.kind {
            case .folder(let f):
                ItemActions.dropItems(ids, on: f.id, store: store,
                                      operation: ItemActions.dropOperation(info, store: store, target: f.id))
            case .smart(.trash, _, _): store.trash(ids)
            case .smart(.uncategorized, _, _): store.clearFolders(ids)
            default: return false
            }
            return true
        }
    }
}

final class SidebarOutlineView: NSOutlineView {
    weak var coordinator: SidebarOutline.Coordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: coordinator?.renameSelected()                                         // 回车重命名
        default: super.keyDown(with: event)
        }
    }

    /// 菜单栏「移到废纸篓」(⌘⌫) 在左侧树有焦点时 = 删除文件夹
    @objc func delete(_ sender: Any?) { coordinator?.deleteSelected() }
    /// 菜单栏「打开」(⌘O/⌘↓) 在左侧树有焦点时 = 把焦点交给网格
    @objc func openSelection(_ sender: Any?) { coordinator?.store.focusGridRequest += 1 }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return coordinator?.menu(forRow: row)
    }
}

final class SidebarCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("SidebarCell")
    private let icon = NSImageView()
    private let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingTail
        title.isEditable = false
        title.focusRingType = .none
        textField = title
        imageView = icon
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        for v in [icon, title, count] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(title: String, icon name: String, tint: NSColor?, count n: Int) {
        textField?.stringValue = title
        textField?.isEditable = false
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        icon.contentTintColor = tint ?? .secondaryLabelColor
        count.stringValue = n > 0 ? n.formatted() : ""
    }
}
