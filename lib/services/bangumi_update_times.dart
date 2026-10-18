import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// 最近两季的「更新时间」数据，来自 bangumi-data 仓库按季度拆分的 JSON
/// （https://github.com/bangumi-data/bangumi-data，CC BY 4.0）。
///
/// 每季一个文件 `data/items/{年}/{季首月}.json`，包含条目的开播时间、
/// 播出周期（`broadcast: "R/<起始>/P7D"`）以及 bangumi / MAL 站点 id。由此推导下一次/上一次更新时间，供时间表排序与展示、追番页
/// 排序使用；同一份数据还提供 mal id 映射，供 AniSkip 并入。
class BangumiUpdateTimesService {
  BangumiUpdateTimesService._();

  static final BangumiUpdateTimesService instance = BangumiUpdateTimesService._();

  static const _maxAge = Duration(days: 7);

  Future<void>? _loading;

  /// bangumi id -> 更新时间条目。未加载完成时为空表。
  Map<int, BangumiUpdateEntry> updates = {};

  /// bangumi id -> MAL id（仅最近两季，ExtLinker 覆盖更全，作为补充）。
  Map<int, int> malIds = {};

  /// 数据刷新完成后的回调（通知服务用它重排提醒）。设置在 main 初始化。
  void Function()? onRefreshed;

  /// 下一次更新时间（epoch ms），无数据或无法推算时返回 null。
  int? nextUpdateEpoch(int bangumiId, {DateTime? now}) =>
      nextUpdateEpochFrom(updates[bangumiId], now ?? DateTime.now());

  /// 上一次更新时间（epoch ms），无数据或未开播时返回 null。
  int? lastUpdateEpoch(int bangumiId, {DateTime? now}) =>
      lastUpdateEpochFrom(updates[bangumiId], now ?? DateTime.now());

  /// 重复调用共享一次下载。抛错不会被保留，下次调用会重试。
  Future<void> ensureLoaded() => _loading ??= _load();

  /// 数据可用（更新时间表非空）时回调；设置在 main 初始化，供通知重排。
  /// 这里额外在「彻底拿不到数据」时弹 toast —— 时间表时间和更新提醒都依赖
  /// 这张表，空了下发端全无反馈，用户根本不知道是下载失败了。
  void _notifyRefreshed() {
    if (updates.isEmpty) {
      KazumiLogger().w('BangumiUpdateTimes: no update data available');
      KazumiDialog.showToast(message: '更新时间数据加载失败，请检查网络后重进时间表');
      return;
    }
    KazumiLogger().i('BangumiUpdateTimes: loaded ${updates.length} entries');
    onRefreshed?.call();
  }

  Future<void> _load() async {
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
          final data = parseBangumiDataSeason(body);
          updates.addAll(data.updates);
          malIds.addAll(data.malIds);
        }
        if (updates.isEmpty) {
          throw const FormatException('bangumi-data: no season data parsed');
        }
        await cache.parent.create(recursive: true);
        await cache.writeAsString(
          jsonEncode({
            'updates': {
              for (final e in updates.entries)
                '${e.key}': [e.value.firstEpochMs, e.value.periodMs],
            },
            // JSON 对象的 key 必须是字符串：malIds 是 Map<int, int>，直接塞进去
            // jsonEncode 会抛「Converting object to an encodable object failed」，
            // 于是解析成功的数据也写不进缓存、updates 一直是空表（直连失败的根因）。
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
        bangumiDataSeasonUrl(year, month),
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

/// 当前的 bangumi-data 季节文件：季首月只可能是 1/4/7/10。
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

/// 季节文件的下载地址。番剧条目加速为直连时走 raw.githubusercontent，
/// 镜像/ECH 走 jsDelivr（该源无 ECH 支持，ECH 也按镜像处理）。
/// [acceleration] 供测试注入；省略时读全局设置。
String bangumiDataSeasonUrl(
  int year,
  int month, {
  BangumiAcceleration? acceleration,
}) {
  final monthPart = month.toString().padLeft(2, '0');
  final relativePath = 'data/items/$year/$monthPart.json';
  return switch (acceleration ?? BangumiAcceleration.current) {
    BangumiAcceleration.direct =>
      'https://raw.githubusercontent.com/bangumi-data/bangumi-data/master/$relativePath',
    _ => 'https://cdn.jsdelivr.net/gh/bangumi-data/bangumi-data@master/$relativePath',
  };
}

/// 从整份季节 JSON 提取更新时间与 mal 映射。
BangumiSeasonData parseBangumiDataSeason(String source) {
  final updates = <int, BangumiUpdateEntry>{};
  final malIds = <int, int>{};
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on Object {
    return BangumiSeasonData(updates, malIds);
  }
  if (decoded is! List) return BangumiSeasonData(updates, malIds);
  for (final item in decoded) {
    if (item is! Map) continue;
    // bangumi-data 里 type 是字符串（"tv" / "web" / "movie"），TV 与 Web
    // 配信的番剧才有更新时间，movie / ova 一次性放送不参与时间表。
    if (item['type'] != 'tv' && item['type'] != 'web') continue;
    int? bangumiId;
    int? malId;
    for (final site in item['sites'] as List? ?? const []) {
      if (site is! Map) continue;
      if (site['site'] == 'bangumi') {
        bangumiId ??= int.tryParse('${site['id']}');
      } else if (site['site'] == 'mal') {
        malId ??= int.tryParse('${site['id']}');
      }
    }
    // 没有 bangumi id 的条目无法和 Bangumi 日历对上，跳过。
    if (bangumiId == null) continue;
    updates[bangumiId] = deriveUpdateEntry(item);
    if (malId != null) malIds[bangumiId] = malId;
  }
  return BangumiSeasonData(updates, malIds);
}

/// 直接取条目自身的 begin / broadcast（日本首播时刻）推算更新时间，
/// 不读站点级时间：国内平台不会上，站点 begin 对用户没有意义。
BangumiUpdateEntry deriveUpdateEntry(Map item) {
  final sourceBegin = '${item['begin']}' != 'null' ? '${item['begin']}' : '';
  final sourceBroadcast =
      '${item['broadcast']}' != 'null' ? '${item['broadcast']}' : null;

  final begin = DateTime.tryParse(sourceBegin)?.toUtc();
  final broadcast = parseIsoBroadcast(sourceBroadcast);
  // begin 只有日期没有时刻时（本地零点解析），拿不出可信的更新时刻。
  final hasTimeOfDay =
      begin != null && sourceBegin.length > 10 && broadcast != null;
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
  final comparison = aNext.compareTo(bNext);
  return comparison != 0 ? comparison : a.id.compareTo(b.id);
}

/// 追番页排序：无更新时间的（即不在最近两季，或两季内推不出时刻的）排最上面；
/// 其余按上一次更新时间从新到旧。
int compareCollectUpdateTime(
  CollectedBangumi a,
  CollectedBangumi b,
  Map<int, BangumiUpdateEntry> updates,
  DateTime now,
) {
  final aLast = lastUpdateEpochFrom(updates[a.bangumiItem.id], now);
  final bLast = lastUpdateEpochFrom(updates[b.bangumiItem.id], now);
  if (aLast == null && bLast == null) {
    return a.bangumiItem.id.compareTo(b.bangumiItem.id);
  }
  if (aLast == null) return -1;
  if (bLast == null) return 1;
  final comparison = bLast.compareTo(aLast);
  return comparison != 0 ? comparison : a.bangumiItem.id.compareTo(b.bangumiItem.id);
}
