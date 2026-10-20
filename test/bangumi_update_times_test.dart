import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/services/anilist_client.dart';
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

    test('AniList 缓存的「下一集」语义：新鲜 vs 已播', () {
      // lastUpdateEpoch 的「上一集」要按缓存新不新鲜分开算：
      // - 新鲜（now < airingAt）：下一集还没播，上一集 = airingAt − 周期
      // - 已过期（now >= airingAt）：那一集已经播了，airingAt 就是上一集，
      //   再减一个周期会多退一周
      // 这里锁住这两个判据本身，避免以后又把两个分支合并。
      final airingAt = first + 2 * week;
      final airing = AniListAiring(
        episode: 3,
        airingAt: airingAt,
        totalEpisodes: 12,
      );

      // 下一集播出前：缓存新鲜，上一集要回推一个周期。
      final before =
          DateTime.fromMillisecondsSinceEpoch(airingAt - 3600000);
      expect(airing.isFreshAt(before), isTrue);
      expect(airingAt - week, first + week);

      // 到点 / 过后：缓存不再新鲜，airingAt 自己就是刚播完的那一集。
      final after = DateTime.fromMillisecondsSinceEpoch(airingAt + 1000);
      expect(airing.isFreshAt(after), isFalse);
      expect(airingAt, first + 2 * week);
      // 这个分支如果再减一个周期，就会错到 first + week。
      expect(airingAt - week, isNot(airingAt));
    });
  });

  group('排序比较器', () {
    // 固定 UTC 时刻，测试结果不随运行时区漂移。
    final now = DateTime.utc(2026, 10, 18, 8);
    final first = DateTime.utc(2026, 10, 7, 15).millisecondsSinceEpoch;
    const week = 7 * 86400000;

    // 时间表排序：时刻来源由调用方给，测试里直接按 bangumi 数据表取
    // （线上是 AniList 优先、bangumi-mal 兜底，兜底分支就是这一条）。
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

    test('时间表：跨星期只比时刻，不比星期', () {
      // 列（星期）由分组决定，排序不再看时刻自带的星期。手动放进某一天
      // 的番、或者时刻来自另一个星期时，排序键只有「当天几点播」。
      final monday = DateTime(2026, 10, 5, 22, 30).millisecondsSinceEpoch;
      final friday = DateTime(2026, 10, 9, 20, 0).millisecondsSinceEpoch;
      final updates = _updates({
        1: _entry(monday, week),
        2: _entry(friday, week),
      });
      // 周五 20:00 比周一 22:30 早 —— 按时刻排，所以周五那条在前。
      // 按星期排的话会是反过来的（周一在前）。
      expect(compare([2, 1], updates, now), isNegative);
      expect(compare([1, 2], updates, now), isPositive);
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
      // 不变量，和具体哪部番无关：同一列里的顺序只能是「当天时刻从早到
      // 晚」，而排序用的那个 epoch 就是卡片上写出 HH:mm 的那个。对七个
      // 星期各取两个时刻验证，不依赖任何特定条目。
      for (var weekday = 1; weekday <= 7; weekday++) {
        // 2026-10-05 是周一，往后推 weekday-1 天就是该星期。
        final day = DateTime(2026, 10, 5 + weekday - 1);
        final earlyFirst = DateTime(day.year, day.month, day.day, 20, 0);
        final lateFirst = DateTime(day.year, day.month, day.day, 21, 0);
        final updates = _updates({
          1: _entry(earlyFirst.millisecondsSinceEpoch, week),
          2: _entry(lateFirst.millisecondsSinceEpoch, week),
        });

        final early = nextUpdateEpochFrom(updates[1], now)!;
        final late = nextUpdateEpochFrom(updates[2], now)!;

        expect(formatUpdateTime(early), '20:00', reason: 'weekday=$weekday');
        expect(formatUpdateTime(late), '21:00', reason: 'weekday=$weekday');

        // 同一列里 20:00 排在 21:00 前面，和卡片上的时刻一致。
        expect(compare([1, 2], updates, now), isNegative,
            reason: 'weekday=$weekday');
        expect(compare([2, 1], updates, now), isPositive,
            reason: 'weekday=$weekday');
      }
    });

    test('时间表：AniList 查不到时兜底 bangumi-mal', () {
      // 时刻链路固定是「AniList 实测优先，查不到兜底 bangumi-mal」。
      // 兜底条目按自己的时刻参与排序和胶囊，不会因为「兜底」而排到最后
      // 或者不显示时间。
      final updates = _updates({
        1: _entry(DateTime(2026, 10, 5, 21, 0).millisecondsSinceEpoch, week),
        2: _entry(DateTime(2026, 10, 6, 22, 0).millisecondsSinceEpoch, week),
      });
      // AniList 没有数据 -> 退回 bangumi-mal。
      final fallback = nextUpdateEpochFrom(updates[1], now);
      expect(fallback, isNotNull);
      expect(formatUpdateTime(fallback), '21:00');
      // 兜底条目按自己的时刻参与排序，不会因为「兜底」而排到最后。
      expect(compare([1, 2], updates, now), isNegative);
      expect(compare([2, 1], updates, now), isPositive);
    });

    test('时间表：手动放进某一天的番按自己的时刻落位', () {
      // 手动设置放送星期的番，它的更新时刻仍来自自己那一档（可能落在
      // 另一个星期）。排序只比当天时刻，所以它在该列里按自己的 HH:mm
      // 落位，不会因为时刻自带的星期被甩到别处。
      final inColumn = DateTime(2026, 10, 7, 22, 0); // 列内原生番
      final manual = DateTime(2026, 10, 9, 19, 30); // 手动放入，时刻是周五
      final updates = _updates({
        1: _entry(inColumn.millisecondsSinceEpoch, week),
        2: _entry(manual.millisecondsSinceEpoch, week),
      });
      // 19:30 在 22:00 前面，尽管两条时刻属于不同星期。
      expect(compare([2, 1], updates, now), isNegative);
      expect(compare([1, 2], updates, now), isPositive);
    });

    test('时间表：没有更新时刻的手动条目排在该列最后', () {
      // 手动添加的番可能不在最近两季的数据里（约 1/3 的当季番如此），
      // 拿不到时刻。它仍要留在用户指定的那一天，只是排到最后。
      final updates = _updates({
        1: _entry(DateTime(2026, 10, 7, 22, 0).millisecondsSinceEpoch, week),
      });
      expect(compare([1, 2], updates, now), isNegative);
      expect(compare([2, 1], updates, now), isPositive);
    });

    // 追番页排序走服务层单例（AniList 优先、bangumi-mal 兜底），数据要
    // 直接放进单例；测试里没有 AniList 缓存，所以走的一定是兜底分支。
    void withUpdates(Map<int, BangumiUpdateEntry> entries, void Function() body) {
      final service = BangumiUpdateTimesService.instance;
      final original = service.updates;
      service.updates = entries;
      try {
        body();
      } finally {
        service.updates = original;
      }
    }

    test('追番页：不在最近两季的排最下面', () {
      withUpdates({
        1: _entry(first, week),
      }, () {
        // 2 无数据（不在最近两季）-> 排在 1 后面。
        expect(
          compareCollectUpdateTime(_collected(2), _collected(1), now),
          isPositive,
        );
        expect(
          compareCollectUpdateTime(_collected(1), _collected(2), now),
          isNegative,
        );
      });
    });

    test('追番页：最近更新的在前', () {
      // 相位错开一个周期的一半，两条目的「上次更新」不会打平。
      withUpdates({
        1: _entry(first, week),
        2: _entry(first + week ~/ 2, week),
      }, () {
        // 2 的上次更新更晚 -> 排前面。
        expect(
          compareCollectUpdateTime(_collected(2), _collected(1), now),
          isNegative,
        );
      });
    });

    test('追番页：推不出更新时间的排最下面', () {
      // 只下载最近两季，所以「不在最近两季」和「推不出更新时间」是同一类：
      // 都排最下面。这里用周期缺失的条目代表这一类。
      withUpdates({
        1: _entry(first, week),
        2: _entry(first, null),
      }, () {
        expect(
          compareCollectUpdateTime(_collected(2), _collected(1), now),
          isPositive,
        );
        expect(
          compareCollectUpdateTime(_collected(1), _collected(2), now),
          isNegative,
        );
      });
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
