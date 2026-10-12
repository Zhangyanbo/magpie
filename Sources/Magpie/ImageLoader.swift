import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 本机缓存目录：~/Library/Caches/Magpie/<库路径哈希>/
/// - thumbs/：缩略图（480px，单张几十 KB），总量超过上限时按最久未用删除
enum LocalCache {
    static let thumbLimitBytes: Int64 = 2 << 30          // 2 GB
    static let thumbTrimTarget: Int64 = 3 << 29          // 删到 1.5 GB

    static func dir(for root: URL) -> URL {
        let hash = Insecure.MD5.hash(data: Data(root.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(noStat: "Magpie/\(hash)")
        try? FileManager.default.createDirectory(at: base.appending(noStat: "thumbs"),
                                                 withIntermediateDirectories: true)
        return base
    }

    /// 缩略图缓存超过上限时，按最近访问时间删掉旧的
    static func trimThumbs(_ dir: URL) {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentAccessDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(v.totalFileAllocatedSize ?? 0), v.contentAccessDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > thumbLimitBytes else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > thumbTrimTarget {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}

/// 限制同时访问 NAS 的读取数。等待队列从尾部出队：
/// 正在看的（urgent）压到尾部优先处理，预取的插到头部垫底。
/// 视图切换时 cancelAll() 丢弃所有排队中的请求；格子滚出屏幕时 cancel(key) 丢弃它的请求。
actor IOGate {
    static let shared = IOGate(limit: 6)
    private let limit: Int
    private var running = 0
    private var waiters: [(key: String, cont: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) { self.limit = limit }

    /// 返回 false 表示请求在排队时被取消了
    func acquire(_ key: String, urgent: Bool) async -> Bool {
        if running < limit { running += 1; return true }
        return await withCheckedContinuation { c in
            if urgent { waiters.append((key, c)) } else { waiters.insert((key, c), at: 0) }
        }
    }

    func release() {
        if let w = waiters.popLast() { w.cont.resume(returning: true) } else { running -= 1 }
    }

    func promote(_ key: String) {
        if let i = waiters.firstIndex(where: { $0.key == key }) { waiters.append(waiters.remove(at: i)) }
    }

    func cancel(_ key: String) {
        if let i = waiters.firstIndex(where: { $0.key == key }) { waiters.remove(at: i).cont.resume(returning: false) }
    }

    func cancelAll() {
        let ws = waiters
        waiters = []
        for w in ws { w.cont.resume(returning: false) }
    }
}

@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    /// 内存缓存按解码后的字节数限制，不按张数
    private let thumbs: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>(); c.totalCostLimit = 128 << 20; return c
    }()
    private let larges: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>(); c.totalCostLimit = 160 << 20; return c
    }()
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private var thumbDir: URL?

    nonisolated static let thumbPixels = 480
    nonisolated static let largePixels = 2800

    func configure(cacheDir: URL) {
        let dir = cacheDir.appending(noStat: "thumbs")
        thumbDir = dir
        thumbs.removeAllObjects(); larges.removeAllObjects()
        DispatchQueue.global(qos: .background).async { LocalCache.trimThumbs(dir) }
    }

    /// 视图切换：丢掉所有还没开始的读取（已经在读的让它读完，结果照样进缓存）
    func cancelPending() {
        Task { await IOGate.shared.cancelAll() }
    }

    func cancel(thumbnailOf item: Item) {
        let key = "T:\(item.id)"
        Task { await IOGate.shared.cancel(key) }
    }

    func cachedThumbnail(_ item: Item) -> NSImage? { thumbs.object(forKey: item.id as NSString) }
    func cachedLarge(_ item: Item) -> NSImage? { larges.object(forKey: item.id as NSString) }

    private static func cost(_ img: NSImage) -> Int { Int(img.size.width * img.size.height * 4) }

    /// 读单个条目的 metadata.json（无索引时按需读取用），同样走 IOGate
    func readMeta(root: URL, id: String, urgent: Bool) async -> [String: Any]? {
        let key = "M:\(id)"
        let url = LibraryIO.itemDir(root: root, id: id).appending(noStat: "metadata.json")
        return await Task.detached(priority: urgent ? .userInitiated : .utility) { () -> [String: Any]? in
            guard await IOGate.shared.acquire(key, urgent: urgent) else { return nil }
            let d = LibraryIO.readJSON(url) as? [String: Any]
            await IOGate.shared.release()
            return d.map(LibraryIO.compact)
        }.value
    }

    /// 网格缩略图：内存 → 本机磁盘缓存 → NAS（库里的 _thumbnail.png，再不行原图）
    func thumbnail(_ item: Item, urgent: Bool = true) async -> NSImage? {
        if let img = cachedThumbnail(item) { return img }
        let key = "T:\(item.id)"
        if let t = inflight[key] {
            if urgent { await IOGate.shared.promote(key) }
            return await t.value
        }
        let local = thumbDir?.appending(noStat: "\(item.id)-\(item.size).img")
        let thumbURL = item.thumbURL, fileURL = item.fileURL, dir = item.dir
        let task = Task.detached(priority: urgent ? .userInitiated : .utility) { () -> NSImage? in
            if let local, let img = Self.downsample(local, Self.thumbPixels) { return img }
            guard await IOGate.shared.acquire(key, urgent: urgent) else { return nil }
            var cg = thumbURL.flatMap { Self.downsampleCG($0, Self.thumbPixels) } ?? Self.downsampleCG(fileURL, Self.thumbPixels)
            if cg == nil {   // 文件名与 name 不一致时才列目录
                let r = LibraryIO.resolveFiles(dir: dir)
                cg = (r.thumb ?? r.main).flatMap { Self.downsampleCG($0, Self.thumbPixels) }
            }
            await IOGate.shared.release()
            guard let cg else { return nil }
            if let local { Self.write(cg, to: local) }
            return Self.image(cg)
        }
        inflight[key] = task
        let img = await task.value
        inflight[key] = nil
        if let img { thumbs.setObject(img, forKey: item.id as NSString, cost: Self.cost(img)) }
        return img
    }

    /// 空格预览用的大图（降采样到 2800px，只放内存，有字节上限）
    func large(_ item: Item, urgent: Bool = true) async -> NSImage? {
        if let img = cachedLarge(item) { return img }
        let key = "L:\(item.id)"
        if let t = inflight[key] {
            if urgent { await IOGate.shared.promote(key) }
            return await t.value
        }
        let fileURL = item.fileURL, dir = item.dir
        let task = Task.detached(priority: urgent ? .userInitiated : .utility) { () -> NSImage? in
            guard await IOGate.shared.acquire(key, urgent: urgent) else { return nil }
            let img = Self.downsample(fileURL, Self.largePixels)
                ?? LibraryIO.resolveFiles(dir: dir).main.flatMap { Self.downsample($0, Self.largePixels) }
            await IOGate.shared.release()
            return img
        }
        inflight[key] = task
        let img = await task.value
        inflight[key] = nil
        if let img { larges.setObject(img, forKey: item.id as NSString, cost: Self.cost(img)) }
        return img
    }

    func prefetchThumbnails(_ items: some Sequence<Item>) {
        for it in items where cachedThumbnail(it) == nil && inflight["T:\(it.id)"] == nil {
            Task { _ = await thumbnail(it, urgent: false) }
        }
    }

    func prefetchLarge(_ items: some Sequence<Item>) {
        for it in items where cachedLarge(it) == nil && inflight["L:\(it.id)"] == nil {
            Task { _ = await large(it, urgent: false) }
        }
    }

    // MARK: - ImageIO

    nonisolated static func downsampleCG(_ url: URL, _ maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,   // 在后台线程就解码好，不留到界面绘制时
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    nonisolated static func downsample(_ url: URL, _ maxPixel: Int) -> NSImage? {
        downsampleCG(url, maxPixel).map(image)
    }

    /// 解码成界面能直接使用的 8 位 sRGB BGRA 位图再放进缓存。
    /// 否则遇到灰度、16 位、CMYK 等格式时，界面层会再复制一份转换后的位图（内存翻倍，且不受缓存上限控制）。
    nonisolated static func image(_ cg: CGImage) -> NSImage {
        let n = normalized(cg)
        return NSImage(cgImage: n, size: NSSize(width: n.width, height: n.height))
    }

    nonisolated static func normalized(_ cg: CGImage) -> CGImage {
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        if cg.bitsPerComponent == 8, cg.bitsPerPixel == 32, cg.bitmapInfo.rawValue == info,
           cg.colorSpace?.name == CGColorSpace.sRGB { return cg }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: info) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage() ?? cg
    }

    /// 写本机缩略图缓存：有透明通道用 PNG，否则 JPEG
    nonisolated static func write(_ cg: CGImage, to url: URL) {
        let alpha = ![.none, .noneSkipLast, .noneSkipFirst].contains(cg.alphaInfo)
        let type = (alpha ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}

struct ThumbnailView: View {
    @EnvironmentObject var store: LibraryStore
    let item: Item
    var fill = false          // true：铺满并裁切（网格卡片）
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image = image ?? ImageLoader.shared.cachedThumbnail(item) {
                if fill {
                    // 铺满时图片会超出边框；clipped 只裁显示不裁点击区域，必须关掉图片的点击，否则会挡住下面的控件
                    Color.clear.overlay(Image(nsImage: image).resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fill).allowsHitTesting(false))
                        .clipped().contentShape(Rectangle())
                } else {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                }
            } else {
                Image(systemName: "photo").font(.title2).foregroundStyle(.quaternary)
            }
        }
        // 视图切换（viewGen 变化）后重新发起；滚出屏幕时取消排队中的请求
        .task(id: "\(item.fileURL.path)#\(store.viewGen)") {
            let it = item
            image = await withTaskCancellationHandler {
                await ImageLoader.shared.thumbnail(it)
            } onCancel: {
                Task { @MainActor in ImageLoader.shared.cancel(thumbnailOf: it) }
            }
        }
    }
}
