import AppKit
import SwiftUI

struct LoadProgress: Equatable {
    var phase: String
    var done = 0
    var total: Int?          // nil = 不确定进度
}

/// 本机索引（全部条目的 metadata）状态。
/// Eagle 格式没有「文件夹 → 条目」的索引，归属只写在每个条目的 metadata.json 里，
/// 所以除「全部」外的视图和搜索都必须先扫一遍全库；扫完存在本机，以后只做增量。
enum IndexState: Equatable { case none, building, ready }

/// 交给后台线程计算的派生数据
private struct Derived {
    var visible: [String]
    var folderNewest: [String: String]
    var counts: [SidebarSel: Int]
    var folderCounts: [String: Int]
    var allTags: [String]
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var root: URL?
    @Published var folders: [Folder] = []
    @Published private(set) var items: [Item] = []
    @Published private(set) var visible: [String] = []      // 当前视图的条目 id，按显示顺序
    @Published private(set) var counts: [SidebarSel: Int] = [:]
    @Published private(set) var folderCounts: [String: Int] = [:]
    @Published private(set) var folderNewest: [String: String] = [:]   // 文件夹 → 最新加入的条目，用作默认封面
    @Published private(set) var allTags: [String] = []
    @Published private(set) var progress: LoadProgress?
    @Published private(set) var indexState: IndexState = .none
    /// 视图切换代数：切换时丢弃排队中的读取，格子的加载任务据此重新发起
    @Published private(set) var viewGen = 0
    @Published var selection: SidebarSel? = .all {
        didSet { if oldValue != selection { preview = false; setSelection([], focus: nil); viewChanged() } }
    }
    @Published var search = "" { didSet { if oldValue != search { viewChanged() } } }
    @Published var selectedItemID: String?
    @Published private(set) var selectedIDs: Set<String> = []
    /// 网格里选中的子文件夹卡片（没选图片时信息栏显示它的设置）
    @Published var selectedFolderCard: String?
    /// 键盘焦点请求：数字变化时对应的视图抢焦点
    @Published var focusSearchRequest = 0
    @Published var focusGridRequest = 0
    @Published var preview = false
    @Published var errorMessage: String?
    @Published private(set) var recents: [String] = UserDefaults.standard.stringArray(forKey: "recentLibraries") ?? []

    private var raws: [String: [String: Any]] = [:]
    private var index: [String: Int] = [:]
    private var mtime: [String: Double] = [:]
    private var allIDs: [String] = []          // 无索引时「全部」视图的来源，按 id 倒序 ≈ 加入时间倒序
    private(set) var folderPaths: [(id: String, path: String)] = []
    private var folderByID: [String: Folder] = [:]
    private var folderParent: [String: String] = [:]
    private var loadToken = UUID()

    /// 所有对库文件的写操作串行放在后台，绝不在主线程碰 NAS
    private let writeQueue = DispatchQueue(label: "openview.write", qos: .userInitiated)

    init() {
        if let last = recents.first { open(URL(fileURLWithPath: last), silent: true) }
    }

    var libraryName: String { root?.deletingPathExtension().lastPathComponent ?? "OpenView" }
    var selectedItem: Item? { selectedItemID.flatMap(item) }
    func item(_ id: String) -> Item? { index[id].map { items[$0] } }

    func folder(_ id: String) -> Folder? { folderByID[id] }

    func folderPath(_ id: String) -> String {
        folderPaths.first { $0.id == id }?.path ?? id
    }

    // MARK: - 子文件夹与封面

    /// 当前文件夹的直接子文件夹（搜索时不显示）
    var currentSubfolders: [Folder] {
        guard case .folder(let id) = selection, search.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return folderByID[id]?.children ?? []
    }

    /// 从根到当前文件夹的路径，用于顶部导航
    var currentPath: [Folder] {
        guard case .folder(var id) = selection else { return [] }
        var path: [Folder] = []
        while let f = folderByID[id] {
            path.insert(f, at: 0)
            guard let p = folderParent[id] else { break }
            id = p
        }
        return path
    }

    /// 封面：手动设置的 coverId → 文件夹里最新的图 → 子文件夹的封面
    func coverID(_ f: Folder) -> String? {
        if let c = f.coverId { return c }
        if let n = folderNewest[f.id] { return n }
        for c in f.children ?? [] { if let id = coverID(c) { return id } }
        return nil
    }

    /// 文件夹内图片总数（含子文件夹，可能重复计数同时在多个子文件夹里的图）
    func totalCount(_ f: Folder) -> Int {
        (folderCounts[f.id] ?? 0) + (f.children ?? []).reduce(0) { $0 + totalCount($1) }
    }

    /// 当前视图是否需要全库索引
    private var needsIndex: Bool {
        (selection ?? .all) != .all || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - 打开 / 最近打开

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true          // .library 可能被系统当成包
        panel.allowsMultipleSelection = false
        panel.message = "选择一个 .library 素材库"
        panel.prompt = "打开"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL, silent: Bool = false) {
        flushIndex(force: true)
        let token = UUID()
        loadToken = token
        root = url
        folders = []; folderPaths = []; folderByID = [:]
        items = []; visible = []; raws = [:]; index = [:]; mtime = [:]; allIDs = []
        counts = [:]; folderCounts = [:]; allTags = []; indexState = .none
        metaInflight = []; pendingMerge = []; unsaved = []; segments = []; idsLoaded = false; pendingBuild = false
        selection = .all; selectedIDs = []; selectedItemID = nil; search = ""; preview = false
        progress = LoadProgress(phase: "正在打开素材库…")
        ImageLoader.shared.configure(cacheDir: LocalCache.dir(for: url))   // 本机只缓存缩略图
        Task { await load(url, token: token, silent: silent) }
    }

    func close() {
        flushIndex(force: true)
        loadToken = UUID()
        ImageLoader.shared.cancelPending()
        root = nil; progress = nil; items = []; visible = []; raws = [:]; index = [:]
        folders = []; selectedIDs = []; selectedItemID = nil; preview = false; indexState = .none
    }

    private func addRecent(_ path: String) {
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        recents = Array(recents.prefix(10))
        UserDefaults.standard.set(recents, forKey: "recentLibraries")
    }

    func removeRecent(_ path: String) {
        recents.removeAll { $0 == path }
        UserDefaults.standard.set(recents, forKey: "recentLibraries")
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.set(recents, forKey: "recentLibraries")
    }

    // MARK: - 打开时只做最少的事

    /// 读文件夹树、库内索引（.openview/index/ 的几个分段文件）和 mtime.json。
    /// 索引完整就只增量读有变化的条目；不完整就什么都不扫，
    /// 「全部」视图按需读取可见格子的 metadata，其他视图用到时再接着建索引。
    private func load(_ url: URL, token: UUID, silent: Bool) async {
        let meta = await Task.detached(priority: .userInitiated) {
            LibraryIO.readJSON(url.appending(noStat: "metadata.json")) as? [String: Any]
        }.value
        guard loadToken == token else { return }
        guard let meta else {
            close()
            if !silent { errorMessage = "「\(url.lastPathComponent)」不是有效的素材库，或者无法访问（缺少 metadata.json）。" }
            return
        }
        addRecent(url.path)
        folders = LibraryIO.parseFolders(meta["folders"] as? [[String: Any]] ?? [])
        rebuildFolderIndex()

        progress = LoadProgress(phase: "正在读取索引…")
        let parsed = await Task.detached(priority: .userInitiated) { () -> (items: [(Item, [String: Any])], segments: [String]) in
            let (raw, segs) = RemoteIndex.load(url)
            let items = raw.compactMap { r in
                (r["id"] as? String).flatMap { LibraryIO.parseItem(r, dir: LibraryIO.itemDir(root: url, id: $0)) }.map { ($0, r) }
            }
            return (items, segs)
        }.value
        guard loadToken == token else { return }
        segments = parsed.segments
        if !parsed.items.isEmpty {
            items = parsed.items.map(\.0)
            index = Dictionary(parsed.items.enumerated().map { ($1.0.id, $0) }, uniquingKeysWith: { a, _ in a })
            raws = Dictionary(parsed.items.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a })
            refresh(now: true)
        }

        progress = LoadProgress(phase: "正在读取条目列表…")
        mtime = await Task.detached(priority: .userInitiated) { LibraryIO.readMtime(root: url) }.value
        guard loadToken == token else { return }
        if mtime.isEmpty {   // 没有 mtime.json 才退回去列目录
            progress = LoadProgress(phase: "正在列出文件…")
            let ids = await Task.detached(priority: .userInitiated) { LibraryIO.listItemIDs(root: url) ?? [] }.value
            guard loadToken == token else { return }
            allIDs = ids.sorted(by: >)
        } else {
            allIDs = mtime.keys.sorted(by: >)
        }
        idsLoaded = true
        progress = nil

        if missingIDs.isEmpty {
            indexState = .ready
            refresh(now: true)
            _ = await readInBatches(changedIDs, url: url, token: token, phase: "正在同步变化")
            compactIfNeeded()
        } else {
            refresh(now: true)
            if needsIndex || pendingBuild { buildIndex() }
        }
    }

    /// 索引里还没有的条目
    private var missingIDs: [String] { allIDs.filter { raws[$0] == nil } }
    /// 索引里有、但 Eagle 改过的条目
    private var changedIDs: [String] {
        allIDs.filter { id in raws[id].map { LibraryIO.num($0["lastModified"]) != mtime[id] } ?? false }
    }

    /// 建立/续建索引：只读索引里还没有或已过期的条目的 metadata（几 KB 的 JSON，不读图片）
    func buildIndex() {
        guard indexState == .none, let url = root else { return }
        guard idsLoaded else { pendingBuild = true; return }   // 条目列表还没读完，读完再建
        pendingBuild = false
        indexState = .building
        let token = loadToken
        let ids = missingIDs + changedIDs
        Task {
            guard await readInBatches(ids, url: url, token: token, phase: "正在建立索引") else { return }
            indexState = .ready
            refresh(now: true)
            compactIfNeeded(force: true)
        }
    }

    /// 重新扫描：列一遍 images/ 目录，补上 mtime.json 漏记的、去掉已删除的（目录可能极大，只在用户要求时做）
    func rescan() {
        guard let url = root, idsLoaded, indexState != .building else { return }
        let token = loadToken
        indexState = .building
        progress = LoadProgress(phase: "正在列出文件…")
        Task {
            let ids = await Task.detached(priority: .utility) { LibraryIO.listItemIDs(root: url) }.value
            guard loadToken == token else { return }
            if let ids {
                let alive = Set(ids)
                remove(raws.keys.filter { !alive.contains($0) })
                allIDs = ids.sorted(by: >)
                guard await readInBatches(missingIDs + changedIDs, url: url, token: token, phase: "正在建立索引") else { return }
            }
            progress = nil
            indexState = .ready
            refresh(now: true)
            compactIfNeeded(force: true)   // 删除的条目要靠重写快照才能从索引里去掉
        }
    }

    private func readInBatches(_ ids: [String], url: URL, token: UUID, phase: String) async -> Bool {
        guard !ids.isEmpty else { return true }
        var done = 0
        while done < ids.count {
            progress = LoadProgress(phase: phase, done: done, total: ids.count)
            let chunk = Array(ids[done..<min(done + 400, ids.count)])
            let got = await Task.detached(priority: .utility) { LibraryIO.readRaws(root: url, ids: chunk) }.value
            guard loadToken == token else { return false }
            merge(got)
            unsaved += got
            flushIndex()   // 每攒够一批就写一个分段到库里，中途退出不丢进度
            refresh()
            done += chunk.count
        }
        flushIndex(force: true)
        progress = nil
        refresh(now: true)
        return true
    }

    // MARK: - 写索引（库内 .openview/index/，后台串行）

    private var unsaved: [[String: Any]] = []
    private var segments: [String] = []
    private var idsLoaded = false
    private var pendingBuild = false

    private func flushIndex(force: Bool = false) {
        guard let root, !unsaved.isEmpty, force || unsaved.count >= 2000 else { return }
        let batch = unsaved
        unsaved = []
        let token = loadToken
        writeQueue.async {
            guard let name = RemoteIndex.append(batch, to: root) else { return }
            DispatchQueue.main.async { if self.loadToken == token { self.segments.append(name) } }
        }
    }

    /// 分段太多时合并成一个快照（只在索引完整时做）
    private func compactIfNeeded(force: Bool = false) {
        guard let root, indexState == .ready, segments.count > (force ? 1 : RemoteIndex.compactThreshold) else { return }
        let snapshot = Array(raws.values), cutoff = RemoteIndex.cutoffNow()
        let token = loadToken
        writeQueue.async {   // 串行队列：之前排队的分段写入都已完成
            guard let name = RemoteIndex.compact(snapshot, takenAt: cutoff, in: root) else { return }
            let remaining = RemoteIndex.segmentNames(root)
            DispatchQueue.main.async {
                guard self.loadToken == token else { return }
                self.segments = remaining.isEmpty ? [name] : remaining
            }
        }
    }

    // MARK: - 按需读取单个条目（无索引时的「全部」视图）

    private var metaInflight = Set<String>()
    private var pendingMerge: [[String: Any]] = []
    private var mergeScheduled = false

    func requestMeta(_ id: String, urgent: Bool = true) {
        guard raws[id] == nil, !metaInflight.contains(id), let root else { return }
        metaInflight.insert(id)
        let token = loadToken
        Task {
            let r = await ImageLoader.shared.readMeta(root: root, id: id, urgent: urgent)
            guard token == loadToken else { return }
            metaInflight.remove(id)
            guard let r else { return }
            pendingMerge.append(r)
            if !mergeScheduled {   // 攒一小批再合并，避免每条都触发界面刷新
                mergeScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.mergeScheduled = false
                    self.merge(self.pendingMerge)
                    self.unsaved += self.pendingMerge
                    self.pendingMerge = []
                    self.flushIndex()
                    self.refresh()
                }
            }
        }
    }

    /// 增量合并，只解析新来的条目
    private func merge(_ list: [[String: Any]]) {
        guard let root, !list.isEmpty else { return }
        var arr = items
        for r in list {
            guard let id = r["id"] as? String,
                  let it = LibraryIO.parseItem(r, dir: LibraryIO.itemDir(root: root, id: id)) else { continue }
            raws[id] = r
            if let i = index[id] { arr[i] = it } else { index[id] = arr.count; arr.append(it) }
        }
        items = arr
    }

    private func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        for id in ids { raws.removeValue(forKey: id) }
        items.removeAll { set.contains($0.id) }
        index = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
    }

    // MARK: - 视图切换

    private func viewChanged() {
        ImageLoader.shared.cancelPending()   // 丢掉上一个视图排队中的读取
        viewGen += 1
        if needsIndex && indexState == .none { buildIndex() }
        refresh(now: true)
    }

    // MARK: - 派生数据（后台计算，节流）

    private var refreshScheduled = false
    private var refreshGen = 0

    /// now = 立即计算（用户操作）；否则最多每 0.5 秒一次（加载过程中）
    func refresh(now: Bool = false) {
        if now { computeDerived(); return }
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshScheduled = false
            self?.computeDerived()
        }
    }

    private func computeDerived() {
        refreshGen += 1
        let gen = refreshGen
        let items = self.items, index = self.index, sel = selection ?? .all
        let lazyIDs = indexState == .ready ? nil : allIDs
        let q = search.trimmingCharacters(in: .whitespaces)
        var sort: (String, Bool)?
        if case .folder(let id) = sel, let f = folderByID[id], let o = f.orderBy { sort = (o, f.sortIncrease) }
        Task {
            let d = await Task.detached(priority: .userInitiated) {
                Self.derive(items: items, index: index, lazyIDs: lazyIDs, sel: sel, query: q, sort: sort)
            }.value
            guard gen == self.refreshGen else { return }
            if self.visible != d.visible { self.visible = d.visible }
            self.counts = d.counts
            self.folderCounts = d.folderCounts
            if self.folderNewest != d.folderNewest { self.folderNewest = d.folderNewest }
            self.allTags = d.allTags
        }
    }

    nonisolated private static func matches(_ it: Item, _ sel: SidebarSel) -> Bool {
        switch sel {
        case .all: return !it.isDeleted
        case .uncategorized: return !it.isDeleted && it.folders.isEmpty
        case .trash: return it.isDeleted
        case .folder(let id): return !it.isDeleted && it.folders.contains(id)
        }
    }

    nonisolated private static func derive(items: [Item], index: [String: Int], lazyIDs: [String]?,
                                           sel: SidebarSel, query q: String, sort: (String, Bool)?) -> Derived {
        var counts: [SidebarSel: Int] = [:]
        var folderCounts: [String: Int] = [:]
        var newest: [String: Item] = [:]
        var tags = Set<String>()
        var list: [Item] = []
        for it in items where it.isSupportedImage {
            if it.isDeleted { counts[.trash, default: 0] += 1 } else {
                counts[.all, default: 0] += 1
                if it.folders.isEmpty { counts[.uncategorized, default: 0] += 1 }
                for f in it.folders {
                    folderCounts[f, default: 0] += 1
                    if newest[f].map({ it.modificationTime > $0.modificationTime }) ?? true { newest[f] = it }
                }
                tags.formUnion(it.tags)
            }
            if matches(it, sel) && (q.isEmpty || it.name.localizedCaseInsensitiveContains(q) ||
                                    it.tags.contains { $0.localizedCaseInsensitiveContains(q) }) {
                list.append(it)
            }
        }

        // 无索引：「全部」直接用 id 列表，没读到的先占位，读到后再过滤掉非图片/已删除
        if let lazyIDs {
            let vis: [String] = sel == .all && q.isEmpty
                ? lazyIDs.filter { id in index[id].map { items[$0].isSupportedImage && !items[$0].isDeleted } ?? true }
                : list.map(\.id)
            return Derived(visible: vis, folderNewest: newest.mapValues(\.id), counts: [.all: lazyIDs.count],
                           folderCounts: folderCounts, allTags: tags.sorted())
        }

        // 文件夹自带排序设置时遵循之，否则按加入时间倒序
        switch sort {
        case let (order, asc)?:
            switch order {
            case "NAME": list.sort { ($0.name.localizedStandardCompare($1.name) == .orderedAscending) == asc }
            case "BTIME": list.sort { asc ? $0.btime < $1.btime : $0.btime > $1.btime }
            default: list.sort { asc ? $0.modificationTime < $1.modificationTime : $0.modificationTime > $1.modificationTime }
            }
        case nil:
            list.sort { $0.modificationTime > $1.modificationTime }
        }
        return Derived(visible: list.map(\.id), folderNewest: newest.mapValues(\.id), counts: counts, folderCounts: folderCounts, allTags: tags.sorted())
    }

    private func rebuildFolderIndex() {
        folderPaths = []; folderByID = [:]; folderParent = [:]
        func walk(_ fs: [Folder], _ prefix: String, _ parent: String?) {
            for f in fs {
                let p = prefix.isEmpty ? f.name : "\(prefix) / \(f.name)"
                folderPaths.append((f.id, p)); folderByID[f.id] = f
                folderParent[f.id] = parent
                walk(f.children ?? [], p, f.id)
            }
        }
        walk(folders, "", nil)
    }

    // MARK: - 选择

    /// 网格里的多选；selectedItemID 是焦点（最后点的那张），信息栏和空格预览跟着它
    func setSelection(_ ids: Set<String>, focus: String?, folderCard: String? = nil) {
        if folderCard != selectedFolderCard { selectedFolderCard = folderCard }
        if ids != selectedIDs { selectedIDs = ids }
        let f = focus.flatMap { ids.contains($0) ? $0 : nil }
            ?? selectedItemID.flatMap { ids.contains($0) ? $0 : nil }
            ?? visible.first(where: ids.contains)
        if f != selectedItemID { selectedItemID = f }
        // 注意：这里不能因为选择为空就关预览——网格换选中时会先短暂清空再选中
    }

    /// 预览中切换：按当前视图的顺序上一张/下一张（与网格的行列无关），到头就停
    func stepPreview(_ delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let i = selectedItemID.flatMap { list.firstIndex(of: $0) } ?? 0
        let j = max(0, min(list.count - 1, i + delta))
        guard j != i || selectedItemID == nil else { return }
        let id = list[j]
        if item(id) == nil { requestMeta(id) }
        setSelection([id], focus: id)
    }

    /// 回到上一级文件夹（⌘↑）
    func goUp() {
        guard case .folder(let id) = selection else { return }
        if let p = folderParent[id] { selection = .folder(p) }
    }

    var selectedItems: [Item] { visible.filter(selectedIDs.contains).compactMap(item) }

    // MARK: - 编辑条目（写回 metadata.json，在后台队列执行）

    func update(_ id: String, _ change: (inout Item) -> Void) { update([id], change) }

    /// 批量修改条目：先乐观更新界面，再在后台逐个重读完整 metadata.json、只改自己管的字段后原子写回；
    /// 全部写完后只写一次 mtime.json。改名只对单个条目生效（要同时重命名文件）。
    func update(_ ids: [String], _ change: (inout Item) -> Void) {
        guard let root else { return }
        struct Job { let id: String; let old: Item; let new: Item; let oldRaw: [String: Any]?
                     let deletedTime: Any?; let rename: (from: URL, to: URL, thumbFrom: URL?, thumbTo: URL?)? }
        let now = LibraryIO.nowMs()
        var jobs: [Job] = []
        for id in ids {
            guard let i = index[id] else { continue }
            let old = items[i]
            var it = old
            change(&it)
            guard it != old else { continue }
            var rename: (from: URL, to: URL, thumbFrom: URL?, thumbTo: URL?)?
            if it.name != old.name {
                guard ids.count == 1, !it.name.isEmpty, !it.name.contains("/") else { it.name = old.name; continue }
                let newMain = it.dir.appending(noStat: "\(it.name).\(it.ext)")
                let newThumb = old.thumbURL.map { _ in it.dir.appending(noStat: "\(it.name)_thumbnail.png") }
                rename = (old.fileURL, newMain, old.thumbURL, newThumb)
                it.fileURL = newMain
                it.thumbURL = newThumb
            }
            var raw = raws[id] ?? [:]
            raw["name"] = it.name; raw["tags"] = it.tags; raw["folders"] = it.folders
            raw["url"] = it.url; raw["annotation"] = it.annotation; raw["isDeleted"] = it.isDeleted
            if it.isDeleted != old.isDeleted {
                if it.isDeleted { raw["deletedTime"] = now } else { raw.removeValue(forKey: "deletedTime") }
            }
            raw["lastModified"] = now
            jobs.append(Job(id: id, old: old, new: it, oldRaw: raws[id], deletedTime: raw["deletedTime"], rename: rename))
            raws[id] = LibraryIO.compact(raw)
            items[i] = it
            mtime[id] = now
        }
        guard !jobs.isEmpty else { return }
        refresh(now: true)

        let mtimeSnapshot = mtime
        let count = max(mtime.count, items.count)
        writeQueue.async {
            var failed: [Job] = []
            var firstError: Error?
            for j in jobs {
                let metaURL = j.new.dir.appending(noStat: "metadata.json")
                do {
                    if let r = j.rename {
                        if FileManager.default.fileExists(atPath: r.to.path) { throw CocoaError(.fileWriteFileExists) }
                        try FileManager.default.moveItem(at: r.from, to: r.to)
                        if let tf = r.thumbFrom, let tt = r.thumbTo { try? FileManager.default.moveItem(at: tf, to: tt) }
                    }
                    var full = LibraryIO.readJSON(metaURL) as? [String: Any] ?? j.oldRaw ?? [:]
                    full["name"] = j.new.name; full["tags"] = j.new.tags; full["folders"] = j.new.folders
                    full["url"] = j.new.url; full["annotation"] = j.new.annotation; full["isDeleted"] = j.new.isDeleted
                    if let d = j.deletedTime { full["deletedTime"] = d } else { full.removeValue(forKey: "deletedTime") }
                    full["lastModified"] = now
                    try LibraryIO.writeJSON(full, to: metaURL)
                } catch {
                    failed.append(j); firstError = firstError ?? error
                }
            }
            if !mtimeSnapshot.isEmpty {
                var m: [String: Any] = mtimeSnapshot
                m["all"] = count
                try? LibraryIO.writeJSON(m, to: root.appending(noStat: "mtime.json"))
            }
            DispatchQueue.main.async {
                for j in failed {   // 写盘失败的回滚
                    guard let k = self.index[j.id] else { continue }
                    self.items[k] = j.old
                    self.raws[j.id] = j.oldRaw
                }
                if let firstError {
                    self.refresh(now: true)
                    self.errorMessage = "有 \(failed.count) 项保存失败：\(firstError.localizedDescription)"
                }
                // 改过的条目也写进索引，下次打开不必重读
                let ok = Set(jobs.map(\.id)).subtracting(failed.map(\.id))
                self.unsaved.append(contentsOf: ok.compactMap { self.raws[$0] })
                self.flushIndex()
            }
        }
    }

    func trash(_ ids: [String]) {
        update(ids) { $0.isDeleted = true }
        setSelection([], focus: nil)
    }

    func restore(_ ids: [String]) {
        update(ids) { $0.isDeleted = false }
        setSelection([], focus: nil)
    }

    /// 放进文件夹。from 不为空时是「移动」：同时从 from 文件夹移出
    func addToFolder(_ ids: [String], _ folderID: String, movingFrom from: String? = nil) {
        update(ids) { it in
            if let from, from != folderID { it.folders.removeAll { $0 == from } }
            if !it.folders.contains(folderID) { it.folders.append(folderID) }
        }
    }

    func removeFromFolder(_ ids: [String], _ folderID: String) {
        update(ids) { $0.folders.removeAll { $0 == folderID } }
    }

    /// 移出所有文件夹（拖到「未分类」）
    func clearFolders(_ ids: [String]) {
        update(ids) { $0.folders = [] }
    }

    func addTags(_ ids: [String], _ tags: [String]) {
        update(ids) { it in for t in tags where !it.tags.contains(t) { it.tags.append(t) } }
    }

    // MARK: - 编辑文件夹树（库级 metadata.json）

    func setFolderColor(_ id: String, _ color: String?) {
        editFolders { tree in
            tree.modify(id) { $0.iconColor = color }
        } json: { tree in
            tree.modify(id) { f in if let color { f["iconColor"] = color } else { f.removeValue(forKey: "iconColor") } }
        }
    }

    func setFolder(_ id: String, name: String? = nil, description: String? = nil, tags: [String]? = nil) {
        if let name, name.trimmingCharacters(in: .whitespaces).isEmpty { return }
        editFolders { tree in
            tree.modify(id) { f in
                if let name { f.name = name }
                if let description { f.description = description }
                if let tags { f.tags = tags }
            }
        } json: { tree in
            tree.modify(id) { f in
                if let name { f["name"] = name }
                if let description { f["description"] = description }
                if let tags { f["tags"] = tags }
            }
        }
    }

    /// 新建文件夹，返回新 id（parent 为 nil 时放在顶层末尾）
    @discardableResult
    func createFolder(in parent: String?, name: String = "新建文件夹") -> String? {
        let id = LibraryIO.newID()
        let now = LibraryIO.nowMs()
        let folder = Folder(id: id, name: name, children: nil, hasPassword: false, coverId: nil,
                            orderBy: nil, sortIncrease: true)
        let dict: [String: Any] = ["id": id, "name": name, "description": "", "children": [],
                                   "modificationTime": now, "tags": [], "password": "", "passwordTips": ""]
        let ok = editFolders { tree in
            tree.insert(folder, under: parent, at: nil)
        } json: { tree in
            tree.insert(dict, under: parent, at: nil)
        }
        return ok ? id : nil
    }

    /// 移动文件夹：parent 为 nil 表示顶层；index 为 nil 表示放到末尾。不能移进自己或自己的子文件夹
    func moveFolder(_ id: String, to parent: String?, at index: Int?) {
        if let parent, parent == id || isDescendant(parent, of: id) { return }
        editFolders { tree in
            guard let node = tree.remove(id) else { return }
            tree.insert(node, under: parent, at: index)
        } json: { tree in
            guard let node = tree.remove(id) else { return }
            tree.insert(node, under: parent, at: index)
        }
    }

    func isDescendant(_ id: String, of ancestor: String) -> Bool {
        var cur = folderParent[id]
        while let c = cur { if c == ancestor { return true }; cur = folderParent[c] }
        return false
    }

    /// 删除文件夹需要知道哪些图片在里面，所以要求索引完整
    var canDeleteFolders: Bool { indexState == .ready }

    /// 删除文件夹（含子文件夹）：图片不删除，只把它们从这些文件夹里移出
    func deleteFolder(_ id: String) {
        guard canDeleteFolders, let f = folderByID[id] else { return }
        var gone: Set<String> = []
        func collect(_ f: Folder) { gone.insert(f.id); f.children?.forEach(collect) }
        collect(f)
        let affected = items.filter { !Set($0.folders).isDisjoint(with: gone) }.map(\.id)
        update(affected) { $0.folders.removeAll(where: gone.contains) }
        if case .folder(let sel) = selection, gone.contains(sel) { selection = folderParent[id].map { .folder($0) } ?? .all }
        editFolders { tree in _ = tree.remove(id) } json: { tree in _ = tree.remove(id) }
    }

    /// 修改文件夹树：先改内存，再在后台重新读取完整的库级 metadata.json，用同样的修改作用到 JSON 上
    /// （保留所有不认识的字段），原子写回。
    @discardableResult
    private func editFolders(_ memory: (inout [Folder]) -> Void,
                             json: @escaping (inout [[String: Any]]) -> Void) -> Bool {
        guard let root else { return false }
        var tree = folders
        memory(&tree)
        guard tree != folders else { return false }
        folders = tree
        rebuildFolderIndex()
        refresh(now: true)
        let url = root.appending(noStat: "metadata.json")
        writeQueue.async { [weak self] in
            do {
                guard var d = LibraryIO.readJSON(url) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
                var arr = d["folders"] as? [[String: Any]] ?? []
                json(&arr)
                d["folders"] = arr
                d["modificationTime"] = LibraryIO.nowMs()
                try LibraryIO.writeJSON(d, to: url)
            } catch {
                DispatchQueue.main.async { self?.errorMessage = "保存文件夹失败：\(error.localizedDescription)" }
            }
        }
        return true
    }
}

// MARK: - 文件夹树操作（内存里的 Folder 和 JSON 字典用同一套逻辑）

protocol FolderNode {
    var nodeID: String? { get }
    var nodeChildren: [Self] { get set }
}

extension Folder: FolderNode {
    var nodeID: String? { id }
    var nodeChildren: [Folder] {
        get { children ?? [] }
        set { children = newValue.isEmpty ? nil : newValue }
    }
}

extension Dictionary: FolderNode where Key == String, Value == Any {
    var nodeID: String? { self["id"] as? String }
    var nodeChildren: [[String: Any]] {
        get { self["children"] as? [[String: Any]] ?? [] }
        set { self["children"] = newValue }
    }
}

extension Array where Element: FolderNode {
    /// 修改指定节点；找到返回 true
    @discardableResult
    mutating func modify(_ id: String, _ change: (inout Element) -> Void) -> Bool {
        for i in indices {
            if self[i].nodeID == id {
                change(&self[i])
                if var d = self[i] as? [String: Any] {   // JSON：记录修改时间
                    d["modificationTime"] = LibraryIO.nowMs()
                    self[i] = d as! Element
                }
                return true
            }
            if self[i].nodeChildren.modify(id, change) { return true }
        }
        return false
    }

    /// 摘下指定节点（连同子树）
    mutating func remove(_ id: String) -> Element? {
        for i in indices {
            if self[i].nodeID == id { return self.remove(at: i) }
            if let n = self[i].nodeChildren.remove(id) { return n }
        }
        return nil
    }

    /// 插入到 parent 下（nil = 顶层）的 index 位置（nil 或越界 = 末尾）
    mutating func insert(_ node: Element, under parent: String?, at index: Int?) {
        guard let parent else {
            insert(node, at: Swift.min(index ?? count, count)); return
        }
        for i in indices {
            if self[i].nodeID == parent {
                var kids = self[i].nodeChildren
                kids.insert(node, at: Swift.min(index ?? kids.count, kids.count))
                self[i].nodeChildren = kids
                return
            }
            self[i].nodeChildren.insert(node, under: parent, at: index)
        }
    }
}
