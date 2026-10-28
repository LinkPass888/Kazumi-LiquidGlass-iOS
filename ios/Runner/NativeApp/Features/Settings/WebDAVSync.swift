//
//  WebDAVSync.swift
//  Kazumi
//
//  设置 →「同步设置」→「多设备同步」的同步引擎。
//
//  和「立即备份 / 从备份恢复」那条整包路径分开：整包是「这台机器盖掉那台」，
//  同步是「两边合成一份」——先把云盘上那份读回来，按内容逐类合并，
//  再把合并结果写回去，最后只把开着的两类写回本机。
//
//  合并规则：
//  · 观看记录、收藏都以番剧 ID 为主键，同一条留 `updatedAt` 新的那份；
//  · 弹幕屏蔽词是文本，两边按行求并集，本机的顺序在前，云盘多出来的接在后面。
//
//  关掉的那一类不拉、不写本机，写回云盘时也原样用云盘那份，
//  免得「只开了观看记录」把云盘上的收藏冲成空。
//

import Foundation

@MainActor
enum WebDAVSync {
    enum Content: String, CaseIterable, Sendable {
        case history
        case collect
        case shield

        /// 屏上那行标题，跟原版一致。
        var rowTitle: String {
            switch self {
            case .history: "观看记录"
            case .collect: "收藏"
            case .shield: "弹幕屏蔽词"
            }
        }

        /// 同步做完给用户看的那一句。
        var doneMessage: String {
            switch self {
            case .history: "观看记录已同步"
            case .collect: "收藏已同步"
            case .shield: "弹幕屏蔽词已同步"
            }
        }

        var runningMessage: String {
            switch self {
            case .history: "正在同步观看记录…"
            case .collect: "正在同步收藏…"
            case .shield: "正在同步弹幕屏蔽词…"
            }
        }
    }

    struct Outcome: Sendable {
        var ok: Bool
        /// 屏上那句。
        var message: String
        /// 进运行日志那句，带技术原文。
        var log: String
        /// 同步结果里第二行那串数字；空串表示没什么可写的。
        var summary: String = ""
    }

    /// 同步中途那一行报给屏上的进度。`total` 为 0 时不画进度条。
    struct ProgressEvent: Sendable {
        var text: String
        var current: Int
        var total: Int
    }

    /// 这台机器上被打开的内容。
    static func enabledContents(_ settings: SettingsStore) -> [Content] {
        var contents: [Content] = []
        if settings.webDavEnableHistory { contents.append(.history) }
        if settings.webDavEnableCollect { contents.append(.collect) }
        if settings.webDavEnableDanmakuShield { contents.append(.shield) }
        return contents
    }

    /// 合并一轮：读云盘 → 逐类合并 → 写回 → 只把开着的那几类落到本机。
    static func sync(
        _ contents: [Content],
        settings: SettingsStore,
        library: LibraryStore,
        progress: (@MainActor (ProgressEvent) -> Void)? = nil
    ) async -> Outcome {
        guard !contents.isEmpty else {
            return Outcome(ok: true, message: "", log: "")
        }
        guard !settings.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Outcome(ok: false, message: "先填 WebDAV 地址", log: "同步跳过：没配地址")
        }

        let client = WebDAVClient(settings: settings)
        progress?(ProgressEvent(text: "正在读取云盘…", current: 0, total: 0))
        let remote: WebDAVClient.Payload?
        /// 云盘上那份是空的（0 字节）：当作还没备份，这次上传会把它覆盖掉。
        /// 空文件里没有任何数据，覆盖它不会丢掉任何东西。
        var cloudBackupWasEmpty = false
        do {
            remote = try await client.download()
        } catch WebDAVClient.WebDAVError.notFound, WebDAVClient.WebDAVError.badStatus(404) {
            // 云盘上还没有这份文件：当作空的一份，这次同步就是第一次上传。
            //
            // 必须接 .notFound：客户端把 404 翻成了这一句（WebDAVClient.validate），
            // 只接 badStatus(404) 会漏掉，「第一次同步」永远报成网络失败。
            remote = nil
        } catch WebDAVClient.WebDAVError.emptyBackup {
            // 文件在，但是 0 字节。跟「还没有备份」一样处理：本机有数据就上传一份。
            cloudBackupWasEmpty = true
            remote = nil
        } catch {
            return Outcome(
                ok: false,
                message: "同步没能完成：\(Self.friendlyText(error))",
                log: "同步读云盘失败：\(Self.technicalText(error))"
            )
        }

        let localRules = settings.danmakuFilterRulesText
        var history = remote?.history ?? []
        var entries = remote?.entries ?? []
        var rules = remote?.danmakuRules ?? ""

        // 云盘上还留着原版 Flutter 写的那几份（LP 2026-10-25：换过来以后老数据得合进来）。
        // 它们不是本端的包，只能按各自格式读一遍；读不出来的当没有，不挡这次同步。
        var legacyHistoryCount = 0
        var legacyRules: [String] = []
        // 云盘上那份原版快照读到了没有：没读到就不许写回，
        // 否则一次网络抖动就会把云盘上的老记录冲成本机这几条。
        var legacyHistoryRead = false
        var legacySnapshot: Data?
        if contents.contains(.history) {
            if let legacy = try? await WebDAVLegacy.history(client: client) {
                legacyHistoryRead = true
                legacySnapshot = legacy.raw
                legacyHistoryCount = legacy.records.count
                history = mergeHistory(local: library.history, remote: history + legacy.records)
            } else {
                history = mergeHistory(local: library.history, remote: history)
            }
        } else {
            history = remote?.history ?? library.history
        }
        if contents.contains(.collect) {
            entries = mergeEntries(local: library.entries, remote: entries)
        } else {
            entries = remote?.entries ?? library.entries
        }
        if contents.contains(.shield) {
            legacyRules = (try? await WebDAVLegacy.shieldRules(client: client)) ?? []
            let cloudRules = legacyRules.isEmpty
                ? rules
                : mergeRules(local: rules, remote: legacyRules.joined(separator: "\n"))
            rules = mergeRules(local: localRules, remote: cloudRules)
        } else {
            rules = remote?.danmakuRules ?? localRules
        }

        progress?(ProgressEvent(text: "正在上传合并结果…", current: 0, total: 0))
        let payload = WebDAVClient.Payload(entries: entries, history: history, danmakuRules: rules)
        do {
            try await client.uploadAndVerify(payload)
        } catch {
            return Outcome(
                ok: false,
                message: "同步没能完成：\(Self.friendlyText(error))",
                log: "同步写云盘失败：\(Self.technicalText(error))"
            )
        }

        // 落到本机：开着的那几类用合并结果，没开的原样不动。
        let localEntries = contents.contains(.collect) ? entries : library.entries
        let localHistory = contents.contains(.history) ? history : library.history
        library.replace(entries: localEntries, history: localHistory)
        if contents.contains(.shield) {
            settings.danmakuFilterRulesText = rules
        }

        // 写回原版那几份（LP 2026-10-25：历史与屏蔽词要支持读写，旧版得读到新记录）。
        var writeBackError: String?
        if contents.contains(.history), legacyHistoryRead {
            do {
                try await WebDAVLegacy.writeHistory(
                    history,
                    existing: legacySnapshot,
                    client: client
                ) { current, total in
                    progress?(ProgressEvent(
                        text: "正在写回原版观看记录 · \(current) / \(total)",
                        current: current,
                        total: total
                    ))
                }
            } catch {
                writeBackError = Self.technicalText(error)
            }
        }
        if contents.contains(.shield) {
            // 只写本机那一份，别的设备的文件一概不碰 —— 这个不用等读成功，
            // 写坏了也只影响本机这一份。
            do {
                try await WebDAVLegacy.writeShield(
                    Self.ruleLines(rules),
                    deviceID: settings.webDAVDeviceID,
                    client: client
                )
            } catch {
                writeBackError = Self.technicalText(error)
            }
        }

        var summaryParts: [String] = []
        if contents.contains(.history) { summaryParts.append("观看记录 \(history.count) 条") }
        if contents.contains(.collect) { summaryParts.append("收藏 \(entries.count) 部") }
        if contents.contains(.shield) { summaryParts.append("屏蔽词 \(Self.ruleCount(rules)) 条") }
        let summary = summaryParts.joined(separator: " · ")

        let counts = "观看记录 \(library.history.count) 条 / 收藏 \(library.entries.count) 部 / 屏蔽词 \(Self.ruleCount(rules)) 条"
        let legacy = legacyHistoryCount > 0 || !legacyRules.isEmpty
            ? "；原版旧数据：历史 \(legacyHistoryCount) 条、屏蔽词 \(legacyRules.count) 条"
            : ""
        if let writeBackError {
            return Outcome(
                ok: false,
                message: "已同步，但没能写回旧版格式：\(writeBackError)",
                log: "多设备同步完成但写回原版格式失败（\(counts)\(legacy)）：\(writeBackError)",
                summary: "\(summary) · 写回旧版格式失败"
            )
        }
        let base = contents.count == 1 ? contents[0].doneMessage : "同步完成"
        // 云盘上原来那份是空的：说一句，别让他继续以为云上一直存着一份。
        let message = cloudBackupWasEmpty
            ? "\(base)（云盘上原来那份是空的，已用这次的结果覆盖）"
            : base
        return Outcome(
            ok: true,
            message: message,
            log: "多设备同步完成（\(counts)\(legacy)\(cloudBackupWasEmpty ? "；云盘原文件为 0 字节，已覆盖" : "")",
            summary: summary
        )
    }

    // MARK: - 合并

    private static func mergeHistory(local: [WatchRecord], remote: [WatchRecord]) -> [WatchRecord] {
        var byID: [Int: WatchRecord] = [:]
        for record in remote { byID[record.bangumiID] = record }
        for record in local {
            if let kept = byID[record.bangumiID], kept.updatedAt >= record.updatedAt { continue }
            byID[record.bangumiID] = record
        }
        return byID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 收藏：本机的顺序留着（用户摆过的分类顺序），云盘上多出来的接在后面。
    private static func mergeEntries(local: [LibraryEntry], remote: [LibraryEntry]) -> [LibraryEntry] {
        var remoteByID: [Int: LibraryEntry] = [:]
        for entry in remote { remoteByID[entry.id] = entry }

        var merged: [LibraryEntry] = []
        var seen = Set<Int>()
        for entry in local {
            seen.insert(entry.id)
            if let other = remoteByID[entry.id], other.updatedAt > entry.updatedAt {
                merged.append(other)
            } else {
                merged.append(entry)
            }
        }
        for entry in remote where !seen.contains(entry.id) {
            merged.append(entry)
        }
        return merged
    }

    /// 屏蔽词：本机顺序在前，云盘多出来的行接在后面，重复的行只留一份。
    private static func mergeRules(local: String, remote: String) -> String {
        var lines: [String] = []
        var seen = Set<String>()
        for text in [local, remote] {
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, seen.insert(line).inserted else { continue }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func ruleCount(_ text: String) -> Int {
        text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    private static func ruleLines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func technicalText(_ error: Error) -> String {
        (error as? WebDAVClient.WebDAVError)?.logDescription ?? error.localizedDescription
    }

    /// 屏上那句话：能说清原因的就直说原因，只有真的是网络层出错才让人去查网络。
    ///
    /// 以前这两个 catch 都只写「请检查网络或服务器配置」，可最常遇到的两种失败
    /// 都跟网络无关（云盘上文件是空的、格式对不上），等于把问题直接推给用户。
    static func friendlyText(_ error: Error) -> String {
        if let webdav = error as? WebDAVClient.WebDAVError {
            return webdav.errorDescription ?? "云盘读写失败。"
        }
        if error is URLError {
            return "连不上服务器，请检查网络或服务器地址。"
        }
        return error.localizedDescription
    }
}
