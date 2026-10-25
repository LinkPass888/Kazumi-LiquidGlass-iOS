//
//  KazumiNetworkPolicy.swift
//  Kazumi
//
//  网络设置里那几项要在「建 URLSession」的那一刻起作用，而各个接口的 session
//  都是静态的、建得比界面早，所以照 BangumiAcceleration 的做法放一份进程内状态：
//  SettingsStore 写入时更新它，各 session 建配置时读它。
//

import Foundation
import os

/// 图片加速方式（对应原版 `ImageAcceleration`，经 wsrv.nl 那套改写）。
enum ImageAcceleration: String, Sendable {
    case direct
    case mirror
}

/// 进程内共享的网络策略。
enum KazumiNetworkPolicy {
    private struct State: Sendable {
        var imageAcceleration: ImageAcceleration = .direct
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// 图片加速方式。
    static var imageAcceleration: ImageAcceleration {
        get { state.withLock { $0.imageAcceleration } }
        set { state.withLock { $0.imageAcceleration = newValue } }
    }
}

/// Bangumi 图片镜像改写（对应原版 `BangumiImageUrlRewriter`）：
/// lain.bgm.tv 和 api.bgm.tv 的 subjects/characters/persons 图片交给 wsrv.nl 转一层。
enum BangumiImageRewriter {
    private static let apiImageKinds: Set<String> = ["subjects", "characters", "persons"]

    static func isBangumiImage(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        if url.host == "lain.bgm.tv" { return true }
        return isAPIImage(url)
    }

    private static func isAPIImage(_ url: URL) -> Bool {
        guard url.host == "api.bgm.tv" else { return false }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count == 4, segments[0] == "v0", segments[3] == "image" else { return false }
        guard apiImageKinds.contains(segments[1]) else { return false }
        guard let id = Int(segments[2]), id > 0 else { return false }
        return true
    }

    /// 当前设置下这张图片该用哪个地址：直连原样返回，镜像走 wsrv.nl。
    static func rewritten(_ url: URL) -> URL {
        guard KazumiNetworkPolicy.imageAcceleration == .mirror, isBangumiImage(url) else {
            return url
        }
        let source = url.host.map { host in
            host + url.path + (url.query.map { "?\($0)" } ?? "")
        } ?? ""
        var components = URLComponents()
        components.scheme = "https"
        components.host = "wsrv.nl"
        components.path = "/"
        var items = [URLQueryItem(name: "url", value: source)]
        // 动图要 wsrv 别压缩帧数（原版同一个参数）。
        if url.path.lowercased().hasSuffix(".gif") {
            items.append(URLQueryItem(name: "n", value: "-1"))
        }
        components.queryItems = items
        return components.url ?? url
    }
}
