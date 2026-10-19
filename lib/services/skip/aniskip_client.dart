import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/skip/skip_segments.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Crowd-sourced skip times from AniSkip (https://api.aniskip.com), keyed by
/// MyAnimeList id. Bangumi ids are mapped through LinkPass888/bangumi-mal
/// (CC BY 4.0), which merges BangumiExtLinker and bangumi-data.
class AniSkipClient {
  AniSkipClient._();

  static final AniSkipClient instance = AniSkipClient._();

  static const _baseUrl = 'https://linkpass888.github.io/bangumi-mal/data';
  static const _mapUrl = '$_baseUrl/bangumi-mal.min.json';
  static const _mapMaxAge = Duration(days: 7);

  Future<Map<int, int>>? _malIds;

  /// 按需查到的分片（bangumi_id % 100 -> {bangumi_id: mal_id}），只在内存里。
  final Map<int, Map<int, int>> _shards = {};

  Future<SkipSegments> lookup(
    int bangumiId,
    int episodeNumber,
    double durationSeconds,
  ) async {
    if (bangumiId <= 0 || episodeNumber <= 0) return SkipSegments.empty;
    try {
      final malId = await malIdFor(bangumiId);
      if (malId == null) return SkipSegments.empty;
      final response = await DioFactory.apiDio.get(
        'https://api.aniskip.com/v2/skip-times/$malId/$episodeNumber',
        queryParameters: {
          'types': ['op', 'ed', 'mixed-op', 'mixed-ed'],
          if (durationSeconds > 0) 'episodeLength': durationSeconds.round(),
        },
        options: Options(listFormat: ListFormat.multiCompatible),
      );
      return parseAniSkipResponse(response.data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return SkipSegments.empty;
      KazumiLogger().w('AniSkip: lookup failed', error: e);
      return SkipSegments.empty;
    } catch (e) {
      KazumiLogger().w('AniSkip: lookup failed', error: e);
      return SkipSegments.empty;
    }
  }

  Future<int?> malIdFor(int bangumiId) async {
    // Overlapping lookups share one download. A throw isn't kept, so the
    // next lookup tries again.
    final load = _malIds ??= _loadMap();
    try {
      final map = await load;
      final cached = map[bangumiId];
      if (cached != null) return cached;
      // 全量表里没有：这个 ID 可能是新番，按分片补查（~2 KB）。
      return await _lookupShard(bangumiId);
    } catch (_) {
      if (identical(_malIds, load)) _malIds = null;
      return null;
    }
  }

  Future<Map<int, int>> _loadMap() async {
    final cache = File(
      path.join(
        (await getApplicationSupportDirectory()).path,
        'skip',
        'bangumi_mal.json',
      ),
    );
    final fresh =
        await cache.exists() &&
        DateTime.now().difference(await cache.lastModified()) < _mapMaxAge;
    if (!fresh) {
      try {
        final response = await DioFactory.apiDio.get<String>(
          _mapUrl,
          options: Options(responseType: ResponseType.plain),
        );
        final compact = parseBangumiMalMap(response.data ?? '{}');
        await cache.parent.create(recursive: true);
        await cache.writeAsString(
          jsonEncode(compact.map((k, v) => MapEntry('$k', v))),
          flush: true,
        );
        return compact;
      } catch (e) {
        KazumiLogger().w('AniSkip: id map download failed', error: e);
      }
    }
    if (!await cache.exists()) return {};
    try {
      final raw = jsonDecode(await cache.readAsString()) as Map<String, dynamic>;
      return raw.map((k, v) => MapEntry(int.parse(k), v as int));
    } on Object {
      return {};
    }
  }

  Future<int?> _lookupShard(int bangumiId) async {
    final shard = bangumiId % 100;
    final cached = _shards[shard];
    if (cached != null) return cached[bangumiId];

    final cache = File(
      path.join(
        (await getApplicationSupportDirectory()).path,
        'skip',
        'shards',
        '$shard.json',
      ),
    );
    final fresh =
        await cache.exists() &&
        DateTime.now().difference(await cache.lastModified()) < _mapMaxAge;
    if (!fresh) {
      try {
        final response = await DioFactory.apiDio.get<String>(
          '$_baseUrl/shards/$shard.json',
          options: Options(responseType: ResponseType.plain),
        );
        final parsed = parseBangumiMalMap(response.data ?? '{}');
        await cache.parent.create(recursive: true);
        await cache.writeAsString(
          jsonEncode(parsed.map((k, v) => MapEntry('$k', v))),
          flush: true,
        );
        _shards[shard] = parsed;
        return parsed[bangumiId];
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) {
          KazumiLogger().w('AniSkip: shard $shard download failed', error: e);
        }
        return null;
      }
    }
    if (!await cache.exists()) return null;
    try {
      final raw = jsonDecode(await cache.readAsString()) as Map<String, dynamic>;
      final parsed = raw.map((k, v) => MapEntry(int.parse(k), v as int));
      _shards[shard] = parsed;
      return parsed[bangumiId];
    } on Object {
      return null;
    }
  }
}

/// Parses bangumi-mal's compact map `{"<bangumi_id>": <mal_id>}`.
Map<int, int> parseBangumiMalMap(String source) {
  final result = <int, int>{};
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on Object {
    return result;
  }
  if (decoded is! Map) return result;
  decoded.forEach((key, value) {
    final bgm = int.tryParse('$key');
    final mal = value is int ? value : int.tryParse('$value');
    if (bgm != null && mal != null && mal > 0) result[bgm] = mal;
  });
  return result;
}

SkipSegments parseAniSkipResponse(Object? data) {
  if (data is! Map || data['found'] != true) return SkipSegments.empty;
  SkipRange? opening;
  SkipRange? ending;
  for (final result in data['results'] as List? ?? const []) {
    if (result is! Map) continue;
    final interval = result['interval'];
    if (interval is! Map) continue;
    final range = SkipRange(
      (interval['startTime'] as num).toDouble(),
      (interval['endTime'] as num).toDouble(),
      SkipSource.aniskip,
    );
    if (range.length <= 0) continue;
    switch (result['skipType']) {
      case 'op' || 'mixed-op':
        opening ??= range;
      case 'ed' || 'mixed-ed':
        ending ??= range;
    }
  }
  return SkipSegments(opening: opening, ending: ending);
}
