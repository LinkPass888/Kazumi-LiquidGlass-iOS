import 'dart:ui';

/// 玻璃材质的场景种类。
///
/// 苹果在 iOS 26 里给了两种玻璃材质，并明确「按承载的内容选材质」：
/// 文字密集的界面用 regular（自适应、保证可读），压在画面/视频上的控件用
/// clear（更通透，让背后的内容透出来）。
///
/// 我们不希望调用点散落着 `regular` / `clear` 字面量 —— 那样以后想调整某个
/// 场景的材质就得全局搜索。所以这里把「场景」建模成枚举，材质的分配集中在
/// [GlassMaterial.of] 一处。
enum GlassSurfaceKind {
  /// 顶栏、滚动折叠头。
  appBar,

  /// 底部弹层（sheet）。
  sheet,

  /// 对话框、吐司。
  dialog,

  /// 菜单面板。
  menu,

  /// 设置页 / 通用分组的浮层表面。
  groupedSurface,

  /// 详情页顶栏 —— 压在封面图上。
  mediaHeader,

  /// 详情页标签条。
  mediaTabBar,

  /// 播放器控制层（控制条、菜单、HUD、跳片头胶囊）。
  playerOverlay,

  /// 浮在内容之上的操作按钮（FAB 一类）。
  floatingAction,

  /// 图片查看器 / 截图预览的浮层。
  imageOverlay,
}

/// 一套玻璃材质的全部参数。
///
/// 这些数值直接喂给 `assets/shaders/liquid_glass.frag` 的 uniform。
/// 两个预设（[regular] / [clear]）对应苹果的两种材质，其余场景通过
/// [GlassMaterial.of] 映射到其中之一，必要时可单独覆写局部参数。
class GlassMaterial {
  const GlassMaterial({
    required this.name,
    required this.refraction,
    required this.highlight,
    required this.blurSigma,
    required this.thickness,
    required this.opacity,
  });

  /// 用于调试与日志的可读名字。
  final String name;

  /// 折光强度：越大边缘的透镜位移越明显。
  final double refraction;

  /// 边缘高光强度。
  final double highlight;

  /// 外层 `ImageFilterConfig.blur` 的 sigma（磨砂半径）。
  final double blurSigma;

  /// 内部厚度渐变强度。
  final double thickness;

  /// 整体不透明度系数。
  final double opacity;

  /// 自适应玻璃：保证背后内容之上的文字可读。
  ///
  /// 折光克制、磨砂更重、边缘高光更明显 —— 这是苹果给「承载内容」的玻璃
  /// 的取值取向。
  static const GlassMaterial regular = GlassMaterial(
    name: 'regular',
    refraction: 0.35,
    highlight: 0.16,
    blurSigma: 14,
    thickness: 0.55,
    opacity: 0.86,
  );

  /// 通透玻璃：用于压在照片 / 视频上的控件。
  ///
  /// 折光更强、磨砂更轻，让画面能透出来；高光略强以维持控件的轮廓。
  static const GlassMaterial clear = GlassMaterial(
    name: 'clear',
    refraction: 0.70,
    highlight: 0.22,
    blurSigma: 6,
    thickness: 0.30,
    opacity: 0.62,
  );

  /// 场景 → 材质。
  ///
  /// 这是整个 App「哪种面用哪种玻璃」的唯一真相。要调整某个场景的材质，
  /// 改这里，不要改调用点。
  static GlassMaterial of(GlassSurfaceKind kind) {
    return switch (kind) {
      // 文字密集：必须保证可读性。
      GlassSurfaceKind.appBar => regular,
      GlassSurfaceKind.sheet => regular,
      GlassSurfaceKind.dialog => regular,
      GlassSurfaceKind.menu => regular,
      GlassSurfaceKind.groupedSurface => regular,
      GlassSurfaceKind.mediaTabBar => regular,
      // 压在画面之上：要透出背后内容。
      GlassSurfaceKind.mediaHeader => clear,
      GlassSurfaceKind.playerOverlay => clear,
      GlassSurfaceKind.floatingAction => clear,
      GlassSurfaceKind.imageOverlay => clear,
    };
  }

  /// 调试开关：把全 App 临时压成同一种材质做对照（[regular] / [clear]）。
  ///
  /// 只在开发期手动设置；发布版本保持 null。
  static GlassMaterial? debugOverride;

  GlassMaterial copyWith({
    double? refraction,
    double? highlight,
    double? blurSigma,
    double? thickness,
    double? opacity,
  }) {
    return GlassMaterial(
      name: name,
      refraction: refraction ?? this.refraction,
      highlight: highlight ?? this.highlight,
      blurSigma: blurSigma ?? this.blurSigma,
      thickness: thickness ?? this.thickness,
      opacity: opacity ?? this.opacity,
    );
  }

  /// 深色模式下玻璃的磨砂需要略强一点，否则背后的深色内容会「透」得脏。
  GlassMaterial forBrightness(Brightness brightness) {
    if (brightness == Brightness.light) {
      return this;
    }
    return copyWith(
      blurSigma: blurSigma * 1.15,
      opacity: (opacity + 0.06).clamp(0.0, 1.0),
    );
  }

  @override
  String toString() => 'GlassMaterial($name)';
}
