import SwiftUI

/// 内容页文件类型筛选（图片 / 视频分开）
enum ContentTypeFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case image = "图片"
    case video = "视频"
    case audio = "音频"

    var id: String { rawValue }

    func matches(_ f: TorrentFile) -> Bool {
        switch self {
        case .all: return true
        case .image: return f.isImage
        case .video: return f.isVideo
        case .audio: return f.isAudio
        }
    }
}

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
    @State private var previewFiles: [TorrentFile] = []
    @State private var previewIndex = 0
    @State private var showPreview = false
    @State private var allExpanded = false
    @State private var opMessage: String?
    @State private var showOpMessage = false
    @State private var pendingDeleteFile: TorrentFile?
    @State private var showDeleteFileDialog = false
    @State private var contentType: ContentTypeFilter = .all
    @State private var shareURL: URL?
    @State private var showShareSheet = false
    @State private var sharingFile = false

    /// 当前显示的文件（按类型筛选）
    private var displayFiles: [TorrentFile] {
        contentType == .all ? files : files.filter { contentType.matches($0) }
    }

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
                VStack(spacing: 0) {
                    // 类型分段：图片 / 视频 分开
                    Picker("类型", selection: $contentType) {
                        ForEach(ContentTypeFilter.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 6)

                    List {
                        // 目录操作行：展开/折叠 + 全选/全不选
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
                            Button {
                                selectAllFiles()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: allSelected ? "checkmark.circle.fill" : "checkmark.circle")
                                    Text(allSelected ? "全不选" : "全选下载")
                                        .font(.caption.weight(.medium))
                                }
                                .foregroundColor(.green)
                            }
                            Spacer()
                            Text("\(displayFiles.count) 个文件 · 勾选=下载")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        ForEach(treeNodes) { node in
                            FileTreeNodeView(node: node,
                                             onToggleFile: { file in toggleFile(file) },
                                             onToggleFolder: { n in toggleFolder(n) },
                                             onPreview: { file in handleTap(file) },
                                             onDeleteFile: { file in pendingDeleteFile = file; showDeleteFileDialog = true },
                                             onShare: { file in Task { await createAndShare(file) } })
                        }
                    }
                    .refreshable { await load() }
                }
            }
        }
        .navigationTitle(torrent.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: contentType) { _ in rebuildTree() }
        .fullScreenCover(isPresented: $showPreview) {
            if !previewFiles.isEmpty {
                MediaPreviewView(fb: fb, settings: settings, torrent: torrent,
                                 files: previewFiles, currentIndex: $previewIndex)
            }
        }
        .alert("提示", isPresented: $showOpMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text(opMessage ?? "")
        }
        .confirmationDialog("删除文件", isPresented: $showDeleteFileDialog, presenting: pendingDeleteFile) { file in
            Button("删除「\(file.name)」", role: .destructive) {
                Task { await deleteFile(file) }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("将永久删除 NAS 上的文件。删除后任务会显示文件缺失，建议稍后重新校验该任务。")
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .overlay {
            if sharingFile {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在生成分享链接...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 用其他 App 打开（生成免认证分享链接）

    private func createAndShare(_ file: TorrentFile) async {
        guard fb.token != nil else {
            opMessage = "FileBrowser 未登录，请返回设置检查"
            showOpMessage = true
            return
        }
        guard file.isPreviewable else { return }
        sharingFile = true
        defer { sharingFile = false }
        let rel = fb.fbRelativePath(savePath: torrent.save_path,
                                    relativeName: file.name,
                                    prefix: settings.pathPrefix)
        do {
            if let share = try await fb.createShare(relativePath: rel, hours: 24),
               let url = URL(string: share.url) {
                shareURL = url
                showShareSheet = true
            } else {
                opMessage = "生成分享链接失败，请检查 filebrowser 版本是否支持分享"
                showOpMessage = true
            }
        } catch {
            opMessage = "分享失败: \(error.localizedDescription)"
            showOpMessage = true
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
            rebuildTree()
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    /// 按当前类型筛选重建目录树（文件默认按大小从大到小排列）
    private func rebuildTree() {
        let sorted = displayFiles.sorted { $0.size > $1.size }
        let tree = FileTreeNode.buildTree(from: sorted)
        if tree.count <= 10 {
            setAll(tree, expanded: true)
            allExpanded = true
        }
        treeNodes = tree
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

    // MARK: - 全选 / 全不选

    /// 当前筛选下是否全部已选（下载）
    private var allSelected: Bool {
        !displayFiles.isEmpty && displayFiles.allSatisfy { $0.priority > 0 }
    }

    /// 全选下载 / 全不选（跳过）
    private func selectAllFiles() {
        let newPrio = allSelected ? 0 : 1
        let ids = displayFiles.map { $0.index }
        guard !ids.isEmpty else { return }
        Task { await setPriority(ids: ids, priority: newPrio) }
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
        // 收集与当前文件同目录的可预览文件，支持左右滑动依次预览（按当前类型筛选的列表）
        let dir = (file.name as NSString).deletingLastPathComponent
        let siblings = displayFiles.filter {
            $0.isPreviewable && ($0.name as NSString).deletingLastPathComponent == dir
        }.sorted { $0.index < $1.index }
        guard !siblings.isEmpty else { return }
        previewFiles = siblings
        previewIndex = siblings.firstIndex(where: { $0.index == file.index }) ?? 0
        showPreview = true
    }

    // MARK: - 删除文件

    private func deleteFile(_ file: TorrentFile) async {
        guard fb.token != nil else {
            opMessage = "FileBrowser 未登录，请返回设置检查"
            showOpMessage = true
            return
        }
        let rel = fb.fbRelativePath(savePath: torrent.save_path,
                                    relativeName: file.name,
                                    prefix: settings.pathPrefix)
        do {
            try await fb.deleteResource(relativePath: rel)
            await load()
            opMessage = "已删除「\(file.fileName)」\n任务会显示文件缺失，可在任务列表长按选择「重新校验」"
            showOpMessage = true
        } catch {
            opMessage = "删除失败: \(error.localizedDescription)"
            showOpMessage = true
        }
    }
}

/// 目录树节点视图（递归）
struct FileTreeNodeView: View {
    @ObservedObject var node: FileTreeNode
    let onToggleFile: (TorrentFile) -> Void
    let onToggleFolder: (FileTreeNode) -> Void
    let onPreview: (TorrentFile) -> Void
    let onDeleteFile: (TorrentFile) -> Void
    let onShare: (TorrentFile) -> Void

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $node.isExpanded) {
                ForEach(node.children) { child in
                    FileTreeNodeView(node: child,
                                     onToggleFile: onToggleFile,
                                     onToggleFolder: onToggleFolder,
                                     onPreview: onPreview,
                                     onDeleteFile: onDeleteFile,
                                     onShare: onShare)
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
                    onPreview: { onPreview(file) },
                    onDelete: { onDeleteFile(file) },
                    onShare: { onShare(file) })
        }
    }

    private var folderCheckImage: some View {
        let allSelected = !node.hasUnselected
        return Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
            .foregroundColor(allSelected ? .blue : .gray.opacity(0.6))
            .font(.system(size: 20))
    }
}

/// 文件行：勾选下载 + 预览 + 长按菜单（删除 / 用其他 App 打开）
struct FileRow: View {
    let file: TorrentFile
    let onToggleDownload: () -> Void
    let onPreview: () -> Void
    let onDelete: () -> Void
    let onShare: () -> Void

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
        .contextMenu {
            Button {
                onPreview()
            } label: {
                Label("预览", systemImage: "play.circle")
            }
            .disabled(!file.isPreviewable)

            Button {
                onShare()
            } label: {
                Label("用其他 App 打开（绕限速）", systemImage: "square.and.arrow.up")
            }
            .disabled(!file.isPreviewable)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除文件", systemImage: "trash")
            }
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// 系统分享面板（UIActivityViewController 的 SwiftUI 包装）
/// 用于把免认证的分享链接交给 SenPlayer / VidHub / Safari 等打开
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
