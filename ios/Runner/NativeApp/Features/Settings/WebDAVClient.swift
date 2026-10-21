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
    /// 与 Flutter 版一致的目录与文件名，保证两端可互相读取。
    static let directoryName = "Kazumi"
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
        case badStatus(Int)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "请先填写 WebDAV 服务器地址"
            case .invalidURL(let url): "WebDAV 地址无效：\(url)"
            case .unauthorized: "认证失败，请检查用户名与密码"
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

    /// MKCOL 建目录；已存在时服务器返回 405，视为成功。
    private func ensureDirectory(_ url: URL) async throws {
        var request = try authorizedRequest(url: url, method: "MKCOL")
        request.setValue("0", forHTTPHeaderField: "content-length")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 405 || (200..<300).contains(http.statusCode) { return }
        try Self.validate(response)
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
