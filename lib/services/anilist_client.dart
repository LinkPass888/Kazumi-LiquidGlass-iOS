import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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
    this.totalEpisodes,
  });

  /// 下一集（即将播出的那一集）的集数。
  final int episode;

  /// 下一集的播出时刻（epoch ms）。
  final int airingAt;

  /// 总集数，AniList 没填时为 null。
  final int? totalEpisodes;

  /// 已播出到第几集：下一集之前的那一集。
  int get currentEpisode => episode - 1;

  /// 缓存有效到下一次播出为止：播出后集数会变，必须重查。
  bool isFreshAt(DateTime now) =>
      now.millisecondsSinceEpoch < airingAt;

  Map<String, dynamic> toJson() => {
        'episode': episode,
        'airingAt': airingAt,
        if (totalEpisodes != null) 'totalEpisodes': totalEpisodes,
      };

  static AniListAiring? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final episode = raw['episode'];
    final airingAt = raw['airingAt'];
    if (episode is! int || airingAt is! int) return null;
    final total = raw['totalEpisodes'];
    return AniListAiring(
      episode: episode,
      airingAt: airingAt,
      totalEpisodes: total is int ? total : null,
    );
  }
}

/// AniList GraphQL 的当季番播出状态。
///
/// - 批量查询：每次 HTTP 请求用 GraphQL 别名合并多部番（[batchSize]），
///   请求量比逐部查询低一个数量级。
/// - 429 退避：读 `Retry-After` / `X-RateLimit-Reset` 再等，不连续重发。
/// - 失败重试：查不到的番记进 [_pendingIds]，下次 [ensureLoaded] 会再试，
///   不会因为一次失败就永久跳过。
class AniListClient {
  AniListClient._();

  static final AniListClient instance = AniListClient._();

  static const _endpoint = 'https://graphql.anilist.co';
  static const _maxAge = Duration(days: 7);

  /// 单次 HTTP 请求里合并的番数。AniList 对 GraphQL 请求体有大小限制，
  /// 25 个别名（每个 ~80 字节）远低于上限，同时把请求数压到 1/25。
  static const _batchSize = 25;

  final Map<int, AniListAiring> _memory = {};

  /// 查询失败、等待下次重试的 bangumi id。
  final Set<int> _pendingIds = {};

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

  /// 批量补齐当季番的播出状态。已缓存的跳过；上次失败的会重试。
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
      batch = _queued.where((id) => cached(id) == null).toList();
      _queued.clear();
    }
  }

  /// 一次 HTTP 查询多部番：GraphQL 别名把每个 MAL id 编成一个字段。
  Future<Map<int, AniListAiring>> fetchBatch(List<int> bangumiIds) async {
    final updates = BangumiUpdateTimesService.instance;
    // bangumi id -> mal id，同时建立别名。
    final aliasToBangumi = <String, int>{};
    final variables = <String, dynamic>{};
    var index = 0;
    for (final bangumiId in bangumiIds) {
      final malId = updates.malIds[bangumiId];
      if (malId == null) continue;
      final alias = 'm$index';
      aliasToBangumi[alias] = bangumiId;
      variables['mal$index'] = malId;
      index++;
    }
    if (aliasToBangumi.isEmpty) return {};

    final fields = aliasToBangumi.entries
        .map((e) =>
            '${e.key}: Media(idMal: \$mal${e.key.substring(1)}, type: ANIME) '
            '{ episodes nextAiringEpisode { episode airingAt } }')
        .join('\n');
    final declarations =
        variables.keys.map((k) => '\$$k: Int').join(', ');
    final query = 'query ($declarations) { $fields }';

    final data = await _post(query, variables);
    if (data == null) return {};

    final result = <int, AniListAiring>{};
    for (final entry in aliasToBangumi.entries) {
      final media = data[entry.key];
      if (media is! Map) continue;
      final next = media['nextAiringEpisode'];
      if (next is! Map) continue;
      final episode = next['episode'];
      final airingAtSeconds = next['airingAt'];
      if (episode is! int || airingAtSeconds is! int) continue;
      final total = media['episodes'];
      result[entry.value] = AniListAiring(
        episode: episode,
        airingAt: airingAtSeconds * 1000,
        totalEpisodes: total is int ? total : null,
      );
    }
    return result;
  }

  /// 单次请求，带 429 退避。返回 `data` 节点；失败返回 null。
  Future<Map<String, dynamic>?> _post(
    String query,
    Map<String, dynamic> variables,
  ) async {
    var attempt = 0;
    while (true) {
      try {
        final response = await DioFactory.apiDio.post(
          _endpoint,
          data: {'query': query, 'variables': variables},
          options: Options(validateStatus: (status) => status != null && status < 500),
        );
        final status = response.statusCode ?? 0;
        if (status == 429) {
          final wait = _retryDelay(response.headers, attempt);
          if (attempt >= 2) return null;
          attempt++;
          await Future.delayed(wait);
          continue;
        }
        if (status >= 400) return null;
        final body = response.data;
        if (body is! Map) return null;
        final data = body['data'];
        return data is Map ? Map<String, dynamic>.from(data) : null;
      } on DioException catch (e) {
        // 网络错误也按退避重试一次，避免整批数据直接丢掉。
        if (attempt >= 2) {
          KazumiLogger().w('AniList: lookup failed', error: e);
          return null;
        }
        attempt++;
        await Future.delayed(_retryDelay(e.response?.headers, attempt));
      }
    }
  }

  /// 429 的等待时间：优先 `Retry-After`，其次 `X-RateLimit-Reset`，
  /// 都没有时按指数退避（1s、2s）。
  Duration _retryDelay(Headers? headers, int attempt) {
    final retryAfter = int.tryParse(headers?.value('retry-after') ?? '');
    if (retryAfter != null && retryAfter > 0) {
      return Duration(seconds: retryAfter.clamp(1, 120));
    }
    final resetEpoch = int.tryParse(headers?.value('x-ratelimit-reset') ?? '');
    if (resetEpoch != null && resetEpoch > 0) {
      final waitMs =
          resetEpoch * 1000 - DateTime.now().millisecondsSinceEpoch;
      if (waitMs > 0) {
        return Duration(milliseconds: waitMs.clamp(1000, 120000));
      }
    }
    return Duration(milliseconds: 1000 * math.pow(2, attempt).toInt());
  }

  Future<void> _loadAll(List<int> bangumiIds) async {
    await _loadDiskCacheOnce();
    final updates = BangumiUpdateTimesService.instance;
    await updates.ensureLoaded();

    // 上次失败的连同本次一起重试。
    final ids = <int>{...bangumiIds, ..._pendingIds}
        .where((id) => cached(id) == null && updates.malIds[id] != null)
        .toList();
    _pendingIds.clear();
    if (ids.isEmpty) {
      await _saveDiskCache();
      return;
    }

    for (var i = 0; i < ids.length; i += _batchSize) {
      final batch = ids.sublist(i, math.min(i + _batchSize, ids.length));
      final airings = await fetchBatch(batch);
      airings.forEach((id, airing) => _memory[id] = airing);
      // 这批里没查到的留到下次重试。
      for (final id in batch) {
        if (!airings.containsKey(id)) _pendingIds.add(id);
      }
      // 批次之间留出间隔，避免短时间内连续打满配额。
      if (i + _batchSize < ids.length) {
        await Future.delayed(const Duration(milliseconds: 400));
      }
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
          for (final entry in _memory.entries)
            '${entry.key}': entry.value.toJson(),
        }),
        flush: true,
      );
    } on Object {
      // 写缓存失败不影响本次使用。
    }
  }
}
