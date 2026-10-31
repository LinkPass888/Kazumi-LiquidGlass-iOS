//
//  RuleLoginScreen.swift
//  Kazumi
//
//  规则登录（LP 5427）：部分规则要登录站点才能播，原来的验证码 WebView 是
//  nonPersistent 的一次性会话，登完什么也留不下。这里用持久的 WKWebView 打开
//  规则自己的站点让用户登录，退出时把 Cookie 交给 PluginCookieStore，
//  规则请求（RuleHTTPClient）就会带上它，重启后也还在。
//

import SwiftUI
import WebKit

struct RuleLoginScreen: View {
    let plugin: Plugin

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var isLoading = true
    @State private var savedCount = 0

    private var startURL: URL? {
        let raw = plugin.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let normalized = EpisodeURL.normalize(baseUrl: raw, raw: raw)
        guard let components = URLComponents(string: normalized) else { return nil }
        // 打开站点首页，不是规则里那条接口路径：登录入口在首页，直接落到接口路径会 404。
        // Cookie 的域是整站共享的，从首页登完照样能带上。
        var origin = URLComponents()
        origin.scheme = components.scheme
        origin.host = components.host
        origin.port = components.port
        return origin.url ?? URL(string: normalized)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let startURL {
                    RuleLoginWebView(
                        url: startURL,
                        pluginName: plugin.name,
                        userAgent: plugin.userAgent,
                        isLoading: $isLoading,
                        savedCount: $savedCount
                    )
                } else {
                    ContentUnavailableView(
                        "这条规则没有站点地址",
                        systemImage: "globe",
                        description: Text("规则里没写基础地址，没法打开登录页。")
                    )
                }
            }
            .navigationTitle("登录 \(plugin.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(KazumiPalette.groupedRow(for: colorScheme))
            }
        }
        .overlay {
            if isLoading && startURL != nil {
                ProgressView()
                    .controlSize(.large)
            }
        }
    }

    private var footer: String {
        if savedCount > 0 {
            return "已保存 \(savedCount) 个登录凭证，这条规则之后的请求会带上它。"
        }
        return "在这里登录站点，登录状态会留给这条规则用；关掉这页不影响播放。"
    }
}

// MARK: - WKWebView

private struct RuleLoginWebView: UIViewRepresentable {
    let url: URL
    let pluginName: String
    let userAgent: String
    @Binding var isLoading: Bool
    @Binding var savedCount: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(pluginName: pluginName, isLoading: $isLoading, savedCount: $savedCount)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 持久化：同一规则下次进来还是登录状态，别每次重登。
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        if !userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            webView.customUserAgent = userAgent
        }
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // 页面退出时再收一次，兜住「登录完直接下滑关掉」这条路径。
        coordinator.harvest(from: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let pluginName: String
        private let isLoading: Binding<Bool>
        private let savedCount: Binding<Int>

        init(pluginName: String, isLoading: Binding<Bool>, savedCount: Binding<Int>) {
            self.pluginName = pluginName
            self.isLoading = isLoading
            self.savedCount = savedCount
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading.wrappedValue = false
            harvest(from: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading.wrappedValue = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading.wrappedValue = false
        }

        /// 把 WebView 的 Cookie 交给规则网络层。
        func harvest(from webView: WKWebView) {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            store.getAllCookies { cookies in
                let mapped = cookies.map {
                    PluginCookieStore.Cookie(
                        name: $0.name,
                        value: $0.value,
                        domain: $0.domain,
                        path: $0.path
                    )
                }
                // 用 WebView 真正发出去的 UA，站点绑定指纹时才对得上。
                let ua = webView.customUserAgent ?? ""
                PluginCookieStore.shared.saveFromLoginWebView(
                    pluginName: self.pluginName,
                    cookies: mapped,
                    userAgent: ua.isEmpty ? nil : ua
                )
                DispatchQueue.main.async {
                    if !mapped.isEmpty { self.savedCount.wrappedValue = mapped.count }
                }
            }
        }
    }
}
