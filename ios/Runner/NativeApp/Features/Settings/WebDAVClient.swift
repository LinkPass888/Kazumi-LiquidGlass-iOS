//
//  WebDAVClient.swift
//  Kazumi
//
//  对应 lib/services/sync/webdav.dart 的必要子集：
//  * 目录固定为 <服务器>/Kazumi/，备份文件 kazumi_backup.json；
//  * 上传前先确保目录存在（MKCOL，已存在则忽略 405）；
//  * 使用 Basic 认证，凭据来自 SettingsStore。
//

import Foundation

@MainActor
struct WebDAVClient {
    /// 与 Flutter 版一致的同步根目录。
    ///
    /// 原版的服务端布局（见 lib/services/sync/webdav.dart:16-20）：
    ///   /kazumiSync/collectibles.tmp               追番收藏（Hive 箱文件）
    ///   /kazumiSync/collectchanges.tmp             收藏变更队列
    ///   /kazumiSync/histories.tmp                  旧版观看记录
    ///   /kazumiSync/history/snapshot.json          观看记录快照
    ///   /kazumiSync/history/changes/<设备>.jsonl    观看记录事件日志
    ///   /kazumiSync/danmakuShield/<设备>.json       弹幕屏蔽词
    ///
    /// 本端只实现「整包备份」这一个子集：往同一个根目录写
    /// `kazumi_backup.json`。两边目录同名、文件不同名也不同格式，因此
    /// **互不识别** —— 不过也不会互相干扰：原版读根目录时按文件名精确匹配
    /// （webdav.dart:203-207 只找 collectibles.tmp / collectchanges.tmp），
    /// 多出这个文件既不会被解析，也不会让同步报错。
    static let directoryName = "kazumiSync"
    static let backupFileName = "kazumi_backup.json"

    struct Payload: Codable, Sendable {
        var version: Int = 1
        var exportedAt: Date = Date()
        var entries: [LibraryEntry]
        var history: [WatchRecord]
    }

    enum WebDAVError: Error, LocalizedError {
        case notConfigured
        case invalidURL(String)
        case unauthorized
        /// 服务器上还没有备份文件（首次使用）。
        case notFound
        case badStatus(Int)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "请先填写 WebDAV 服务器地址"
            case .invalidURL(let url): "WebDAV 地址无效：\(url)"
            case .unauthorized: "认证失败，请检查用户名与密码"
            case .notFound: "服务器上还没有备份，先点「立即备份」上传一份"
            case .badStatus(let status): "服务器返回 HTTP \(status)"
            case .decoding(let message): message
            }
        }
    }

    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func upload(_ payload: Payload) async throws {
        let folder = try folderURL()
        try await ensureDirectory(folder)
        let target = folder.appending(path: Self.backupFileName)
        var request = try authorizedRequest(url: target, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try Self.encoder().encode(payload)
        let (_, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response)
    }

    func download() async throws -> Payload {
        let target = try folderURL().appending(path: Self.backupFileName)
        let request = try authorizedRequest(url: target, method: "GET")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response)
        do {
            return try Self.decoder().decode(Payload.self, from: data)
        } catch {
            throw WebDAVError.decoding("备份文件解析失败：\(error.localizedDescription)")
        }
    }

    /// 连通性检查：对应原版 `WebDav().ping()`。
    ///
    /// 只做一次根目录的 PROPFIND，不发任何写请求，
    /// 用来在填完地址后先确认「地址 / 账号 / 密码」这三样是对的。
    func ping() async throws {
        let raw = settings.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw WebDAVError.notConfigured }
        guard var url = URL(string: raw) else { throw WebDAVError.invalidURL(raw) }
        if !url.absoluteString.hasSuffix("/") {
            url.append(path: "")
        }
        var request = try authorizedRequest(url: url, method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "depth")
        request.setValue("application/xml", forHTTPHeaderField: "content-type")
        let (_, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response)
    }

    // MARK: - 内部

    private func folderURL() throws -> URL {
        let raw = settings.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw WebDAVError.notConfigured }
        guard var base = URL(string: raw) else { throw WebDAVError.invalidURL(raw) }
        if !base.absoluteString.hasSuffix("/") {
            base.append(path: "")
        }
        return base.appending(path: Self.directoryName, directoryHint: .isDirectory)
    }

    /// MKCOL 建目录。
    ///
    /// 已存在时各家的返回并不统一：RFC 4918 规定是 405，
    /// 也有服务器返回 301 / 409，还有直接回 204 的 —— 这些都算「目录已在」，
    /// 不能当成失败上报（否则第一次之后每次备份都报错）。
    private func ensureDirectory(_ url: URL) async throws {
        var request = try authorizedRequest(url: url, method: "MKCOL")
        request.setValue("0", forHTTPHeaderField: "content-length")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300, 301, 405, 409:
            return
        default:
            try Self.validate(response)
        }
    }

    private func authorizedRequest(url: URL, method: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        let user = settings.webDAVUser.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty {
            let token = Data("\(user):\(settings.webDAVPassword)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "authorization")
        }
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300, 201, 204:
            return
        case 401, 403:
            throw WebDAVError.unauthorized
        case 404:
            // 首次使用时目录或备份文件还不存在，这不是网络故障，
            // 要给用户一句能照着做的话，而不是「服务器返回 HTTP 404」。
            throw WebDAVError.notFound
        default:
            throw WebDAVError.badStatus(http.statusCode)
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
