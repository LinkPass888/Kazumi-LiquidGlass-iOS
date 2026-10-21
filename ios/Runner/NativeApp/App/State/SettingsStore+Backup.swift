//
//  SettingsStore+Backup.swift
//  Kazumi
//
//  设置的导出 / 导入，对应 lib/pages/settings/backup_settings.dart。
//
//  原版的设置存在 Hive 的 settings box 里，键名就是下面 legacyKeys 的右列。
//  导出时用原版键名写，导入时原版键名与本地键名都认，
//  于是旧版（Flutter）导出的备份能原样导入这边。
//

import Foundation

extension SettingsStore {
    /// 本地键名 -> 原版（Hive）键名。
    private static let legacyKeys: [String: String] = [
        SettingsKey.webDAVURL: "webDavURL",
        SettingsKey.webDAVUser: "webDavUsername",
        SettingsKey.webDAVPassword: "webDavPasswd",
        SettingsKey.webDAVAutoSync: "webDavEnable",
        SettingsKey.bangumiSyncEnabled: "bangumiSyncEnable",
        SettingsKey.danmakuEnabled: "danmakuEnabledByDefault",
        SettingsKey.playSpeed: "defaultPlaySpeed",
        SettingsKey.proxyEnabled: "proxyEnable",
        SettingsKey.proxyHost: "proxyUrl",
        SettingsKey.updateNotificationEnabled: "bangumiUpdateNotifyEnable",
    ]

    /// 备份里使用的键名：有原版键名就用原版的。
    private static func backupKey(_ localKey: String) -> String {
        legacyKeys[localKey] ?? localKey
    }

    /// 当前设置的备份快照。
    ///
    /// `omitCredentials` 为 true 时跳过账号与密码，
    /// 对应原版「不含账号与密码」的导出范围。
    func backupSnapshot(omitCredentials: Bool) -> [String: JSONValue] {
        var pairs: [(String, JSONValue)] = [
            (Self.backupKey(SettingsKey.themeMode), .string(themeMode.rawValue)),
            (Self.backupKey(SettingsKey.themeColor), .string(themeColor.id)),
            (Self.backupKey(SettingsKey.oledEnhance), .bool(oledEnhance)),
            (Self.backupKey(SettingsKey.glassEnabled), .bool(glassEnabled)),
            (Self.backupKey(SettingsKey.autoPlayNext), .bool(autoPlayNext)),
            (Self.backupKey(SettingsKey.autoSkipOpEd), .bool(autoSkipOpEd)),
            (Self.backupKey(SettingsKey.danmakuEnabled), .bool(danmakuEnabled)),
            (Self.backupKey(SettingsKey.danmakuOpacity), .double(danmakuOpacity)),
            (Self.backupKey(SettingsKey.danmakuFontSize), .double(danmakuFontSize)),
            (Self.backupKey(SettingsKey.danmakuArea), .double(danmakuArea)),
            (Self.backupKey(SettingsKey.playSpeed), .double(playSpeed)),
            (Self.backupKey(SettingsKey.playerEntryFullscreen), .bool(playerEntryFullscreen)),
            (Self.backupKey(SettingsKey.meteredNetworkLimit), .bool(meteredNetworkLimit)),
            (Self.backupKey(SettingsKey.updateNotificationEnabled), .bool(updateNotificationEnabled)),
        ]
        if !omitCredentials {
            pairs += [
                (Self.backupKey(SettingsKey.webDAVURL), .string(webDAVURL)),
                (Self.backupKey(SettingsKey.webDAVUser), .string(webDAVUser)),
                (Self.backupKey(SettingsKey.webDAVPassword), .string(webDAVPassword)),
                (Self.backupKey(SettingsKey.webDAVAutoSync), .bool(webDAVAutoSync)),
                (Self.backupKey(SettingsKey.bangumiAccessToken), .string(bangumiAccessToken)),
                (Self.backupKey(SettingsKey.bangumiUsername), .string(bangumiUsername)),
                (Self.backupKey(SettingsKey.bangumiSyncEnabled), .bool(bangumiSyncEnabled)),
                (Self.backupKey(SettingsKey.danmakuShieldSyncEnabled), .bool(danmakuShieldSyncEnabled)),
                (Self.backupKey(SettingsKey.proxyEnabled), .bool(proxyEnabled)),
                (Self.backupKey(SettingsKey.proxyHost), .string(proxyHost)),
                (Self.backupKey(SettingsKey.proxyPort), .int(proxyPort)),
            ]
        }
        var result: [String: JSONValue] = [:]
        for (key, value) in pairs {
            result[key] = value
        }
        return result
    }

    /// 从备份里恢复设置，返回真正恢复的项数。
    ///
    /// 备份里可能同时出现原版键名与本地键名，原版键名优先。
    @discardableResult
    func applyBackup(_ settings: [String: JSONValue]) -> Int {
        func value(_ localKey: String) -> JSONValue? {
            if let legacy = Self.legacyKeys[localKey], let value = settings[legacy] {
                return value
            }
            return settings[localKey]
        }

        var restored = 0
        if let raw = value(SettingsKey.themeMode)?.stringValue,
           let mode = KazumiThemeMode(rawValue: raw) {
            themeMode = mode
            restored += 1
        }
        if let raw = value(SettingsKey.themeColor)?.stringValue, !raw.isEmpty {
            themeColor = KazumiThemeColor.named(raw)
            restored += 1
        }
        if let flag = value(SettingsKey.oledEnhance)?.boolValue {
            oledEnhance = flag
            restored += 1
        }
        if let flag = value(SettingsKey.glassEnabled)?.boolValue {
            glassEnabled = flag
            restored += 1
        }
        if let flag = value(SettingsKey.autoPlayNext)?.boolValue {
            autoPlayNext = flag
            restored += 1
        }
        if let flag = value(SettingsKey.autoSkipOpEd)?.boolValue {
            autoSkipOpEd = flag
            restored += 1
        }
        if let flag = value(SettingsKey.danmakuEnabled)?.boolValue {
            danmakuEnabled = flag
            restored += 1
        }
        if let number = value(SettingsKey.danmakuOpacity)?.doubleValue {
            danmakuOpacity = number
            restored += 1
        }
        if let number = value(SettingsKey.danmakuFontSize)?.doubleValue {
            danmakuFontSize = number
            restored += 1
        }
        if let number = value(SettingsKey.danmakuArea)?.doubleValue {
            danmakuArea = number
            restored += 1
        }
        if let number = value(SettingsKey.playSpeed)?.doubleValue {
            playSpeed = number
            restored += 1
        }
        if let flag = value(SettingsKey.playerEntryFullscreen)?.boolValue {
            playerEntryFullscreen = flag
            restored += 1
        }
        if let flag = value(SettingsKey.meteredNetworkLimit)?.boolValue {
            meteredNetworkLimit = flag
            restored += 1
        }
        if let flag = value(SettingsKey.updateNotificationEnabled)?.boolValue {
            updateNotificationEnabled = flag
            restored += 1
        }
        if let text = value(SettingsKey.webDAVURL)?.stringValue {
            webDAVURL = text
            restored += 1
        }
        if let text = value(SettingsKey.webDAVUser)?.stringValue {
            webDAVUser = text
            restored += 1
        }
        if let text = value(SettingsKey.webDAVPassword)?.stringValue {
            webDAVPassword = text
            restored += 1
        }
        if let flag = value(SettingsKey.webDAVAutoSync)?.boolValue {
            webDAVAutoSync = flag
            restored += 1
        }
        if let text = value(SettingsKey.bangumiAccessToken)?.stringValue {
            bangumiAccessToken = text
            restored += 1
        }
        if let text = value(SettingsKey.bangumiUsername)?.stringValue {
            bangumiUsername = text
            restored += 1
        }
        if let flag = value(SettingsKey.bangumiSyncEnabled)?.boolValue {
            bangumiSyncEnabled = flag
            restored += 1
        }
        if let flag = value(SettingsKey.danmakuShieldSyncEnabled)?.boolValue {
            danmakuShieldSyncEnabled = flag
            restored += 1
        }
        if let flag = value(SettingsKey.proxyEnabled)?.boolValue {
            proxyEnabled = flag
            restored += 1
        }
        if let text = value(SettingsKey.proxyHost)?.stringValue {
            proxyHost = text
            restored += 1
        }
        if let number = value(SettingsKey.proxyPort)?.intValue {
            proxyPort = number
            restored += 1
        }
        return restored
    }
}