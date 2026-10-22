//
//  WebDAVScreen.swift
//  Kazumi
//
//  同步备份，对应 lib/pages/settings/sync/sync_settings_page.dart 的分组：
//  * 追番同步（Bangumi）：开关、账号与令牌；
//  * 多设备同步（WebDAV）：服务器地址、账号密码、立即备份 / 从备份恢复；
//  * 应用设置：跳到「设置备份」，用文本在设备间搬运设置。
//
//  原版把这三块放在同一页里并列，用户不必猜「同步」和「设置备份」的区别。
//

import SwiftUI

struct WebDAVScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    @State private var statusMessage: String?
    @State private var isBusy = false
    @State private var isConfirmingRestore = false

    var body: some View {
        Form {
            Section {
                Toggle("同步追番状态", isOn: bangumiSyncBinding)
                TextField("Bangumi 用户名", text: bangumiUsernameBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Bangumi 访问令牌", text: bangumiTokenBinding)
                Toggle("同步弹幕屏蔽规则", isOn: shieldSyncBinding)
            } header: {
                Text("追番同步 · Bangumi")
            } footer: {
                Text("与 Bangumi 保持相同的追番状态（想看 / 在看 / 看过 / 搁置 / 抛弃），并可同步弹幕屏蔽词。")
            }

            Section {
                TextField("https://dav.example.com/", text: webDAVURLBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                TextField("用户名", text: webDAVUserBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("密码", text: webDAVPasswordBinding)

                Toggle("自动同步", isOn: webDAVAutoSyncBinding)
            } header: {
                Text("多设备同步 · WebDAV")
            } footer: {
                Text("备份内容：追番收藏与观看记录。服务器上保存在 kazumiSync/kazumi_backup.json，与 Flutter 版使用同一个同步目录，可直接互通。")
            }

            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    Label("测试连接", systemImage: "network")
                }
                .disabled(isBusy || !isConfigured)

                Button {
                    Task { await backup() }
                } label: {
                    Label("立即备份", systemImage: "icloud.and.arrow.up")
                }
                .disabled(isBusy || !isConfigured)

                Button {
                    isConfirmingRestore = true
                } label: {
                    Label("从备份恢复", systemImage: "icloud.and.arrow.down")
                }
                .disabled(isBusy || !isConfigured)
            } header: {
                Text("备份与恢复")
            } footer: {
                Text("「测试连接」只发一次只读请求，确认地址与账号可用；不会写入任何内容。")
            }

            if let statusMessage {
                Section("状态") {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    router.push(.settingsBackup)
                } label: {
                    Label("设置备份", systemImage: "arrow.triangle.2.circlepath")
                }
            } header: {
                Text("应用设置")
            } footer: {
                Text("把应用设置导出成一段文本，在另一台设备上粘贴回来即可恢复。")
            }
        }
        .navigationTitle("同步备份")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .confirmationDialog("恢复会覆盖本机现有收藏与历史，确定继续？", isPresented: $isConfirmingRestore, titleVisibility: .visible) {
            Button("覆盖恢复", role: .destructive) {
                Task { await restore() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 绑定

    private var bangumiSyncBinding: Binding<Bool> {
        Binding(get: { settings.bangumiSyncEnabled }, set: { settings.bangumiSyncEnabled = $0 })
    }

    private var bangumiUsernameBinding: Binding<String> {
        Binding(get: { settings.bangumiUsername }, set: { settings.bangumiUsername = $0 })
    }

    private var bangumiTokenBinding: Binding<String> {
        Binding(get: { settings.bangumiAccessToken }, set: { settings.bangumiAccessToken = $0 })
    }

    private var shieldSyncBinding: Binding<Bool> {
        Binding(
            get: { settings.danmakuShieldSyncEnabled },
            set: { settings.danmakuShieldSyncEnabled = $0 }
        )
    }

    private var webDAVURLBinding: Binding<String> {
        Binding(get: { settings.webDAVURL }, set: { settings.webDAVURL = $0 })
    }

    private var webDAVUserBinding: Binding<String> {
        Binding(get: { settings.webDAVUser }, set: { settings.webDAVUser = $0 })
    }

    private var webDAVPasswordBinding: Binding<String> {
        Binding(get: { settings.webDAVPassword }, set: { settings.webDAVPassword = $0 })
    }

    private var webDAVAutoSyncBinding: Binding<Bool> {
        Binding(get: { settings.webDAVAutoSync }, set: { settings.webDAVAutoSync = $0 })
    }

    private var isConfigured: Bool {
        !settings.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 备份 / 恢复

    private func testConnection() async {
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        do {
            try await WebDAVClient(settings: settings).ping()
            statusMessage = "连接正常，可以备份或恢复"
            KazumiLogBuffer.network("WebDAV 连接测试通过")
        } catch {
            statusMessage = "连接失败：\(error.localizedDescription)"
            KazumiLogBuffer.network("WebDAV 连接测试失败：\(error.localizedDescription)")
        }
    }

    private func backup() async {
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        do {
            let payload = WebDAVClient.Payload(
                entries: library.entries,
                history: library.history
            )
            try await WebDAVClient(settings: settings).upload(payload)
            statusMessage = "备份完成：\(library.entries.count) 条收藏 / \(library.history.count) 条记录"
            KazumiLogBuffer.network("WebDAV 备份完成")
        } catch {
            statusMessage = "备份失败：\(error.localizedDescription)"
            KazumiLogBuffer.network("WebDAV 备份失败：\(error.localizedDescription)")
        }
    }

    private func restore() async {
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        do {
            let payload = try await WebDAVClient(settings: settings).download()
            library.replace(entries: payload.entries, history: payload.history)
            statusMessage = "恢复完成：\(payload.entries.count) 条收藏 / \(payload.history.count) 条记录"
            KazumiLogBuffer.network("WebDAV 恢复完成")
        } catch {
            statusMessage = "恢复失败：\(error.localizedDescription)"
            KazumiLogBuffer.network("WebDAV 恢复失败：\(error.localizedDescription)")
        }
    }
}

