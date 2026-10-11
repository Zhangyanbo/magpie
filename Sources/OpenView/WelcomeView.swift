import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.tint)
                Text("OpenView").font(.largeTitle.weight(.semibold))
                Text("兼容 Eagle 格式的素材库浏览器").foregroundStyle(.secondary)
                Button { store.openPanel() } label: {
                    Label("打开素材库…", systemImage: "folder").padding(.horizontal, 8)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text("最近打开")
                    .font(.headline).foregroundStyle(.secondary)
                    .padding([.horizontal, .top], 16).padding(.bottom, 8)
                if store.recents.isEmpty {
                    Text("暂无记录").foregroundStyle(.tertiary).padding(16)
                    Spacer()
                } else {
                    List(store.recents, id: \.self) { path in
                        RecentRow(path: path)
                            .contentShape(Rectangle())
                            .onTapGesture { store.open(URL(fileURLWithPath: path)) }
                            .contextMenu {
                                Button("从列表中移除") { store.removeRecent(path) }
                                Button("在访达中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                }
                            }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: 320, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.background.secondary)
        }
    }
}

/// 不检查路径是否存在：NAS 未挂载或很慢时，主线程上的 fileExists 会卡住界面
private struct RecentRow: View {
    let path: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "books.vertical").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                    .fontWeight(.medium)
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
    }
}
