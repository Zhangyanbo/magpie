import AppKit

extension NSPasteboard.PasteboardType {
    /// 程序内拖动：图片条目 id、文件夹 id
    static let magpieItem = NSPasteboard.PasteboardType("io.github.magpie.item")
    static let magpieFolder = NSPasteboard.PasteboardType("io.github.magpie.folder")
}

/// 带闭包的菜单项
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
         enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

/// 图片的各种操作。右键菜单、快捷键、信息栏按钮、拖放都调用这里，保证行为一致
@MainActor
enum ItemActions {
    static func menu(store: LibraryStore, ids: [String], open: @escaping (Item) -> Void) -> NSMenu {
        let items = ids.compactMap(store.item)
        let m = NSMenu()
        m.autoenablesItems = false
        let n = items.count
        if n == 1, let it = items.first {
            m.addItem(ActionMenuItem("在新窗口中打开") { open(it) })
        }
        m.addItem(ActionMenuItem("在访达中显示") { reveal(items) })
        m.addItem(.separator())
        m.addItem(ActionMenuItem(n > 1 ? "拷贝 \(n) 项" : "拷贝", key: "c") { copyToPasteboard(store: store, ids: ids) })
        m.addItem(ActionMenuItem(n > 1 ? "拷贝 \(n) 个文件路径" : "拷贝文件路径") { copyPaths(items) })
        m.addItem(ActionMenuItem("导出到…") { export(items) })
        m.addItem(.separator())

        let add = NSMenuItem(title: "添加到文件夹", action: nil, keyEquivalent: "")
        add.submenu = folderMenu(store: store) { store.addToFolder(ids, $0) }
        m.addItem(add)
        if case .folder(let fid) = store.selection {
            m.addItem(ActionMenuItem("从「\(store.folder(fid)?.name ?? "")」中移除") { store.removeFromFolder(ids, fid) })
        }
        m.addItem(.separator())
        if store.selection == .trash {
            m.addItem(ActionMenuItem("从废纸篓恢复", key: "\u{8}") { store.restore(ids) })
        } else {
            m.addItem(ActionMenuItem("移到废纸篓", key: "\u{8}") { store.trash(ids) })
        }
        return m
    }

    /// 所有文件夹的扁平菜单（带层级缩进）
    static func folderMenu(store: LibraryStore, choose: @escaping (String) -> Void) -> NSMenu {
        let m = NSMenu()
        func walk(_ fs: [Folder], _ depth: Int) {
            for f in fs {
                let item = ActionMenuItem(f.name) { choose(f.id) }
                item.indentationLevel = depth
                item.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
                m.addItem(item)
                walk(f.children ?? [], depth + 1)
            }
        }
        walk(store.folders, 0)
        return m
    }

    /// 拷贝到剪贴板：文件本身（可在访达、聊天软件等处粘贴）；单张图片时同时放图片数据
    static func copyToPasteboard(store: LibraryStore, ids: [String]) {
        let items = ids.compactMap(store.item)
        guard !items.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items.map { $0.fileURL as NSURL })
        let change = pb.changeCount
        if items.count == 1 {
            let url = items[0].fileURL
            DispatchQueue.global(qos: .userInitiated).async {   // 读原图可能在 NAS 上，不在主线程做
                guard let data = try? Data(contentsOf: url), let img = NSImage(data: data),
                      let tiff = img.tiffRepresentation else { return }
                DispatchQueue.main.async {
                    // 剪贴板在此期间没被改过才补上图片数据
                    let pb = NSPasteboard.general
                    guard pb.changeCount == change else { return }
                    pb.pasteboardItems?.first?.setData(tiff, forType: .tiff)
                }
            }
        }
    }

    static func copyPaths(_ items: [Item]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(items.map(\.fileURL.path).joined(separator: "\n"), forType: .string)
    }

    static func reveal(_ items: [Item]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.fileURL))
    }

    /// 导出：把原文件拷贝到选定的目录（重名时加编号）
    static func export(_ items: [Item]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出"
        panel.message = "选择导出 \(items.count) 个文件的位置"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let sources = items.map { ($0.fileURL, "\($0.name).\($0.ext)") }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var failed = 0
            for (src, name) in sources {
                var dest = dir.appending(noStat: name)
                var k = 2
                while fm.fileExists(atPath: dest.path) {
                    let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                    dest = dir.appending(noStat: ext.isEmpty ? "\(base) \(k)" : "\(base) \(k).\(ext)")
                    k += 1
                }
                do { try fm.copyItem(at: src, to: dest) } catch { failed += 1 }
            }
            DispatchQueue.main.async {
                if failed > 0 {
                    let a = NSAlert()
                    a.messageText = "有 \(failed) 个文件导出失败"
                    a.runModal()
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }
        }
    }

    /// 拖动用的剪贴板项：对外是文件（拖到访达即拷贝），对内带条目 id
    static func dragItem(_ item: Item) -> NSPasteboardItem {
        let p = NSPasteboardItem()
        p.setString(item.fileURL.absoluteString, forType: .fileURL)
        p.setString(item.id, forType: .magpieItem)
        return p
    }

    static func dragFolder(_ id: String) -> NSPasteboardItem {
        let p = NSPasteboardItem()
        p.setString(id, forType: .magpieFolder)
        return p
    }

    static func draggedItemIDs(_ info: NSDraggingInfo) -> [String] {
        (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .magpieItem) }
    }

    static func draggedFolderID(_ info: NSDraggingInfo) -> String? {
        info.draggingPasteboard.pasteboardItems?.first?.string(forType: .magpieFolder)
    }

    /// 图片拖到某个文件夹时：按住 ⌥ 是「添加」；否则从某个文件夹视图拖出来是「移动」，从其他视图拖出来是「添加」
    static func dropOperation(_ info: NSDraggingInfo, store: LibraryStore, target: String) -> NSDragOperation {
        if case .folder(let from) = store.selection, from != target,
           !NSEvent.modifierFlags.contains(.option) { return .move }
        return .copy
    }

    static func dropItems(_ ids: [String], on target: String, store: LibraryStore, operation: NSDragOperation) {
        if operation == .move, case .folder(let from) = store.selection {
            store.addToFolder(ids, target, movingFrom: from)
        } else {
            store.addToFolder(ids, target)
        }
    }

    /// 文件夹能否放进 target（nil = 顶层）
    static func canMoveFolder(_ id: String, into target: String?, store: LibraryStore) -> Bool {
        guard let target else { return true }
        return target != id && !store.isDescendant(target, of: id)
    }

    static func confirmDeleteFolder(_ id: String, store: LibraryStore) {
        guard let f = store.folder(id) else { return }
        guard store.canDeleteFolders else {
            let a = NSAlert()
            a.messageText = "暂时不能删除文件夹"
            a.informativeText = "删除文件夹需要先知道哪些图片在里面。请等索引建立完成后再试。"
            a.runModal()
            return
        }
        let a = NSAlert()
        a.messageText = "删除文件夹「\(f.name)」？"
        a.informativeText = (f.children?.isEmpty == false ? "它的子文件夹也会一起删除。" : "")
            + "里面的图片不会被删除，只是不再属于这个文件夹。"
        a.alertStyle = .warning
        a.addButton(withTitle: "删除")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { store.deleteFolder(id) }
    }
}
