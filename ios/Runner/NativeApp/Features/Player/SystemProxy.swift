//
//  SystemProxy.swift
//  Kazumi
//
//  读系统代理（LP 5063 / 5067）。
//
//  为什么需要它：播放内核是 libmpv，它自己那套 HTTP 栈**不认 iOS 的系统代理**。
//  NSURLSession（接口请求那一路）系统会自己带上代理，mpv 不会，所以代理工具没开
//  Tun／增强模式、只设了 Wi-Fi 的 HTTP 代理时，界面能刷、片子放不出来。
//
//  iOS 上 App 能拿到的只有 `CFNetworkCopySystemProxySettings()` 这一份（也就是
//  Wi-Fi 设置里那个 HTTP 代理）。手动填地址端口那套是桌面和安卓的用法，iOS 不做
//  （LP 5067）。
//

import CFNetwork
import Foundation

enum SystemProxy {
    /// 系统当前的 HTTP 代理，形如 `http://127.0.0.1:6152`；没开就返回 nil。
    ///
    /// 只读 HTTP 那一组：`kCFNetworkProxiesHTTPSEnable` 等在 iOS 上是不可用的
    /// （编译器直接报 unavailable），而 iOS 的 Wi-Fi 代理本来也只写 HTTP 这一组，
    /// 代理工具把 http 和 https 都收在这同一个端口上。
    static func httpProxyURL() -> String? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue()
                as? [String: Any]
        else { return nil }

        guard let enabled = settings[kCFNetworkProxiesHTTPEnable as String] as? Bool
                ?? (settings[kCFNetworkProxiesHTTPEnable as String] as? Int).map({ $0 != 0 }),
              enabled,
              let host = settings[kCFNetworkProxiesHTTPProxy as String] as? String,
              !host.isEmpty
        else { return nil }

        let port: Int
        if let number = settings[kCFNetworkProxiesHTTPPort as String] as? Int {
            port = number
        } else if let number = settings[kCFNetworkProxiesHTTPPort as String] as? NSNumber {
            port = number.intValue
        } else {
            port = 0
        }
        guard port > 0 else { return nil }
        return "http://\(host):\(port)"
    }
}
