import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/bangumi_update_times.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// 一部番的 AniList 播出状态。
class AniListAiring {
  const AniListAiring({
    required this.episode,
    required this.airingAt,
  });

  /// 下一集（即将播出的那一集）的集数。
  final int episode;

  /// 下一集的播出时刻（epoch ms）。
  final int airingAt;

  /// 已播出到第几集：下一集之前的那一集。
  int get currentEpisode => episode - 1;

  /// 缓存有效到下一次播出为止：播出后集数会变，必须重查。
  bool isFreshAt(DateTime now) =>
      now.millisecondsSinceEpoch < airingAt;

  Map<String, dynamic> toJson() => {
        'episode': episode,
        'airingAt': airingAt,
      };

  static AniListAiring? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final episode = raw['episode'];
    final airingAt = raw['airingAt'];
    if (episode is! int || airingAt is! int) return null;
    return AniListAiring(episode: episode, airingAt: airingAt);
  }
}

/// AniList GraphQL 的当季番播出状态。
///
/// 只给「当季在更」的番用：bangumi 的日历里有周几和时刻，但停播/延期
/// 它不知道；AniList 的 `nextAiringEpisode` 是实时数据。缓存到「下一集
/// 播出时刻」为止，而不是固定 TTL —— 一周只有一部番更新一次，按播出日
/// 分批查询，请求量很小。
class AniListClient {
  AniListClient._();

  static final AniListClient instance = AniListClient._();

  static const _endpoint = 'https://graphql.anilist.co';
  static const _maxAge = Duration(days: 7);

  final Map<int, AniListAiring> _memory = {};

  Future<void>? _loading;

  /// 加载进行中时新追加的番（切 tab 查另一天时会走到这里）。
  final Set<int> _queued = {};

  bool _diskLoaded = false;

  /// 读取「新鲜」的播出状态：缓存时间还没到下一集播出，集数不会变。
  AniListAiring? cached(int bangumiId, {DateTime? now}) {
    final airing = _memory[bangumiId];
    if (airing == null) return null;
    return airing.isFreshAt(now ?? DateTime.now()) ? airing : null;
  }

  /// 读取缓存，不管是否过期。过期的值是上一集的实测结果，仍然比
  /// bangumi 的周期推算准；刷新失败或还没刷新时用它兜底。
  AniListAiring? staleCached(int bangumiId) => _memory[bangumiId];

  /// 批量补齐当季番的播出状态。已缓存的跳过，失败的静默忽略。
  /// 正在加载时把新 ID 追加进队列，由同一轮加载处理。
  Future<void> ensureLoaded(Iterable<int> bangumiIds) {
    final now = DateTime.now();
    final missing = bangumiIds
        .where((id) => cached(id, now: now) == null)
        .toSet()
        .toList();
    if (missing.isEmpty) return Future.value();
    final running = _loading;
    if (running != null) {
      _queued.addAll(missing);
      return running;
    }
    late final Future<void> future;
    future = _drain(missing).whenComplete(() {
      if (identical(_loading, future)) _loading = null;
    });
    _loading = future;
    return future;
  }

  /// 处理完当前批次后，如果中途又追加了新的番，继续处理。
  Future<void> _drain(List<int> firstBatch) async {
    var batch = firstBatch;
    while (batch.isNotEmpty) {
      await _loadAll(batch);
      batch = _queued
          .where((id) => cached(id) == null)
          .toList();
      _queued.clear();
    }
  }

  /// 按 bangumi id 查 MAL id，再查 AniList。单次请求即一部番。
  Future<AniListAiring?> fetch(int bangumiId, int malId) async {
    try {
      final response = await DioFactory.apiDio.post(
        _endpoint,
        data: {
          'query':
              'query (\$mal: Int) { Media(idMal: \$mal, type: ANIME) { nextAiringEpisode { episode airingAt } } }',
          'variables': {'mal': malId},
        },
      );
      final data = response.data;
      if (data is! Map) return null;
      final media = (data['data'] as Map?)?['Media'];
      if (media is! Map) return null;
      final next = media['nextAiringEpisode'];
      if (next is! Map) return null;
      final episode = next['episode'];
      final airingAtSeconds = next['airingAt'];
      if (episode is! int || airingAtSeconds is! int) return null;
      return AniListAiring(
        episode: episode,
        airingAt: airingAtSeconds * 1000,
      );
    } on DioException catch (e) {
      // 429 = 限流；404 = 查不到。都静默回退。
      if (e.response?.statusCode != 404 && e.response?.statusCode != 429) {
        KazumiLogger().w('AniList: lookup failed for mal=$malId', error: e);
      }
      return null;
    } catch (e) {
      KazumiLogger().w('AniList: lookup failed for mal=$malId', error: e);
      return null;
    }
  }

  Future<void> _loadAll(List<int> bangumiIds) async {
    await _loadDiskCacheOnce();
    final updates = BangumiUpdateTimesService.instance;
    await updates.ensureLoaded();

    for (final bangumiId in bangumiIds) {
      if (cached(bangumiId) != null) continue;
      final malId = updates.malIds[bangumiId];
      if (malId == null) continue;
      final airing = await fetch(bangumiId, malId);
      if (airing != null) _memory[bangumiId] = airing;
    }
    await _saveDiskCache();
  }

  Future<void> _loadDiskCacheOnce() async {
    if (_diskLoaded) return;
    _diskLoaded = true;
    await _loadDiskCache();
  }

  Future<File> _cacheFile() async => File(
        path.join(
          (await getApplicationSupportDirectory()).path,
          'anilist',
          'airing.json',
        ),
      );

  Future<void> _loadDiskCache() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists() ||
          DateTime.now().difference(await file.lastModified()) > _maxAge) {
        return;
      }
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return;
      raw.forEach((key, value) {
        final id = int.tryParse('$key');
        final airing = AniListAiring.fromJson(value);
        if (id != null && airing != null) _memory[id] = airing;
      });
    } on Object {
      // 缓存损坏就忽略，下次查询重新拉。
    }
  }

  Future<void> _saveDiskCache() async {
    try {
      final file = await _cacheFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          for (final entry in _memory.entries) '${entry.key}': entry.value.toJson(),
        }),
        flush: true,
      );
    } on Object {
      // 写缓存失败不影响本次使用。
    }
  }
}
