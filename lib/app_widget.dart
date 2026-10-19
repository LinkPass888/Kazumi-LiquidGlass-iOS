import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/metered_network_service.dart';
import 'package:kazumi/bean/settings/theme_provider.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/utils/app_theme.dart';

class AppWidget extends StatefulWidget {
  const AppWidget({super.key});

  @override
  State<AppWidget> createState() => _AppWidgetState();
}

class _AppWidgetState extends State<AppWidget>
    with WidgetsBindingObserver {
  bool _didApplyStoredThemeSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final themeProvider = context.watch<ThemeProvider>();
    _applyStoredThemeSettings(themeProvider);
  }

  void _applyStoredThemeSettings(ThemeProvider themeProvider) {
    if (_didApplyStoredThemeSettings) return;
    _didApplyStoredThemeSettings = true;
    applyStoredThemeSettings(themeProvider);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      KazumiLogger()
          .i("AppLifecycleState.paused: Application moved to background");
    } else if (state == AppLifecycleState.resumed) {
      KazumiLogger()
          .i("AppLifecycleState.resumed: Application moved to foreground");
      await MeteredNetworkService.refresh();
    } else if (state == AppLifecycleState.inactive) {
      KazumiLogger().i("AppLifecycleState.inactive: Application is inactive");
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeProvider themeProvider = context.watch<ThemeProvider>();

    return MaterialApp.router(
      title: "Kazumi",
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [
        Locale.fromSubtags(
            languageCode: 'zh', scriptCode: 'Hans', countryCode: "CN")
      ],
      locale: const Locale.fromSubtags(
          languageCode: 'zh', scriptCode: 'Hans', countryCode: "CN"),
      theme: themeProvider.light,
      darkTheme: themeProvider.dark,
      themeMode: themeProvider.themeMode,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      routerConfig: ModularApp.routerConfigOf(context),
    );
  }
}
