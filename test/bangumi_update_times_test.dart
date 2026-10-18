import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/services/bangumi_update_times.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';

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

    test('季节文件 URL 月份补零 + 按直连/镜像选源', () {
      // 加速模式显式注入，不触碰 GStorage（测试环境没有 Hive box）。
      expect(bangumiDataSeasonUrl(2026, 1, acceleration: BangumiAcceleration.direct),
          'https://raw.githubusercontent.com/bangumi-data/bangumi-data/master/data/items/2026/01.json');
      expect(bangumiDataSeasonUrl(2026, 10, acceleration: BangumiAcceleration.mirror),
          'https://cdn.jsdelivr.net/gh/bangumi-data/bangumi-data@master/data/items/2026/10.json');
      expect(bangumiDataSeasonUrl(2026, 7, acceleration: BangumiAcceleration.ech),
          contains('cdn.jsdelivr.net'));
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
    test('用条目自身 begin/broadcast，站点时间不参与', () {
      // type 用真实格式：bangumi-data 里是字符串 "tv"/"web"/"movie"，
      // 不是数字（写成数字会全部被跳过，时间表和排程都拿不到数据）。
      const source = '''
      [
        {
          "title": "A", "type": "tv", "begin": "2026-10-01T15:00:00.000Z",
          "broadcast": "R/2026-10-01T15:00:00.000Z/P7D",
          "sites": [
            {"site": "bangumi", "id": "100"},
            {"site": "mal", "id": "200"},
            {"site": "gamer", "id": "g1",
             "begin": "2026-10-02T16:00:00.000Z",
             "broadcast": "R/2026-10-02T16:00:00.000Z/P7D"}
          ]
        },
        {
          "title": "B", "type": "web", "begin": "2026-10-01T15:00:00.000Z",
          "sites": [{"site": "mal", "id": "201"}]
        },
        {"title": "C", "type": "movie", "sites": [{"site": "bangumi", "id": "300"}]},
        {"title": "D", "type": "ova", "sites": [{"site": "bangumi", "id": "400"}]}
      ]
      ''';
      final data = parseBangumiDataSeason(source);
      // movie / ova 一次性放送不参与更新时间。
      expect(data.updates.keys, [100]);
      // 只看条目自身的 begin，gamer 的站点 begin（晚一天）不参与。
      expect(data.updates[100]!.firstEpochMs,
          DateTime.parse('2026-10-01T15:00:00.000Z').millisecondsSinceEpoch);
      expect(data.updates[100]!.periodMs, 7 * 86400000);
      expect(data.malIds[100], 200);
    });

    test('损坏 JSON 返回空表', () {
      final data = parseBangumiDataSeason('not json');
      expect(data.updates, isEmpty);
      expect(data.malIds, isEmpty);
    });

    test('日期只有 date 无时刻时周期为 null', () {
      const source = '''
      [{"title": "A", "type": "tv", "begin": "2026-10-01",
        "sites": [{"site": "bangumi", "id": "1"}]}]
      ''';
      final data = parseBangumiDataSeason(source);
      // DateTime.tryParse('2026-10-01') 产生本地零点，length <= 10，
      // 不可信时刻 -> period 为 null。
      expect(data.updates[1]!.periodMs, isNull);
      expect(data.updates[1]!.firstEpochMs, isNotNull);
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

    test('时间表：无更新时间排最后', () {
      final updates = _updates({
        1: _entry(first, week),
      });
      // 2 无数据 -> 排在 1 后面。
      expect(
        compareTimelineUpdateTime(_item(1), _item(2), updates, now),
        isNegative,
      );
      expect(
        compareTimelineUpdateTime(_item(2), _item(1), updates, now),
        isPositive,
      );
    });

    test('时间表：更早更新在前', () {
      final updates = _updates({
        1: _entry(first, week),
        2: _entry(first + 3600000, week),
      });
      expect(
        compareTimelineUpdateTime(_item(1), _item(2), updates, now),
        isNegative,
      );
    });

    test('追番页：不在最近两季的排最上面', () {
      final updates = _updates({
        1: _entry(first, week),
      });
      // 2 无数据（不在最近两季）-> 排在 1 前面。
      expect(
        compareCollectUpdateTime(_collected(2), _collected(1), updates, now),
        isNegative,
      );
      expect(
        compareCollectUpdateTime(_collected(1), _collected(2), updates, now),
        isPositive,
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

    test('追番页：推不出更新时间的排最上面', () {
      // 只下载最近两季，所以「不在最近两季」和「推不出更新时间」是同一类：
      // 都排最上面。这里用周期缺失的条目代表这一类。
      final updates = _updates({
        1: _entry(first, week),
        2: _entry(first, null),
      });
      expect(
        compareCollectUpdateTime(_collected(2), _collected(1), updates, now),
        isNegative,
      );
      expect(
        compareCollectUpdateTime(_collected(1), _collected(2), updates, now),
        isPositive,
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
