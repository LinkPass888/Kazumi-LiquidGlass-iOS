import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/utils/anime_season.dart';
import 'package:kazumi/repositories/collect_repository.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/bangumi_timeline_store.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:mobx/mobx.dart';

part 'timeline_controller.g.dart';

enum TimelineSort { popularity, rating, defaultOrder }

class TimelineController = _TimelineController with _$TimelineController;

abstract class _TimelineController with Store {
  _TimelineController(this._collectRepository);

  final ICollectRepository _collectRepository;

  @observable
  ObservableList<List<BangumiItem>> bangumiCalendar =
      ObservableList<List<BangumiItem>>();

  /// 接口返回的原始日历，详情页的自定义条目每次都从它重新合并
  List<List<BangumiItem>> _baseBangumiCalendar = [];

  @readonly
  DateTime _selectedDate = DateTime.now();

  @observable
  bool isLoading = false;

  @observable
  bool isTimeOut = false;

  @observable
  late bool notShowAbandonedBangumis =
      _collectRepository.getTimelineNotShowAbandonedBangumis();

  @observable
  late bool notShowWatchedBangumis =
      _collectRepository.getTimelineNotShowWatchedBangumis();

  @observable
  late bool onlyShowWatchingBangumis =
      _collectRepository.getTimelineOnlyShowWatchingBangumis();

  @readonly
  TimelineSort _sort = TimelineSort.popularity;

  bool get _bangumiMirrorEnabled =>
      BangumiAcceleration.current == BangumiAcceleration.mirror;

  @action
  Future<void> loadSeason(DateTime date) async {
    if (isLoading) return;
    isLoading = true;
    isTimeOut = false;
    try {
      _selectedDate = date;
      bangumiCalendar.clear();
      if (isSameSeason(date, DateTime.now())) {
        _setBangumiCalendarBase(await BangumiApi.getCalendar());
        isTimeOut = bangumiCalendar.isEmpty;
      } else {
        await _getSchedulesBySeason(date);
        _setBangumiCalendarBase(bangumiCalendar.toList());
        isTimeOut = bangumiCalendar.every((day) => day.isEmpty);
      }
      if (!isTimeOut) {
        _applyCustomTimelineEntries();
        changeSort(_sort);
      }
    } catch (error, stackTrace) {
      isTimeOut = true;
      KazumiLogger().e('Timeline: loading season failed',
          error: error, stackTrace: stackTrace);
    } finally {
      isLoading = false;
    }
  }

  // MobX batches clear/addAll between awaits so observers never see a partial update.
  @action
  Future<void> _getSchedulesBySeason(DateTime date) async {
    final dateRange = AnimeSeason(date).toSeasonStartAndEnd();
    if (_bangumiMirrorEnabled) {
      bangumiCalendar
          .addAll(await BangumiApi.getBangumiMirrorSeasonCalendar(dateRange));
      return;
    }

    const pageCount = 4;
    const limit = 20;
    final resBangumiCalendar = List.generate(7, (_) => <BangumiItem>[]);
    for (var page = 0; page < pageCount; page++) {
      final newList =
          await BangumiApi.getCalendarBySearch(dateRange, limit, page * limit);
      for (int i = 0; i < resBangumiCalendar.length; ++i) {
        resBangumiCalendar[i].addAll(newList[i]);
      }
      bangumiCalendar.clear();
      bangumiCalendar.addAll(resBangumiCalendar);
    }
  }

  @action
  void changeSort(TimelineSort sort) {
    _sort = sort;
    final Comparator<BangumiItem> compare = switch (sort) {
      TimelineSort.popularity => (a, b) => b.votes.compareTo(a.votes),
      TimelineSort.rating => (a, b) => b.ratingScore.compareTo(a.ratingScore),
      TimelineSort.defaultOrder => (a, b) => a.id.compareTo(b.id),
    };
    final resBangumiCalendar = bangumiCalendar.toList();
    for (final dayList in resBangumiCalendar) {
      dayList.sort(compare);
    }
    bangumiCalendar.clear();
    bangumiCalendar.addAll(resBangumiCalendar);
  }

  /// 保存接口返回的原始日历，并把展示用日历重置为它的副本
  void _setBangumiCalendarBase(List<List<BangumiItem>> calendar) {
    _baseBangumiCalendar = calendar
        .map((dayList) => List<BangumiItem>.from(dayList))
        .toList();
    _resetBangumiCalendarFromBase();
  }

  void _resetBangumiCalendarFromBase() {
    bangumiCalendar.clear();
    bangumiCalendar.addAll(
      _baseBangumiCalendar
          .map((dayList) => List<BangumiItem>.from(dayList))
          .toList(),
    );
  }

  /// 把番剧详情页设置的「在时间表展示」条目合并进日历
  void _applyCustomTimelineEntries() {
    if (bangumiCalendar.isEmpty) {
      return;
    }
    final weekdays = BangumiTimelineStore.loadShownWeekdays();
    if (weekdays.isEmpty) {
      return;
    }
    final items = <int, BangumiItem>{};
    for (final collectible in GStorage.collectibles.values) {
      final bangumiItem = collectible.bangumiItem;
      if (!weekdays.containsKey(bangumiItem.id)) {
        continue;
      }
      if (!bangumiKeepsTimelineEntry(collectible.type)) {
        continue;
      }
      items[bangumiItem.id] = bangumiItem;
    }
    if (items.isEmpty) {
      return;
    }
    final merged = mergeBangumiTimelineEntries(
      base: bangumiCalendar,
      weekdays: weekdays,
      items: items,
    );
    bangumiCalendar.clear();
    bangumiCalendar.addAll(merged);
  }

  /// 详情页修改自定义条目后刷新时间表
  void refreshCustomTimelineEntries() {
    if (_baseBangumiCalendar.isEmpty) {
      return;
    }
    _resetBangumiCalendarFromBase();
    _applyCustomTimelineEntries();
    changeSort(_sort);
  }

  @action
  Future<void> setNotShowAbandonedBangumis(bool value) async {
    notShowAbandonedBangumis = value;
    await _collectRepository.updateTimelineNotShowAbandonedBangumis(value);
  }

  @action
  Future<void> setNotShowWatchedBangumis(bool value) async {
    notShowWatchedBangumis = value;
    await _collectRepository.updateTimelineNotShowWatchedBangumis(value);
  }

  @action
  Future<void> setOnlyShowWatchingBangumis(bool value) async {
    onlyShowWatchingBangumis = value;
    await _collectRepository.updateTimelineOnlyShowWatchingBangumis(value);
  }

  Set<int> loadWatchingBangumiIds() {
    return _collectRepository.getBangumiIdsByType(CollectType.watching);
  }

  int get activeFilterCount => [
        onlyShowWatchingBangumis,
        notShowWatchedBangumis,
        notShowAbandonedBangumis,
      ].where((enabled) => enabled).length;

  List<List<BangumiItem>> filterCalendar(Set<int> watchingIds) {
    final abandonedIds = notShowAbandonedBangumis
        ? _collectRepository.getBangumiIdsByType(CollectType.abandoned)
        : <int>{};
    final watchedIds = notShowWatchedBangumis
        ? _collectRepository.getBangumiIdsByType(CollectType.watched)
        : <int>{};
    final onlyWatching = onlyShowWatchingBangumis;
    return List.generate(7, (day) {
      if (day >= bangumiCalendar.length) return <BangumiItem>[];
      return bangumiCalendar[day]
          .where((item) =>
              !abandonedIds.contains(item.id) &&
              !watchedIds.contains(item.id) &&
              (!onlyWatching || watchingIds.contains(item.id)))
          .toList();
    });
  }

  @action
  Future<void> clearFilters() async {
    await Future.wait([
      setNotShowAbandonedBangumis(false),
      setNotShowWatchedBangumis(false),
      setOnlyShowWatchingBangumis(false),
    ]);
  }
}
