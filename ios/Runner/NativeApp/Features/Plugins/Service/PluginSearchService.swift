//
//  PluginSearchService.swift
//  Kazumi
//
//  1:1 翻译 lib/services/plugin/plugin_search_service.dart 与 lib/utils/async_session.dart。
//
//  每条规则维护一个会话：同一规则的手动重搜（别名/手动关键词）会让仍在运行的
//  旧请求结果作废，避免旧结果覆盖新结果。
//

import Foundation
import Observation

/// 对应 AsyncSessionOwner / AsyncSession。
final class AsyncSessionOwner: @unchecked Sendable {
    private let lock = NSLock()
    private let token = UUID()
    private var version = 0
    private var isClosed = false

    struct Session: Sendable {
        let owner: UUID
        let version: Int
    }

    func begin() -> Session? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return nil }
        version += 1
        return Session(owner: token, version: version)
    }

    func isActive(_ session: Session) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isClosed && session.owner == token && session.version == version
    }

    func cancel() {
        lock.lock()
        if !isClosed { version += 1 }
        lock.unlock()
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        version += 1
        lock.unlock()
    }
}

@MainActor
@Observable
final class PluginSearchService {
    private(set) var responses: [PluginSearchResponse] = []
    private(set) var statuses: [String: PluginSearchStatus] = [:]

    private let plugins: PluginsController
    private let engine: RuleEngine
    private let cancelToken = RuleCancelToken()
    private var querySessions: [String: AsyncSessionOwner] = [:]
    private var isCancelled = false

    init(plugins: PluginsController, engine: RuleEngine = RuleEngine()) {
        self.plugins = plugins
        self.engine = engine
    }

    func status(for pluginName: String) -> PluginSearchStatus? {
        statuses[pluginName]
    }

    func responses(for pluginName: String) -> [SearchItem] {
        responses.first { $0.pluginName == pluginName }?.data ?? []
    }

    func querySource(_ keyword: String, pluginName: String) async {
        guard let plugin = plugins.plugin(named: pluginName) else { return }
        responses.removeAll { $0.pluginName == pluginName }
        statuses[pluginName] = .pending
        await queryPlugin(plugin, keyword: keyword)
    }

    /// 发布验证码 WebView 抓到的结果页，省掉一次网络往返。
    /// HTML 解析不出结果时返回 false，调用方回退到 querySource。
    func applyHarvestedSearchResult(pluginName: String, html: String) -> Bool {
        guard !isCancelled, let plugin = plugins.plugin(named: pluginName) else { return false }
        let config = RuleExecutionConfig(plugin: plugin)
        guard let result = engine.tryParseHarvestedSearch(config, raw: html) else { return false }
        responses.removeAll { $0.pluginName == pluginName }
        statuses[pluginName] = .success
        plugins.validityTracker.markSearchValid(pluginName)
        responses.append(result)
        return true
    }

    func queryAllSource(_ keyword: String) async {
        responses.removeAll()
        statuses.removeAll()
        let snapshot = plugins.pluginList
        for plugin in snapshot {
            statuses[plugin.name] = .pending
        }
        await withTaskGroup(of: Void.self) { group in
            for plugin in snapshot {
                group.addTask { @MainActor in
                    await self.queryPlugin(plugin, keyword: keyword)
                }
            }
        }
    }

    private func queryPlugin(_ plugin: Plugin, keyword: String) async {
        guard !isCancelled else { return }
        let owner = querySessions[plugin.name] ?? {
            let created = AsyncSessionOwner()
            querySessions[plugin.name] = created
            return created
        }()
        guard let session = owner.begin() else { return }
        do {
            let trace = try await engine.search(
                RuleExecutionConfig(plugin: plugin),
                keyword: keyword,
                cancelToken: cancelToken
            )
            guard !isCancelled, owner.isActive(session) else { return }
            statuses[plugin.name] = .success
            if !trace.response.data.isEmpty {
                plugins.validityTracker.markSearchValid(plugin.name)
            }
            // 结果整体替换，避免手动重搜后出现重复条目。
            responses.removeAll { $0.pluginName == plugin.name }
            responses.append(trace.response)
        } catch {
            guard !isCancelled, owner.isActive(session) else { return }
            handleSearchError(plugin, error: error)
        }
    }

    private func handleSearchError(_ plugin: Plugin, error: Error) {
        switch error {
        case RuleError.captchaRequired(let name):
            KazumiLog.plugin.info("PluginSearchService: captcha required for \(name, privacy: .public)")
            statuses[name] = .captcha
        case RuleError.noResult(let name):
            KazumiLog.plugin.info("PluginSearchService: no results for \(name, privacy: .public)")
            statuses[name] = .noResult
        case RuleError.searchFailed(let name, _):
            KazumiLog.plugin.warning("PluginSearchService: search error for \(name, privacy: .public)")
            statuses[name] = .error
        default:
            KazumiLog.plugin.warning("PluginSearchService: search error for \(plugin.name, privacy: .public)")
            statuses[plugin.name] = .error
        }
    }

    func cancel() {
        isCancelled = true
        cancelToken.cancel()
        for owner in querySessions.values { owner.cancel() }
    }
}
// MARK: - 验证码接管

@MainActor
extension PluginSearchService {
    /// 当某条规则返回 `captchaRequired` 时创建验证流程；
    /// 验证成功会优先使用 WebView 收割到的页面，省掉一次网络往返。
    func makeCaptchaFlow(for pluginName: String, keyword: String) -> CaptchaFlow? {
        guard let plugin = plugins.plugin(named: pluginName) else { return nil }
        guard plugin.antiCrawlerConfig.enabled else { return nil }
        let flow = CaptchaFlow(plugin: plugin, keyword: keyword) { [weak self] html in
            guard let self else { return }
            if self.applyHarvestedSearchResult(pluginName: pluginName, html: html) { return }
            // 收割页解析不出结果（仍是挑战页或重定向页）时回退到重新搜索。
            Task { await self.querySource(keyword, pluginName: pluginName) }
        }
        return flow
    }

    /// 需要验证的规则名称（供界面决定是否弹出验证面板）。
    var captchaPluginNames: [String] {
        statuses.compactMap { name, status in status == .captcha ? name : nil }
    }
}
