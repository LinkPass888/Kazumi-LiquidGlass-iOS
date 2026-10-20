import 'dart:convert';

import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 番剧时间表条目
///
/// 番剧处于「在看」时，用户可以指定它的放送星期，
/// 并决定是否让它在时间表的对应星期里展示。
class BangumiTimelineEntry {
  BangumiTimelineEntry({
    required this.weekday,
    this.showInTimeline = false,
  });

  /// 1 = 星期一 ... 7 = 星期日
  int weekday;

  /// 是否在时间表对应放送星期展示
  bool showInTimeline;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'weekday': weekday,
      'show': showInTimeline,
    };
  }

  BangumiTimelineEntry copyWith({
    int? weekday,
    bool? showInTimeline,
  }) {
    return BangumiTimelineEntry(
      weekday: weekday ?? this.weekday,
      showInTimeline: showInTimeline ?? this.showInTimeline,
    );
  }

  @override
  String toString() => 'weekday: $weekday, showInTimeline: $showInTimeline';
}

/// 把星期数值限制在 1 - 7，非法值按星期一处理
int normalizeBangumiWeekday(int weekday) {
  if (weekday < 1) {
    return 1;
  }
  if (weekday > 7) {
    return 7;
  }
  return weekday;
}

/// 只有「在看」的番剧保留时间表条目，其余收藏状态视为自动删除
bool bangumiKeepsTimelineEntry(int collectType) {
  return collectType == CollectType.watching.value;
}

/// 解析持久化的条目，非法内容返回空表
Map<int, BangumiTimelineEntry> decodeBangumiTimelineEntries(String? raw) {
  if (raw == null || raw.isEmpty) {
    return <int, BangumiTimelineEntry>{};
  }
  try {
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return <int, BangumiTimelineEntry>{};
    }
    final entries = <int, BangumiTimelineEntry>{};
    decoded.forEach((key, value) {
      final int? bangumiId = int.tryParse(key.toString());
      if (bangumiId == null || value is! Map) {
        return;
      }
      final int? weekday = int.tryParse('${value['weekday']}');
      if (weekday == null) {
        return;
      }
      entries[bangumiId] = BangumiTimelineEntry(
        weekday: normalizeBangumiWeekday(weekday),
        showInTimeline: value['show'] == true,
      );
    });
    return entries;
  } catch (error) {
    KazumiLogger().w(
      'Bangumi timeline entries decode failed',
      error: error,
    );
    return <int, BangumiTimelineEntry>{};
  }
}

/// 序列化条目，空表返回空字符串
String encodeBangumiTimelineEntries(
  Map<int, BangumiTimelineEntry> entries,
) {
  if (entries.isEmpty) {
    return '';
  }
  final json = <String, dynamic>{};
  entries.forEach((bangumiId, entry) {
    json['$bangumiId'] = entry.toJson();
  });
  return jsonEncode(json);
}

/// 把自定义条目合并进日历
///
/// [base] 为接口返回的七天日历，[weekdays] 为需要展示的番剧 ID -> 星期，
/// [items] 为番剧详情。已在日历中的番剧会从原位置移走，避免重复展示。
List<List<BangumiItem>> mergeBangumiTimelineEntries({
  required List<List<BangumiItem>> base,
  required Map<int, int> weekdays,
  required Map<int, BangumiItem> items,
}) {
  if (base.isEmpty || weekdays.isEmpty || items.isEmpty) {
    return base;
  }
  final merged = base
      .map(
        (day) => day
            .where((bangumiItem) => !weekdays.containsKey(bangumiItem.id))
            .toList(),
      )
      .toList();
  while (merged.length < 7) {
    merged.add(<BangumiItem>[]);
  }
  weekdays.forEach((bangumiId, weekday) {
    final bangumiItem = items[bangumiId];
    if (bangumiItem == null) {
      return;
    }
    merged[normalizeBangumiWeekday(weekday) - 1].add(bangumiItem);
  });
  return merged;
}

/// 时间表条目的持久化
class BangumiTimelineStore {
  /// 读取全部条目
  static Map<int, BangumiTimelineEntry> loadAll() {
    try {
      return decodeBangumiTimelineEntries(
        GStorage.getSetting(SettingsKeys.bangumiTimelineEntries),
      );
    } catch (error) {
      KazumiLogger().w(
        'Bangumi timeline entries load failed',
        error: error,
      );
      return <int, BangumiTimelineEntry>{};
    }
  }

  static BangumiTimelineEntry? entryOf(int bangumiId) {
    return loadAll()[bangumiId];
  }

  /// 获取所有需要展示的番剧 ID -> 星期
  static Map<int, int> loadShownWeekdays() {
    final weekdays = <int, int>{};
    loadAll().forEach((bangumiId, entry) {
      if (entry.showInTimeline) {
        weekdays[bangumiId] = entry.weekday;
      }
    });
    return weekdays;
  }

  /// 设置放送星期，没有条目时新建
  static Future<void> setWeekday(int bangumiId, int weekday) async {
    final entries = loadAll();
    final entry = entries[bangumiId] ??
        BangumiTimelineEntry(weekday: normalizeBangumiWeekday(weekday));
    entry.weekday = normalizeBangumiWeekday(weekday);
    entries[bangumiId] = entry;
    await _save(entries);
  }

  /// 设置是否在时间表展示
  static Future<void> setShowInTimeline(
    int bangumiId,
    bool showInTimeline, {
    int? weekday,
  }) async {
    final entries = loadAll();
    final entry = entries[bangumiId] ??
        BangumiTimelineEntry(
          weekday: normalizeBangumiWeekday(weekday ?? 1),
        );
    if (weekday != null) {
      entry.weekday = normalizeBangumiWeekday(weekday);
    }
    entry.showInTimeline = showInTimeline;
    entries[bangumiId] = entry;
    await _save(entries);
  }

  /// 删除单条数据
  static Future<void> remove(int bangumiId) async {
    final entries = loadAll();
    if (entries.remove(bangumiId) == null) {
      return;
    }
    await _save(entries);
  }

  /// 番剧不再处于「在看」时删除数据
  static Future<void> dropIfNotWatching(
    int bangumiId,
    int collectType,
  ) async {
    if (bangumiKeepsTimelineEntry(collectType)) {
      return;
    }
    await remove(bangumiId);
  }

  static Future<void> _save(
    Map<int, BangumiTimelineEntry> entries,
  ) async {
    try {
      await GStorage.putSetting(
        SettingsKeys.bangumiTimelineEntries,
        encodeBangumiTimelineEntries(entries),
      );
    } catch (error, stackTrace) {
      KazumiLogger().e(
        'Bangumi timeline entries save failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}
