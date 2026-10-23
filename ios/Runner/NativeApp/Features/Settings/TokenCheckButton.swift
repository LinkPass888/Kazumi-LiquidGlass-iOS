//
//  TokenCheckButton.swift
//  Runner
//
//  令牌输入框下面的两个按钮：「去 Bangumi 生成令牌」和「检查令牌」。
//
//  为什么要有它：侧载装 App 的人自己粘令牌，粘错了页面只是空白一片，
//  分不清是令牌错、网络错还是 App 坏了。点一下直接问服务器要自己的用户信息，
//  四种结果摆出来：连接正常（带账号名）、没填、被拒、网络异常。
//
//  它同时也是链路证据：能拿到用户名，就说明令牌真的穿过了请求层。
//
//  结构上有一条硬约束：**Form 里一个 cell 只放一个可点元素**。
//  曾经把两个按钮包在一个 VStack 里当一行，结果 iOS 把整行当成一个按钮，
//  点「检查令牌」走的却是上面那颗的动作（实测：点它弹出的是令牌页）。
//  所以这里不包 VStack，按顺序直接吐兄弟节点，每个各自成一个 cell。
//

import SafariServices
import SwiftUI

struct TokenCheckActions: View {
    /// Bangumi 的访问令牌生成页。
    private static let tokenPageURL = URL(string: "https://next.bgm.tv/demo/access-token")!

    /// 「去 Bangumi 生成令牌」下面那句说明：点下去会先看到人机验证。
    /// 文案由 Camo 定稿；显示和 VoiceOver 听到的用同一个常量、都不带句号。
    private static let tokenPageNote = "令牌页需要人机验证，通过后就能生成令牌"

    /// 当前的令牌值。只在它变了的时候用来清掉上一次的结论——
    /// 令牌无效的橙字留在那儿，用户改完令牌再粘一串，看着还像在报错。
    var token: String = ""

    /// 身份的去向。这一页的「用户 ID」行在上面单独一个 cell，看不到这里的 `result`，
    /// 所以每次检查的结果连同拿到的身份一起往上报：拿到就是 `confirmed`，
    /// 被拒或连不上就 `unconfirmed`（不能留着上一次）。
    var onIdentity: (BangumiIdentity) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    @State private var isChecking = false
    @State private var result: BangumiAPI.TokenCheckResult?
    @State private var isShowingTokenPage = false

    @ViewBuilder
    var body: some View {
        Button {
            isShowingTokenPage = true
        } label: {
            Text("去 Bangumi 生成令牌")
                .frame(maxWidth: .infinity, alignment: .leading)
                .hitTarget44(alignment: .leading)
        }
        // 同一行里还有别的按钮时，.borderless 让每个按钮各自接管自己的点击。
        // 结构上已经分成了不同 cell，这里是第二道保险。
        .buttonStyle(.borderless)
        .accessibilityHint(Self.tokenPageNote)
        .listRowSeparator(.hidden)
        .sheet(isPresented: $isShowingTokenPage) {
            SafariSheet(url: Self.tokenPageURL)
                .ignoresSafeArea()
        }

        // 这句讲的是「点下去会看到什么」，不是警告：次要色、无图标、不可点。
        // 用 .footnote 而不是固定 13pt，跟系统的文字大小一起缩放。
        Text(Self.tokenPageNote)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(2)
            .accessibilityHidden(true)
            .listRowSeparator(.hidden)

        Button {
            Task { await check() }
        } label: {
            HStack(spacing: 6) {
                if isChecking {
                    ProgressView().controlSize(.small)
                }
                Text(isChecking ? "正在检查…" : "检查令牌")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .hitTarget44(alignment: .leading)
        }
        .buttonStyle(.borderless)
        .disabled(isChecking)
        .listRowSeparator(.hidden)
        // 令牌一改，上一次的结论就不再成立，清掉。
        .onChange(of: token) {
            result = nil
            onIdentity(.unverified)
        }

        if let result, let text = message(for: result) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let symbol = symbol(for: result) {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                }
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote)
            .foregroundStyle(color(for: result))
            .listRowSeparator(.hidden)
        }
    }

    private func check() async {
        isChecking = true
        let outcome = await BangumiAPI.checkToken()
        // 排错信息进日志：界面上不贴原因（Camo 定稿）。
        if case let .unreachable(reason) = outcome {
            KazumiLogBuffer.network("检查令牌失败：\(reason)")
        }
        isChecking = false
        result = outcome
        switch outcome {
        case let .ok(_, id, username) where !id.isEmpty:
            onIdentity(.confirmed(id: id, username: username))
        case .ok(_):
            // 服务器认了令牌，却没给出 id：这仍然是「没能确认你是谁」。
            onIdentity(.unconfirmed)
        case .missing:
            // 还没问过服务器，不是「问过没答案」。
            onIdentity(.unverified)
        case .rejected, .unreachable(_):
            onIdentity(.unconfirmed)
        }
        // VoiceOver 用户点完得知道结果，否则只看到界面没变化。
        if let text = message(for: outcome) {
            AccessibilityNotification.Announcement(text).post()
        }
    }

    private func message(for result: BangumiAPI.TokenCheckResult) -> String? {
        switch result {
        case let .ok(name, _, _):
            return "连接正常，当前账号：\(name)。"
        case .missing:
            return "还没有填令牌。点「去 Bangumi 生成令牌」，拿到后粘到上面这一栏。"
        case .rejected:
            return "令牌无效：服务器拒绝了这个令牌。可能填漏了字符，或者已经过期；点「去 Bangumi 生成令牌」重新拿一个。"
        case .unreachable:
            // 具体原因（错误对象、状态码）只进日志，不贴到界面上（Camo 定稿）。
            return "网络异常：请求没能到达 Bangumi。检查网络或代理后再试，令牌本身可能没问题。"
        }
    }

    /// 每种状态都有图标：只靠颜色区分对色盲不成立。
    private func symbol(for result: BangumiAPI.TokenCheckResult) -> String? {
        switch result {
        case .ok(_):
            return "checkmark.circle.fill"
        case .missing:
            return nil
        case .rejected:
            return "exclamationmark.triangle.fill"
        case .unreachable:
            return "wifi.exclamationmark"
        }
    }

    private func color(for result: BangumiAPI.TokenCheckResult) -> Color {
        switch result {
        case .ok(_):
            return KazumiPalette.accent(for: colorScheme)
        case .missing:
            // 提示，不是错误：橙色会让人以为填错了。
            return .secondary
        case .rejected:
            return .orange
        case .unreachable:
            // 网络不通不是用户的错，红色太凶。
            return .secondary
        }
    }
}

/// App 内的浏览器（SFSafariViewController）。
private struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.preferredControlTintColor = .tintColor
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
