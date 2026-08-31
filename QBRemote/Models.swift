import Foundation

// MARK: - qBittorrent 数据模型

/// 种子任务信息（对应 qB API /api/v2/torrents/info 返回的字段）
struct TorrentInfo: Identifiable, Codable, Hashable {
    let hash: String
    let name: String
    let state: String
    let progress: Double
    let size: Int64
    let dlspeed: Int64
    let upspeed: Int64
    let eta: Int
    let num_seeds: Int
    let num_leechs: Int
    let save_path: String
    let download_path: String?
    let added_on: Int
    let completion_on: Int
    let tracker: String?
    let trackers_count: Int?

    var id: String { hash }

    /// 已下载字节数
    var downloaded: Int64 { Int64(Double(size) * progress) }

    /// 状态描述（翻译成中文）
    var stateText: String {
        switch state {
        case "downloading": return "下载中"
        case "uploading": return "做种中"
        case "stalledUP": return "已暂停(做种)"
        case "stalledDL": return "已暂停(下载)"
        case "pausedUP": return "已完成"
        case "pausedDL": return "已暂停"
        case "checkingUP": return "校验中"
        case "checkingDL": return "校验中"
        case "error": return "错误"
        case "queuedDL": return "队列中"
        case "queuedUP": return "队列中(做种)"
        case "missingFiles": return "文件缺失"
        case "metaDL": return "获取元数据"
        case "forcedDL": return "强制下载"
        case "forcedUP": return "强制做种"
        case "moving": return "移动中"
        case "stoppedUP": return "已停止(做种)"
        case "stoppedDL": return "已停止"
        default: return state
        }
    }
}

/// 种子文件信息（对应 qB API /api/v2/torrents/files）
struct TorrentFile: Identifiable, Codable, Hashable {
    let index: Int
    let name: String
    let size: Int64
    let progress: Double
    var priority: Int

    var id: Int { index }

    /// 文件名（去掉路径部分）
    var fileName: String {
        (name as NSString).lastPathComponent
    }

    /// 文件扩展名
    var fileExtension: String {
        (fileName as NSString).pathExtension.lowercased()
    }

    /// 是否视频
    var isVideo: Bool {
        ["mp4", "mkv", "mov", "m4v", "avi", "wmv", "flv", "webm", "ts", "mpg", "mpeg", "3gp"].contains(fileExtension)
    }

    /// 是否图片
    var isImage: Bool {
        ["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "svg"].contains(fileExtension)
    }

    /// 是否音频
    var isAudio: Bool {
        ["mp3", "wav", "flac", "aac", "ogg", "m4a", "wma"].contains(fileExtension)
    }

    /// 是否可预览
    var isPreviewable: Bool { isVideo || isImage || isAudio }

    /// 文件图标
    var iconName: String {
        if isVideo { return "film" }
        if isImage { return "photo" }
        if isAudio { return "music.note" }
        return "doc"
    }
}

// MARK: - 传输信息

/// qB 全局传输信息（/api/v2/transfer/info），限速单位为 字节/秒
struct TransferInfo: Codable {
    let dl_info_speed: Int64?
    let up_info_speed: Int64?
    let dl_rate_limit: Int64?
    let up_rate_limit: Int64?
}

// MARK: - 目录树节点

/// 用于把扁平的文件列表构建成目录树（像 qB 原版"内容"标签一样）
final class FileTreeNode: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let isDirectory: Bool
    let file: TorrentFile?
    @Published var children: [FileTreeNode] = []
    @Published var isExpanded = false

    init(name: String, isDirectory: Bool, file: TorrentFile? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.file = file
    }

    /// 递归收集该节点（含子节点）下的所有文件
    var allFiles: [TorrentFile] {
        if let file = file { return [file] }
        var result: [TorrentFile] = []
        for c in children {
            result += c.allFiles
        }
        return result
    }

    /// 该目录下是否有未选中的文件（priority == 0）
    var hasUnselected: Bool {
        allFiles.contains { $0.priority == 0 }
    }

    /// 由扁平文件列表构建目录树
    static func buildTree(from files: [TorrentFile]) -> [FileTreeNode] {
        let root = FileTreeNode(name: "", isDirectory: true)
        for f in files {
            let parts = f.name.split(separator: "/").map(String.init)
            if parts.isEmpty { continue }
            var node = root
            for (i, part) in parts.enumerated() {
                let isLast = (i == parts.count - 1)
                if isLast {
                    // 叶子：文件
                    node.children.append(FileTreeNode(name: part, isDirectory: false, file: f))
                } else {
                    // 中间：目录（存在则复用，不存在则创建）
                    if let existing = node.children.first(where: { $0.name == part && $0.isDirectory }) {
                        node = existing
                    } else {
                        let dir = FileTreeNode(name: part, isDirectory: true)
                        node.children.append(dir)
                        node = dir
                    }
                }
            }
        }
        return root.children
    }
}
