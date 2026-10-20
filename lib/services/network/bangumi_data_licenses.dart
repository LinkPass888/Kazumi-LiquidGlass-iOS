import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// bangumi-mal / BangumiExtLinker / bangumi-data 的 CC BY 4.0 署名与许可。
///
/// 这些数据用于时间表的更新时间、追番页排序、通知排程，以及 AniSkip /
/// AniList 的 bangumi ↔ MAL id 转换，CC BY 4.0 要求在使用处保留署名，
/// 所以注册进「第三方许可证」列表，和 ech_http 的原生依赖放在一起。
void registerBangumiDataLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ['bangumi-mal', 'BangumiExtLinker', 'bangumi-data'],
      await rootBundle.loadString('licenses/bangumi-data/NOTICE.txt'),
    );
    yield LicenseEntryWithLineBreaks(
      const ['bangumi-data (CC BY 4.0)'],
      await rootBundle.loadString(
          'licenses/bangumi-data/BangumiExtLinker_LICENSE.txt'),
    );
  });
}
