import AppKit
import SwiftUI

/// 中间网格：用 AppKit 的 NSCollectionView 实现。
/// 拖动框选、Shift/⌘ 多选、⌘A、方向键（含 Shift 扩展）都是系统原生行为，和访达一致；
/// 只有可见的格子会创建，几万张图也不卡。
struct CollectionGrid: NSViewRepresentable {
    @EnvironmentObject var store: LibraryStore
    let ids: [String]
    let subs: [Folder]
    let thumbSize: Double
    let open: (Item) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let cv = GridCollectionView()
        cv.coordinator = c
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.allowsEmptySelection = true
        cv.backgroundColors = [.clear]
        cv.collectionViewLayout = c.layout
        cv.dataSource = c
        cv.delegate = c
        cv.register(GridCell.self, forItemWithIdentifier: GridCell.id)
        cv.register(GridHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                    withIdentifier: GridHeader.id)
        cv.setDraggingSourceOperationMask(.copy, forLocal: false)
        cv.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        cv.registerForDraggedTypes([.openviewItem, .openviewFolder])
        c.collectionView = cv

        let scroll = NSScrollView()
        cv.autoresizingMask = [.width]
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        DispatchQueue.main.async { cv.window?.makeFirstResponder(cv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.store = store
        c.open = open
        c.apply(ids: ids, subs: subs, thumbSize: thumbSize, viewGen: store.viewGen)
        if c.focusRequest != store.focusGridRequest {
            c.focusRequest = store.focusGridRequest
            if let cv = c.collectionView { DispatchQueue.main.async { cv.window?.makeFirstResponder(cv) } }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate,
                             NSCollectionViewDelegateFlowLayout {
        weak var collectionView: GridCollectionView?
        var store: LibraryStore!
        var open: (Item) -> Void = { _ in }
        var focusRequest = 0
        let layout: NSCollectionViewFlowLayout = {
            let l = NSCollectionViewFlowLayout()
            l.minimumInteritemSpacing = 18
            l.minimumLineSpacing = 22
            l.sectionInset = NSEdgeInsets(top: 8, left: 22, bottom: 22, right: 22)
            return l
        }()

        private var ids: [String] = []
        private var position: [String: Int] = [:]
        private var subs: [Folder] = []
        private var thumbSize: Double = 0
        private var viewGen = -1
        private var syncing = false

        /// 有子文件夹时 section 0 是子文件夹，section 1 是图片；否则只有图片一个 section
        private var hasSubs: Bool { !subs.isEmpty }
        private var itemSection: Int { hasSubs ? 1 : 0 }

        func apply(ids: [String], subs: [Folder], thumbSize: Double, viewGen: Int) {
            guard let cv = collectionView else { return }
            if thumbSize != self.thumbSize {
                self.thumbSize = thumbSize
                layout.invalidateLayout()
            }
            if ids != self.ids || subs.map(\.id) != self.subs.map(\.id) {
                self.ids = ids
                self.subs = subs
                position = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
                syncing = true
                cv.reloadData()
                syncing = false
            } else {
                self.subs = subs
                // 数据没变：只刷新可见格子（metadata 读到了、名称改了、视图切换后重新请求缩略图）
                let regen = viewGen != self.viewGen
                for ip in cv.indexPathsForVisibleItems() {
                    if let cell = cv.item(at: ip) as? GridCell { configure(cell, at: ip, force: regen) }
                }
            }
            self.viewGen = viewGen
            syncSelectionFromStore()
        }

        // MARK: 选择同步

        private func syncSelectionFromStore() {
            guard let cv = collectionView else { return }
            var want = Set(store.selectedIDs.compactMap { position[$0] }.map { IndexPath(item: $0, section: itemSection) })
            if hasSubs, let f = store.selectedFolderCard, let i = subs.firstIndex(where: { $0.id == f }) {
                want.insert(IndexPath(item: i, section: 0))
            }
            guard want != cv.selectionIndexPaths else { return }
            syncing = true
            cv.selectionIndexPaths = want
            syncing = false
            if let id = store.selectedItemID, let i = position[id] {
                let ip = IndexPath(item: i, section: itemSection)
                if !cv.indexPathsForVisibleItems().contains(ip) {
                    cv.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
                }
            }
        }

        private func pushSelectionToStore(focus: String?) {
            guard !syncing, let cv = collectionView else { return }
            let sel = cv.selectionIndexPaths.filter { $0.section == itemSection }.map { ids[$0.item] }
            let card = hasSubs ? cv.selectionIndexPaths.filter { $0.section == 0 }.max().map { subs[$0.item].id } : nil
            store.setSelection(Set(sel), focus: focus, folderCard: card)
        }

        func collectionView(_ cv: NSCollectionView, didSelectItemsAt ips: Set<IndexPath>) {
            let focus = ips.filter { $0.section == itemSection }.max().map { ids[$0.item] }
            pushSelectionToStore(focus: focus)
        }

        func collectionView(_ cv: NSCollectionView, didDeselectItemsAt ips: Set<IndexPath>) {
            pushSelectionToStore(focus: nil)
        }

        /// 选中的 id，按网格顺序
        var selectedIDs: [String] {
            (collectionView?.selectionIndexPaths ?? []).filter { $0.section == itemSection }
                .sorted().map { ids[$0.item] }
        }

        // MARK: 数据源

        func numberOfSections(in cv: NSCollectionView) -> Int { hasSubs ? 2 : 1 }

        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection s: Int) -> Int {
            hasSubs && s == 0 ? subs.count : ids.count
        }

        func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
            let cell = cv.makeItem(withIdentifier: GridCell.id, for: ip) as! GridCell
            configure(cell, at: ip, force: false)
            return cell
        }

        private func configure(_ cell: GridCell, at ip: IndexPath, force: Bool) {
            if hasSubs && ip.section == 0 {
                guard ip.item < subs.count else { return }
                let f = subs[ip.item]
                let cover = store.coverID(f)
                let coverItem = cover.flatMap(store.item)
                if let cover, coverItem == nil { store.requestMeta(cover) }
                let n = store.totalCount(f), k = f.children?.count ?? 0
                let sub = [n > 0 ? "\(n) 张" : nil, k > 0 ? "\(k) 个子文件夹" : nil].compactMap { $0 }.joined(separator: " · ")
                cell.show(folder: f, cover: coverItem, subtitle: sub, force: force)
            } else {
                guard ip.item < ids.count else { return }
                let id = ids[ip.item]
                if let item = store.item(id) {
                    cell.show(item: item, force: force)
                } else {
                    cell.showPlaceholder(id: id)
                    store.requestMeta(id)
                }
            }
        }

        func collectionView(_ cv: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                            at ip: IndexPath) -> NSView {
            let h = cv.makeSupplementaryView(ofKind: kind, withIdentifier: GridHeader.id, for: ip) as! GridHeader
            h.set(ip.section == 0 ? "子文件夹" : "图片", count: ip.section == 0 ? subs.count : ids.count)
            return h
        }

        // MARK: 布局

        func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout,
                            sizeForItemAt ip: IndexPath) -> NSSize {
            let avail = max(100, cv.bounds.width - 44)
            let gap = 18.0
            let cols = max(1, Int((avail + gap) / (thumbSize + gap)))
            let w = floor((avail - gap * Double(cols - 1)) / Double(cols))
            return NSSize(width: w, height: w * 0.75 + 46)
        }

        func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout,
                            referenceSizeForHeaderInSection s: Int) -> NSSize {
            hasSubs && (s == 0 || !ids.isEmpty) ? NSSize(width: cv.bounds.width, height: 34) : .zero
        }

        // MARK: 拖动：图片拖到访达/其他应用是文件，程序内带 id；子文件夹卡片可以拖到别的文件夹

        func collectionView(_ cv: NSCollectionView, canDragItemsAt ips: Set<IndexPath>, with event: NSEvent) -> Bool {
            true
        }

        func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt ip: IndexPath) -> NSPasteboardWriting? {
            if hasSubs && ip.section == 0 { return ip.item < subs.count ? ItemActions.dragFolder(subs[ip.item].id) : nil }
            guard let item = store.item(ids[ip.item]) else { return nil }
            return ItemActions.dragItem(item)
        }

        /// 只能放到子文件夹卡片上：图片 → 放进该文件夹；文件夹 → 成为它的子文件夹
        func collectionView(_ cv: NSCollectionView, validateDrop info: NSDraggingInfo,
                            proposedIndexPath ipPtr: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation opPtr: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            let ip = ipPtr.pointee as IndexPath
            guard hasSubs, ip.section == 0, ip.item < subs.count else { return [] }
            opPtr.pointee = .on
            let target = subs[ip.item].id
            if let fid = ItemActions.draggedFolderID(info) {
                return ItemActions.canMoveFolder(fid, into: target, store: store) && fid != target ? .move : []
            }
            guard !ItemActions.draggedItemIDs(info).isEmpty else { return [] }
            return ItemActions.dropOperation(info, store: store, target: target)
        }

        func collectionView(_ cv: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath ip: IndexPath,
                            dropOperation: NSCollectionView.DropOperation) -> Bool {
            guard hasSubs, ip.section == 0, ip.item < subs.count else { return false }
            let target = subs[ip.item].id
            if let fid = ItemActions.draggedFolderID(info) {
                store.moveFolder(fid, to: target, at: nil)
                return true
            }
            let ids = ItemActions.draggedItemIDs(info)
            guard !ids.isEmpty else { return false }
            ItemActions.dropItems(ids, on: target, store: store,
                                  operation: ItemActions.dropOperation(info, store: store, target: target))
            return true
        }

        // MARK: 滚动预取

        @objc func scrolled() {
            guard let cv = collectionView else { return }
            let last = cv.indexPathsForVisibleItems().filter { $0.section == itemSection }.map(\.item).max() ?? 0
            let next = ids[min(last + 1, ids.count)..<min(last + 60, ids.count)]
            var items: [Item] = []
            for id in next {
                if let it = store.item(id) { items.append(it) } else { store.requestMeta(id, urgent: false) }
            }
            ImageLoader.shared.prefetchThumbnails(items)
        }

        // MARK: 鼠标与键盘（由 GridCollectionView 转过来）

        func isFolderCell(_ ip: IndexPath) -> Bool { hasSubs && ip.section == 0 }

        func clicked(at ip: IndexPath, count: Int) -> Bool {
            guard count == 2 else { return false }
            if hasSubs && ip.section == 0 {
                if ip.item < subs.count { store.selection = .folder(subs[ip.item].id) }
                return true
            }
            if let item = store.item(ids[ip.item]) { open(item); return true }
            return false
        }

        func togglePreview() {
            guard store.selectedItemID != nil else { return }
            store.preview.toggle()
        }

        func escape() {
            if store.preview { store.preview = false } else { store.setSelection([], focus: nil, folderCard: nil) }
        }

        /// 回车 / ⌘↓ / ⌘O：有选中的图片就打开图片，否则进入选中的子文件夹
        func openFocused() {
            if let item = store.selectedItem { open(item) }
            else if let f = store.selectedFolderCard { store.selection = .folder(f) }
        }

        /// ⌘⌫：选中了图片就移到废纸篓（废纸篓里则恢复）；只选中子文件夹卡片时删除文件夹
        func deleteSelection() {
            let sel = selectedIDs
            if !sel.isEmpty {
                if store.selection == .trash { store.restore(sel) } else { store.trash(sel) }
            } else if let f = store.selectedFolderCard {
                ItemActions.confirmDeleteFolder(f, store: store)
            }
        }

        func menu(for ip: IndexPath?) -> NSMenu? {
            guard let cv = collectionView else { return nil }
            if let ip, hasSubs && ip.section == 0 {
                guard ip.item < subs.count else { return nil }
                if !cv.selectionIndexPaths.contains(ip) {
                    cv.selectionIndexPaths = [ip]
                    pushSelectionToStore(focus: nil)
                }
                let id = subs[ip.item].id
                let m = FolderActions.menu(store: store, id: id, rename: nil)
                m.insertItem(ActionMenuItem("打开") { [weak self] in self?.store.selection = .folder(id) }, at: 0)
                m.insertItem(.separator(), at: 1)
                return m
            }
            if let ip, !cv.selectionIndexPaths.contains(ip) {
                cv.selectionIndexPaths = [ip]
                pushSelectionToStore(focus: ids[ip.item])
            }
            let sel = selectedIDs
            guard !sel.isEmpty else { return nil }
            return ItemActions.menu(store: store, ids: sel, open: open)
        }
    }
}

// MARK: - 集合视图子类：键盘、双击、右键

final class GridCollectionView: NSCollectionView {
    weak var coordinator: CollectionGrid.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let c = coordinator, let ip = indexPathForItem(at: p) else { return super.mouseDown(with: event) }
        // 和访达一样：单击选中，双击打开（子文件夹 = 进入，图片 = 在新窗口查看）
        if event.clickCount == 2, c.clicked(at: ip, count: 2) { return }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let c = coordinator else { return super.keyDown(with: event) }
        // 带 ⌘ 的快捷键都在菜单栏里（OpenViewApp），通过响应链调到下面的 @objc 方法
        // 预览打开时：左右（以及上下）= 按顺序上一张/下一张，不按网格行列移动
        if c.store.preview {
            switch event.keyCode {
            case 123, 126: c.store.stepPreview(-1); return
            case 124, 125: c.store.stepPreview(1); return
            default: break
            }
        }
        switch event.keyCode {
        case 49: c.togglePreview()                                  // 空格
        case 36, 76: c.openFocused()                                // 回车
        case 53: c.escape()                                         // Esc
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        return coordinator?.menu(for: indexPathForItem(at: p))
    }

    @objc func copy(_ sender: Any?) {
        guard let c = coordinator else { return }
        ItemActions.copyToPasteboard(store: c.store, ids: c.selectedIDs)
    }

    @objc func delete(_ sender: Any?) {
        coordinator?.deleteSelection()
    }

    @objc func openSelection(_ sender: Any?) {
        coordinator?.openFocused()
    }
}

// MARK: - 格子

private final class CardView: NSView {
    var selected = false { didSet { needsDisplay = true } }
    let image = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        image.wantsLayer = true
        image.layer?.contentsGravity = .resizeAspectFill
        image.layer?.masksToBounds = true
        image.layer?.cornerRadius = 10
        addSubview(image)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        image.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        image.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        image.layer?.borderWidth = 1
        layer?.cornerRadius = 13
        layer?.borderWidth = selected ? 2.5 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
    override func layout() {
        super.layout()
        image.frame = bounds.insetBy(dx: 4, dy: 4)
    }
}

final class GridCell: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("GridCell")

    private let card = CardView()
    private let badge = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private var task: Task<Void, Never>?
    private var shownKey: String?
    private var pendingThumb: Item?

    override func loadView() {
        view = NSView()
        name.font = .systemFont(ofSize: NSFont.systemFontSize)
        name.lineBreakMode = .byTruncatingMiddle
        sub.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        badge.contentTintColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        badge.layer?.cornerRadius = 5
        badge.imageScaling = .scaleNone
        for v in [card, name, sub] { view.addSubview(v) }
        card.addSubview(badge)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds
        let cardH = b.width * 0.75
        // AppKit 坐标原点在左下
        card.frame = NSRect(x: -4, y: b.height - cardH - 4, width: b.width + 8, height: cardH + 8)
        name.frame = NSRect(x: 0, y: b.height - cardH - 26, width: b.width, height: 18)
        sub.frame = NSRect(x: 0, y: b.height - cardH - 44, width: b.width, height: 16)
        badge.frame = NSRect(x: 12, y: 12, width: 22, height: 20)
    }

    override var isSelected: Bool { didSet { card.selected = isSelected } }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelLoad()
        shownKey = nil
        card.image.layer?.contents = nil
    }

    func show(item: Item, force: Bool) {
        badge.isHidden = true
        name.stringValue = item.fullName
        sub.stringValue = item.subtitle
        loadThumb(item, key: "\(item.id)|\(item.fileURL.path)", force: force)
    }

    func show(folder: Folder, cover: Item?, subtitle: String, force: Bool) {
        badge.isHidden = false
        badge.image = NSImage(systemSymbolName: folder.hasPassword ? "lock.fill" : "folder.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        name.stringValue = folder.name
        sub.stringValue = subtitle
        if let cover {
            loadThumb(cover, key: "F\(folder.id)|\(cover.id)", force: force)
        } else {
            cancelLoad(); shownKey = nil
            card.image.layer?.contents = nil
        }
    }

    func showPlaceholder(id: String) {
        badge.isHidden = true
        name.stringValue = ""
        sub.stringValue = ""
        cancelLoad(); shownKey = nil
        card.image.layer?.contents = nil
    }

    private func loadThumb(_ item: Item, key: String, force: Bool) {
        if !force && key == shownKey && (card.image.layer?.contents != nil || task != nil) { return }
        cancelLoad()
        shownKey = key
        if let img = ImageLoader.shared.cachedThumbnail(item) {
            setImage(img); return
        }
        card.image.layer?.contents = nil
        pendingThumb = item
        task = Task { @MainActor [weak self] in
            let img = await ImageLoader.shared.thumbnail(item)
            guard let self, !Task.isCancelled, self.shownKey == key else { return }
            self.task = nil
            self.pendingThumb = nil
            if let img { self.setImage(img) }
        }
    }

    /// 格子被复用或内容换了：取消还在排队的缩略图读取
    private func cancelLoad() {
        task?.cancel(); task = nil
        if let p = pendingThumb { ImageLoader.shared.cancel(thumbnailOf: p) }
        pendingThumb = nil
    }

    private func setImage(_ img: NSImage) {
        card.image.layer?.contents = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

final class GridHeader: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("GridHeader")
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ title: String, count: Int) {
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        s.append(NSAttributedString(string: "  \(count)", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        label.attributedStringValue = s
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 22, y: 6, width: bounds.width - 44, height: 18)
    }
}
