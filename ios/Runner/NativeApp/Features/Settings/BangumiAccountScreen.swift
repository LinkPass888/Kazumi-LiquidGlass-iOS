//
//  BangumiAccountScreen.swift
//  Kazumi
//
//  账号与备份 → 「Bangumi 账号」页。
//
//  这一页只放真正会改变行为的账号部分：用户 ID、访问令牌与「检查令牌」。
//  页名有意不叫「追番同步」：原生侧还没有同步引擎，标题不能承诺一件做不到的事。
//  「自动同步 / 同步偏好 / 同步结果提示 / 自动标记看过」四个开关的键虽然在
//  SettingsStore 里，但没有任何同步引擎或播放器读取它们——拨了只会写一个
//  没人消费的值，属于产品明令禁止的「摆着但不动」。等消费端落地再补。
//  「立即同步追番」同理：没有双向合并引擎就不放按钮。
//

import SwiftUI

struct BangumiAccountScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme

    /// 「用户 ID」行现在是什么状态。默认「未验证」：这一页打开时我们还没问过服务器。
    @State private var identity: BangumiIdentity = .unverified

    var body: some View {
        Form {
            Section {
                // 这行原来是「用户名」输入框，由人手填。改成只读的 ID，理由不是好看：
                // 手填错一个字符，同步引擎读到的就是别人的公开收藏。ID 只能由令牌换回来，
                // 所以不再给人填的机会，也没得填错。
                HStack {
                    Text("用户 ID")
                    Spacer(minLength: 8)
                    Text(identity.text)
                        // 未确认的两种走次要色，不用橙色：橙色留给下面那行检查结果，
                        // 一行里两个橙会像两处都在报警（Camo）。
                        .foregroundStyle(identity.isConfirmed ? Color.primary : Color.secondary)
                        .multilineTextAlignment(.trailing)
                }
                // 读屏读整行「用户 ID，866413」；未确认时也要把状态念出来，
                // 值位空着的话读屏只会念一个光秃的标签。
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("用户 ID，\(identity.text)")

                HStack {
                    Text("访问令牌")
                    SecureField("", text: tokenBinding)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("访问令牌")
                }

                // 生成令牌 / 检查令牌 / 四态结果由共用组件负责：
                // 它的几个节点各自成 cell，避免 Form 把整行并成一颗按钮。
                TokenCheckActions(token: settings.bangumiAccessToken, onIdentity: applyIdentity)
            } header: {
                Text("账号")
            } footer: {
                // 设置备份导出令牌是用户主动行为；这里承诺的是「同步」不带凭据。
                Text("账号和令牌不会被同步到服务器。")
            }
        }
        .navigationTitle("Bangumi 账号")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
    }

    // MARK: - 绑定

    /// 检查结果回到这页：更新「用户 ID」行，顺手把服务器给的用户名存成缓存。
    ///
    /// 用户名只当缓存用：同步引擎合并前必须自己再问一次 `/v0/me`（交接文档里那条），
    /// 不能拿这里的值去拼收藏列表地址——它是可能过期的。
    private func applyIdentity(_ new: BangumiIdentity) {
        identity = new
        if case let .confirmed(_, username) = new, !username.isEmpty {
            settings.bangumiUsername = username
        }
    }

    /// 令牌的 didSet 会同步注入 BangumiAPI，改完立即对请求生效。
    private var tokenBinding: Binding<String> {
        Binding(get: { settings.bangumiAccessToken }, set: { settings.bangumiAccessToken = $0 })
    }
}

/// 「用户 ID」这一行可能出现的三种状态，三种都要显示出来。
///
/// 为什么不是「有值 / 空着」两种：空着分不出「我们还没问」和「问过但没得到答案」，
/// 而这两件事对用户的意义完全不同（Camo 定的词：「未验证」与「无法确认」）。
enum BangumiIdentity: Equatable {
    /// 还没填令牌，或者填了还没点过「检查令牌」——我们还没问过服务器。
    case unverified
    /// 检查过，服务器认了这个令牌，并说出了它属于谁。
    case confirmed(id: String, username: String)
    /// 检查过，但没拿到身份：令牌被拒，或者网络根本没通。
    case unconfirmed

    /// 值位上的字。ID 只放那串数字，不加「ID：」前缀，标签已经说了是 ID（Camo）。
    var text: String {
        switch self {
        case .unverified:
            return "未验证"
        case let .confirmed(id, _):
            return id
        case .unconfirmed:
            return "无法确认"
        }
    }

    var isConfirmed: Bool {
        if case .confirmed = self { return true }
        return false
    }
}
