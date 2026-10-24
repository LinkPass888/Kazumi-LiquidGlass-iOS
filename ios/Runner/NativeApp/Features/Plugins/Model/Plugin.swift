//
//  Plugin.swift
//  Kazumi
//
//  1:1 翻译 lib/plugins/plugins.dart：字段集合、默认值、JSON 键名（含 muliSources 拼写）、
//  api 字段为字符串（需要更高版本客户端时按整数比较）均与原实现保持一致。
//

import Foundation

/// 规则名归一化：与原项目 pluginNameKey 一致，大小写不敏感。
func pluginNameKey(_ name: String) -> String {
    name.lowercased()
}

struct Plugin: Hashable, Sendable, Identifiable {
    var api: String
    var type: String
    var name: String
    var version: String
    var muliSources: Bool

    /// 历史字段，仅为导入导出兼容而保留。
    var useWebview: Bool

    /// 历史字段，仅为导入导出兼容而保留。
    var useNativePlayer: Bool

    var usePost: Bool
    var useLegacyParser: Bool
    var adBlocker: Bool
    var userAgent: String
    var baseUrl: String
    var searchURL: String
    var searchList: String
    var searchName: String
    var searchResult: String
    var chapterRoads: String
    var chapterResult: String
    var referer: String
    var searchMode: RuleMode
    var chapterMode: RuleMode
    var searchApiConfig: ApiSearchConfig
    var chapterApiConfig: ApiChapterConfig
    var antiCrawlerConfig: AntiCrawlerConfig

    var id: String { pluginNameKey(name) }

    init(
        api: String,
        type: String = "anime",
        name: String,
        version: String,
        muliSources: Bool = true,
        useWebview: Bool = true,
        useNativePlayer: Bool = true,
        usePost: Bool = false,
        useLegacyParser: Bool = false,
        adBlocker: Bool = false,
        userAgent: String = "",
        baseUrl: String = "",
        searchURL: String = "",
        searchList: String = "",
        searchName: String = "",
        searchResult: String = "",
        chapterRoads: String = "",
        chapterResult: String = "",
        referer: String = "",
        searchMode: RuleMode = .xpath,
        chapterMode: RuleMode = .xpath,
        searchApiConfig: ApiSearchConfig = ApiSearchConfig(),
        chapterApiConfig: ApiChapterConfig = ApiChapterConfig(),
        antiCrawlerConfig: AntiCrawlerConfig = .empty
    ) {
        self.api = api
        self.type = type
        self.name = name
        self.version = version
        self.muliSources = muliSources
        self.useWebview = useWebview
        self.useNativePlayer = useNativePlayer
        self.usePost = usePost
        self.useLegacyParser = useLegacyParser
        self.adBlocker = adBlocker
        self.userAgent = userAgent
        self.baseUrl = baseUrl
        self.searchURL = searchURL
        self.searchList = searchList
        self.searchName = searchName
        self.searchResult = searchResult
        self.chapterRoads = chapterRoads
        self.chapterResult = chapterResult
        self.referer = referer
        self.searchMode = searchMode
        self.chapterMode = chapterMode
        self.searchApiConfig = searchApiConfig
        self.chapterApiConfig = chapterApiConfig
        self.antiCrawlerConfig = antiCrawlerConfig
    }

    init(json: JSONValue) {
        let object = json.objectValue ?? [:]
        self.init(
            api: object["api"]?.stringValue ?? "1",
            type: object["type"]?.stringValue ?? "anime",
            name: object["name"]?.stringValue ?? "",
            version: object["version"]?.stringValue ?? "",
            muliSources: object["muliSources"]?.boolValue ?? true,
            useWebview: object["useWebview"]?.boolValue ?? true,
            useNativePlayer: object["useNativePlayer"]?.boolValue ?? true,
            usePost: object["usePost"]?.boolValue ?? false,
            useLegacyParser: object["useLegacyParser"]?.boolValue ?? false,
            adBlocker: object["adBlocker"]?.boolValue ?? false,
            userAgent: object["userAgent"]?.stringValue ?? "",
            baseUrl: object["baseURL"]?.stringValue ?? "",
            searchURL: object["searchURL"]?.stringValue ?? "",
            searchList: object["searchList"]?.stringValue ?? "",
            searchName: object["searchName"]?.stringValue ?? "",
            searchResult: object["searchResult"]?.stringValue ?? "",
            chapterRoads: object["chapterRoads"]?.stringValue ?? "",
            chapterResult: object["chapterResult"]?.stringValue ?? "",
            referer: object["referer"]?.stringValue ?? "",
            searchMode: RuleMode.normalize(object["searchMode"]),
            chapterMode: RuleMode.normalize(object["chapterMode"]),
            searchApiConfig: ApiSearchConfig(json: object["searchApiConfig"]),
            chapterApiConfig: ApiChapterConfig(json: object["chapterApiConfig"]),
            antiCrawlerConfig: object["antiCrawlerConfig"] == nil
                ? .empty
                : AntiCrawlerConfig(json: object["antiCrawlerConfig"])
        )
    }

    /// 新建规则时使用的模板（对应 Plugin.fromTemplate）。
    static func template(apiLevel: Int) -> Plugin {
        Plugin(api: String(apiLevel), name: "", version: "")
    }

    func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "api": .string(api),
            "type": .string(type),
            "name": .string(name),
            "version": .string(version),
            "muliSources": .bool(muliSources),
            "useWebview": .bool(useWebview),
            "useNativePlayer": .bool(useNativePlayer),
            "usePost": .bool(usePost),
            "useLegacyParser": .bool(useLegacyParser),
            "adBlocker": .bool(adBlocker),
            "userAgent": .string(userAgent),
            "baseURL": .string(baseUrl),
            "searchURL": .string(searchURL),
            "searchList": .string(searchList),
            "searchName": .string(searchName),
            "searchResult": .string(searchResult),
            "chapterRoads": .string(chapterRoads),
            "chapterResult": .string(chapterResult),
            "referer": .string(referer),
            "searchMode": .string(searchMode.rawValue),
            "chapterMode": .string(chapterMode.rawValue)
        ]
        // 持久化会重写整张规则表，因此已配置但当前未启用的 API 规则也要保留。
        if searchMode == .api || !searchApiConfig.request.url.isEmpty {
            object["searchApiConfig"] = searchApiConfig.toJSON()
        }
        if chapterMode == .api || !chapterApiConfig.request.url.isEmpty {
            object["chapterApiConfig"] = chapterApiConfig.toJSON()
        }
        object["antiCrawlerConfig"] = antiCrawlerConfig.toJSON()
        return .object(object)
    }

    var usesApiSearch: Bool { searchMode == .api }

    /// 对应 `int.parse(api) > ApiEndpoints.apiLevel`；api 非数字时视为兼容。
    var requiresNewerClient: Bool {
        guard let level = Int(api.trimmingCharacters(in: .whitespaces)) else { return false }
        return level > KazumiAppInfo.ruleAPILevel
    }

    /// 播放与下载最终媒体时使用的请求头。
    func buildHttpHeaders() -> [String: String] {
        var headers = ["user-agent": userAgent.isEmpty ? HTTPHeaders.randomUserAgent() : userAgent]
        if !referer.isEmpty { headers["referer"] = referer }
        return headers
    }
}
