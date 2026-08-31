import SwiftUI

/// 任务详情：按目录树显示文件 + 预览
struct TorrentDetailView: View {
    @ObservedObject var qb: QBClient
    @ObservedObject var fb: FileBrowserClient
    @ObservedObject var settings: SettingsStore
    let torrent: TorrentInfo

    @State private var files: [TorrentFile] = []
    @State private var treeNodes: [FileTreeNode] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var previewingFile: TorrentFile?
    @State private var allExpanded = false

    var body: some View {
        Group {
            if isLoading && files.isEmpty {
                ProgressView("正在加载文件...")
            } else if files.isEmpty && !(errorText?.isEmpty ?? true) {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundColor(.orange)
                    Text(errorText!)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if files.isEmpty {
                Text("该任务没有文件")
                    .foregroundColor(.secondary)
            } else {
                List {
                    // 目录操作行
                    Button {
                        toggleAll()
                    } label: {
                        HStack {
                            Image(systemName: allExpanded ? "arrow.up.right.square" : "arrow.down.right.square")
                            Text(allExpanded ? "全部折叠" : "全部展开")
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text("\(files.count) 个文件")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.blue)

                    ForEach(treeNodes) { node in
                        FileTreeNodeView(node: node, onTap: { file in
                            handleTap(file)
                        })
                    }
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(torrent.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $previewingFile) { file in
            MediaPreviewView(fb: fb, settings: settings, file: file, torrent: torrent)
        }
    }

    private func load() async {
        isLoading = true
        errorText = nil
        do {
            if !qb.isLoggedIn {
                _ = try await qb.login(username: UserDefaults.standard.string(forKey: "qbUsername") ?? "",
                                       password: UserDefaults.standard.string(forKey: "qbPassword") ?? "")
            }
            files = try await qb.fetchFiles(hash: torrent.hash)
            // 构建目录树
            let tree = FileTreeNode.buildTree(from: files)
            // 文件多时默认展开一层，否则全部展开
            if tree.count <= 10 {
                setAll(tree, expanded: true)
                allExpanded = true
            }
            treeNodes = tree
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    private func toggleAll() {
        allExpanded.toggle()
        setAll(treeNodes, expanded: allExpanded)
    }

    private func setAll(_ nodes: [FileTreeNode], expanded: Bool) {
        for n in nodes {
            n.isExpanded = expanded
            setAll(n.children, expanded: expanded)
        }
    }

    private func handleTap(_ file: TorrentFile) {
        guard file.isPreviewable else { return }
        guard fb.token != nil else {
            errorText = "FileBrowser 未登录，请返回设置检查"
            return
        }
        previewingFile = file
    }
}

/// 目录树节点视图（递归）
struct FileTreeNodeView: View {
    @ObservedObject var node: FileTreeNode
    let onTap: (TorrentFile) -> Void

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $node.isExpanded) {
                ForEach(node.children) { child in
                    FileTreeNodeView(node: child, onTap: onTap)
                }
            } label: {
                Label(node.name, systemImage: node.isExpanded ? "folder.fill" : "folder")
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
        } else {
            if let file = node.file {
                Button {
                    onTap(file)
                } label: {
                    FileRow(file: file)
                }
                .disabled(!file.isPreviewable)
            }
        }
    }
}

/// 文件行
struct FileRow: View {
    let file: TorrentFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.iconName)
                .font(.system(size: 20))
                .foregroundColor(file.isPreviewable ? .blue : .gray)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(file.fileName)
                    .font(.subheadline)
                    .foregroundColor(file.isPreviewable ? .primary : .secondary)
                    .lineLimit(2)

                HStack {
                    Text(formatSize(file.size))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if file.progress < 1.0 {
                        Text("\(Int(file.progress * 100))%")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    if file.isPreviewable {
                        Image(systemName: "play.circle")
                            .font(.system(size: 16))
                            .foregroundColor(.blue)
                    }
                }
            }

            ProgressView(value: file.progress)
                .frame(width: 40)
                .tint(file.progress >= 1.0 ? .green : .blue)
        }
        .padding(.vertical, 2)
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
