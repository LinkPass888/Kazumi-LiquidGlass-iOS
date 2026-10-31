//
//  RulesRepoClient.swift
//  Kazumi
//
//  1:1 翻译 lib/request/clients/rules_repo_client.dart 与 dio_factory.dart 中的
//  _RulesMirrorInterceptor：规则目录默认走 raw.githubusercontent.com，
//  开启镜像后改写为 raw.gitcode.com 镜像。
//

import Foundation
import os

enum KazumiEndpoints {
    /// 规则仓库。
    static let pluginShop = "https://raw.githubusercontent.com/Predidit/KazumiRules/main/"

    /// 规则仓库镜像。
    static let pluginShopMirror = "https://raw.gitcode.com/gh_mirrors/ka/KazumiRules/raw/main/"
}

final class RulesRepoClient: Sendable {
    static let shared = RulesRepoClient()

    /// 由设置页写入；仅影响后续请求，与 interceptor 的即时读取行为一致。
    static let enableMirror = OSAllocatedUnfairLock(initialState: false)

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        KazumiNetworkPolicy.applyProxy(to: config)
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 24
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    /// 对应 RulesRepoClient.instance.getText。
    func getText(_ url: String) async throws -> String {
        let finalURL = Self.mirrored(url)
        var request = URLRequest(url: URL(string: finalURL) ?? URL(string: url) ?? KazumiAppInfo.projectURL)
        request.httpMethod = "GET"
        request.setValue(HTTPHeaders.randomUserAgent(), forHTTPHeaderField: "user-agent")
        KazumiLog.network.debug("Rules repo GET \(finalURL, privacy: .public)")
        do {
            let (data, response) = try await session.data(for: request)
            let body = String(data: data, encoding: .utf8) ?? ""
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NetworkError.badResponse(status: http.statusCode, body: body, headers: [:]) 
            }
            return body
        } catch let error as URLError {
            if error.code == .cancelled { throw NetworkError.cancelled }
            throw NetworkError.transport(error.localizedDescription)
        }
    }

    /// 对应 _RulesMirrorInterceptor：只改写规则仓库前缀。
    static func mirrored(_ url: String) -> String {
        guard enableMirror.withLock({ $0 }),
              url.hasPrefix(KazumiEndpoints.pluginShop) else { return url }
        return KazumiEndpoints.pluginShopMirror
            + url.dropFirst(KazumiEndpoints.pluginShop.count)
    }
}
