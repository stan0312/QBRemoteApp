import SwiftUI

/// 预览页右上角「设置」弹层：播放控制（暂停/开始全部）、播放速度、调试日志、连接设置
struct PreviewSettingsSheet: View {
    @ObservedObject var settings: SettingsStore
    @Binding var controlCmd: PreviewControl
    @Binding var playbackRate: Float
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("播放控制")) {
                    Button {
                        controlCmd = .pauseAll
                    } label: {
                        Label("暂停全部", systemImage: "pause.circle.fill")
                            .foregroundColor(.primary)
                    }
                    Button {
                        controlCmd = .playAll
                    } label: {
                        Label("开始全部", systemImage: "play.circle.fill")
                            .foregroundColor(.primary)
                    }
                }
                Section(header: Text("播放速度"),
                        footer: Text("对所有视频生效，当前 \(String(format: "%.2f", playbackRate))x")) {
                    Slider(value: $playbackRate, in: 0.5...2.0, step: 0.25) {
                        Text("播放速度")
                    }
                    Text("\(String(format: "%.2f", playbackRate))x")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                Section(header: Text("调试")) {
                    NavigationLink(destination: LogView()) {
                        Label("调试日志", systemImage: "doc.text.magnifyingglass")
                    }
                }
                Section(header: Text("连接")) {
                    NavigationLink(destination: SettingsView(settings: settings)) {
                        Label("连接设置", systemImage: "network")
                    }
                }
            }
            .navigationTitle("预览设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
