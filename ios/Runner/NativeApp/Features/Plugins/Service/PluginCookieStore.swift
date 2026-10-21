//
//  PluginCookieStore.swift
//  Kazumi
//
//  1:1 翻译 lib/services/plugin/plugin_cookie_manager.dart。
//
//  为每条规则维护独立的内存 Cookie 集合，由验证码 WebView 写入 document.cookie，
//  规则请求执行器按需组装 Cookie 请求头。验证 Cookie 通常与 UA 绑定，
//  因此同时记录 WebView 的 UA 供后续请求对齐指纹。Cookie 只在本进程内有效，
//  重启后需要重新验证（与原实现一致）。
//

import Foundation

final class PluginCookieStore: @unchecked Sendable {
    static let shared = PluginCookieStore()

    struct Cookie: Sendable, Equatable {
        var name: String
        var value: String
        var domain: String
        var path: String
    }

    private let lock = NSLock()
    private var jars: [String: [Cookie]] = [:]
    private var userAgents: [String: String] = [:]

    /// 与 cookie_jar 的 saveFromResponse 对齐：同名同域的 Cookie 覆盖旧值。
    func saveFromWebView(pluginName: String, pageUrl: String, cookieString: String, userAgent: String?) {
        if let userAgent {
            let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lock.lock()
                userAgents[pluginName] = trimmed
                lock.unlock()
            }
        }
        let trimmedCookies = cookieString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCookies.isEmpty { return }
        guard let host = URLComponents(string: pageUrl)?.host, !host.isEmpty else { return }

        let parsed = parse(trimmedCookies, host: host)
        if parsed.isEmpty { return }

        lock.lock()
        var jar = jars[pluginName] ?? []
        for cookie in parsed {
            if let index = jar.firstIndex(where: { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }) {
                jar[index] = cookie
            } else {
                jar.append(cookie)
            }
        }
        jars[pluginName] = jar
        lock.unlock()

        KazumiLog.plugin.info(
            "[PluginCookieStore] Saved \(parsed.count) cookies for \(pluginName, privacy: .public)"
        )
    }

    /// 解析 `a=b; c=d` 形式的字符串（document.cookie 的格式）。
    private func parse(_ raw: String, host: String) -> [Cookie] {
        var cookies: [Cookie] = []
        for part in raw.split(separator: ";", omittingEmptySubsequences: false) {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            cookies.append(Cookie(name: name, value: value, domain: host, path: "/"))
        }
        return cookies
    }

    /// 与 CookieJar.loadForRequest 对齐：域名匹配（含父域）且路径前缀匹配。
    func cookies(pluginName: String, url: String) -> [Cookie] {
        guard let components = URLComponents(string: url) else { return [] }
        let host = (components.host ?? "").lowercased()
        let requestPath = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        lock.lock()
        defer { lock.unlock() }
        guard let jar = jars[pluginName] else { return [] }
        return jar.filter { cookie in
            let domainMatches = !host.isEmpty &&
                (host == cookie.domain.lowercased() || host.hasSuffix(".\(cookie.domain.lowercased())"))
            return domainMatches && pathMatches(requestPath: requestPath, cookiePath: cookie.path)
        }
    }

    private func pathMatches(requestPath: String, cookiePath: String) -> Bool {
        if requestPath == cookiePath { return true }
        if !requestPath.hasPrefix(cookiePath) { return false }
        return cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).hasPrefix("/")
    }

    /// 组装 `name=value; name=value` 形式的请求头，无 Cookie 时返回空串。
    func cookieHeader(pluginName: String, url: String) -> String {
        cookies(pluginName: pluginName, url: url)
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// 验证时 WebView 使用的 UA；未验证过的规则返回 nil。
    func userAgent(for pluginName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return userAgents[pluginName]
    }

    func clear(pluginName: String) {
        lock.lock()
        jars[pluginName] = nil
        userAgents[pluginName] = nil
        lock.unlock()
    }

    func clearAll() {
        lock.lock()
        jars.removeAll()
        userAgents.removeAll()
        lock.unlock()
    }
}
