import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// 双击打开的独立查看窗口
struct ViewerTarget: Codable, Hashable {
    var path: String
    var title: String
}

@main
struct MagpieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: LibraryStore

    init() {
        Self.migrateFromOpenView()
        _store = StateObject(wrappedValue: LibraryStore())
    }

    /// 本软件旧名 OpenView：第一次启动时搬过来旧的设置（最近打开、界面状态）和本机缩略图缓存
    private static func migrateFromOpenView() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromOpenView") else { return }
        d.set(true, forKey: "migratedFromOpenView")
        for (k, v) in d.persistentDomain(forName: "io.github.openview") ?? [:] where d.object(forKey: k) == nil {
            d.set(v, forKey: k)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let old = caches.appending(noStat: "OpenView"), new = caches.appending(noStat: "Magpie")
        if !FileManager.default.fileExists(atPath: new.path) { try? FileManager.default.moveItem(at: old, to: new) }
    }

    var body: some Scene {
        Window("Magpie", id: "main") {
            Group {
                if store.root == nil { WelcomeView() } else { LibraryView() }
            }
            .environmentObject(store)
            .frame(minWidth: 900, minHeight: 560)
            .alert("出错了", isPresented: Binding(get: { store.errorMessage != nil },
                                                set: { if !$0 { store.errorMessage = nil } })) {
                Button("好") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
        }
        .defaultSize(width: 1400, height: 880)
        .commands { LibraryCommands(store: store) }

        WindowGroup("查看图片", id: "viewer", for: ViewerTarget.self) { $target in
            if let target { ImageViewerView(target: target) }
        }
        .defaultSize(width: 1200, height: 800)
    }
}

/// 菜单栏：所有键盘操作都在这里，可以从菜单里看到。
/// 作用于「当前选中的东西」的命令（打开、删除）走响应链，由有焦点的视图（网格或左侧树）各自处理，和访达一致。
struct LibraryCommands: Commands {
    @ObservedObject var store: LibraryStore
    @AppStorage("thumbSize") private var thumbSize: Double = 190
    @AppStorage("showInspector") private var showInspector = true

    private var hasLibrary: Bool { store.root != nil }

    private func send(_ name: String) {
        NSApp.sendAction(Selector(name), to: nil, from: nil)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建文件夹") { _ = store.createFolder(in: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!hasLibrary)
            Divider()
            Button("打开") { send("openSelection:") }
                .keyboardShortcut("o")
                .disabled(!hasLibrary)
            Button("打开（⌘↓）") { send("openSelection:") }
                .keyboardShortcut(.downArrow)
                .disabled(!hasLibrary)
            Divider()
            Button("打开素材库…") { store.openPanel() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Menu("最近打开") {
                ForEach(store.recents, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) { store.open(URL(fileURLWithPath: path)) }
                }
                Divider()
                Button("清除最近打开") { store.clearRecents() }.disabled(store.recents.isEmpty)
            }
            Divider()
            Button("重新扫描素材库") { store.rescan() }
                .disabled(!hasLibrary || store.indexState == .building)
                .help("列出全部文件，补全索引中遗漏或已删除的条目")
            Button("关闭素材库") { store.close() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!hasLibrary)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button(store.selection == .trash ? "从废纸篓恢复" : "移到废纸篓") { send("delete:") }
                .keyboardShortcut(.delete)
                .disabled(!hasLibrary)
            Divider()
            Button("查找") { store.focusSearchRequest += 1 }
                .keyboardShortcut("f")
                .disabled(!hasLibrary)
        }

        CommandGroup(before: .sidebar) {
            Button("快速查看（空格）") { store.preview.toggle() }
                .disabled(store.selectedItemID == nil)
            Divider()
            Button("放大缩略图") { thumbSize = min(340, thumbSize + 30) }
                .keyboardShortcut("=")
            Button("缩小缩略图") { thumbSize = max(120, thumbSize - 30) }
                .keyboardShortcut("-")
            Button(showInspector ? "隐藏信息栏" : "显示信息栏") { showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }

        CommandMenu("前往") {
            Button("上一级文件夹") { store.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled({ if case .folder = store.selection { return false }; return true }())
            Divider()
            Button("全部") { store.selection = .all }.keyboardShortcut("1")
            Button("未分类") { store.selection = .uncategorized }.keyboardShortcut("2")
            Button("废纸篓") { store.selection = .trash }.keyboardShortcut("3")
        }
    }
}
