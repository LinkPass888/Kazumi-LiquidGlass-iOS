//
//  PopularController.swift
//  Kazumi
//
//  1:1 翻译 lib/pages/popular/popular_controller.dart：
//  * 默认展示趋势榜（trendList），每页 24 条、按 id 去重续接；
//  * 选择标签后展示 bangumiList，来自官方搜索接口；
//  * 空列表即视为超时以展示错误态（isTimeOut），与原实现一致。
//

import Observation

@MainActor
@Observable
final class PopularController {
    /// 与 Dart 的 _trendPageSize 一致。
    static let trendPageSize = 24

    private var trendOffset = 0

    var currentTag: String = ""
    private(set) var bangumiList: [BangumiItem] = []
    private(set) var trendList: [BangumiItem] = []
    private(set) var isLoadingMore = false
    private(set) var isTimeOut = false

    /// 当前展示的列表：无标签时是趋势榜，否则是标签结果。
    var items: [BangumiItem] {
        currentTag.isEmpty ? trendList : bangumiList
    }

    private var isBangumiMirrorEnabled: Bool {
        BangumiAcceleration.isMirrorEnabled
    }

    func setCurrentTag(_ tag: String) {
        currentTag = tag
    }

    func clearBangumiList() {
        bangumiList.removeAll()
    }

    /// 对应 queryBangumiByTrend：type == "init" 时从头加载。
    func queryBangumiByTrend(type: String = "add") async {
        if type == "init" {
            trendList.removeAll()
            trendOffset = 0
        }
        isLoadingMore = true
        let result = isBangumiMirrorEnabled
            ? await BangumiAPI.mirrorPopular(limit: Self.trendPageSize, offset: trendOffset)
            : await BangumiAPI.trends(limit: Self.trendPageSize, offset: trendOffset)
        if !result.isEmpty {
            trendOffset += Self.trendPageSize
        }
        var existing = Set(trendList.map(\.id))
        for item in result where existing.insert(item.id).inserted {
            trendList.append(item)
        }
        isLoadingMore = false
        isTimeOut = trendList.isEmpty
    }

    /// 对应 queryBangumiByTag：官方接口按随机名次抓取，镜像按标签分页。
    func queryBangumiByTag(type: String = "add") async {
        if type == "init" {
            bangumiList.removeAll()
        }
        isLoadingMore = true
        let tag = currentTag
        let result: [BangumiItem]
        if isBangumiMirrorEnabled {
            result = await BangumiAPI.mirrorPopular(tag: tag, offset: bangumiList.count)
        } else {
            result = await BangumiAPI.listByTag(rank: Int.random(in: 1...8000), tag: tag)
        }
        bangumiList.append(contentsOf: result)
        isLoadingMore = false
        isTimeOut = bangumiList.isEmpty
    }
}
