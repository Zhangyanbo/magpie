import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("thumbSize") private var thumbSize: Double = 190

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            ZStack {
                GridView(thumbSize: $thumbSize)
                if store.preview, let item = store.selectedItem {
                    QuickPreview(item: item).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: store.preview)
            .toolbar {
                ToolbarItem {
                    Button { showInspector.toggle() } label: {
                        Label("信息", systemImage: "sidebar.right")
                    }
                    .help("显示/隐藏信息栏")
                }
            }
            .inspector(isPresented: $showInspector) {
                InspectorView().inspectorColumnWidth(min: 270, ideal: 320, max: 440)
            }
        }
        .navigationTitle("")
        .toolbarBackground(.hidden, for: .windowToolbar)
    }
}

// MARK: - 左侧

struct SidebarView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var folderSearch = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Circle().strokeBorder(.primary.opacity(0.7), lineWidth: 1.5))
                    Text(store.libraryName).font(.title3.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button { _ = store.createFolder(in: nil) } label: { Image(systemName: "folder.badge.plus") }
                        .buttonStyle(.borderless)
                        .help("新建文件夹")
                }
                FieldBox(icon: "magnifyingglass") {
                    TextField("搜索文件夹…", text: $folderSearch).textFieldStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 8)

            SidebarOutline(filter: folderSearch)

            if let p = store.progress {
                LoadingProgress(progress: p, compact: true)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                    .padding(10)
            }
        }
    }
}

/// 文件夹颜色：与 Eagle 的 iconColor 取值一致，用户在右键菜单里手动设置；没设置时用默认样式
enum FolderTint {
    static let options: [(key: String, name: String, color: Color)] = [
        ("red", "红色", .red), ("orange", "橙色", .orange), ("yellow", "黄色", .yellow),
        ("green", "绿色", .green), ("aqua", "青色", .cyan), ("blue", "蓝色", .blue),
        ("purple", "紫色", .purple), ("pink", "粉色", .pink),
    ]
    static func color(_ key: String?) -> Color {
        options.first { $0.key == key }?.color ?? .secondary
    }
}

/// 圆角浅灰底的输入框容器
struct FieldBox<Content: View>: View {
    let icon: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            content
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - 中间

struct GridView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.openWindow) private var openWindow
    @Binding var thumbSize: Double
    @FocusState private var searchFocused: Bool

    var body: some View {
        let ids = store.visible
        let subs = store.currentSubfolders
        VStack(spacing: 0) {
            header(count: ids.count)
            CollectionGrid(ids: ids, subs: subs, thumbSize: thumbSize, open: open)
                .overlay {
                    if ids.isEmpty && subs.isEmpty, let p = store.progress {
                        LoadingProgress(progress: p).frame(width: 320)
                    } else if ids.isEmpty && subs.isEmpty {
                        ContentUnavailableView(store.search.isEmpty ? "没有图片" : "无搜索结果",
                                               systemImage: "photo.on.rectangle")
                    }
                }
        }
        .background(.background)
        .onChange(of: store.selectedItemID) { _, _ in prefetchAround(ids) }
        .onChange(of: store.preview) { _, _ in prefetchAround(ids) }
        .onChange(of: store.focusSearchRequest) { _, _ in searchFocused = true }
    }

    /// 顶部：搜索框 + 缩略图大小，下面是标题（路径）和数量
    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                FieldBox(icon: "magnifyingglass") {
                    TextField("搜索名称或标签…", text: $store.search)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { store.focusGridRequest += 1 }
                        .onExitCommand { store.search = ""; store.focusGridRequest += 1 }
                        .onKeyPress(.downArrow) { store.focusGridRequest += 1; return .handled }
                    if !store.search.isEmpty {
                        Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                    } else {
                        Text("⌘F").font(.caption).foregroundStyle(.tertiary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
                    }
                }
                .frame(maxWidth: 520)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.3x3").imageScale(.small).foregroundStyle(.secondary)
                    Slider(value: $thumbSize, in: 120...340).frame(width: 110).controlSize(.small)
                    Image(systemName: "square.grid.2x2").imageScale(.small).foregroundStyle(.secondary)
                }
                .help("缩略图大小")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                let path = store.currentPath
                if path.count > 1 {
                    PathBar(path: path)
                } else {
                    Text(viewTitle).font(.title3.weight(.semibold))
                }
                Text(count > 0 || store.progress == nil ? "\(count.formatted()) 项" : "正在载入…")
                    .font(.callout).foregroundStyle(.secondary)
                if store.selectedIDs.count > 1 {
                    Text("已选 \(store.selectedIDs.count) 项").font(.callout).foregroundStyle(Color.accentColor)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 8)
    }

    private var viewTitle: String {
        if !store.search.trimmingCharacters(in: .whitespaces).isEmpty { return "搜索结果" }
        switch store.selection ?? .all {
        case .all: return "全部"
        case .uncategorized: return "未分类"
        case .trash: return "废纸篓"
        case .folder(let id): return store.currentPath.last?.name ?? store.folderPath(id)
        }
    }

    /// 预览打开时，提前读当前和前后相邻的大图
    private func prefetchAround(_ ids: [String]) {
        guard store.preview, let id = store.selectedItemID, let i = ids.firstIndex(of: id) else { return }
        ImageLoader.shared.prefetchLarge(ids[max(0, i - 1)..<min(ids.count, i + 3)].compactMap(store.item))
    }

    private func open(_ item: Item) {
        openWindow(id: "viewer", value: ViewerTarget(path: item.fileURL.path, title: item.name))
    }
}

/// 顶部路径导航：点击上级跳回去
struct PathBar: View {
    @EnvironmentObject var store: LibraryStore
    let path: [Folder]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(path.enumerated()), id: \.element.id) { i, f in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                if i == path.count - 1 {
                    Text(f.name).font(.title3.weight(.semibold))
                } else {
                    Button(f.name) { store.selection = .folder(f.id) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }
}

extension Item {
    var fullName: String { ext.isEmpty ? name : "\(name).\(ext)" }
    /// 「5.2 MB · 6000 × 4000」
    var subtitle: String {
        var parts: [String] = []
        if size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if width > 0 { parts.append("\(width) × \(height)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 空格快速预览

struct QuickPreview: View {
    @EnvironmentObject var store: LibraryStore
    let item: Item
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial)
            if let image {
                Image(nsImage: image)
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 6)
                    .padding(.horizontal, 32).padding(.top, 52).padding(.bottom, 48)
            } else {
                ProgressView()
            }
            VStack {
                // 顶部：当前是第几张 / 共几张（按当前视图的顺序）
                if let i = store.visible.firstIndex(of: item.id) {
                    Text("\(i + 1) / \(store.visible.count)")
                        .font(.callout.monospacedDigit())
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 12)
                }
                Spacer()
                Text(item.fullName)
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.preview = false }
        .task(id: item.id) {
            image = ImageLoader.shared.cachedLarge(item) ?? ImageLoader.shared.cachedThumbnail(item)
            if image == nil { image = await ImageLoader.shared.thumbnail(item) }
            if let big = await ImageLoader.shared.large(item) { image = big }
        }
    }
}

// MARK: - 载入进度

struct LoadingProgress: View {
    let progress: LoadProgress
    var compact = false

    var body: some View {
        let label = HStack {
            Text(progress.phase)
            Spacer()
            if let total = progress.total {
                Text("\(progress.done) / \(total)").monospacedDigit()
            }
        }
        .font(compact ? .caption : .callout)
        .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 6) {
            label
            if let total = progress.total, total > 0 {
                ProgressView(value: Double(progress.done), total: Double(total))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .controlSize(compact ? .small : .regular)
    }
}
