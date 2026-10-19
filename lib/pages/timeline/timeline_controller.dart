import 'dart:async';

import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/bangumi_update_times.dart';
import 'package:kazumi/utils/anime_season.dart';
import 'package:kazumi/repositories/collect_repository.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:kazumi/services/logging/logger.dart';
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
        // 先用已有数据排一次（数据还没到也能按热度/评分展示）。
        changeSort(_sort);
        unawaited(BangumiUpdateTimesService.instance.ensureLoaded().then((_) {
          // 周几也走更新时间数据：把番剧按更新时刻的本地星期重新分桶，
          // 无更新时间的保留 bangumi 日历原分组。
          _regroupByUpdateWeekday();
          changeSort(_sort);
          // 只补查今天播出的番：其余日子等用户切到那一天的 tab 再查。
          // 每部番缓存到下一次播出，一天最多十几部，请求量很小。
          unawaited(ensureAniListForToday());
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
    final Comparator<BangumiItem> compare = switch (sort) {
      TimelineSort.popularity => (a, b) => b.votes.compareTo(a.votes),
      TimelineSort.rating => (a, b) => b.ratingScore.compareTo(a.ratingScore),
      // 默认顺序即按更新时间从早到晚，无更新时间的排当日最后。
      TimelineSort.defaultOrder => (a, b) => compareTimelineUpdateTime(
          a,
          b,
          BangumiUpdateTimesService.instance.updates,
          DateTime.now(),
        ),
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

  /// 按更新时刻的本地星期重新分桶：AniList 优先，bangumi-mal 兜底，
  /// 都没有的番保留 bangumi 日历原分组。周几于是和更新时间同源。
  void _regroupByUpdateWeekday() {
    if (_baseBangumiCalendar.isEmpty) return;
    final service = BangumiUpdateTimesService.instance;
    final regrouped = List.generate(7, (_) => <BangumiItem>[]);
    for (var day = 0; day < _baseBangumiCalendar.length; day++) {
      for (final item in _baseBangumiCalendar[day]) {
        final weekday = service.updateWeekday(item.id);
        // weekday 1-7；没有更新时间就留在原来的那一天。
        final target = weekday == null ? day : weekday - 1;
        regrouped[target.clamp(0, 6)].add(item);
      }
    }
    bangumiCalendar.clear();
    bangumiCalendar.addAll(regrouped);
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

  /// 单部番剧的下一次更新时间（epoch ms），卡片文案与排序共用。
  int? nextUpdateEpoch(int bangumiId) =>
      BangumiUpdateTimesService.instance.nextUpdateEpoch(bangumiId);

  /// 单部番剧已更新到第几集，卡片集数胶囊用。
  int? currentEpisode(int bangumiId) =>
      BangumiUpdateTimesService.instance.currentEpisode(bangumiId);

  /// 只给指定星期（0 = 周一 ... 6 = 周日）的番补 AniList 实测状态。
  /// 当季的今天用；切 tab 时也调到对应那一天。
  Future<void> ensureAniListForDay(int dayIndex) async {
    if (dayIndex < 0 || dayIndex >= bangumiCalendar.length) return;
    final ids = bangumiCalendar[dayIndex].map((item) => item.id).toList();
    if (ids.isEmpty) return;
    await BangumiUpdateTimesService.instance.ensureAniListLoaded(ids);
    // AniList 的实测星期可能与推算不同，到达后重新分桶一次。
    _regroupByUpdateWeekday();
    changeSort(_sort);
  }

  /// 只查今天那一天的当季番，供首次加载用。
  Future<void> ensureAniListForToday() =>
      ensureAniListForDay(DateTime.now().weekday - 1);

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
