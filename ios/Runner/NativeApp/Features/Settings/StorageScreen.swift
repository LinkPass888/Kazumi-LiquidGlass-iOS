//
//  StorageScreen.swift
//  Kazumi
//
//  存储与日志，对应 lib/pages/settings/storage_settings.dart：
//  * 缓存：显示图片缓存占用，可一键清除（下次加载重新下载）；
//  * 诊断：进入运行日志。
//
//  原版的「清除图片缓存」在清完后会重新统计一次大小，这里同样在清空后
//  重算，避免界面停在旧的 MB 数上。
//

import SwiftUI

struct StorageScreen: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    @State private var cacheBytes: Int?
    @State private var isClearing = false
    @State private var isConfirmingClear = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Button {
                    isConfirmingClear = true
                } label: {
                    HStack(spacing: 12) {
                        Label("清除图片缓存", systemImage: "photo.on.rectangle.angled")
                        Spacer()
                        Text(cacheDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isClearing)
            } header: {
                Text("缓存")
            } footer: {
                Text("图片会在下次加载时重新下载。视频、记录与设置不会删除。")
            }

            Section {
                Button {
                    router.push(.logs)
                } label: {
                    HStack {
                        Label("运行日志", systemImage: "doc.text.magnifyingglass")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("诊断")
            }

            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("存储与日志")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .task { await refreshSize() }
        .confirmationDialog("清除图片缓存？", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("清除缓存", role: .destructive) {
                Task { await clear() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("图片会在下次加载时重新下载。视频、记录和设置不会删除。")
        }
    }

    private var cacheDescription: String {
        if isClearing { return "正在清除…" }
        guard let cacheBytes else { return "正在统计…" }
        return String(format: "%.2f MB", Double(cacheBytes) / (1024 * 1024))
    }

    private func refreshSize() async {
        cacheBytes = await KazumiImageLoader.shared.diskSizeInBytes()
    }

    private func clear() async {
        isClearing = true
        defer { isClearing = false }
        KazumiImageLoader.shared.clear()
        // 清空是异步的（后台删文件），等一会儿再统计，避免读到旧值。
        try? await Task.sleep(for: .milliseconds(300))
        await refreshSize()
        message = "图片缓存已清除"
    }
}
