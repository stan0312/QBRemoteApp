import SwiftUI
import UIKit

/// 调试日志查看页：实时刷新、可滚动、一键复制全部、清空
struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logs: [AppLog.LogEntry] = []
    @State private var timer: Timer?
    @State private var copied = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(logs) { e in
                        Text("[\(e.time)] [\(e.tag)] \(e.message)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 1)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(8)
            }
            .background(Color(.secondarySystemBackground))
            .onAppear {
                logs = AppLog.shared.snapshot
                scrollToBottom(proxy)
                // 每秒刷新，方便观察预览过程中的实时日志
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    logs = AppLog.shared.snapshot
                    scrollToBottom(proxy)
                }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
        }
        .navigationTitle("调试日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(copied ? "已复制 ✓" : "复制全部") {
                    UIPasteboard.general.string = AppLog.shared.exportText
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                }
                Button("清空") {
                    AppLog.shared.clear()
                    logs = []
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.none) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}
