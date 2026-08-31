import SwiftUI
import UniformTypeIdentifiers

/// 添加任务：磁力链接 / HTTP 种子 / 上传 .torrent 文件
struct AddTorrentView: View {
    @ObservedObject var qb: QBClient
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlsText = ""
    @State private var savePath = ""
    @State private var addPaused = false
    @State private var selectedTorrentName: String?
    @State private var selectedTorrentData: Data?
    @State private var showFileImporter = false
    @State private var isAdding = false
    @State private var errorText: String?
    @State private var successText: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("磁力链接或 HTTP 种子地址"),
                        footer: Text("每行一个，可同时添加多个。") ) {
                    TextEditor(text: $urlsText)
                        .frame(minHeight: 120)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section(header: Text("或上传 .torrent 文件")) {
                    Button {
                        showFileImporter = true
                    } label: {
                        HStack {
                            Image(systemName: "doc.badge.plus")
                            Text(selectedTorrentName ?? "选择 .torrent 文件")
                                .foregroundColor(selectedTorrentName != nil ? .primary : .blue)
                        }
                    }
                    if selectedTorrentName != nil {
                        Button("移除已选文件", role: .destructive) {
                            selectedTorrentName = nil
                            selectedTorrentData = nil
                        }
                    }
                }

                Section(header: Text("保存路径（可选）"),
                        footer: Text("留空使用 qBittorrent 默认保存目录。格式如 /Video/Movie")) {
                    TextField("默认保存目录", text: $savePath)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section {
                    Toggle("添加后暂停", isOn: $addPaused)
                }

                if let errorText = errorText {
                    Section {
                        Text(errorText)
                            .foregroundColor(.red)
                    }
                }
                if let successText = successText {
                    Section {
                        Text(successText)
                            .foregroundColor(.green)
                    }
                }

                Section {
                    Button {
                        Task { await add() }
                    } label: {
                        if isAdding {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("添加任务")
                                .frame(maxWidth: .infinity)
                                .font(.headline.bold())
                        }
                    }
                    .disabled(isAdding || (urlsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedTorrentData == nil))
                }
            }
            .navigationTitle("添加任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data]) { result in
            switch result {
            case .success(let url):
                guard url.startAccessingSecurityScopedResource() else {
                    errorText = "无法访问该文件"
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }
                do {
                    let data = try Data(contentsOf: url)
                    self.selectedTorrentData = data
                    self.selectedTorrentName = url.lastPathComponent
                } catch {
                    self.errorText = "读取文件失败: \(error.localizedDescription)"
                }
            case .failure(let error):
                self.errorText = "选择文件失败: \(error.localizedDescription)"
            }
        }
    }

    private func add() async {
        isAdding = true
        errorText = nil
        successText = nil
        do {
            if !qb.isLoggedIn {
                _ = try await qb.login(username: settings.qbUsername, password: settings.qbPassword)
            }
            let path = savePath.trimmingCharacters(in: .whitespacesAndNewlines)
            let urls = urlsText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !urls.isEmpty {
                try await qb.addTorrents(urls: urls, savePath: path.isEmpty ? nil : path, paused: addPaused)
            }
            if let data = selectedTorrentData {
                try await qb.uploadTorrentFile(fileData: data,
                                               filename: selectedTorrentName ?? "torrent.torrent",
                                               savePath: path.isEmpty ? nil : path,
                                               paused: addPaused)
            }
            successText = "已添加，请到任务列表查看"
            urlsText = ""
            selectedTorrentName = nil
            selectedTorrentData = nil
        } catch {
            errorText = error.localizedDescription
        }
        isAdding = false
    }
}
