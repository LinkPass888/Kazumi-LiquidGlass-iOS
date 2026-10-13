import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/metered_network_service.dart';
import 'package:window_manager/window_manager.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/dialog/exit_confirmation_dialog.dart';
import 'package:kazumi/bean/settings/theme_provider.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/utils/theme.dart';

class AppWidget extends StatefulWidget {
  const AppWidget({super.key});

  @override
  State<AppWidget> createState() => _AppWidgetState();
}

class _AppWidgetState extends State<AppWidget>
    with TrayListener, WidgetsBindingObserver, WindowListener {
  final TrayManager trayManager = TrayManager.instance;
  bool _isHandlingWindowClose = false;
  bool _didApplyStoredThemeSettings = false;
  Brightness? _lastTitleBarBrightness;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    _initializePlatformIntegrations();
  }

  Future<void> _initializePlatformIntegrations() async {
    if (isDesktop()) {
      await windowManager.setPreventClose(true);
      await _handleTray();
    }
    await _configurePreferredDisplayMode();
  }

  Future<void> _configurePreferredDisplayMode() async {
    if (!Platform.isAndroid) return;

    try {
      final modes = await FlutterDisplayMode.supported;
      final storageDisplay = GStorage.getSetting(SettingsKeys.displayMode);
      DisplayMode selectedMode = DisplayMode.auto;
      if (storageDisplay != null) {
        selectedMode = modes.firstWhere(
          (e) => e.toString() == storageDisplay,
          orElse: () => DisplayMode.auto,
        );
      }
      final preferred = modes.firstWhere(
        (el) => el == selectedMode,
        orElse: () => DisplayMode.auto,
      );
      await FlutterDisplayMode.setPreferredMode(preferred);
    } catch (e) {
      KazumiLogger().e('DisPlay: set preferred mode failed', error: e);
    }
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final themeProvider = context.watch<ThemeProvider>();
    _applyStoredThemeSettings(themeProvider);
    _syncWindowsTitleBarBrightness(themeProvider);
  }

  void _applyStoredThemeSettings(ThemeProvider themeProvider) {
    if (_didApplyStoredThemeSettings) return;
    _didApplyStoredThemeSettings = true;

    themeProvider.setThemeMode(_storedThemeMode(), notify: false);
    themeProvider.setDynamic(
      GStorage.getSetting(SettingsKeys.useDynamicColor),
      notify: false,
    );
    themeProvider.setFontFamily(
      GStorage.getSetting(SettingsKeys.useSystemFont),
      notify: false,
    );

    final color = _storedThemeColor();
    final oledEnhance = GStorage.getSetting(SettingsKeys.oledEnhance);
    final defaultDarkTheme = _buildAppTheme(
      brightness: Brightness.dark,
      color: color,
      fontFamily: themeProvider.currentFontFamily,
    );
    themeProvider.setTheme(
      _buildAppTheme(
        brightness: Brightness.light,
        color: color,
        fontFamily: themeProvider.currentFontFamily,
      ),
      oledEnhance ? oledDarkTheme(defaultDarkTheme) : defaultDarkTheme,
      notify: false,
    );
  }

  ThemeMode _storedThemeMode() {
    return switch (GStorage.getSetting(SettingsKeys.themeMode)) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };
  }

  Color _storedThemeColor() {
    final defaultThemeColor = GStorage.getSetting(SettingsKeys.themeColor);
    if (defaultThemeColor == 'default') {
      return Colors.green;
    }
    return Color(int.parse(defaultThemeColor, radix: 16));
  }

  ThemeData _buildAppTheme({
    required Brightness brightness,
    required String? fontFamily,
    Color? color,
    ColorScheme? colorScheme,
  }) {
    // 全局圆角：整个 App 的「一块面」都用同一个半径（见 KazumiGlass.radiusOf）。
    // 这里按窗口短边算一次 —— 主题是脱离 BuildContext 构建的，拿不到 MediaQuery。
    final double radius = KazumiGlass.radiusFor(_windowShortestSide());
    final BorderRadius globalRadius = BorderRadius.circular(radius);
    final RoundedRectangleBorder globalShape =
        RoundedRectangleBorder(borderRadius: globalRadius);
    // 下面两处是往 Apple 观感靠的最小改动（细节见各自注释）：
    // 1) 压低 Material 3 的「表面着色」（surfaceTint）：M3 会给卡片 / 弹窗 /
    //    菜单叠一层主题色的半透明覆盖，苹果的界面是中性灰面，不这么做白面上
    //    会泛出一层莫名的绿/紫。
    // 2) 点按反馈从 M3 的 InkSparkle（Android 上会溅出小星星）换成克制的
    //    InkRipple，并且只留一点极淡的高亮 —— 苹果的按钮按下就是轻微压暗。
    final ColorScheme scheme = colorScheme ??
        ColorScheme.fromSeed(
          seedColor: color ?? Colors.green,
          brightness: brightness,
        );
    final Color splash = scheme.primary.withValues(alpha: 0.08);
    final Color highlight = scheme.primary.withValues(alpha: 0.06);
    return ThemeData(
      useMaterial3: true,
      fontFamily: fontFamily,
      brightness: brightness,
      colorSchemeSeed: color,
      colorScheme: colorScheme,
      progressIndicatorTheme: progressIndicatorTheme2024,
      sliderTheme: sliderTheme2024,
      // Apple 观感：克制的按下反馈，不要 Material 3 的星星水波。
      splashFactory: InkRipple.splashFactory,
      splashColor: splash,
      highlightColor: highlight,
      pageTransitionsTheme: pageTransitionsTheme2024,
      // 下面这些是 Material 自带的「面板类」控件。以前各自用框架默认圆角
      // （卡片 12、对话框 28、输入框 4/12……），彼此对不上；统一到全局半径后，
      // 卡片、弹窗、底部弹层、输入框、标签、菜单、提示条看起来才是同一套。
      //
      // 表面着色归零：M3 默认把主题色以低透明度叠在所有 surface 上（primary /
      // secondary / surfaceContainer……），卡片和面板因此都泛着主题色的偏色。
      // 苹果的中性面不这么做。主题里需要用的容器色仍是 ColorScheme 给的，只是
      // 不再额外「染」一层。
      cardTheme: CardThemeData(
        shape: globalShape,
        clipBehavior: Clip.antiAlias,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        shape: globalShape,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: const BottomSheetThemeData().copyWith(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
        ),
        surfaceTintColor: Colors.transparent,
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: globalShape,
        surfaceTintColor: Colors.transparent,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          shape: WidgetStatePropertyAll<OutlinedBorder>(globalShape),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: globalShape,
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: globalRadius),
        enabledBorder: OutlineInputBorder(borderRadius: globalRadius),
        focusedBorder: OutlineInputBorder(borderRadius: globalRadius),
        errorBorder: OutlineInputBorder(borderRadius: globalRadius),
        focusedErrorBorder: OutlineInputBorder(borderRadius: globalRadius),
      ),
    );
  }

  /// 当前窗口的短边（逻辑像素）。主题构建在 BuildContext 之外，用它估屏幕圆角。
  double _windowShortestSide() {
    final ui.FlutterView? view = ui.PlatformDispatcher.instance.implicitView;
    if (view == null) return 393;
    final Size size = view.physicalSize / view.devicePixelRatio;
    return size.shortestSide;
  }

  void _syncWindowsTitleBarBrightness(ThemeProvider themeProvider) {
    if (!Platform.isWindows) return;

    final brightness =
        themeProvider.isEffectiveDark() ? Brightness.dark : Brightness.light;
    if (_lastTitleBarBrightness == brightness) return;

    _lastTitleBarBrightness = brightness;
    windowManager.setBrightness(brightness).catchError((e) {
      KazumiLogger().w('Window: set title bar brightness failed', error: e);
    });
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show_window':
        windowManager.show();
      case 'exit':
        exit(0);
    }
  }

  // windowManager.close() triggers this handler; exit() bypasses confirmation.
  @override
  Future<void> onWindowClose() async {
    if (_isHandlingWindowClose || !mounted) return;
    _isHandlingWindowClose = true;
    try {
      var action = switch (GStorage.getSetting(SettingsKeys.exitBehavior)) {
        0 => ExitDialogAction.exit,
        1 => ExitDialogAction.minimizeToTray,
        _ => null,
      };
      if (action == null) {
        final result = await KazumiDialog.show<ExitDialogResult>(
          builder: (_) => const ExitConfirmationDialog(),
        );
        if (result == null || !mounted) return;

        action = result.action;
        if (result.rememberChoice) {
          await GStorage.putSetting(
            SettingsKeys.exitBehavior,
            switch (action) {
              ExitDialogAction.exit => 0,
              ExitDialogAction.minimizeToTray => 1,
            },
          );
        }
      }

      if (!mounted) return;
      switch (action) {
        case ExitDialogAction.exit:
          exit(0);
        case ExitDialogAction.minimizeToTray:
          await windowManager.hide();
      }
    } finally {
      _isHandlingWindowClose = false;
    }
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
  Future<void> didChangePlatformBrightness() async {
    super.didChangePlatformBrightness();
    final ThemeProvider themeProvider = context.read<ThemeProvider>();
    KazumiLogger().i(
        "Platform brightness changed, themeMode: ${themeProvider.themeMode}");

    _syncWindowsTitleBarBrightness(themeProvider);
  }

  Future<void> _handleTray() async {
    if (Platform.isWindows) {
      await trayManager.setIcon('assets/images/logo/logo_lanczos.ico');
    } else if (Platform.environment.containsKey('FLATPAK_ID') ||
        Platform.environment.containsKey('SNAP')) {
      await trayManager.setIcon('io.github.Predidit.Kazumi');
    } else {
      await trayManager.setIcon('assets/images/logo/logo_rounded.png');
    }

    if (!Platform.isLinux) {
      await trayManager.setToolTip('Kazumi');
    }

    Menu trayMenu = Menu(items: [
      MenuItem(key: 'show_window', label: '显示窗口'),
      MenuItem.separator(),
      MenuItem(key: 'exit', label: '退出 Kazumi')
    ]);
    await trayManager.setContextMenu(trayMenu);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeProvider themeProvider = context.watch<ThemeProvider>();
    bool oledEnhance = GStorage.getSetting(SettingsKeys.oledEnhance);

    var app = DynamicColorBuilder(
      builder: (theme, darkTheme) {
        final useDynamicColor =
            themeProvider.useDynamicColor && theme != null && darkTheme != null;
        final lightTheme = useDynamicColor
            ? _buildAppTheme(
                brightness: Brightness.light,
                colorScheme: theme,
                fontFamily: themeProvider.currentFontFamily,
              )
            : themeProvider.light;
        final dynamicDarkTheme = useDynamicColor
            ? _buildAppTheme(
                brightness: Brightness.dark,
                colorScheme: darkTheme,
                fontFamily: themeProvider.currentFontFamily,
              )
            : themeProvider.dark;
        final effectiveDarkTheme = useDynamicColor && oledEnhance
            ? oledDarkTheme(dynamicDarkTheme)
            : dynamicDarkTheme;

        return MaterialApp.router(
          title: "Kazumi",
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [
            Locale.fromSubtags(
                languageCode: 'zh', scriptCode: 'Hans', countryCode: "CN")
          ],
          locale: const Locale.fromSubtags(
              languageCode: 'zh', scriptCode: 'Hans', countryCode: "CN"),
          theme: lightTheme,
          darkTheme: effectiveDarkTheme,
          themeMode: themeProvider.themeMode,
          scaffoldMessengerKey: rootScaffoldMessengerKey,
          routerConfig: ModularApp.routerConfigOf(context),
        );
      },
    );

    return app;
  }
}
