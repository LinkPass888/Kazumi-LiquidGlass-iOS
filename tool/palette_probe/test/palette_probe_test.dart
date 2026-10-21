// 用 Flutter 自己的取色算法，复核 iOS 端固化的配色表是否与原版一致。
//
// 原版取色有两处：
//   1. 强调色 = `ColorScheme.fromSeed(seedColor:)` 的 primary；
//   2. 配色卡片的三色 + 勾选圆 = `lib/bean/card/palette_card.dart` 里
//      直接用 `Hct.from(hue, chroma, tone)` 算出来的值。
//
// iOS 端把这套值固化在
// `ios/Runner/NativeApp/Design/KazumiThemeColor.swift`，这里用 Flutter
// 现算一遍再逐项比对，避免两边悄悄跑偏。
//
// 运行：
//   cd tool/palette_probe
//   flutter pub get
//   flutter test

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// 与 lib/bean/settings/color_type.dart 的 `colorThemeTypes` 一一对应。
const Map<String, Color> _seeds = {
  'default': Color(0xFF4CAF50),
  'teal': Color(0xFF009688),
  'blue': Color(0xFF2196F3),
  'indigo': Color(0xFF3F51B5),
  'violet': Color(0xFF6750A4),
  'pink': Color(0xFFE91E63),
  'yellow': Color(0xFFFFEB3B),
  'orange': Color(0xFFFF9800),
  'deepOrange': Color(0xFFFF5722),
};

/// iOS 端固化配色表的 Swift 源文件。
final File _swiftFile = File(
  '../../ios/Runner/NativeApp/Design/KazumiThemeColor.swift',
);

String _argb(Color color) =>
    color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();

void main() {
  test('iOS 配色表与 Flutter 原版取色一致', () {
    final source = _swiftFile.readAsStringSync();

    for (final entry in _seeds.entries) {
      final id = entry.key;
      final seed = entry.value;

      final light = ColorScheme.fromSeed(seedColor: seed);
      final dark = ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.dark,
      );

      final hct = Hct.fromInt(seed.toARGB32());
      final cardPrimary = Color(Hct.from(hct.hue, 20.0, 90.0).toInt());
      final cardTertiary = Color(Hct.from(hct.hue + 50, 20.0, 85.0).toInt());
      final cardPrimaryContainer = Color(Hct.from(hct.hue, 30.0, 50.0).toInt());
      final cardCheckbox = Color(Hct.from(hct.hue, 30.0, 40.0).toInt());

      final expected = <String, String>{
        'seed': _argb(seed),
        'lightPrimary': _argb(light.primary),
        'darkPrimary': _argb(dark.primary),
        'cardPrimary': _argb(cardPrimary),
        'cardTertiary': _argb(cardTertiary),
        'cardPrimaryContainer': _argb(cardPrimaryContainer),
        'cardCheckbox': _argb(cardCheckbox),
      };

      expected.forEach((field, hex) {
        expect(
          source,
          contains('$field: 0x$hex'),
          reason: '$id 的 $field 应为 0x$hex，Swift 配色表与 Flutter 原版不一致',
        );
      });
    }
  });

  test('配色方案数量与原版一致', () {
    final source = _swiftFile.readAsStringSync();

    for (final id in _seeds.keys) {
      expect(source, contains('id: "$id"'), reason: '缺少配色方案 $id');
    }
    expect(
      RegExp(r'id: "').allMatches(source).length,
      _seeds.length,
      reason: 'Swift 配色表里的方案数量与原版不一致',
    );
  });
}
