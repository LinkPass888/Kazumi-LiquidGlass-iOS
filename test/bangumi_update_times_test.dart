import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/services/bangumi_update_times.dart';

BangumiUpdateEntry _entry(int? first, int? period) =>
    BangumiUpdateEntry(first, period);

Map<int, BangumiUpdateEntry> _updates(Map<int, BangumiUpdateEntry> entries) =>
    entries;

BangumiItem _item(int id) {
  return BangumiItem(
    id: id,
    type: 2,
    name: 'subject $id',
    nameCn: '条目 $id',
    summary: '',
    airDate: '2026-10-01',
    airWeekday: 4,
    rank: 0,
    images: const {
      'large': '',
      'common': '',
      'medium': '',
      'small': '',
      'grid': '',
    },
    tags: const <BangumiTag>[],
    alias: const [],
    ratingScore: 0,
    votes: 0,
    votesCount: const [],
    info: '',
  );
}

CollectedBangumi _collected(int id) {
  return CollectedBangumi(_item(id), DateTime.now(), 1);
}

void main() {
  group('季节推导', () {
    test('当前季节只落在 1/4/7/10', () {
      expect(currentBangumiDataSeason(DateTime(2026, 10, 18)), (2026, 10));
      expect(currentBangumiDataSeason(DateTime(2026, 12, 31)), (2026, 10));
      expect(currentBangumiDataSeason(DateTime(2026, 1, 1)), (2026, 1));
      expect(currentBangumiDataSeason(DateTime(2026, 4, 15)), (2026, 4));
      expect(currentBangumiDataSeason(DateTime(2026, 7, 2)), (2026, 7));
    });

    test('上一季跨年回退到去年 10 月', () {
      expect(previousBangumiDataSeason(DateTime(2026, 1, 1)), (2025, 10));
      expect(previousBangumiDataSeason(DateTime(2026, 10, 18)), (2026, 7));
      expect(previousBangumiDataSeason(DateTime(2026, 4, 1)), (2026, 1));
    });

    test('季节文件 URL 月份补零', () {
      // 统一走 GitHub Pages，加速设置不再影响地址。
      expect(bangumiMalSeasonUrl(2026, 1),
          'https://linkpass888.github.io/bangumi-mal/data/seasons/2026/01.json');
      expect(bangumiMalSeasonUrl(2026, 10),
          'https://linkpass888.github.io/bangumi-mal/data/seasons/2026/10.json');
      expect(bangumiMalSeasonUrl(2026, 7),
          'https://linkpass888.github.io/bangumi-mal/data/seasons/2026/07.json');
    });
  });

  group('broadcast 周期解析', () {
    test('标准 R/<ISO>/P7D', () {
      expect(parseIsoBroadcast('R/2026-10-07T15:00:00.000Z/P7D'),
          7 * 86400000);
    });

    test('带小时周期', () {
      expect(parseIsoBroadcast('R/2026-10-07T15:00:00.000Z/P1DT2H'),
          86400000 + 2 * 3600000);
    });

    test('非法输入返回 null', () {
      expect(parseIsoBroadcast(null), isNull);
      expect(parseIsoBroadcast(''), isNull);
      expect(parseIsoBroadcast('P7D'), isNull);
      expect(parseIsoBroadcast('R/2026-10-07T15:00:00.000Z/P0D'), isNull);
      expect(parseIsoBroadcast('R/2026-10-07T15:00:00.000Z/P7W'), isNull);
    });
  });

  group('季节 JSON 解析', () {
    test('bangumi-mal 季节格式：begin/broadcast/mal_id', () {
      const source = '''
      {
        "season": "2026-10", "count": 2,
        "items": {
          "100": {"bangumi_id": 100, "mal_id": 200,
            "begin": "2026-10-01T15:00:00.000Z",
            "broadcast": "R/2026-10-01T15:00:00.000Z/P7D"},
          "101": {"bangumi_id": 101, "mal_id": null,
            "begin": "2026-10-02T15:00:00.000Z", "broadcast": null}
        }
      }
      ''';
      final data = parseBangumiMalSeason(source);
      expect(data.updates.keys, [100, 101]);
      expect(data.updates[100]!.firstEpochMs,
          DateTime.parse('2026-10-01T15:00:00.000Z').millisecondsSinceEpoch);
      expect(data.updates[100]!.periodMs, 7 * 86400000);
      expect(data.updates[101]!.periodMs, isNull);
      // 没有 MAL id 的条目不写进映射表。
      expect(data.malIds, {100: 200});
    });

    test('损坏 JSON 返回空表', () {
      final data = parseBangumiMalSeason('not json');
      expect(data.updates, isEmpty);
      expect(data.malIds, isEmpty);
    });

    test('缺 items 字段返回空表', () {
      final data = parseBangumiMalSeason('{"season": "2026-10"}');
      expect(data.updates, isEmpty);
      expect(data.malIds, isEmpty);
    });
  });

  group('更新时刻推算', () {
    final first = DateTime.utc(2026, 10, 7, 15).millisecondsSinceEpoch;
    const week = 7 * 86400000;

    test('开播前返回 first', () {
      final now = DateTime.fromMillisecondsSinceEpoch(first - 1000);
      expect(nextUpdateEpochFrom(_entry(first, week), now), first);
    });

    test('开播后外推到下一个整周期', () {
      final now =
          DateTime.fromMillisecondsSinceEpoch(first + week + 3600000);
      expect(nextUpdateEpochFrom(_entry(first, week), now), first + 2 * week);
      expect(
          lastUpdateEpochFrom(_entry(first, week), now), first + week);
    });

    test('恰好落在更新点上', () {
      final now =
          DateTime.fromMillisecondsSinceEpoch(first + 2 * week);
      expect(nextUpdateEpochFrom(_entry(first, week), now), first + 2 * week);
      expect(lastUpdateEpochFrom(_entry(first, week), now),
          first + 2 * week);
    });

    test('缺字段返回 null', () {
      final now = DateTime.now();
      expect(nextUpdateEpochFrom(null, now), isNull);
      expect(nextUpdateEpochFrom(_entry(first, null), now), isNull);
      expect(lastUpdateEpochFrom(_entry(first, null), now), isNull);
    });

    test('未开播时 last 为 null', () {
      final now = DateTime.fromMillisecondsSinceEpoch(first - 1000);
      expect(lastUpdateEpochFrom(_entry(first, week), now), isNull);
    });
  });

  group('排序比较器', () {
    // 固定 UTC 时刻，测试结果不随运行时区漂移。
    final now = DateTime.utc(2026, 10, 18, 8);
    final first = DateTime.utc(2026, 10, 7, 15).millisecondsSinceEpoch;
    const week = 7 * 86400000;

    // 时间表排序：时刻来源由调用方给，测试里直接按 bangumi 数据表取，
    // 和线上 `timelineUpdateEpoch(preferAniList: false)` 一致。
    int compare(List<int> entryIds, Map<int, BangumiUpdateEntry> updates,
        DateTime at) {
      return compareTimelineUpdateTime(
        _item(entryIds[0]),
        _item(entryIds[1]),
        at,
        epochFor: (id) => nextUpdateEpochFrom(updates[id], at),
      );
    }

    test('时间表：无更新时间排最后', () {
      final updates = _updates({
        1: _entry(first, week),
      });
      // 2 无数据 -> 排在 1 后面。
      expect(compare([1, 2], updates, now), isNegative);
      expect(compare([2, 1], updates, now), isPositive);
    });

    test('时间表：更早更新在前', () {
      final updates = _updates({
        1: _entry(first, week),
        2: _entry(first + 3600000, week),
      });
      expect(compare([1, 2], updates, now), isNegative);
    });

    test('时间表：同一天内按当天时刻排，不按「下一次」的绝对时刻', () {
      // 周日 00:00 档和周日 10:00 档。
      final midnight = DateTime(2026, 10, 4, 0, 0).millisecondsSinceEpoch;
      final morning = DateTime(2026, 10, 4, 10, 0).millisecondsSinceEpoch;
      final updates = _updates({
        1: _entry(midnight, week),
        2: _entry(morning, week),
      });
      // 周日凌晨 5 点加载：0 点档已经过了、下一次在下周日，10 点档就在
      // 今天 —— 直接比绝对时刻会把 10 点档排到 0 点档前面。按当天时刻则
      // 0 点档在前，和加载时刻无关。
      final sundayDawn = DateTime(2026, 10, 4, 5);
      expect(compare([1, 2], updates, sundayDawn), isNegative);
      expect(compare([2, 1], updates, sundayDawn), isPositive);
    });

    test('时间表：跨星期按星期几从周一到周日', () {
      // 只在「无更新时间的番留在原分组」这种混排时才会比较到跨星期。
      final monday = DateTime(2026, 10, 5, 22, 30).millisecondsSinceEpoch;
      final friday = DateTime(2026, 10, 9, 22, 30).millisecondsSinceEpoch;
      final updates = _updates({
        1: _entry(monday, week),
        2: _entry(friday, week),
      });
      expect(compare([1, 2], updates, now), isNegative);
    });

    test('时间表：同一星期几按当天时刻从早到晚', () {
      final early = DateTime(2026, 10, 9, 18).millisecondsSinceEpoch;
      final late = DateTime(2026, 10, 9, 23, 30).millisecondsSinceEpoch;
      final updates = _updates({
        1: _entry(early, week),
        2: _entry(late, week),
      });
      expect(compare([1, 2], updates, now), isNegative);
    });

    test('时间表：排序键就是卡片显示的时刻（同一来源）', () {
      // 回归：周六 20:00 的番曾因为排序用 bangumi-mal 的「首播那一集」
      // 时刻（周一 22:30）而排到周一 21:00 的番后面，卡片却显示 20:00。
      // 现在排序和显示取同一个 epoch，两者的相位必然一致。
      final updates = _updates({
        1: _entry(DateTime(2026, 10, 3, 20, 0).millisecondsSinceEpoch, week),
        2: _entry(DateTime(2026, 10, 5, 21, 0).millisecondsSinceEpoch, week),
      });
      final epoch = nextUpdateEpochFrom(updates[1], now);
      final shown = DateTime.fromMillisecondsSinceEpoch(epoch!);
      // 卡片写的「HH:mm」来自同一个 epoch。
      expect(formatUpdateTime(epoch), '20:00');
      expect(shown.weekday, DateTime.saturday);
      // 周六 20:00 排在周一 21:00 前面（同一列里不会出现跨星期混排）。
      expect(compare([1, 2], updates, now), isNegative);
    });

    test('时间表：AniList 查不到时兜底 bangumi-mal，兜底后三者仍一致', () {
      // 服务层的兜底逻辑：preferAniList 时 AniList 没数据就走
      // nextUpdateEpochFrom(bangumi-mal)。这里直接验证「兜底后拿到的
      // 那个 epoch」同时决定星期、排序和卡片上的 HH:mm —— 也就是
      // 兜底不会让分组/排序/显示分家，只是那一天可能不准。
      final updates = _updates({
        1: _entry(DateTime(2026, 10, 5, 21, 0).millisecondsSinceEpoch, week),
        2: _entry(DateTime(2026, 10, 6, 22, 0).millisecondsSinceEpoch, week),
      });
      // AniList 没有数据 -> 退回 bangumi-mal。
      final fallback = nextUpdateEpochFrom(updates[1], now);
      expect(fallback, isNotNull);
      final shown = DateTime.fromMillisecondsSinceEpoch(fallback!);
      expect(shown.weekday, DateTime.monday);
      expect(formatUpdateTime(fallback), '21:00');
      // 兜底条目按自己的时刻参与排序，不会因为「兜底」而排到最后。
      expect(compare([1, 2], updates, now), isNegative);
      expect(compare([2, 1], updates, now), isPositive);
    });

    test('追番页：不在最近两季的排最下面', () {
      final updates = _updates({
        1: _entry(first, week),
      });
      // 2 无数据（不在最近两季）-> 排在 1 后面。
      expect(
        compareCollectUpdateTime(_collected(2), _collected(1), updates, now),
        isPositive,
      );
      expect(
        compareCollectUpdateTime(_collected(1), _collected(2), updates, now),
        isNegative,
      );
    });

    test('追番页：最近更新的在前', () {
      // 相位错开一个周期的一半，两条目的「上次更新」不会打平。
      final updates = _updates({
        1: _entry(first, week),
        2: _entry(first + week ~/ 2, week),
      });
      // 2 的上次更新更晚 -> 排前面。
      expect(
        compareCollectUpdateTime(_collected(2), _collected(1), updates, now),
        isNegative,
      );
    });

    test('追番页：推不出更新时间的排最下面', () {
      // 只下载最近两季，所以「不在最近两季」和「推不出更新时间」是同一类：
      // 都排最下面。这里用周期缺失的条目代表这一类。
      final updates = _updates({
        1: _entry(first, week),
        2: _entry(first, null),
      });
      expect(
        compareCollectUpdateTime(_collected(2), _collected(1), updates, now),
        isPositive,
      );
      expect(
        compareCollectUpdateTime(_collected(1), _collected(2), updates, now),
        isNegative,
      );
    });
  });

  group('formatUpdateTime', () {
    test('格式为 HH:mm', () {
      final ms = DateTime(2026, 10, 15, 18, 30).millisecondsSinceEpoch;
      expect(formatUpdateTime(ms), '18:30');
    });

    test('补零', () {
      final ms = DateTime(2026, 10, 15, 9, 5).millisecondsSinceEpoch;
      expect(formatUpdateTime(ms), '09:05');
    });

    test('null 返回 null', () {
      expect(formatUpdateTime(null), isNull);
    });
  });
}
