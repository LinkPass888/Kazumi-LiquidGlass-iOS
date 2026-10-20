import 'dart:async';

import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/bangumi_update_times.dart';
import 'package:kazumi/utils/anime_season.dart';
import 'package:kazumi/repositories/collect_repository.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:kazumi/services/logging/logger.dart';
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

  /// 时间表的时刻来源是否用 AniList 实测播出时刻（界面设置里可切换）。
  /// 默认就是 AniList：bangumi-mal 的 begin 是「首播那一集」的时刻，
  /// 和之后每周的实际播出时间可能差一天（如 511936 首播在周一深夜、
  /// 常规档是周六 20:00），拿它当分组依据会把番放到错误的星期。
  bool get prefersAniListWeekday =>
      GStorage.getSetting(SettingsKeys.timelinePreferredSource) == 'anilist';

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
          // 按 AniList 分组时，分组依据就是 AniList 的时刻：只给今天那
          // 一天补查，其余日子的番会一直停在 bangumi-mal 的星期上，直到
          // 用户切到那个 tab。所以这里把当季整季一次补齐（分批、每批之间
          // 有间隔，请求量按「有多少部还没缓存」走，不是每次重拉）。
          if (prefersAniListWeekday) {
            unawaited(ensureAniListForAll());
          } else {
            // 按 bangumi-mal 分组时，切 tab 才补查那一天（只为拿集数/进度）。
            unawaited(ensureAniListForToday());
          }
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
    // 一次排序内把设置和时刻表固定下来：比较器会被调用几百次，
    // 每次都去读设置/重算时刻既慢，又可能在设置刚改时前后不一致。
    final preferAniList = prefersAniListWeekday;
    final epochs = <int, int?>{};
    int? epochFor(int id) => epochs.putIfAbsent(
          id,
          () => BangumiUpdateTimesService.instance.timelineUpdateEpoch(
            id,
            now: now,
            preferAniList: preferAniList,
          ),
        );
    final Comparator<BangumiItem> compare = switch (sort) {
      TimelineSort.popularity => (a, b) => b.votes.compareTo(a.votes),
      TimelineSort.rating => (a, b) => b.ratingScore.compareTo(a.ratingScore),
      // 默认顺序即按更新时间从早到晚，无更新时间的排当日最后。
      // 时刻来源和分组、卡片胶囊同一个：切到 AniList 就三者一起切。
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
  }

  void _resetBangumiCalendarFromBase() {
    bangumiCalendar.clear();
    bangumiCalendar.addAll(
      _baseBangumiCalendar
          .map((dayList) => List<BangumiItem>.from(dayList))
          .toList(),
    );
  }

  /// 按更新时间重新分桶：bangumi 放送星期（默认）或 AniList 实测星期，
  /// 都没有的番保留 bangumi 日历原分组。周几于是和更新时间同源。
  void _regroupByUpdateWeekday() {
    if (_baseBangumiCalendar.isEmpty) return;
    final service = BangumiUpdateTimesService.instance;
    final preferAniList = prefersAniListWeekday;
    final regrouped = List.generate(7, (_) => <BangumiItem>[]);
    for (var day = 0; day < _baseBangumiCalendar.length; day++) {
      for (final item in _baseBangumiCalendar[day]) {
        final weekday = service.updateWeekday(
          item.id,
          preferAniList: preferAniList,
        );
        // weekday 1-7；没有更新时间就留在原来的那一天。
        final target = weekday == null ? day : weekday - 1;
        regrouped[target.clamp(0, 6)].add(item);
      }
    }
    bangumiCalendar.clear();
    bangumiCalendar.addAll(regrouped);
  }

  /// 界面设置里切换星期来源后调用：重新分桶并排序；切到 AniList 时
  /// 还要把整季补查一遍，否则没查过的那几天仍是 bangumi-mal 的星期。
  @action
  void refreshWeekdaySource() {
    _regroupByUpdateWeekday();
    changeSort(_sort);
    if (prefersAniListWeekday) unawaited(ensureAniListForAll());
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

  /// 时间表用的「更新时刻」：分组、排序、卡片胶囊三者共用这一个入口，
  /// 来源由「时间表星期来源」设置决定（AniList 实测，兜底 bangumi-mal）。
  /// 三者分开取会错位 —— 分组用 A、排序用 B、胶囊用 C 时，同一列里
  /// 就会出现「周六 20:00 的番排在周一 21:00 后面」。
  int? timelineUpdateEpoch(int bangumiId, {DateTime? now}) =>
      BangumiUpdateTimesService.instance.timelineUpdateEpoch(
        bangumiId,
        now: now,
        preferAniList: prefersAniListWeekday,
      );

  /// 单部番剧的下一次更新时间（epoch ms），详情页等非时间表场景用。
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

  /// 当季全部番的 AniList 实测状态。按 AniList 分组时用：分组依据就是
  /// AniList 的时刻，只查今天会让其余六天停在 bangumi-mal 的星期上。
  /// 请求量按「还没缓存/已到下集播出」的条目走（见 AniListClient），
  /// 分批带间隔，不会每次都把整季重拉一遍。
  Future<void> ensureAniListForAll() async {
    final ids = <int>{};
    for (final dayList in _baseBangumiCalendar) {
      for (final item in dayList) {
        ids.add(item.id);
      }
    }
    if (ids.isEmpty) return;
    await BangumiUpdateTimesService.instance.ensureAniListLoaded(ids);
    // 补齐后按新时刻重新分桶排序；查不到的番自然退回 bangumi-mal，
    // 分组/排序/显示仍然是同一个来源，只是那一天的数据不够准。
    _regroupByUpdateWeekday();
    changeSort(_sort);
  }

  /// 当天所有番的更新时刻（bangumi id -> epoch ms），卡片时间胶囊用。
  /// 直接取 [timelineUpdateEpoch]，和分组、排序同源；以前这里固定用
  /// AniList，而分组可能按 bangumi，于是同一列里胶囊和排序各说一套。
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
