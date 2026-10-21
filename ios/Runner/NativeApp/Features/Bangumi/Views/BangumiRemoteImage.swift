//
//  BangumiRemoteImage.swift
//  Kazumi
//
//  对应 lib/bean/card/network_img_layer.dart 的职责：加载 Bangumi 封面。
//  Bangumi 的图片地址可能是 http，原生 URLSession 会受 ATS 限制，
//  因此这里统一按 https 发起（bangumi 图床两者都可用），并把已下载的
//  图片写进 URLCache，滚动回来时不再重复请求。
//

import SwiftUI

struct BangumiRemoteImage: View {
    let url: String

    private var resolvedURL: URL? {
        guard !url.isEmpty else { return nil }
        if url.hasPrefix("//") { return URL(string: "https:" + url) }
        if url.hasPrefix("http://") {
            return URL(string: "https://" + url.dropFirst("http://".count))
        }
        return URL(string: url)
    }

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let resolvedURL {
                    AsyncImage(url: resolvedURL, transaction: Transaction(animation: .easeOut(duration: 0.18))) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            placeholder
                        case .empty:
                            ProgressView()
                        @unknown default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipped()
    }

    private var placeholder: some View {
        Image(systemName: "movieclapper")
            .font(.title3)
            .foregroundStyle(.tertiary)
    }
}
