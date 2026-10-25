//
//  SyncBackupScreen.swift
//  Kazumi
//
//  设置 → 账号与备份（主页）。
//
//  这一层只做两件事：
//    * 两路同步各一行，点进去才是配置页；主页只陈述当前状态，不在这里改配置；
//    * 设置备份直接在本页摊开（LP 690：不再开二级页），因为它不经过服务器，
//      和上面两路同步不是同一件事。
//
//  副标题不是装饰：只写服务名时，用户看不出这一行到底管什么，所以两行都带。
//  状态只从真实配置算，不写死；「连接异常」需要持久化上次检查结果（现在没有），
//  所以 Bangumi 账号这一行只有「未填写令牌 / 已保存令牌」两态。
//
//  ── 名字对照表（改一处必须同时看这张表）─────────────────────────────────────
//  这五处名字和它们下面三处说明是同一个事实的五个说法，翻一个就得翻全部：
//    1. 本页标题、本页在「我的」和「设置」列表里的行           现在：同步设置
//       LP 清单第八项就叫「同步设置」，Ato 2026-10-24 定：只改名，内容不动。
//       下面那组三件的条件针对的是「同步备份」与「多设备同步」这两个说法，
//       不是这一处——入口名随清单，行内还叫备份。
//    2. WebDAV 那一行的标题                                  现在：WebDAV 备份
//       1 与 2 改回「同步备份」「多设备同步」的条件是同一组三件齐：
//       WebDAV 按类型分件落地 + 全局总闸 + 自动推送。缺一件就不改，名字先停在备份。
//    3. WebDAV 页里的分组标题                                现在：服务器
//       这一处本来就是原版叫法，不跟着改回。
//    4. Bangumi 这一行与那一页的标题                          现在：Bangumi 账号
//    5. 追番页右上角那颗玻璃药丸                                现在：备份
//       4 与 5 必须同一版翻成「追番同步」「同步」，条件是「立即同步追番」真能跑。
//       只翻一个会出现「页名叫账号、里面却有同步按钮」那种错位。
//  随之要一起重写的三处说明（都在别处的文件里，不在这张页）：
//    * 本页第一行副标题（Bangumi 那一行小字）
//    * 「设置」列表里本页那行的说明
//    * 「我的」页里本页那行的副标题
//  它们现在都只提令牌和备份，页一改名就变成「站在门口读不到门里有什么」。
//  ─────────────────────────────────────────────────────────────────────
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SyncBackupScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme

    /// 是否跳过账号与密码（默认跳过，与主项目一致）。
    @State private var omitCredentials = true
    @State private var backupMessage: String?
    @State private var pendingPayload: SettingsBackup.Payload?
    @State private var isShowingRestoreConfirm = false
    /// 导出/导入文件用的状态。
    @State private var backupDocument: BackupFileDocument?
    @State private var backupExportName = ""
    @State private var isShowingBackupExporter = false
    @State private var isShowingBackupImporter = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    BangumiAccountScreen()
                } label: {
                    serviceRow(
                        title: "Bangumi 账号",
                        subtitle: "账号与访问令牌",
                        status: bangumiStatusText
                    )
                }

                // 这一轮 WebDAV 备份页还没有「启用 WebDAV」总闸与内容开关，
                // 所以状态只能报「地址有没有配」两态；
                // 规格里的「已开启 / 已关闭」「未选择内容」等分件版落地后再回来补齐。
                NavigationLink {
                    WebDAVScreen()
                } label: {
                    serviceRow(
                        title: "WebDAV 备份",
                        subtitle: "WebDAV 地址、备份与恢复",
                        status: webDAVStatusText
                    )
                }
            }

            Section {
                Toggle("不含账号与密码", isOn: $omitCredentials)

                // 开关只决定凭据带不带，不决定其余设置；这句把后果说清楚，
                // 免得用户以为打开开关之后追番和观看历史也会一起备份。
                Text(omitCredentials
                     ? "跳过追番同步、WebDAV、代理等凭据，其余设置照常恢复。"
                     : "包含同步账号、WebDAV 与代理密码，请只存放在自己可信的地方。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                // 两行两列（LP 在 Colo 那张卡上选的；Colo 规格 v7.20）：
                // 四个动作装进一个 List cell，导出、恢复各占一行。
                // 一行一个时这四个动作占 296 点，挤成两行两列实测 124 点，
                // 而且「导出」「恢复」一横行就分出来了。
                // 用 Grid 不用两层 HStack：某一格折成两行时，同行另一格跟着等高，
                // 边框不会一高一低（Colo 的规格）。列宽、行高都由 Grid 自己算。
                // 诊断版：临时换成两层 HStack，只用来分辨「按下时那套 Grid 排版」是不是元凶。
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        actionCell("导出到剪贴板", icon: "doc.on.clipboard") { exportBackup() }
                        actionCell("导出到文件", icon: "folder") { exportBackupToFile() }
                    }

                    // 分两件事说，不把已验证的结论和未验证的推测混在一起：
                    // 1. 卸载不会清空系统剪贴板。模拟器上验证过：写入一段标记文本，
                    //    卸载 App 后仍能读回。
                    // 2. 重装后 App 能不能读到这段内容，取决于系统的粘贴授权提示；
                    //    这一点尚未在真机上验证。
                    HStack(spacing: 8) {
                        actionCell("从剪贴板恢复", icon: "square.and.arrow.down") { importBackupFromClipboard() }
                        actionCell("从文件恢复", icon: "doc.badge.plus") { isShowingBackupImporter = true }
                    }
                }
                // 四个动作只交一次行留白：不压掉 44 点的手指尖，只把四道行留白减成一道。
                .listRowInsets(EdgeInsets(top: 15, leading: 16, bottom: 15, trailing: 16))

                // 结果单元格始终存在，只换文字：增删行会让整组高度跳动。
                // 还没操作时它只是一行空白（空格占位），不构成常驻提示。
                Text(backupMessage ?? " ")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("设置备份")
            } footer: {
                // 这句只说我们这边备份了什么：不写「云端也有一份」，
                // 否则用户会以为收藏已有备份，和真实的备份范围不符。
                Text("备份只包含应用设置。追番、观看历史、缓存与播放器日志不在备份里；账号与密码由导出时那个开关决定带不带。")
            }
        }
        // 这一页今天确实只做账号、WebDAV 备份与设置备份，没有任何自动同步，
        // 所以叫「账号与备份」而不是「同步备份」。只有等分件版同步、
        // 「启用 WebDAV」总闸与自动推送三件事都落地后，才改回「同步备份」。
        .navigationTitle("同步设置")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        // 恢复确认挂在 Form 上：行内挂零高度视图时弹不出来。
        .confirmationDialog("恢复这些设置？", isPresented: $isShowingRestoreConfirm, titleVisibility: .visible) {
            Button("恢复设置") { applyPendingBackup() }
            Button("取消", role: .cancel) { pendingPayload = nil }
        } message: {
            Text(restoreConfirmMessage)
        }
        .fileExporter(
            isPresented: $isShowingBackupExporter,
            document: backupDocument,
            contentType: .json,
            defaultFilename: backupExportName
        ) { result in
            switch result {
            case .success:
                backupMessage = "已导出到文件"
            case .failure(let error):
                backupMessage = "存不到这个位置，可能是空间不够，或者没有写入权限。"
            }
            backupDocument = nil
        }
        .fileImporter(
            isPresented: $isShowingBackupImporter,
            allowedContentTypes: [.json, .plainText]
        ) { result in
            switch result {
            case .success(let url):
                importBackupFromFile(url)
            case .failure(let error):
                backupMessage = "读不到这个文件，可能已被移动，或者没有访问权限。"
            }
        }
    }

    // MARK: - 服务行

    /// 一行服务：标题 + 副标题 +（可选）右侧状态。
    /// 箭头由 NavigationLink 自己给，再画一个会变成两个 chevron。
    private func serviceRow(title: String, subtitle: String, status: String? = nil) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let status {
                // 状态只陈述事实，不点也不变色；整行才是点击目标。
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .hitTarget44(alignment: .leading)
    }

    /// 与 Bangumi 账号页同一口径：令牌为空就是未填写，否则已保存。
    private var bangumiStatusText: String {
        settings.bangumiAccessToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? "未填写令牌" : "已保存令牌"
    }

    /// 与 Bangumi 账号行同一口径：去掉首尾空白后为空就是未配置。
    /// 「已开启 / 已关闭」「未选择内容」依赖总闸与内容开关，
    /// 这一轮 WebDAV 备份页还没有它们，等分件版落地再补。
    private var webDAVStatusText: String {
        settings.webDAVURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? "未配置" : "已保存地址"
    }

    // MARK: - 设置备份

    /// 一格动作。`.bordered` 是为了让四个动作在同一格里看得出各自的边界；
    /// `maxWidth: .infinity` 让可点区域铺满整个格子（以前只有文字那么宽，
    /// 点在行右侧空白上不会触发，看着像按不动）。
    private func actionCell(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // 用 HStack 而不是 Label：Label 的图标默认在整块文字里垂直居中，
            // 折成两行时图标会悬在中间；firstTextBaseline 让图标跟第一行齐。
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                // 图标钉 16 点，不跟着字号缩放：两列宽度一样，格子才对得齐。
                Image(systemName: icon)
                    .font(.system(size: 16))
                Text(title)
                    // 字号 Ato 定在 .body：去引号后五个字，375 点宽下还有余量，不降字号。
                    .font(.body)
                    // 挤不下时换行，不许截断：按钮上出现「导出到剪贴…」等于动作名少一半。
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    private func exportBackup() {
        let snapshot = settings.backupSnapshot(omitCredentials: omitCredentials)
        guard !snapshot.isEmpty else {
            backupMessage = "没有可导出的设置"
            return
        }
        UIPasteboard.general.string = SettingsBackup.encode(snapshot)
        backupMessage = "已复制 \(snapshot.count) 项设置到剪贴板"
    }

    private func importBackupFromClipboard() {
        backupMessage = nil
        // 直接读 `.string`：真机上这一步会由系统弹出粘贴授权，允许之后这次读取
        // 就拿到内容。以前这里借 `detectValues` 走同一套授权，但那个调用本身
        // 会把 App 打死——模拟器上点一次就原地回主屏，连空回调、不改任何状态
        // 都死（探针己验过），所以不再碰它。
        //
        // 下面三行日志是为了“点一下就退”这类崩溃：它们走 os.Logger，进系统
        // 日志，App 死了也还在。屏上的日志页是内存里的，崩了就没了。
        KazumiLogBuffer.network("剪贴板恢复：已按下，准备读剪贴板")
        guard let raw = UIPasteboard.general.string else {
            KazumiLogBuffer.network("剪贴板恢复：读到空（无内容或未授权）")
            backupMessage = Self.clipboardEmptyMessage
            return
        }
        KazumiLogBuffer.network("剪贴板恢复：读到 \(raw.count) 字")
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            backupMessage = Self.clipboardEmptyMessage
            return
        }
        acceptClipboardBackup(text)
    }

    /// 剪贴板和文件两条路共用同一套解码说法（Camo 的规则：同一样东西用同一个词）。
    /// 失败的措辞一律来自 SettingsBackup.BackupError，不在这里另造。
    private func acceptClipboardBackup(_ raw: String) {
        do {
            let payload = try SettingsBackup.decode(raw)
            guard payload.count > 0 else {
                backupMessage = Self.emptyBackupMessage
                return
            }
            pendingPayload = payload
            isShowingRestoreConfirm = true
        } catch {
            backupMessage = error.localizedDescription
        }
    }

    private static let clipboardEmptyMessage = "剪贴板里没有设置备份。先复制一段备份文本，或者改用从文件恢复。"
    private static let emptyBackupMessage = "备份里没有设置内容"

    private func applyPendingBackup() {
        guard let payload = pendingPayload else { return }
        pendingPayload = nil
        let count = settings.applyBackup(payload.settings)
        backupMessage = "已恢复 \(count) 项设置"
    }

    /// 导出到文件：内容与剪贴板那份完全一样，只是走文件系统。
    private func exportBackupToFile() {
        let snapshot = settings.backupSnapshot(omitCredentials: omitCredentials)
        guard !snapshot.isEmpty else {
            backupMessage = "没有可导出的设置"
            return
        }
        backupDocument = BackupFileDocument(text: SettingsBackup.encode(snapshot))
        backupExportName = "kazumi-settings-\(Self.fileStampText())"
        isShowingBackupExporter = true
    }

    private func importBackupFromFile(_ url: URL) {
        // 文件里选来的 URL 在沙箱外，先取得访问权，用完释放。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            acceptBackup(String(decoding: data, as: UTF8.self))
        } catch {
            backupMessage = "读不到这个文件，可能已被移动，或者没有访问权限。"
        }
    }

    /// 剪贴板与文件两条路共用：解码 → 计数 → 弹确认框。
    private func acceptBackup(_ raw: String) {
        do {
            let payload = try SettingsBackup.decode(raw)
            guard payload.count > 0 else {
                backupMessage = Self.emptyBackupMessage
                return
            }
            pendingPayload = payload
            isShowingRestoreConfirm = true
        } catch {
            backupMessage = error.localizedDescription
        }
    }

    private static func fileStampText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }

    private var restoreConfirmMessage: String {
        guard let payload = pendingPayload else { return "" }
        var blocks = [
            "备份时间：\(Self.timestampText(payload.exportedAt))\n"
                + "共 \(payload.count) 项设置，将覆盖当前设置。",
        ]
        if payload.settings.keys.contains(where: SettingsBackup.credentialKeys.contains) {
            blocks.append("备份包含账号或代理密码。恢复后请到「账号与备份」里确认凭据仍然有效。")
        }
        blocks.append("引导步骤、通知权限、设备同步状态不会被改动。")
        return blocks.joined(separator: "\n\n")
    }

    private static func timestampText(_ date: Date?) -> String {
        guard let date else { return "时间未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

/// 交给系统文件导出用的文档：纯文本 JSON，与剪贴板那份内容一致。
/// （原先和已经撤掉的设置备份页放在一起；现在这里是唯一的使用方。）
struct BackupFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
