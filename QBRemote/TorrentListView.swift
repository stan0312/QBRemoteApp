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

/// 状态分类标签
enum StatusFilter: String, CaseIterable {
    case all = "全部"
    case downloading = "下载中"
    case seeding = "做种中"
    case completed = "已完成"
    case paused = "暂停"
    case error = "错误"

    func matches(_ t: TorrentInfo) -> Bool {
        switch self {
        case .all: return true
        case .downloading:
            return ["downloading", "forcedDL", "metaDL", "stalledDL", "checkingDL"].contains(t.state)
        case .seeding:
            return ["uploading", "forcedUP", "stalledUP", "checkingUP"].contains(t.state)
        case .completed:
            return t.progress >= 1.0
        case .paused:
            return ["pausedDL", "pausedUP", "stoppedDL", "stoppedUP", "queuedDL", "queuedUP"].contains(t.state)
        case .error:
            return ["error", "missingFiles"].contains(t.state)
        }
    }
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
    @State private var statusFilter: StatusFilter = .all
    @State private var trackerFilter: String? = nil
    @State private var categoryFilter: String? = nil
    @State private var tagFilter: String? = nil
    @State private var showCatSection = false
    @State private var showTagSection = false
    @State private var showTrackerSection = false
    @State private var totalDL: Int64 = 0
    @State private var totalUP: Int64 = 0

    /// 所有任务中出现过的分类
    private var categoryList: [String] {
        Set(torrents.compactMap { $0.category }.filter { !$0.isEmpty }).sorted()
    }

    /// 所有任务中出现过的标签
    private var tagList: [String] {
        var set = Set<String>()
        for t in torrents {
            for tag in (t.tags ?? "").split(separator: ",") {
                let s = tag.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { set.insert(s) }
            }
        }
        return set.sorted()
    }

    /// 所有任务中出现过的 Tracker 域名
    private var trackerDomains: [String] {
        var set = Set<String>()
        for t in torrents {
            let d = trackerDomain(t.tracker)
            if !d.isEmpty { set.insert(d) }
        }
        return set.sorted()
    }

    private func trackerDomain(_ url: String?) -> String {
        guard let url = url, let u = URL(string: url), let host = u.host else { return "" }
        return host
    }

    /// 按状态 + 分类 + 标签 + Tracker 筛选，再按排序方式排序
    private var filteredTorrents: [TorrentInfo] {
        let list = torrents.filter { t in
            statusFilter.matches(t)
                && (trackerFilter == nil || trackerDomain(t.tracker) == trackerFilter)
                && (categoryFilter == nil || (t.category ?? "") == categoryFilter)
                && (tagFilter == nil || (t.tags ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.contains(tagFilter!))
        }
        switch sortOption {
        case .addDesc: return list.sorted { $0.added_on > $1.added_on }
        case .addAsc: return list.sorted { $0.added_on < $1.added_on }
        case .sizeDesc: return list.sorted { $0.size > $1.size }
        case .sizeAsc: return list.sorted { $0.size < $1.size }
        case .nameAsc: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .progressAsc: return list.sorted { $0.progress < $1.progress }
        case .progressDesc: return list.sorted { $0.progress > $1.progress }
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
                    VStack(spacing: 0) {
                        // 全局速度栏
                        HStack {
                            Label(formatSpeed(totalDL), systemImage: "arrow.down.circle")
                                .foregroundColor(.blue)
                            Spacer()
                            Text("\(filteredTorrents.count) 个任务")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Label(formatSpeed(totalUP), systemImage: "arrow.up.circle")
                                .foregroundColor(.green)
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(.systemBackground))

                        // 状态分类标签（固定展示）
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(StatusFilter.allCases, id: \.self) { f in
                                    chip(text: f.rawValue, selected: statusFilter == f) {
                                        statusFilter = f
                                    }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                        }

                        // 分类（可折叠）
                        if !categoryList.isEmpty {
                            filterSection(title: "分类",
                                          isExpanded: $showCatSection,
                                          chips: categoryList,
                                          selected: $categoryFilter,
                                          allText: "全部分类")
                        }

                        // 标签（可折叠）
                        if !tagList.isEmpty {
                            filterSection(title: "标签",
                                          isExpanded: $showTagSection,
                                          chips: tagList,
                                          selected: $tagFilter,
                                          allText: "全部标签")
                        }

                        // Tracker（可折叠）
                        if !trackerDomains.isEmpty {
                            filterSection(title: "Tracker",
                                          isExpanded: $showTrackerSection,
                                          chips: trackerDomains,
                                          selected: $trackerFilter,
                                          allText: "全部 Tracker")
                        }

                        Divider()

                        // 任务列表
                        List {
                            ForEach(filteredTorrents) { t in
                                NavigationLink(destination: TorrentDetailView(qb: qb, fb: fb, settings: settings, torrent: t)) {
                                    TorrentRow(torrent: t)
                                }
                                .contextMenu { torrentMenu(t) }
                            }
                        }
                        .refreshable { await load() }
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
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
        .task {
            await load()
            // 每 3 秒静默刷新（速度实时更新）
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await quietRefresh()
            }
        }
    }

    // MARK: - 分类标签

    /// 可折叠的筛选区块（标题行 + 可横向滑动的 chips）
    @ViewBuilder
    private func filterSection(title: String,
                               isExpanded: Binding<Bool>,
                               chips: [String],
                               selected: Binding<String?>,
                               allText: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(text: allText, selected: selected.wrappedValue == nil) {
                            selected.wrappedValue = nil
                        }
                        ForEach(chips, id: \.self) { c in
                            chip(text: c, selected: selected.wrappedValue == c) {
                                selected.wrappedValue = c
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private func chip(text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.caption.weight(selected ? .bold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? Color.blue : Color(.systemGray6))
                .foregroundColor(selected ? .white : .primary)
                .cornerRadius(14)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }

    private func formatSpeed(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB/s", Double(bytes) / 1024 / 1024)
        } else if bytes >= 1024 {
            return String(format: "%.0f KB/s", Double(bytes) / 1024)
        } else {
            return "0 B/s"
        }
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
            updateSpeeds()
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    /// 静默刷新（不显示加载动画）
    private func quietRefresh() async {
        guard qb.isLoggedIn else { return }
        do {
            torrents = try await qb.fetchTorrents()
            updateSpeeds()
        } catch {
            // 静默失败，不打扰
        }
    }

    private func updateSpeeds() {
        totalDL = torrents.reduce(0) { $0 + $1.dlspeed }
        totalUP = torrents.reduce(0) { $0 + $1.upspeed }
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
                Text("↓ " + formatSpeed(torrent.dlspeed))
                    .font(.caption)
                    .foregroundColor(.blue)
                Text("↑ " + formatSpeed(torrent.upspeed))
                    .font(.caption)
                    .foregroundColor(.green)
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
            return "0 B/s"
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
