//
//  SettingsBackupScreen.swift
//  Kazumi
//
//  设置备份页，1:1 对应 lib/pages/settings/backup_settings.dart：
//  * 导出：可选范围（全部设置 / 不含账号与密码），复制一段备份文本到剪贴板；
//  * 导入：从剪贴板读回备份文本并恢复。
//
//  备份文本的格式与旧版（Flutter）完全一致，因此旧版导出的备份能直接粘回来。
//

import SwiftUI
import UIKit

struct SettingsBackupScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme

    /// 是否跳过账号与密码（默认跳过，与原版一致）。
    @State private var omitCredentials = true
    @State private var isBusy = false
    @State private var message: String?
    @State private var pendingPayload: SettingsBackup.Payload?
    @State private var isShowingConfirm = false

    var body: some View {
        Form {
            Section("导出") {
                Toggle("不含账号与密码", isOn: $omitCredentials)
                Text(omitCredentials
                     ? "跳过追番同步、WebDAV、代理等凭据，其余设置照常恢复。"
                     : "包含同步账号、WebDAV 与代理密码，请只存放在自己可信的地方。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    export()
                } label: {
                    Label("导出到剪贴板", systemImage: "doc.on.clipboard")
                }
                .disabled(isBusy)
            }

            Section {
                Button {
                    importFromClipboard()
                } label: {
                    Label("从剪贴板恢复", systemImage: "square.and.arrow.down")
                }
                .disabled(isBusy)
            } header: {
                Text("导入")
            } footer: {
                Text("备份只包含应用设置。追番列表、观看记录、下载与播放器日志不会导出，请用 WebDAV 同步另行备份。")
            }

            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("设置备份")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .confirmationDialog("恢复设置", isPresented: $isShowingConfirm, titleVisibility: .visible) {
            Button("恢复设置") { applyPending() }
            Button("取消", role: .cancel) { pendingPayload = nil }
        } message: {
            Text("恢复后会覆盖当前的应用设置。备份里如果包含账号或代理密码，恢复后请到同步设置里确认凭据仍然有效。")
        }
    }

    // MARK: - 行为

    private func export() {
        let snapshot = settings.backupSnapshot(omitCredentials: omitCredentials)
        guard !snapshot.isEmpty else {
            message = "没有可导出的设置"
            return
        }
        UIPasteboard.general.string = SettingsBackup.encode(snapshot)
        message = "已复制 \(snapshot.count) 项设置到剪贴板，建议粘贴到备忘录保存"
    }

    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            message = "剪贴板是空的，请先复制设置备份内容"
            return
        }
        do {
            let payload = try SettingsBackup.decode(text)
            guard payload.count > 0 else {
                message = "备份里没有可恢复的设置"
                return
            }
            pendingPayload = payload
            isShowingConfirm = true
        } catch {
            message = error.localizedDescription
        }
    }

    private func applyPending() {
        guard let payload = pendingPayload else { return }
        pendingPayload = nil
        let count = settings.applyBackup(payload.settings)
        message = "已恢复 \(count) 项设置"
    }
}