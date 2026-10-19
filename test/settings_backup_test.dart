import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/storage/settings_backup.dart';

void main() {
  group('encode', () {
    test('keeps scalar and string-list settings, skips internal keys', () {
      final text = SettingsBackup.encode(
        {
          'themeMode': 'dark',
          'defaultVolume': 80.0,
          'hAenable': false,
          'danmakuChConvert': 1,
          'shortcut_playPause': ['Space'],
          'proxyConfigured': true,
          'historySyncDeviceId': 'device-a',
          'downloadDirectory': '/private/var/mobile/Downloads',
          'downloadDirectoryBookmark': 'AAAA',
          'danmakuSearchHistory_123': ['one piece'],
          'unencodable': {'nested': true},
        },
        now: DateTime.utc(2026, 10, 19, 12, 30),
      );

      final decoded = jsonDecode(text) as Map<String, dynamic>;
      expect(decoded['app'], 'Kazumi');
      expect(decoded['version'], SettingsBackup.version);
      expect(decoded['exportedAt'], '2026-10-19T12:30:00.000Z');
      expect(decoded['settings'], {
        'themeMode': 'dark',
        'defaultVolume': 80.0,
        'hAenable': false,
        'danmakuChConvert': 1,
      });
    });

    test('omits sensitive keys when asked', () {
      final text = SettingsBackup.encode(
        {
          'themeMode': 'light',
          'bangumiAccessToken': 'token',
          'webDavPassword': 'secret',
        },
        omit: const {'bangumiAccessToken', 'webDavPassword'},
      );

      final decoded = jsonDecode(text) as Map<String, dynamic>;
      expect(decoded['settings'], {'themeMode': 'light'});
    });
  });

  group('decode', () {
    test('round-trips an exported backup', () {
      final text = SettingsBackup.encode(
        {
          'themeMode': 'dark',
          'danmakuFontSize': 25.0,
          'hAenable': true,
          'shortcut_playPause': ['Space'],
        },
        now: DateTime.utc(2026, 1, 2, 3, 4),
      );

      final backup = SettingsBackup.decode(text);

      expect(backup.count, 3);
      expect(backup.settings['themeMode'], 'dark');
      expect(backup.settings['danmakuFontSize'], 25.0);
      expect(backup.settings['hAenable'], isTrue);
      expect(backup.exportedAt, DateTime.utc(2026, 1, 2, 3, 4).toLocal());
    });

    test('rejects malformed JSON', () {
      expect(
        () => SettingsBackup.decode('not json'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('JSON'),
          ),
        ),
      );
    });

    test('rejects text that is not a Kazumi backup', () {
      expect(
        () => SettingsBackup.decode('{"app":"Other","version":1,"settings":{}}'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Kazumi'),
          ),
        ),
      );
    });

    test('rejects backups from a newer app version', () {
      expect(
        () => SettingsBackup.decode(
          jsonEncode({
            'app': 'Kazumi',
            'version': SettingsBackup.version + 1,
            'settings': {'themeMode': 'dark'},
          }),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('更新版本'),
          ),
        ),
      );
    });

    test('drops excluded keys present in a hand-edited backup', () {
      final backup = SettingsBackup.decode(
        jsonEncode({
          'app': 'Kazumi',
          'version': 1,
          'exportedAt': 'not-a-date',
          'settings': {
            'themeMode': 'dark',
            'historySyncSequence': 42,
            'proxyConfigured': true,
            'shortcut_playPause': ['Space'],
          },
        }),
      );

      expect(backup.settings, {'themeMode': 'dark'});
      expect(backup.exportedAt, isNull);
    });
  });

  group('isExcludedKey', () {
    test('matches exact and prefixed internal keys', () {
      expect(SettingsBackup.isExcludedKey('historySyncDeviceId'), isTrue);
      expect(SettingsBackup.isExcludedKey('shortcut_nextEpisode'), isTrue);
      expect(SettingsBackup.isExcludedKey('danmakuSearchHistory_1'), isTrue);
      expect(SettingsBackup.isExcludedKey('downloadDirectory'), isTrue);
      expect(SettingsBackup.isExcludedKey('downloadDirectoryBookmark'), isTrue);
      expect(SettingsBackup.isExcludedKey('themeMode'), isFalse);
    });
  });
}
