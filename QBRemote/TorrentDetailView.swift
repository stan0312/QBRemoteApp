import SwiftUI

/// 任务详情：按目录树显示文件 + 预览 + 勾选下载/不下载
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
    @State private var opMessage: String?
    @State private var showOpMessage = false

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
                    HStack {
                        Button {
                            toggleAll()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: allExpanded ? "arrow.up.right.square" : "arrow.down.right.square")
                                Text(allExpanded ? "全部折叠" : "全部展开")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundColor(.blue)
                        }
                        Spacer()
                        Text("\(files.count) 个文件 · 勾选=下载")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    ForEach(treeNodes) { node in
                        FileTreeNodeView(node: node,
                                         onToggleFile: { file in toggleFile(file) },
                                         onToggleFolder: { n in toggleFolder(n) },
                                         onPreview: { file in handleTap(file) })
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
        .alert("提示", isPresented: $showOpMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text(opMessage ?? "")
        }
    }

    // MARK: - 加载

    private func load() async {
        isLoading = true
        errorText = nil
        do {
            if !qb.isLoggedIn {
                _ = try await qb.login(username: settings.qbUsername,
                                       password: settings.qbPassword)
            }
            files = try await qb.fetchFiles(hash: torrent.hash)
            let tree = FileTreeNode.buildTree(from: files)
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

    // MARK: - 展开/折叠

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

    // MARK: - 勾选下载/不下载

    private func toggleFile(_ file: TorrentFile) {
        let newPrio = file.priority > 0 ? 0 : 1
        Task { await setPriority(ids: [file.index], priority: newPrio) }
    }

    private func toggleFolder(_ node: FileTreeNode) {
        let fs = node.allFiles
        guard !fs.isEmpty else { return }
        // 全部已选 -> 全部取消；否则全部选中
        let allSelected = fs.allSatisfy { $0.priority > 0 }
        let newPrio = allSelected ? 0 : 1
        Task { await setPriority(ids: fs.map { $0.index }, priority: newPrio) }
    }

    private func setPriority(ids: [Int], priority: Int) async {
        do {
            try await qb.setFilePriority(hash: torrent.hash, ids: ids, priority: priority)
            await load()
        } catch {
            opMessage = "设置失败: \(error.localizedDescription)"
            showOpMessage = true
        }
    }

    // MARK: - 预览

    private func handleTap(_ file: TorrentFile) {
        guard file.isPreviewable else { return }
        guard fb.token != nil else {
            opMessage = "FileBrowser 未登录，请返回设置检查"
            showOpMessage = true
            return
        }
        previewingFile = file
    }
}

/// 目录树节点视图（递归）
struct FileTreeNodeView: View {
    @ObservedObject var node: FileTreeNode
    let onToggleFile: (TorrentFile) -> Void
    let onToggleFolder: (FileTreeNode) -> Void
    let onPreview: (TorrentFile) -> Void

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $node.isExpanded) {
                ForEach(node.children) { child in
                    FileTreeNodeView(node: child,
                                     onToggleFile: onToggleFile,
                                     onToggleFolder: onToggleFolder,
                                     onPreview: onPreview)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: node.isExpanded ? "folder.fill" : "folder")
                        .foregroundColor(.blue)
                    Text(node.name)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    // 文件夹级勾选：全选 / 全不选
                    Button {
                        onToggleFolder(node)
                    } label: {
                        folderCheckImage
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if let file = node.file {
            FileRow(file: file,
                    onToggleDownload: { onToggleFile(file) },
                    onPreview: { onPreview(file) })
        }
    }

    private var folderCheckImage: some View {
        let allSelected = !node.hasUnselected
        return Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
            .foregroundColor(allSelected ? .blue : .gray.opacity(0.6))
            .font(.system(size: 20))
    }
}

/// 文件行：勾选下载 + 预览
struct FileRow: View {
    let file: TorrentFile
    let onToggleDownload: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // 勾选框：勾选 = 下载，取消 = 跳过
            Button {
                onToggleDownload()
            } label: {
                Image(systemName: file.priority > 0 ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(file.priority > 0 ? .blue : .gray.opacity(0.6))
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)

            // 主体（点按预览，仅可预览类型）
            Button {
                onPreview()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: file.iconName)
                        .font(.system(size: 18))
                        .foregroundColor(file.isPreviewable ? .blue : .gray)
                        .frame(width: 26)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.fileName)
                            .font(.subheadline)
                            .foregroundColor(file.priority > 0 ? .primary : .secondary)
                            .lineLimit(2)
                        HStack {
                            Text(formatSize(file.size))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            if file.progress < 1.0 && file.priority > 0 {
                                Text("\(Int(file.progress * 100))%")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                            Spacer()
                            if file.isPreviewable {
                                Image(systemName: "play.circle")
                                    .font(.system(size: 15))
                                    .foregroundColor(.blue)
                            }
                        }
                    }

                    ProgressView(value: file.progress)
                        .frame(width: 40)
                        .tint(file.progress >= 1.0 ? .green : .blue)
                }
            }
            .buttonStyle(.plain)
            .disabled(!file.isPreviewable)
        }
        .padding(.vertical, 2)
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
