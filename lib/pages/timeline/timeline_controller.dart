import 'dart:async';

import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/bangumi_update_times.dart';
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
  TimelineSort _sort = TimelineSort.defaultOrder;

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
        // 把详情页设置的「在时间表展示」条目并进来，再排一次。
        _applyCustomTimelineEntries();
        changeSort(_sort);
        // 更新时间数据异步到达后必须重排一次：changeSort 会改写
        // bangumiCalendar，Observer 随之重建，卡片的更新时间文案才能从
        // 初始空值刷新出来。数据为空时重排无副作用。
        unawaited(BangumiUpdateTimesService.instance.ensureLoaded().then((_) {
          changeSort(_sort);
        }));
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
    final now = DateTime.now();
    // 一次排序内把时刻固定下来：比较器会被调用几百次，每次都重算
    // 既慢，又可能在数据刚到时不前后一致。
    final epochs = <int, int?>{};
    int? epochFor(int id) => epochs.putIfAbsent(
          id,
          () => BangumiUpdateTimesService.instance.timelineUpdateEpoch(
            id,
            now: now,
          ),
        );
    final Comparator<BangumiItem> compare = switch (sort) {
      TimelineSort.popularity => (a, b) => b.votes.compareTo(a.votes),
      TimelineSort.rating => (a, b) => b.ratingScore.compareTo(a.ratingScore),
      // 默认顺序即按当天更新时刻从早到晚，无更新时间的排当日最后。
      // 时刻和卡片胶囊同一个（timelineUpdateEpoch），列由分组决定。
      TimelineSort.defaultOrder => (a, b) =>
          compareTimelineUpdateTime(a, b, now, epochFor: epochFor),
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
    invalidateCollectedWeekdays();
  }

  void _resetBangumiCalendarFromBase() {
    bangumiCalendar.clear();
    bangumiCalendar.addAll(
      _baseBangumiCalendar
          .map((dayList) => List<BangumiItem>.from(dayList))
          .toList(),
    );
  }

  /// 时间表里各番实际所在的星期：0 = 星期一 ... 6 = 星期日。
  ///
  /// 追番页的「更新时间」排序用它，和时间表分组同一个来源。日历加载完
  /// 之后才有值，所以带上一次加载的完整日历，而不是只读当前展示的
  /// [bangumiCalendar]（点了星期筛选 / 详情页还没刷新时它可能不全）。
  Map<int, int> get timelineWeekdays {
    final weekdays = <int, int>{};
    for (var day = 0; day < _baseBangumiCalendar.length; day++) {
      for (final bangumiItem in _baseBangumiCalendar[day]) {
        weekdays[bangumiItem.id] = day;
      }
    }
    for (final entry in BangumiTimelineStore.loadCustomWeekdays().entries) {
      weekdays[entry.key] = entry.value - 1;
    }
    return weekdays;
  }

  /// 追番页收藏里的番 -> 放送星期（1 = 星期一 ... 7 = 星期日）。
  ///
  /// 优先级和时间表一致：用户手动选的星期 → bangumi 日历的分组 → 条目
  /// 自己的开播日星期（时间表还没加载过时的兜底）。追番页可能先于时间表
  /// 打开，那时日历是空的，只能靠开播日先给出一个可排序的值，日历加载
  /// 后 [invalidateCollectedWeekdays] 会让它重算。缓存到下一轮刷新，
  /// 比较器会被调用几十次，不能每次都重读设置。
  Map<int, int>? _collectedWeekdays;

  Map<int, int> collectedWeekdays() {
    final cached = _collectedWeekdays;
    if (cached != null) return cached;
    final weekdays = <int, int>{};
    final calendar = timelineWeekdays;
    final custom = BangumiTimelineStore.loadCustomWeekdays();
    for (final collectible in GStorage.collectibles.values) {
      final bangumiId = collectible.bangumiItem.id;
      weekdays[bangumiId] = custom[bangumiId] ??
          (calendar[bangumiId] != null
              ? calendar[bangumiId]! + 1
              : normalizeBangumiWeekday(collectible.bangumiItem.airWeekday));
    }
    _collectedWeekdays = weekdays;
    return weekdays;
  }

  /// 时间表加载完 / 详情页改了星期后，让追番页的下一次排序重新取值。
  ///
  /// 同时递增 [collectedWeekdaysRevision]：追番页用 mobx reaction 观察它，
  /// 在详情页改完星期返回时能立刻重排，不必等切 tab。
  @action
  void invalidateCollectedWeekdays() {
    _collectedWeekdays = null;
    collectedWeekdaysRevision++;
  }

  @observable
  int collectedWeekdaysRevision = 0;

  /// 把详情页设置的条目并进日历（改放送星期 / 开关「在时间表展示」）。
  ///
  /// 星期只看两处：bangumi 日历原本的分组，以及用户点选过的放送星期。
  /// 不再按更新时刻反推星期 —— AniList 的 airingAt 跟的是先行配信，
  /// bangumi 的放送星期跟的是电视放送，拿时刻反推会把番挪到错误的星期。
  /// 哪一条算「用户选的」由 [resolveTimelineWeekdays] 决定。
  ///
  /// 每次合并都从 [_baseBangumiCalendar] 重新开始：用户改掉某部番的
  /// 放送星期后，它要能从原来的那一天挪走，而不是两处都留一份。
  void _applyCustomTimelineEntries() {
    if (_baseBangumiCalendar.isEmpty) {
      return;
    }
    final shown = BangumiTimelineStore.loadShownWeekdays();
    final custom = BangumiTimelineStore.loadCustomWeekdays();
    if (shown.isEmpty && custom.isEmpty) {
      return;
    }

    // 日历里已有的番：手动改星期时不用去收藏里找副本。
    final baseItems = <int, BangumiItem>{};
    for (final dayList in _baseBangumiCalendar) {
      for (final bangumiItem in dayList) {
        baseItems[bangumiItem.id] = bangumiItem;
      }
    }

    final collectTypes = <int, int>{};
    final items = <int, BangumiItem>{};
    for (final collectible in GStorage.collectibles.values) {
      final bangumiItem = collectible.bangumiItem;
      collectTypes[bangumiItem.id] = collectible.type;
      items[bangumiItem.id] = bangumiItem;
    }
    items.addAll(baseItems);

    final weekdays = resolveTimelineWeekdays(
      shown: shown,
      custom: custom,
      inCalendar: baseItems.keys.toSet(),
      collectTypes: collectTypes,
    );
    if (weekdays.isEmpty) {
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

  /// 番剧在时间表里的分组（1 = 星期一）。
  ///
  /// 顺序和合并时一致：用户选过的星期 → bangumi 日历里的分组。两者都
  /// 不知道（详情页先于时间表打开）时返回 null，由调用方退回自己的默认值。
  ///
  /// 只开「在时间表展示」写进来的星期不算：那只是当时所在的列，没有
  /// 「换列」的意思（见 [resolveTimelineWeekdays]）。
  int? timelineWeekdayOf(int bangumiId) {
    final custom = BangumiTimelineStore.loadCustomWeekdays()[bangumiId];
    if (custom != null) return custom;
    for (var day = 0; day < _baseBangumiCalendar.length; day++) {
      for (final bangumiItem in _baseBangumiCalendar[day]) {
        if (bangumiItem.id == bangumiId) return day + 1;
      }
    }
    return null;
  }

  /// 这部番在时间表里能不能看到：bangumi 日历里有，或者开了「在时间表
  /// 展示」。详情页据此决定改完星期后要不要提示去点亮图标。
  bool isInTimeline(int bangumiId) {
    if (BangumiTimelineStore.entryOf(bangumiId)?.showInTimeline ?? false) {
      return true;
    }
    for (final dayList in _baseBangumiCalendar) {
      for (final bangumiItem in dayList) {
        if (bangumiItem.id == bangumiId) return true;
      }
    }
    return false;
  }

  /// 详情页修改自定义条目后刷新时间表（改放送星期 / 开关「在时间表展示」）。
  @action
  void refreshCustomTimelineEntries() {
    // 星期变了，追番页的「更新时间」排序也要重排。
    invalidateCollectedWeekdays();
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

  /// 单部番剧的具体更新时刻（epoch ms）：AniList 实测优先，bangumi-mal
  /// 兜底。排序和卡片胶囊共用它；星期不从这里推（见 [_applyCustomTimelineEntries]）。
  int? timelineUpdateEpoch(int bangumiId, {DateTime? now}) =>
      BangumiUpdateTimesService.instance.timelineUpdateEpoch(
        bangumiId,
        now: now,
      );

  /// 单部番剧的下一次更新时间（epoch ms），详情页等非时间表场景用。
  int? nextUpdateEpoch(int bangumiId) =>
      BangumiUpdateTimesService.instance.nextUpdateEpoch(bangumiId);

  /// 单部番剧已更新到第几集，卡片集数胶囊用。
  int? currentEpisode(int bangumiId) =>
      BangumiUpdateTimesService.instance.currentEpisode(bangumiId);

  /// 只给指定星期（0 = 周一 ... 6 = 周日）的番补 AniList 实测状态。
  /// 切 tab 时调到对应那一天，只为拿到准确的时刻与集数。
  Future<void> ensureAniListForDay(int dayIndex) async {
    if (dayIndex < 0 || dayIndex >= bangumiCalendar.length) return;
    final ids = bangumiCalendar[dayIndex].map((item) => item.id).toList();
    if (ids.isEmpty) return;
    await BangumiUpdateTimesService.instance.ensureAniListLoaded(ids);
    // 时刻变了要重排（分组不动）。
    changeSort(_sort);
  }

  /// 当天所有番的更新时刻（bangumi id -> epoch ms），卡片时间胶囊用。
  /// 和排序同一个入口 [timelineUpdateEpoch]，同一列里胶囊和先后不会分家。
  Map<int, int> updateEpochsForDay(int dayIndex) {
    if (dayIndex < 0 || dayIndex >= bangumiCalendar.length) return const {};
    final now = DateTime.now();
    final result = <int, int>{};
    for (final item in bangumiCalendar[dayIndex]) {
      final epoch = timelineUpdateEpoch(item.id, now: now);
      if (epoch != null) result[item.id] = epoch;
    }
    return result;
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
