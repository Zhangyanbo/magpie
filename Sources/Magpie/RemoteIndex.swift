import Foundation

/// Magpie 自己的索引，放在库里（可以在 NAS 上）：<库>/.magpie/index/*.json
///
/// - 分段追加：每读完一批条目就写一个新分段，从不原地修改大文件，中途退出不丢进度。
/// - 文件名以毫秒时间戳开头，按文件名排序合并，后写的覆盖先写的；多台电脑各写各的分段，不需要锁。
/// - 不记录「完成」标记：是否完整 = mtime.json 里的每个 id 都在索引里。
/// - 分段过多时合并成一个快照分段，再删掉被合并的旧分段。
/// - 索引只是加速用；Eagle 的 metadata.json 才是权威数据。
enum RemoteIndex {
    static let version = 1
    static let compactThreshold = 20

    static func dir(_ root: URL) -> URL { root.appending(noStat: ".magpie/index") }

    /// 本软件旧名 OpenView，旧索引在 .openview/index/。不改名搬家（在 SMB 上改名目录可能失败），
    /// 而是两个目录一起读；下次合并快照时写进新目录，旧分段删掉
    static func legacyDir(_ root: URL) -> URL { root.appending(noStat: ".openview/index") }

    /// 两个目录里的全部分段，按文件名（时间戳）排序
    static func segments(_ root: URL) -> [URL] {
        [legacyDir(root), dir(root)].flatMap { d in
            ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [])
                .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
                .map { d.appending(noStat: $0) }
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func segmentNames(_ root: URL) -> [String] { segments(root).map(\.lastPathComponent) }

    static func hasLegacy(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: legacyDir(root).path)
    }

    /// 读全部分段并按顺序合并，返回 (条目, 分段文件名)
    static func load(_ root: URL) -> (items: [[String: Any]], segments: [String]) {
        let urls = segments(root)
        var parts = [[[String: Any]]](repeating: [], count: urls.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            guard let d = LibraryIO.readJSON(urls[i]) as? [String: Any],
                  d["version"] as? Int == version else { return }
            let items = d["items"] as? [[String: Any]] ?? []
            lock.lock(); parts[i] = items; lock.unlock()
        }
        var merged: [String: [String: Any]] = [:]
        for part in parts { for r in part { if let id = r["id"] as? String { merged[id] = r } } }
        return (Array(merged.values), urls.map(\.lastPathComponent))
    }

    private static func newName() -> String {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        return String(format: "%013lld-%@.json", ms, UUID().uuidString.prefix(8).lowercased())
    }

    /// 追加一个分段（原子写），返回文件名
    @discardableResult
    static func append(_ items: [[String: Any]], to root: URL) -> String? {
        guard !items.isEmpty else { return nil }
        let d = dir(root)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let name = newName()
        do {
            try LibraryIO.writeJSON(["version": version, "items": items], to: d.appending(noStat: name))
            return name
        } catch {
            return nil
        }
    }

    /// 把全部条目写成一个快照分段，成功后删掉快照生成之前写的所有分段。
    /// 按文件名里的时间戳判断，而不是按内存里登记的列表，避免刚写完还没登记的分段漏删。
    @discardableResult
    static func compact(_ items: [[String: Any]], takenAt cutoff: String, in root: URL) -> String? {
        guard let name = append(items, to: root) else { return nil }
        let fm = FileManager.default
        for u in segments(root) where u.lastPathComponent != name && u.lastPathComponent < cutoff {
            try? fm.removeItem(at: u)
        }
        // 旧目录的分段都已并入快照：整个 .openview/ 删掉（只在里面没有别的分段时）
        if (try? fm.contentsOfDirectory(atPath: legacyDir(root).path))?.contains(where: { $0.hasSuffix(".json") }) != true {
            try? fm.removeItem(at: legacyDir(root).deletingLastPathComponent())
        }
        return name
    }

    /// 当前时刻对应的分段名前缀，用作合并的分界
    static func cutoffNow() -> String {
        String(format: "%013lld", Int64(Date().timeIntervalSince1970 * 1000))
    }
}
