//
//  WebDAVScreen.swift
//  Kazumi
//
//  对应 lib/pages/settings/sync/webdav 与 services/sync/webdav.dart：
//  * 配置服务器地址、用户名、密码；
//  * 备份文件固定放在 <服务器>/Kazumi/ 下的 kazumi_backup.json；
//  * 「立即备份」上传当前收藏与历史，「从备份恢复」下载并覆盖。
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
            Section("服务器") {
                TextField("https://dav.example.com/", text: Binding(
                    get: { settings.webDAVURL },
                    set: { settings.webDAVURL = $0 }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

                TextField("用户名", text: Binding(
                    get: { settings.webDAVUser },
                    set: { settings.webDAVUser = $0 }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                SecureField("密码", text: Binding(
                    get: { settings.webDAVPassword },
                    set: { settings.webDAVPassword = $0 }
                ))

                Toggle("自动同步", isOn: Binding(
                    get: { settings.webDAVAutoSync },
                    set: { settings.webDAVAutoSync = $0 }
                ))
            }

            Section("备份") {
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
            }

            if let statusMessage {
                Section("状态") {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("备份内容：追番收藏与观看记录。服务器上保存在 Kazumi/kazumi_backup.json，与 Flutter 版使用同一路径，可直接互通。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

    private var isConfigured: Bool {
        !settings.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 备份 / 恢复

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

