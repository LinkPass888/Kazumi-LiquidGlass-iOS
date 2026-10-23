//
//  WebDAVScreen.swift
//  Kazumi
//
//  设置 →「账号与备份」→「WebDAV 备份」（二级页）。这一版仍是整包模型：
//  服务器地址 / 用户名 / 密码，加上整包备份与恢复（立即备份 / 从备份恢复 / 测试连接）。
//
//  追番账号与令牌只在 BangumiAccountScreen 一处输入，本页不再重复；
//  设置备份也只留在「账号与备份」主页，本页不再提供入口。
//  「同步追番状态」「同步弹幕屏蔽规则」「自动同步」三个开关的键没有消费者，
//  已经从界面撤掉（设置属性本身不删，避免破坏旧备份的恢复）。
//

import SwiftUI

struct WebDAVScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(\.colorScheme) private var colorScheme

    @State private var statusMessage: String?
    @State private var isBusy = false
    @State private var isConfirmingRestore = false

    var body: some View {
        Form {
            Section {
                TextField("https://dav.example.com/", text: webDAVURLBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                TextField("用户名", text: webDAVUserBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("密码", text: webDAVPasswordBinding)
            } header: {
                Text("服务器")
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
        }
        .navigationTitle("WebDAV 备份")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .confirmationDialog("恢复会覆盖本机现有的追番、观看历史与屏蔽词，确定继续？", isPresented: $isConfirmingRestore, titleVisibility: .visible) {
            Button("覆盖恢复", role: .destructive) {
                Task { await restore() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 绑定

    private var webDAVURLBinding: Binding<String> {
        Binding(get: { settings.webDAVURL }, set: { settings.webDAVURL = $0 })
    }

    private var webDAVUserBinding: Binding<String> {
        Binding(get: { settings.webDAVUser }, set: { settings.webDAVUser = $0 })
    }

    private var webDAVPasswordBinding: Binding<String> {
        Binding(get: { settings.webDAVPassword }, set: { settings.webDAVPassword = $0 })
    }

    private var isConfigured: Bool {
        !settings.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 屏蔽词条数：一行一条，空行不算。
    private func ruleCount(_ text: String) -> Int {
        text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
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
                history: library.history,
                danmakuRules: settings.danmakuFilterRulesText
            )
            try await WebDAVClient(settings: settings).uploadAndVerify(payload)
            statusMessage = "备份完成：\(library.entries.count) 部追番 / \(library.history.count) 条观看历史 / \(ruleCount(payload.danmakuRules)) 条屏蔽词"
            KazumiLogBuffer.network("WebDAV 备份完成（已读回核对）")
        } catch {
            statusMessage = "备份没有完成。原因记在「存储与日志」的「运行日志」里。"
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
            settings.danmakuFilterRulesText = payload.danmakuRules
            statusMessage = "恢复完成：\(payload.entries.count) 部追番 / \(payload.history.count) 条观看历史 / \(ruleCount(payload.danmakuRules)) 条屏蔽词"
            KazumiLogBuffer.network("WebDAV 恢复完成")
        } catch {
            statusMessage = "恢复没有完成。原因记在「存储与日志」的「运行日志」里。"
            KazumiLogBuffer.network("WebDAV 恢复失败：\(error.localizedDescription)")
        }
    }
}

