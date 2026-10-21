//
//  BangumiRemoteImage.swift
//  Kazumi
//
//  对应 lib/bean/card/network_img_layer.dart 的职责：加载 Bangumi 封面。
//  Bangumi 的图片地址可能是 http，原生 URLSession 会受 ATS 限制，
//  因此这里统一按 https 发起（bangumi 图床两者都可用）。
//
//  图片走 `KazumiImageLoader` 的两级缓存：视图初始化时先同步问一次内存缓存，
//  命中就直接当首帧画出来 —— 列表上下滚动、从详情页返回都不会再闪一次白。
//

import SwiftUI

struct BangumiRemoteImage: View {
    let url: String
    /// 与 Dart 版 BoxFit.cover 对应的 contentMode。
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    init(url: String, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
        // 命中内存缓存时直接出图，不经历「占位 → 图片」这一帧。
        let key = KazumiImageLoader.cacheKey(for: url)
        _image = State(initialValue: key.isEmpty ? nil : KazumiImageLoader.shared.cachedImage(for: key))
    }

    private var key: String { KazumiImageLoader.cacheKey(for: url) }

    var body: some View {
        ZStack {
            placeholderBackground

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if key.isEmpty {
                placeholderSymbol
            } else if failed {
                placeholderSymbol
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: key) {
            await loadIfNeeded()
        }
    }

    /// 占位底：很淡的一层，图片淡入时几乎看不出切换，也不会整块发灰。
    private var placeholderBackground: some View {
        Rectangle()
            .fill(.quinary)
    }

    private var placeholderSymbol: some View {
        Image(systemName: "movieclapper")
            .font(.title3)
            .foregroundStyle(.tertiary)
    }

    private func loadIfNeeded() async {
        guard !key.isEmpty else {
            failed = false
            return
        }
        if image != nil { return }
        let hit = await KazumiImageLoader.shared.load(key)
        guard !Task.isCancelled else { return }
        if hit, let cached = KazumiImageLoader.shared.cachedImage(for: key) {
            withAnimation(.easeOut(duration: 0.15)) {
                image = cached
                failed = false
            }
        } else {
            failed = true
        }
    }
}

/// 圆形头像（对应原版 lib/bean/widget/bangumi_avatar.dart 的 BangumiAvatar）。
///
/// 与原版的差别在裁切方式：原版把图居中裁成圆，人脸偏上时会把头顶切掉。
/// 这里按 `focus` 参数选择竖直方向的取景中心 —— 0 是顶部对齐（露出头部），
/// 0.5 才是居中。角色 / 制作人员头像统一用偏上的取景。
struct KazumiAvatar: View {
    let url: String
    /// 直径。
    var size: CGFloat = 40
    /// 竖直取景中心：0 顶部、0.5 居中、1 底部。
    var focus: CGFloat = 0.18

    @State private var image: UIImage?
    @State private var failed = false

    init(url: String, size: CGFloat = 40, focus: CGFloat = 0.18) {
        self.url = url
        self.size = size
        self.focus = focus
        let key = KazumiImageLoader.cacheKey(for: url)
        _image = State(initialValue: key.isEmpty ? nil : KazumiImageLoader.shared.cachedImage(for: key))
    }

    private var key: String { KazumiImageLoader.cacheKey(for: url) }

    var body: some View {
        ZStack {
            Circle().fill(.quinary)

            if let image, image.size.width > 0, image.size.height > 0 {
                let scale = max(size / image.size.width, size / image.size.height)
                let width = image.size.width * scale
                let height = image.size.height * scale
                Image(uiImage: image)
                    .resizable()
                    .frame(width: width, height: height)
                    // 子视图在 ZStack 里是居中的：先按居中算，再把竖直中心
                    // 从 0.5 平移到 focus（0 顶部 / 1 底部）。
                    .offset(y: (height - size) * (0.5 - focus))
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: key) {
            await loadIfNeeded()
        }
    }

    private func loadIfNeeded() async {
        guard !key.isEmpty, image == nil else { return }
        let hit = await KazumiImageLoader.shared.load(key)
        guard !Task.isCancelled else { return }
        if hit, let cached = KazumiImageLoader.shared.cachedImage(for: key) {
            withAnimation(.easeOut(duration: 0.15)) {
                image = cached
            }
        } else {
            failed = true
        }
    }
}

