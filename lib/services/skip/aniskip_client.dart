import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/bangumi_update_times.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/skip/skip_segments.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Crowd-sourced skip times from AniSkip (https://api.aniskip.com), keyed by
/// MyAnimeList id. Bangumi ids are mapped through Rhilip/BangumiExtLinker
/// (CC BY 4.0).
class AniSkipClient {
  AniSkipClient._();

  static final AniSkipClient instance = AniSkipClient._();

  static const _mapUrl =
      'https://rhilip.github.io/BangumiExtLinker/data/anime_map.json';
  static const _mapMaxAge = Duration(days: 7);

  Future<Map<int, int>>? _malIds;

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
      return (await load)[bangumiId];
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
        'bgm_mal.json',
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
        final compact = compactBangumiMalMap(response.data ?? '[]');
        // 并入最近两季 bangumi-data 的 mal 映射（新番覆盖更快）；
        // ExtLinker 为主，冲突不覆盖。拿不到季节数据就只用 ExtLinker。
        try {
          await BangumiUpdateTimesService.instance.ensureLoaded();
          BangumiUpdateTimesService.instance.malIds
              .forEach((bgm, mal) => compact.putIfAbsent(bgm, () => mal));
        } catch (_) {}
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
}

/// Reduces BangumiExtLinker's anime_map.json to bangumi id -> MAL id.
Map<int, int> compactBangumiMalMap(String source) {
  final result = <int, int>{};
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on Object {
    return result;
  }
  if (decoded is! List) return result;
  for (final row in decoded) {
    if (row is! Map) continue;
    final bgm = int.tryParse('${row['bgm_id'] ?? ''}');
    final mal = int.tryParse('${row['mal_id'] ?? ''}');
    if (bgm != null && mal != null) result[bgm] = mal;
  }
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
