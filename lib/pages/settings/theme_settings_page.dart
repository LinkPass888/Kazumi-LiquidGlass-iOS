import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/card/palette_card.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/theme_provider.dart';
import 'package:kazumi/bean/settings/color_type.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_dropdown_tile.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/utils/theme.dart';

class ThemeSettingsPage extends StatefulWidget {
  const ThemeSettingsPage({super.key});

  @override
  State<ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends State<ThemeSettingsPage> {
  late dynamic defaultThemeMode;
  late dynamic defaultThemeColor;
  late bool oledEnhance;
  late final ThemeProvider themeProvider;

  @override
  void initState() {
    super.initState();
    defaultThemeMode = GStorage.getSetting(SettingsKeys.themeMode);
    defaultThemeColor = GStorage.getSetting(SettingsKeys.themeColor);
    oledEnhance = GStorage.getSetting(SettingsKeys.oledEnhance);
    themeProvider = context.read<ThemeProvider>();
  }

  void setTheme(Color? color) {
    var defaultDarkTheme = ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: color,
        progressIndicatorTheme: progressIndicatorTheme2024,
        sliderTheme: sliderTheme2024,
        pageTransitionsTheme: pageTransitionsTheme2024);
    var oledTheme = oledDarkTheme(defaultDarkTheme);
    themeProvider.setTheme(
      ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          colorSchemeSeed: color,
          progressIndicatorTheme: progressIndicatorTheme2024,
          sliderTheme: sliderTheme2024,
          pageTransitionsTheme: pageTransitionsTheme2024),
      oledEnhance ? oledTheme : defaultDarkTheme,
    );
    defaultThemeColor = color?.toARGB32().toRadixString(16) ?? 'default';
    GStorage.putSetting(SettingsKeys.themeColor, defaultThemeColor);
  }

  void resetTheme() {
    var defaultDarkTheme = ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.green,
        progressIndicatorTheme: progressIndicatorTheme2024,
        sliderTheme: sliderTheme2024,
        pageTransitionsTheme: pageTransitionsTheme2024);
    var oledTheme = oledDarkTheme(defaultDarkTheme);
    themeProvider.setTheme(
      ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          colorSchemeSeed: Colors.green,
          progressIndicatorTheme: progressIndicatorTheme2024,
          sliderTheme: sliderTheme2024,
          pageTransitionsTheme: pageTransitionsTheme2024),
      oledEnhance ? oledTheme : defaultDarkTheme,
    );
    defaultThemeColor = 'default';
    GStorage.putSetting(SettingsKeys.themeColor, 'default');
  }

  void updateTheme(String theme) async {
    if (theme == 'dark') {
      themeProvider.setThemeMode(ThemeMode.dark);
    }
    if (theme == 'light') {
      themeProvider.setThemeMode(ThemeMode.light);
    }
    if (theme == 'system') {
      themeProvider.setThemeMode(ThemeMode.system);
    }
    await GStorage.putSetting(SettingsKeys.themeMode, theme);
    setState(() {
      defaultThemeMode = theme;
    });
  }

  void updateOledEnhance() {
    dynamic color;
    oledEnhance = GStorage.getSetting(SettingsKeys.oledEnhance);
    if (defaultThemeColor == 'default') {
      color = Colors.green;
    } else {
      color = Color(int.parse(defaultThemeColor, radix: 16));
    }
    setTheme(color);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('外观设置'),
      body: SettingsList(
        sections: [
          SettingsSection(
            title: Text('外观'),
            tiles: [
              SettingsDropdownTile<String>(
                leading: Icons.dark_mode_rounded,
                title: const Text('深色模式'),
                value: defaultThemeMode,
                fallbackLabel: '跟随系统',
                options: const {'system': '跟随系统', 'light': '浅色', 'dark': '深色'},
                onChanged: updateTheme,
              ),
              SettingsTile(
                leading: Icons.palette_rounded,
                onPressed: (_) async {
                  KazumiDialog.show(builder: (context) {
                    return AlertDialog(
                      title: Text('配色方案'),
                      content: StatefulBuilder(builder:
                          (BuildContext context, StateSetter setState) {
                        final List<Map<String, dynamic>> colorThemes =
                            colorThemeTypes;
                        return Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          children: [
                            ...colorThemes.map(
                              (e) {
                                final index = colorThemes.indexOf(e);
                                return GestureDetector(
                                  onTap: () {
                                    index == 0
                                        ? resetTheme()
                                        : setTheme(e['color']);
                                    KazumiDialog.dismiss();
                                  },
                                  child: Column(
                                    children: [
                                      PaletteCard(
                                        color: e['color'],
                                        selected: (e['color']
                                                    .value
                                                    .toRadixString(16) ==
                                                defaultThemeColor ||
                                            (defaultThemeColor == 'default' &&
                                                index == 0)),
                                      ),
                                      Text(e['label']),
                                    ],
                                  ),
                                );
                              },
                            )
                          ],
                        );
                      }),
                    );
                  });
                },
                title: Text('配色方案'),
              ),
            ],
          ),
          SettingsSection(
            title: Text('显示'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.contrast_rounded,
                onToggle: (value) async {
                  oledEnhance = value ?? !oledEnhance;
                  await GStorage.putSetting(
                      SettingsKeys.oledEnhance, oledEnhance);
                  updateOledEnhance();
                  setState(() {});
                },
                title: Text('OLED优化'),
                description: Text('深色模式下使用纯黑背景'),
                initialValue: oledEnhance,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
