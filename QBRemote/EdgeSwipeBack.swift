import SwiftUI
import UIKit

/// 全局「从左向右边缘滑动返回上一级」
///
/// 1) SwiftUI 的 NavigationView/NavigationStack 底层是 UINavigationController。
///    通过扩展让它始终接管 interactivePopGestureRecognizer，即使页面隐藏了
///    系统返回按钮、或自定义了返回按钮，左缘右滑返回也始终可用。
/// 2) fullScreenCover（如媒体全屏预览）没有系统右滑返回，用 UIScreenEdgePanGestureRecognizer
///    在屏幕左缘 44pt 区域监听右滑并关闭 —— 系统级边缘手势，不干扰 TabView 中间翻页。
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        // 开启系统级右滑返回手势，并允许自定义导航栏/隐藏返回按钮场景下依然生效
        interactivePopGestureRecognizer?.isEnabled = true
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 只有导航栈里还有上一层时才响应右滑（避免根页面右滑触发无意义的 pop）
        return viewControllers.count > 1
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // 与横向滑动组件（列表、TabView）共存，不互相抢占
        return false
    }
}

/// 屏幕左缘右滑检测器（UIKit 边缘手势，系统优先级高，专用于全屏预览关闭）
struct EdgePanCloseDetector: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        let pan = UIScreenEdgePanGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.handle(_:)))
        pan.edges = .left
        pan.minimumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }

        @objc func handle(_ gesture: UIScreenEdgePanGestureRecognizer) {
            if gesture.state == .ended {
                action()
            }
        }
    }
}

/// 为任意视图（特别是 fullScreenCover / sheet）附加「从左边缘向右滑动」的关闭手势
struct EdgeSwipeDismissModifier: ViewModifier {
    let action: () -> Void
    /// 左缘手势区域宽度（pt），只占屏幕最左缘，不挡中间内容的滑动/点击
    private let edgeWidth: CGFloat = 44

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                EdgePanCloseDetector(action: action)
                    .frame(width: edgeWidth)
            }
    }
}

extension View {
    /// 让当前视图支持「左缘右滑关闭」（配合 dismiss 使用）
    func edgeSwipeDismiss(action: @escaping () -> Void) -> some View {
        modifier(EdgeSwipeDismissModifier(action: action))
    }
}
