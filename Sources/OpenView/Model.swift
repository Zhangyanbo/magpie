import Foundation

/// 库级 metadata.json 中的文件夹（通过 children 嵌套）
struct Folder: Identifiable, Hashable {
    let id: String
    var name: String
    var children: [Folder]?   // nil = 叶子，供 OutlineGroup 使用
    var hasPassword: Bool
    var coverId: String?      // Eagle 里手动设置的封面条目
    var description = ""
    var tags: [String] = []
    var iconColor: String?    // Eagle 的文件夹颜色：red/orange/yellow/green/aqua/blue/purple/pink，nil = 默认
    var orderBy: String?
    var sortIncrease: Bool
}

/// images/<id>.info/metadata.json 中的素材
struct Item: Identifiable, Hashable {
    let id: String
    var name: String
    var ext: String
    var tags: [String]
    var folders: [String]
    var isDeleted: Bool
    var url: String
    var annotation: String
    var width: Int
    var height: Int
    var size: Int
    var btime: Double
    var modificationTime: Double
    var palette: [[Int]]
    var dir: URL
    var fileURL: URL
    var thumbURL: URL?

    var isSupportedImage: Bool { Self.imageExts.contains(ext.lowercased()) }
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "bmp", "gif", "webp", "heic", "tif", "tiff"]
}

enum SidebarSel: Hashable {
    case all, uncategorized, trash
    case folder(String)
}

enum LibraryIO {
    /// Eagle 风格的 13 位 id：毫秒时间戳 base36（大写）+ 随机补足
    static func newID() -> String {
        let t = String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36).uppercased()
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return t + String((0..<max(0, 13 - t.count)).map { _ in chars.randomElement()! })
    }

    static func nowMs() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    static func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? Double(v as? String ?? "") ?? 0 }

    static func readJSON(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func writeJSON(_ obj: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    static func parseFolders(_ arr: [[String: Any]]) -> [Folder] {
        arr.map { d in
            let kids = parseFolders(d["children"] as? [[String: Any]] ?? [])
            return Folder(id: d["id"] as? String ?? UUID().uuidString,
                          name: d["name"] as? String ?? "",
                          children: kids.isEmpty ? nil : kids,
                          hasPassword: !((d["password"] as? String) ?? "").isEmpty,
                          coverId: (d["coverId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                          description: d["description"] as? String ?? "",
                          tags: d["tags"] as? [String] ?? [],
                          iconColor: (d["iconColor"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                          orderBy: d["orderBy"] as? String,
                          sortIncrease: d["sortIncrease"] as? Bool ?? true)
        }
    }

    static func parseItem(_ d: [String: Any], dir: URL) -> Item? {
        guard let id = d["id"] as? String else { return nil }
        let name = d["name"] as? String ?? ""
        let ext = d["ext"] as? String ?? ""
        // 不列目录（SMB 上很慢），直接按 name.ext 推算；读失败时再用 resolveFiles 兜底
        let noThumb = d["noThumbnail"] as? Bool ?? false
        return Item(id: id, name: name, ext: ext,
                    tags: d["tags"] as? [String] ?? [],
                    folders: d["folders"] as? [String] ?? [],
                    isDeleted: d["isDeleted"] as? Bool ?? false,
                    url: d["url"] as? String ?? "",
                    annotation: d["annotation"] as? String ?? "",
                    width: Int(num(d["width"])), height: Int(num(d["height"])),
                    size: Int(num(d["size"])),
                    btime: num(d["btime"]), modificationTime: num(d["modificationTime"]),
                    palette: (d["palettes"] as? [[String: Any]] ?? []).compactMap { $0["color"] as? [Int] },
                    dir: dir,
                    fileURL: dir.appending(noStat: "\(name).\(ext)"),
                    thumbURL: noThumb ? nil : dir.appending(noStat: "\(name)_thumbnail.png"))
    }

    /// 实际列目录找原文件和缩略图（只在推算的路径读不到时使用）
    static func resolveFiles(dir: URL) -> (main: URL?, thumb: URL?) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let thumb = files.first { $0.hasSuffix("_thumbnail.png") }
        let main = files.first { $0 != "metadata.json" && !$0.hasSuffix("_thumbnail.png") && !$0.hasPrefix(".") }
        return (main.map { dir.appending(noStat: $0) }, thumb.map { dir.appending(noStat: $0) })
    }

    static func itemDir(root: URL, id: String) -> URL {
        root.appending(noStat: "images/\(id).info")
    }

    /// 索引里只存界面用得到的字段（去掉 ocr/detection、palettes 的 $$hashKey 等），文件小、读得快。
    /// 写回条目时会重新读完整的 metadata.json，所以不会丢失 Eagle 的其他字段。
    static let indexKeys: Set<String> = ["id", "name", "ext", "tags", "folders", "isDeleted", "url", "annotation",
                                         "width", "height", "size", "btime", "mtime", "modificationTime",
                                         "lastModified", "noThumbnail", "star", "deletedTime"]

    static func compact(_ d: [String: Any]) -> [String: Any] {
        var out = d.filter { indexKeys.contains($0.key) }
        if let p = d["palettes"] as? [[String: Any]] {
            out["palettes"] = p.prefix(8).map { ["color": $0["color"] ?? [], "ratio": $0["ratio"] ?? 0] }
        }
        return out
    }

    /// mtime.json：id → lastModified。单个文件，比列目录快得多
    static func readMtime(root: URL) -> [String: Double] {
        var m: [String: Double] = [:]
        for (k, v) in readJSON(root.appending(noStat: "mtime.json")) as? [String: Any] ?? [:] where k != "all" {
            m[k] = num(v)
        }
        return m
    }

    /// 列出 images/ 下的全部条目 id（目录可能极大，SMB 上很慢，只在后台校验时用）
    static func listItemIDs(root: URL) -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.appending(noStat: "images").path)
        else { return nil }
        return names.filter { $0.hasSuffix(".info") }.map { String($0.dropLast(5)) }
    }

    /// 并行读取一批条目的 metadata.json。SMB 延迟高，并发数大于 CPU 核数
    static func readRaws(root: URL, ids: [String]) -> [[String: Any]] {
        var out = [[String: Any]?](repeating: nil, count: ids.count)
        let lock = NSLock()
        let group = DispatchGroup()
        let sem = DispatchSemaphore(value: 24)
        let queue = DispatchQueue(label: "openview.read", qos: .userInitiated, attributes: .concurrent)
        for (i, id) in ids.enumerated() {
            sem.wait()
            group.enter()
            queue.async {
                defer { sem.signal(); group.leave() }
                let url = itemDir(root: root, id: id).appending(noStat: "metadata.json")
                guard let d = readJSON(url) as? [String: Any], d["id"] is String else { return }
                let c = compact(d)
                lock.lock(); out[i] = c; lock.unlock()
            }
        }
        group.wait()
        return out.compactMap { $0 }
    }
}

extension URL {
    /// 拼路径时不访问文件系统。
    /// `appendingPathComponent(_:)` 不带目录参数时会对结果 lstat 一次以判断是否为目录，
    /// 在 SMB 上每次都是一次网络往返：五万个条目 × 3 个路径曾让读取索引卡十几秒。
    func appending(noStat component: String) -> URL {
        appending(path: component, directoryHint: .inferFromPath)
    }
}
