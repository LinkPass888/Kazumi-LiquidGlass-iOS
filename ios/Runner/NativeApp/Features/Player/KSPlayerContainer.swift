//
//  KSPlayerContainer.swift
//  Kazumi
//
//  把 KSPlayer 的 IOSVideoPlayerView 包进 SwiftUI。
//  只使用已确认存在的 API（KSOptions / KSPlayerResourceDefinition /
//  KSPlayerResource / IOSVideoPlayerView.set(resource:)），
//  避免依赖未验证的 SwiftUI 组件签名。
//  2.3.x 起上游只发布单一的 `KSPlayer` 模块（含 UIKit 播放控件），
//  因此不再 `import KSPlayerUI`。
//

import SwiftUI
import UIKit
import KSPlayer

struct KSPlayerContainer: UIViewRepresentable {
    let url: URL
    let resourceName: String
    let referer: String?
    let userAgent: String?

    func makeUIView(context: Context) -> IOSVideoPlayerView {
        let view = IOSVideoPlayerView()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: IOSVideoPlayerView, context: Context) {
        // 同一 URL 重复刷新会打断播放，这里用 coordinator 去重。
        guard context.coordinator.lastURL != url else { return }
        context.coordinator.lastURL = url

        var options = KSOptions()
        // 规则站点普遍校验 UA 与 Referer，缺一不可。
        if let userAgent, !userAgent.isEmpty {
            options.userAgent = userAgent
            options.appendHeader(["User-Agent": userAgent])
        }
        if let referer, !referer.isEmpty {
            options.referer = referer
            options.appendHeader(["Referer": referer])
        }
        // KSOptions 同时暴露了同名的静态属性（全局默认）与实例属性，
        // 在可变局部变量上访问时才会解析到实例属性。
        options.isAutoPlay = true

        let definition = KSPlayerResourceDefinition(
            url: url,
            definition: resourceName,
            options: options
        )
        let resource = KSPlayerResource(name: resourceName, definitions: [definition])
        uiView.set(resource: resource)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIView(_ uiView: IOSVideoPlayerView, coordinator: Coordinator) {
        coordinator.lastURL = nil
    }

    final class Coordinator {
        var lastURL: URL?
    }
}
