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
    let priority: Int

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
