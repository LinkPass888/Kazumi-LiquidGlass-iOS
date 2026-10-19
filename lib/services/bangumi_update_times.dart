import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/anilist_client.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// 最近两季的「更新时间」数据，来自 bangumi-mal 仓库按季度拆分的 JSON
/// （https://github.com/LinkPass888/bangumi-mal，CC BY 4.0）。
///
/// 每季一个文件 `data/seasons/{年}/{季首月}.json`，包含条目的开播时间（begin）、
/// 播出周期（broadcast: "R/<起始>/P7D"）以及 bangumi / MAL id。由此推导下一次/上一次更新时间，供时间表排序与展示、追番页
/// 排序使用；同一份数据还提供 mal id 映射，供 AniSkip 与 AniList 使用。
class BangumiUpdateTimesService {
  BangumiUpdateTimesService._();

  static final BangumiUpdateTimesService instance = BangumiUpdateTimesService._();

  static const _maxAge = Duration(days: 7);

  Future<void>? _loading;

  /// bangumi id -> 更新时间条目。未加载完成时为空表。
  Map<int, BangumiUpdateEntry> updates = {};

  /// bangumi id -> MAL id（仅最近两季，供 AniSkip 与 AniList 查询使用）。
  Map<int, int> malIds = {};

  /// 数据刷新完成后的回调（通知服务用它重排提醒）。设置在 main 初始化。
  void Function()? onRefreshed;

  /// 下一次更新时间（epoch ms），无数据或无法推算时返回 null。
  /// 优先用 AniList 的实测播出时刻（停播/延期会反映）；缓存过期也先用
  /// 缓存值；完全没有才按 bangumi-mal 推算。
  int? nextUpdateEpoch(int bangumiId, {DateTime? now}) {
    final current = now ?? DateTime.now();
    final anilist = AniListClient.instance.cached(bangumiId, now: current) ??
        AniListClient.instance.staleCached(bangumiId, now: current);
    // 过期的缓存只知道「上一集的播出时刻」，回推一个周期即下一次。
    if (anilist != null) {
      if (anilist.isFreshAt(current)) return anilist.airingAt;
      final period = updates[bangumiId]?.periodMs;
      if (period != null) return anilist.airingAt + period;
    }
    return nextUpdateEpochFrom(updates[bangumiId], current);
  }

  /// 上一次更新时间（epoch ms），无数据或未开播时返回 null。
  /// 优先用 AniList 的实测值：下一集（episode）之前的那一集，它已播出
  /// 的重排时刻取 airingAt 减一个周期不准确，所以直接用本期已播推算。
  int? lastUpdateEpoch(int bangumiId, {DateTime? now}) {
    final current = now ?? DateTime.now();
    final anilist = AniListClient.instance.cached(bangumiId, now: current) ??
        AniListClient.instance.staleCached(bangumiId, now: current);
    if (anilist != null) {
      final entry = updates[bangumiId];
      final period = entry?.periodMs;
      // AniList 只给「下一集」，用下一次播出时刻回推一个周期即为上次更新。
      if (period != null) return anilist.airingAt - period;
      if (!anilist.isFreshAt(current)) return anilist.airingAt;
    }
    return lastUpdateEpochFrom(updates[bangumiId], current);
  }

  /// 当前已播出到第几集（1-based），无数据或未开播时返回 null。
  /// 优先用 AniList 的实测值（停播/延期会反映）；缓存过期也先用缓存
  /// （那一集确实已经播出了），完全没有才按 bangumi-mal 推算。
  int? currentEpisode(int bangumiId, {DateTime? now}) {
    final current = now ?? DateTime.now();
    final anilist = AniListClient.instance.cached(bangumiId, now: current);
    if (anilist != null) return anilist.currentEpisode;
    final stale =
        AniListClient.instance.staleCached(bangumiId, now: current);
    if (stale != null) return stale.currentEpisode;
    final entry = updates[bangumiId];
    final first = entry?.firstEpochMs;
    final period = entry?.periodMs;
    if (first == null || period == null) return null;
    final nowMs = current.millisecondsSinceEpoch;
    if (nowMs < first) return null;
    return ((nowMs - first) ~/ period) + 1;
  }

  /// 单部番的放送星期（1 = 周一 ... 7 = 周日，本地时区）。
  /// 默认用 bangumi-mal 的推算值：它周一的日子就是条目页的「放送星期」，
  /// 同一时段（比如深夜档跨零点）的番会落在同一天，按时间排序也才连得上。
  /// AniList 只在调用方明确要求时使用：它的 `airingAt` 是新一轮播出
  /// （首播日 / 先行配信日），和条目页的放送星期可能差一两天。
  int? updateWeekday(int bangumiId, {DateTime? now, bool preferAniList = false}) {
    final current = now ?? DateTime.now();
    final epoch = preferAniList
        ? nextUpdateEpoch(bangumiId, now: current)
        : nextUpdateEpochFrom(updates[bangumiId], current);
    if (epoch == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(epoch).weekday;
  }

  /// 总集数，仅 AniList 提供；没有数据返回 null。
  int? totalEpisodes(int bangumiId, {DateTime? now}) {
    final current = now ?? DateTime.now();
    final anilist = AniListClient.instance.cached(bangumiId, now: current) ??
        AniListClient.instance.staleCached(bangumiId, now: current);
    return anilist?.totalEpisodes;
  }

  /// 番剧是否在最近两季的数据范围内（不在就没有更新时间可展示）。
  bool isRecentSeason(int bangumiId) => updates.containsKey(bangumiId);

  /// 重复调用共享一次下载。拿到数据后沿用；空表说明这次失败了（网络或
  /// 缓存都不可用），丢掉这次结果，下次调用重新下载。
  Future<void> ensureLoaded() {
    final running = _loading;
    if (running != null) return running;
    late final Future<void> future;
    future = _load().whenComplete(() {
      if (identical(_loading, future) && updates.isEmpty) _loading = null;
    });
    _loading = future;
    return future;
  }

  /// 为当季番批量补齐 AniList 播出状态（失败静默回退到 bangumi-mal）。
  Future<void> ensureAniListLoaded(Iterable<int> bangumiIds) async {
    await AniListClient.instance.ensureLoaded(bangumiIds);
    onRefreshed?.call();
  }

  /// 数据可用（更新时间表非空）时回调；设置在 main 初始化，供通知重排。
  /// 这里额外在「彻底拿不到数据」时弹 toast —— 时间表时间和更新提醒都依赖
  /// 这张表，空了下发端全无反馈，用户根本不知道是下载失败了。
  void _notifyRefreshed() {
    if (updates.isEmpty) {
      KazumiLogger().w('BangumiUpdateTimes: no update data available');
      // 一次会话只提示一次：时间表、追番页、详情页都会调用 ensureLoaded，
      // 失败重试时不该反复弹同一个 toast。
      if (!_warnedEmpty) {
        _warnedEmpty = true;
        KazumiDialog.showToast(message: '更新时间数据加载失败，请检查网络后重进时间表');
      }
      return;
    }
    KazumiLogger().i('BangumiUpdateTimes: loaded ${updates.length} entries');
    onRefreshed?.call();
  }

  bool _warnedEmpty = false;

  Future<void> _load() async {
    try {
      await _loadData();
    } catch (error, stackTrace) {
      // 兜底：调用方（时间表、追番页、详情页）都只 await，不处理异常。
      KazumiLogger().e('BangumiUpdateTimes: load failed',
          error: error, stackTrace: stackTrace);
      _notifyRefreshed();
    }
  }

  Future<void> _loadData() async {
    final cache = File(
      path.join(
        (await getApplicationSupportDirectory()).path,
        'update_times',
        'bangumi_update_times.json',
      ),
    );
    final fresh =
        await cache.exists() &&
        DateTime.now().difference(await cache.lastModified()) < _maxAge;
    if (!fresh) {
      try {
        final now = DateTime.now();
        final (year, month) = currentBangumiDataSeason(now);
        final (prevYear, prevMonth) = previousBangumiDataSeason(now);
        final bodies = await Future.wait([
          _fetchSeason(year, month),
          _fetchSeason(prevYear, prevMonth),
        ]);
        final updates = <int, BangumiUpdateEntry>{};
        final malIds = <int, int>{};
        for (final body in bodies) {
          if (body.isEmpty) continue;
          final data = parseBangumiMalSeason(body);
          updates.addAll(data.updates);
          malIds.addAll(data.malIds);
        }
        if (updates.isEmpty) {
          throw const FormatException('bangumi-mal: no season data parsed');
        }
        await cache.parent.create(recursive: true);
        await cache.writeAsString(
          jsonEncode({
            'updates': {
              for (final e in updates.entries)
                '${e.key}': [e.value.firstEpochMs, e.value.periodMs],
            },
            'mal': {for (final e in malIds.entries) '${e.key}': e.value},
          }),
          flush: true,
        );
        this.updates = updates;
        this.malIds = malIds;
        _notifyRefreshed();
        return;
      } catch (e) {
        KazumiLogger().w('BangumiUpdateTimes: season download failed',
            error: e);
      }
    }
    if (!await cache.exists()) {
      _notifyRefreshed();
      return;
    }
    // 下载失败时回退到旧缓存（哪怕已过期），offline 也有数据可用。
    try {
      final raw =
          jsonDecode(await cache.readAsString()) as Map<String, dynamic>;
      final rawUpdates = raw['updates'];
      final rawMal = raw['mal'];
      if (rawUpdates is! Map) {
        _notifyRefreshed();
        return;
      }
      final updates = <int, BangumiUpdateEntry>{};
      rawUpdates.forEach((key, value) {
        final int? id = int.tryParse(key.toString());
        if (id == null || value is! List || value.length < 2) return;
        updates[id] = BangumiUpdateEntry(
          value[0] is int ? value[0] as int : null,
          value[1] is int ? value[1] as int : null,
        );
      });
      final malIds = <int, int>{};
      if (rawMal is Map) {
        rawMal.forEach((key, value) {
          final int? id = int.tryParse(key.toString());
          final int? mal = value is int ? value : int.tryParse('$value');
          if (id != null && mal != null) malIds[id] = mal;
        });
      }
      this.updates = updates;
      this.malIds = malIds;
      _notifyRefreshed();
    } on Object {
      // 缓存损坏则保持空表，各页面走「无数据」排序分支。
      _notifyRefreshed();
    }
  }

  Future<String> _fetchSeason(int year, int month) async {
    try {
      final response = await DioFactory.apiDio.get<String>(
        bangumiMalSeasonUrl(year, month),
        options: Options(responseType: ResponseType.plain),
      );
      return response.data ?? '';
    } on DioException catch (e) {
      // 新季度文件可能尚未发布，404 不应拖垮整次加载。
      if (e.response?.statusCode != 404) {
        KazumiLogger().w(
            'BangumiUpdateTimes: $year-$month fetch failed', error: e);
      }
      return '';
    }
  }
}

/// 单部番剧的更新时间信息。字段可为 null：null first = 只有日期没有时刻，
/// null period = 推不出播出周期。
class BangumiUpdateEntry {
  const BangumiUpdateEntry(this.firstEpochMs, this.periodMs);

  /// 第一集播出的时刻（epoch ms，UTC 转换后）。
  final int? firstEpochMs;

  /// 播出周期（毫秒），来自 broadcast 的 PnD 部分。
  final int? periodMs;
}

class BangumiSeasonData {
  const BangumiSeasonData(this.updates, this.malIds);

  final Map<int, BangumiUpdateEntry> updates;
  final Map<int, int> malIds;
}

/// 当前的季节：季首月只可能是 1/4/7/10。
(int, int) currentBangumiDataSeason(DateTime now) {
  final month = ((now.month - 1) ~/ 3) * 3 + 1;
  return (now.year, month);
}

/// 上一季，处理跨年（1 月 -> 去年 10 月）。
(int, int) previousBangumiDataSeason(DateTime now) {
  final (year, month) = currentBangumiDataSeason(now);
  if (month == 1) return (year - 1, 10);
  return (year, month - 3);
}

/// 季节文件的下载地址。统一走 GitHub Pages（jsDelivr 对 GitHub Pages 内容不适用）。
/// [acceleration] 供测试注入；省略时读全局设置。
String bangumiMalSeasonUrl(
  int year,
  int month, {
  BangumiAcceleration? acceleration,
}) {
  final monthPart = month.toString().padLeft(2, '0');
  return 'https://linkpass888.github.io/bangumi-mal/data/seasons/$year/$monthPart.json';
}

/// 从 bangumi-mal 季节 JSON 提取更新时间与 mal 映射。
///
/// 格式：`{"season": "2026-01", "count": 91, "items": {"<bangumi_id>": {bangumi_id, mal_id, begin, broadcast, ...}}}`
/// begin 是 ISO UTC 时间戳，broadcast 是 `"R/<ISO>/P7D"` 或 null。
BangumiSeasonData parseBangumiMalSeason(String source) {
  final updates = <int, BangumiUpdateEntry>{};
  final malIds = <int, int>{};
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on Object {
    return BangumiSeasonData(updates, malIds);
  }
  if (decoded is! Map) return BangumiSeasonData(updates, malIds);
  final items = decoded['items'];
  if (items is! Map) return BangumiSeasonData(updates, malIds);
  items.forEach((key, value) {
    if (value is! Map) return;
    final bangumiId = int.tryParse(key.toString());
    if (bangumiId == null) return;
    updates[bangumiId] = deriveBangumiMalEntry(value);
    final malId = value['mal_id'];
    if (malId is int && malId > 0) {
      malIds[bangumiId] = malId;
    }
  });
  return BangumiSeasonData(updates, malIds);
}

/// 从 bangumi-mal 记录推算更新时间。begin 是 UTC ISO 时间戳，
/// broadcast 是 `"R/<ISO>/P7D"` 形式。没有 broadcast 时推不出周期。
BangumiUpdateEntry deriveBangumiMalEntry(Map item) {
  final beginStr = '${item['begin']}' != 'null' ? '${item['begin']}' : '';
  final broadcastStr =
      '${item['broadcast']}' != 'null' ? '${item['broadcast']}' : null;

  final begin = DateTime.tryParse(beginStr)?.toUtc();
  final broadcast = parseIsoBroadcast(broadcastStr);
  // begin 只有日期（或年月）没有时刻时，拿不出可信的更新时刻。
  // bangumi-mal 的 begin 若是 "2024-10" / "2024-10-06" 这类粗粒度值就走这里。
  final hasTimeOfDay =
      begin != null && beginStr.length > 10 && broadcast != null;
  return BangumiUpdateEntry(
    begin?.millisecondsSinceEpoch,
    hasTimeOfDay ? broadcast : null,
  );
}

/// 解析 `R/<ISO8601>/P7D` 形式的播出周期，返回周期毫秒数；无法解析返回 null。
int? parseIsoBroadcast(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^R/[^/]+/P(?:(\d+)D)?(?:T(?:(\d+)H)?)?$')
      .firstMatch(value.trim());
  if (match == null) return null;
  final days = int.tryParse(match.group(1) ?? '') ?? 0;
  final hours = int.tryParse(match.group(2) ?? '') ?? 0;
  if (days == 0 && hours == 0) return null;
  return days * 86400000 + hours * 3600000;
}

/// 下一次更新时刻。first <= now 时取 now 之后的第一个整周期点。
int? nextUpdateEpochFrom(BangumiUpdateEntry? entry, DateTime now) {
  final first = entry?.firstEpochMs;
  final period = entry?.periodMs;
  if (first == null || period == null) return null;
  final nowMs = now.millisecondsSinceEpoch;
  if (nowMs <= first) return first;
  final k = (nowMs - first) / period;
  return first + k.ceil() * period;
}

/// 上一次更新时刻。尚未开播返回 null。
int? lastUpdateEpochFrom(BangumiUpdateEntry? entry, DateTime now) {
  final first = entry?.firstEpochMs;
  final period = entry?.periodMs;
  if (first == null || period == null) return null;
  final nowMs = now.millisecondsSinceEpoch;
  if (nowMs < first) return null;
  return first + ((nowMs - first) ~/ period) * period;
}

/// 「18:30」形式（不带周几：时间表已按星期分组，重复没有意义），本地时区；
/// 无法解析返回 null。
String? formatUpdateTime(int? epochMs) {
  if (epochMs == null) return null;
  final time = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// 时间表排序：按下一次更新时间从早到晚，无数据的排最后，同序回退 id。
///
/// 时间表是按星期分组展示的，而「下一次」是相对现在滚动的：周一晚上
/// 加载时，周日档的番下一次在下周、周五档的在周五，直接比绝对时刻会让
/// 同一列里的先后随加载时间变化。所以先比「星期几 + 当天时刻」，再比
/// 绝对时刻兜底（同一相位但周期不同的条目）。
int compareTimelineUpdateTime(
  BangumiItem a,
  BangumiItem b,
  Map<int, BangumiUpdateEntry> updates,
  DateTime now,
) {
  final aNext = nextUpdateEpochFrom(updates[a.id], now);
  final bNext = nextUpdateEpochFrom(updates[b.id], now);
  if (aNext == null && bNext == null) return a.id.compareTo(b.id);
  if (aNext == null) return 1;
  if (bNext == null) return -1;
  final comparison = compareWeeklyPhase(aNext, bNext);
  return comparison != 0 ? comparison : a.id.compareTo(b.id);
}

/// 按「本地星期几、再按当天时刻」比较两个播出时刻；同一相位再比绝对时刻。
int compareWeeklyPhase(int aEpochMs, int bEpochMs) {
  final a = DateTime.fromMillisecondsSinceEpoch(aEpochMs);
  final b = DateTime.fromMillisecondsSinceEpoch(bEpochMs);
  final weekday = a.weekday.compareTo(b.weekday);
  if (weekday != 0) return weekday;
  final minute = (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute);
  if (minute != 0) return minute;
  return aEpochMs.compareTo(bEpochMs);
}

/// 追番页排序：有更新时间的按上一次更新时间从新到旧；无更新时间的排底部。
int compareCollectUpdateTime(
  CollectedBangumi a,
  CollectedBangumi b,
  Map<int, BangumiUpdateEntry> updates,
  DateTime now,
) {
  final aLast = _resolveLastEpoch(a.bangumiItem.id, updates, now);
  final bLast = _resolveLastEpoch(b.bangumiItem.id, updates, now);
  if (aLast == null && bLast == null) {
    return a.bangumiItem.id.compareTo(b.bangumiItem.id);
  }
  if (aLast == null) return 1;
  if (bLast == null) return -1;
  final comparison = bLast.compareTo(aLast);
  return comparison != 0 ? comparison : a.bangumiItem.id.compareTo(b.bangumiItem.id);
}

/// 上一次更新时刻：优先 AniList 实测（下一集回推一个周期），缓存过期也先用；
/// 否则 bangumi-mal。
int? _resolveLastEpoch(
  int bangumiId,
  Map<int, BangumiUpdateEntry> updates,
  DateTime now,
) {
  final anilist = AniListClient.instance.cached(bangumiId, now: now) ??
      AniListClient.instance.staleCached(bangumiId, now: now);
  final period = updates[bangumiId]?.periodMs;
  if (anilist != null && period != null) {
    return anilist.airingAt - period;
  }
  return lastUpdateEpochFrom(updates[bangumiId], now);
}
