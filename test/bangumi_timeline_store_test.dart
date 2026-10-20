import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/services/storage/bangumi_timeline_store.dart';

void main() {
  group('BangumiTimelineEntry encode / decode', () {
    test('round trips entries', () {
      final encoded = encodeBangumiTimelineEntries(
        <int, BangumiTimelineEntry>{
          1: BangumiTimelineEntry(weekday: 7, showInTimeline: true),
          2: BangumiTimelineEntry(weekday: 3),
        },
      );

      final decoded = decodeBangumiTimelineEntries(encoded);

      expect(decoded.length, 2);
      expect(decoded[1]!.weekday, 7);
      expect(decoded[1]!.showInTimeline, isTrue);
      expect(decoded[2]!.weekday, 3);
      expect(decoded[2]!.showInTimeline, isFalse);
    });

    test('returns empty map for empty content', () {
      expect(encodeBangumiTimelineEntries(<int, BangumiTimelineEntry>{}), '');
      expect(decodeBangumiTimelineEntries(''), isEmpty);
      expect(decodeBangumiTimelineEntries(null), isEmpty);
    });

    test('skips broken entries instead of throwing', () {
      final decoded = decodeBangumiTimelineEntries(
        '{"3":{"weekday":2,"show":true},"4":{"weekday":"x"},"5":8}',
      );

      expect(decoded.containsKey(4), isFalse);
      expect(decoded.containsKey(5), isFalse);
      expect(decoded[3]!.weekday, 2);
    });

    test('returns empty map for invalid json', () {
      expect(decodeBangumiTimelineEntries('{"3":'), isEmpty);
      expect(decodeBangumiTimelineEntries('[1,2,3]'), isEmpty);
    });

    test('clamps stored weekday into 1-7', () {
      final decoded = decodeBangumiTimelineEntries('{"6":{"weekday":42}}');

      expect(decoded[6]!.weekday, 7);
      expect(normalizeBangumiWeekday(0), 1);
      expect(normalizeBangumiWeekday(-3), 1);
    });
  });

  group('bangumiKeepsTimelineEntry', () {
    test('keeps only watching bangumis', () {
      expect(bangumiKeepsTimelineEntry(CollectType.watching.value), isTrue);
      expect(bangumiKeepsTimelineEntry(CollectType.planToWatch.value), isFalse);
      expect(bangumiKeepsTimelineEntry(CollectType.onHold.value), isFalse);
      expect(bangumiKeepsTimelineEntry(CollectType.watched.value), isFalse);
      expect(bangumiKeepsTimelineEntry(CollectType.abandoned.value), isFalse);
      expect(bangumiKeepsTimelineEntry(CollectType.none.value), isFalse);
    });
  });

  group('mergeBangumiTimelineEntries', () {
    test('moves an existing bangumi to the selected weekday', () {
      final calendar = _emptyCalendar();
      calendar[3].add(_item(10));

      final merged = mergeBangumiTimelineEntries(
        base: calendar,
        weekdays: <int, int>{10: 7},
        items: <int, BangumiItem>{10: _item(10)},
      );

      expect(merged[3], isEmpty);
      expect(merged[6].map((item) => item.id), <int>[10]);
    });

    test('adds a bangumi missing from the calendar', () {
      final calendar = _emptyCalendar();

      final merged = mergeBangumiTimelineEntries(
        base: calendar,
        weekdays: <int, int>{7: 2},
        items: <int, BangumiItem>{7: _item(7)},
      );

      expect(merged[1].map((item) => item.id), <int>[7]);
      expect(merged[1].length, 1);
    });

    test('keeps untouched days in order', () {
      final calendar = _emptyCalendar();
      calendar[0].addAll(<BangumiItem>[_item(1), _item(2)]);
      calendar[6].add(_item(9));

      final merged = mergeBangumiTimelineEntries(
        base: calendar,
        weekdays: <int, int>{9: 1},
        items: <int, BangumiItem>{9: _item(9)},
      );

      expect(merged[0].map((item) => item.id), <int>[1, 2, 9]);
      expect(merged[6], isEmpty);
    });

    test('pads the calendar to seven days', () {
      final merged = mergeBangumiTimelineEntries(
        base: <List<BangumiItem>>[
          <BangumiItem>[_item(1)],
        ],
        weekdays: <int, int>{2: 5},
        items: <int, BangumiItem>{2: _item(2)},
      );

      expect(merged.length, 7);
      expect(merged[4].map((item) => item.id), <int>[2]);
      expect(merged[0].map((item) => item.id), <int>[1]);
    });

    test('ignores entries without bangumi details', () {
      final calendar = _emptyCalendar();

      final merged = mergeBangumiTimelineEntries(
        base: calendar,
        weekdays: <int, int>{3: 4},
        items: <int, BangumiItem>{},
      );

      expect(merged, same(calendar));
    });

    test('returns base when nothing to merge', () {
      final calendar = _emptyCalendar();

      expect(
        mergeBangumiTimelineEntries(
          base: calendar,
          weekdays: <int, int>{},
          items: <int, BangumiItem>{},
        ),
        same(calendar),
      );
      expect(
        mergeBangumiTimelineEntries(
          base: <List<BangumiItem>>[],
          weekdays: <int, int>{1: 1},
          items: <int, BangumiItem>{1: _item(1)},
        ),
        isEmpty,
      );
    });
  });
}

List<List<BangumiItem>> _emptyCalendar() {
  return List<List<BangumiItem>>.generate(7, (_) => <BangumiItem>[]);
}

BangumiItem _item(int id) {
  return BangumiItem(
    id: id,
    type: 2,
    name: 'subject $id',
    nameCn: '条目 $id',
    summary: '',
    airDate: '2026-01-01',
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
