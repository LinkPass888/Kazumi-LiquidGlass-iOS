//
//  KazumiSwipeBack.swift
//  Kazumi
//
//  恢复系统「从屏幕左缘右滑返回」的手势。
//
//  详情页用了 `.toolbar(.hidden, for: .navigationBar)` 自绘顶栏，导航栏一隐藏，
//  UINavigationController 会连带把 interactivePopGestureRecognizer 关掉
//  （它的 delegate 只看导航栏返回按钮），于是只剩自定义返回键能退出。
//  这里把代理换成自己的实现：只要栈里还有上一页就允许侧滑，栈底则不允许
//  —— 直接置 nil 会在根页面把导航栈卡死。
//

import SwiftUI
import UIKit

struct KazumiSwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        Enabler(delegate: context.coordinator)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigation = gestureRecognizer.view?.window?
                .findNavigationController() else { return false }
            return navigation.viewControllers.count > 1
        }
    }

    /// 挂在页面上的空控制器，只负责把代理接过去。
    private final class Enabler: UIViewController {
        private weak var delegate: Coordinator?

        init(delegate: Coordinator) {
            self.delegate = delegate
            super.init(nibName: nil, bundle: nil)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            install()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        private func install() {
            guard let navigation = navigationController ?? parent?.navigationController else { return }
            guard let gesture = navigation.interactivePopGestureRecognizer else { return }
            gesture.isEnabled = true
            gesture.delegate = delegate
        }
    }
}

private extension UIView {
    /// 从视图树往上找最近的 UINavigationController。
    func findNavigationController() -> UINavigationController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let navigation = current as? UINavigationController { return navigation }
            responder = current.next
        }
        return nil
    }
}
