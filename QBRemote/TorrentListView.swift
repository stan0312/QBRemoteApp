import SwiftUI

/// 任务列表排序方式
enum SortOption: String, CaseIterable {
    case addDesc = "添加时间 (新→旧)"
    case addAsc = "添加时间 (旧→新)"
    case sizeDesc = "大小 (大→小)"
    case sizeAsc = "大小 (小→大)"
    case nameAsc = "名称 (A→Z)"
    case progressAsc = "进度 (未完成在前)"
    case progressDesc = "进度 (已完成在前)"
}

/// 任务列表页
struct TorrentListView: View {
    @ObservedObject var qb: QBClient
    @ObservedObject var fb: FileBrowserClient
    @ObservedObject var settings: SettingsStore
    @State private var torrents: [TorrentInfo] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var showAdd = false
    @State private var showSpeedLimit = false
    @State private var pendingDelete: TorrentInfo?
    @State private var showDeleteDialog = false
    @State private var opMessage: String?
    @State private var showOpMessage = false
    @State private var sortOption: SortOption = .addDesc

    /// 按当前排序方式排序
    private var sortedTorrents: [TorrentInfo] {
        switch sortOption {
        case .addDesc: return torrents.sorted { $0.added_on > $1.added_on }
        case .addAsc: return torrents.sorted { $0.added_on < $1.added_on }
        case .sizeDesc: return torrents.sorted { $0.size > $1.size }
        case .sizeAsc: return torrents.sorted { $0.size < $1.size }
        case .nameAsc: return torrents.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .progressAsc: return torrents.sorted { $0.progress < $1.progress }
        case .progressDesc: return torrents.sorted { $0.progress > $1.progress }
        }
    }

    var body: some View {
        NavigationView {
            Group {
                if torrents.isEmpty && isLoading {
                    ProgressView("正在加载任务...")
                } else if torrents.isEmpty && !(errorText?.isEmpty ?? true) {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)
                        Text(errorText!)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("重试") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if torrents.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("暂无任务")
                            .foregroundColor(.secondary)
                        Button {
                            showAdd = true
                        } label: {
                            Label("添加任务", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(sortedTorrents) { t in
                            NavigationLink(destination: TorrentDetailView(qb: qb, fb: fb, settings: settings, torrent: t)) {
                                TorrentRow(torrent: t)
                            }
                            .contextMenu { torrentMenu(t) }
                        }
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("下载任务")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 18) {
                        Button {
                            showAdd = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        // 排序
                        Menu {
                            Picker("排序方式", selection: $sortOption) {
                                ForEach(SortOption.allCases, id: \.self) { opt in
                                    Text(opt.rawValue).tag(opt)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        Menu {
                            Button("暂停全部") { Task { await runOp("pause", hashes: ["all"]) } }
                            Button("恢复全部") { Task { await runOp("resume", hashes: ["all"]) } }
                            Divider()
                            Button("限速设置") { showSpeedLimit = true }
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showAdd) {
            AddTorrentView(qb: qb, settings: settings)
        }
        .sheet(isPresented: $showSpeedLimit) {
            SpeedLimitView(qb: qb)
        }
        .confirmationDialog("删除任务", isPresented: $showDeleteDialog, presenting: pendingDelete) { t in
            Button("删除任务并删除文件", role: .destructive) {
                Task { await deleteTask(t, deleteFiles: true) }
            }
            Button("仅删除任务（保留文件）", role: .destructive) {
                Task { await deleteTask(t, deleteFiles: false) }
            }
            Button("取消", role: .cancel) {}
        } message: { t in
            Text("「\(t.name)」")
        }
        .alert("提示", isPresented: $showOpMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text(opMessage ?? "")
        }
        .task { await load() }
    }

    // MARK: - 单任务操作菜单

    @ViewBuilder
    private func torrentMenu(_ t: TorrentInfo) -> some View {
        let isPaused = t.state.hasPrefix("paused") || t.state.hasPrefix("stopped") || t.state == "error" || t.state == "missingFiles"

        if isPaused {
            Button {
                Task { await runOp("resume", hashes: [t.hash]) }
            } label: {
                Label("继续", systemImage: "play.fill")
            }
        } else {
            Button {
                Task { await runOp("pause", hashes: [t.hash]) }
            } label: {
                Label("暂停", systemImage: "pause.fill")
            }
        }

        Button {
            Task { await runOp("recheck", hashes: [t.hash]) }
        } label: {
            Label("重新校验", systemImage: "checkmark.circle")
        }

        Divider()

        Button(role: .destructive) {
            pendingDelete = t
            showDeleteDialog = true
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - 操作

    private func runOp(_ action: String, hashes: [String]) async {
        do {
            switch action {
            case "pause": try await qb.pause(hashes: hashes)
            case "resume": try await qb.resume(hashes: hashes)
            case "recheck": try await qb.recheck(hashes: hashes)
            default: break
            }
            await load()
        } catch {
            opMessage = error.localizedDescription
            showOpMessage = true
        }
    }

    private func deleteTask(_ t: TorrentInfo, deleteFiles: Bool) async {
        do {
            try await qb.delete(hashes: [t.hash], deleteFiles: deleteFiles)
            await load()
        } catch {
            opMessage = error.localizedDescription
            showOpMessage = true
        }
    }

    private func load() async {
        isLoading = true
        errorText = nil
        do {
            if !qb.isLoggedIn {
                let ok = try await qb.login(username: settings.qbUsername,
                                            password: settings.qbPassword)
                if !ok {
                    errorText = "qB 登录失败，请检查账号密码"
                    isLoading = false
                    return
                }
            }
            torrents = try await qb.fetchTorrents()
            torrents.sort { $0.added_on > $1.added_on }
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }
}

/// 单个任务行
struct TorrentRow: View {
    let torrent: TorrentInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(torrent.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            HStack {
                Text(torrent.stateText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if torrent.dlspeed > 0 {
                    Text("↓ " + formatSpeed(torrent.dlspeed))
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                if torrent.upspeed > 0 {
                    Text("↑ " + formatSpeed(torrent.upspeed))
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            ProgressView(value: torrent.progress)
                .tint(progressColor)

            HStack {
                Text("\(Int(torrent.progress * 100))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatSize(torrent.downloaded) + " / " + formatSize(torrent.size))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var progressColor: Color {
        switch torrent.state {
        case "uploading", "stalledUP", "pausedUP", "stoppedUP", "queuedUP", "forcedUP":
            return .green
        case "downloading", "stalledDL", "forcedDL", "metaDL", "queuedDL":
            return .blue
        case "error", "missingFiles":
            return .red
        default:
            return .gray
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatSpeed(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB/s", Double(bytes) / 1024 / 1024)
        } else if bytes >= 1024 {
            return String(format: "%.0f KB/s", Double(bytes) / 1024)
        } else {
            return "\(bytes) B/s"
        }
    }
}

/// 全局限速设置
struct SpeedLimitView: View {
    @ObservedObject var qb: QBClient
    @Environment(\.dismiss) private var dismiss
    @State private var dlText = ""
    @State private var upText = ""
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("全局限速（KB/s，填 0 表示不限速）")) {
                    HStack {
                        Text("下载")
                        Spacer()
                        TextField("不限速", text: $dlText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                    HStack {
                        Text("上传")
                        Spacer()
                        TextField("不限速", text: $upText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                }
                Section {
                    Button {
                        Task { await apply() }
                    } label: {
                        Text("应用限速")
                            .frame(maxWidth: .infinity)
                            .font(.headline.bold())
                    }
                }
                if let errorText = errorText {
                    Section {
                        Text(errorText).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("限速设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let info = try await qb.fetchTransferInfo()
            // transfer/info 返回的是字节/秒，转换为 KB/s
            let dl = info.dl_rate_limit ?? 0
            let up = info.up_rate_limit ?? 0
            DispatchQueue.main.async {
                dlText = dl > 0 ? "\(dl / 1024)" : "0"
                upText = up > 0 ? "\(up / 1024)" : "0"
                loading = false
            }
        } catch {
            errorText = error.localizedDescription
            loading = false
        }
    }

    private func apply() async {
        do {
            let dl = Int(dlText) ?? 0
            let up = Int(upText) ?? 0
            try await qb.setGlobalDownloadLimit(kbPerSec: dl)
            try await qb.setGlobalUploadLimit(kbPerSec: up)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
