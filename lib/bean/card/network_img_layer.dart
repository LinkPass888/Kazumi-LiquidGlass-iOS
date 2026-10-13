import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/image_extension.dart';

class NetworkImgLayer extends StatelessWidget {
  const NetworkImgLayer({
    super.key,
    this.src,
    required this.width,
    required this.height,
    this.fit = BoxFit.cover,
    this.type,
    this.fadeOutDuration,
    this.fadeInDuration,
    this.origAspectRatio,
    this.filterQuality = FilterQuality.high,
    this.color,
    this.colorBlendMode,
    this.borderRadius,
  });

  final String? src;
  final double width;
  final double height;
  final BoxFit fit;
  final String? type;
  final Duration? fadeOutDuration;
  final Duration? fadeInDuration;
  final double? origAspectRatio;
  final FilterQuality filterQuality;
  final Color? color;
  final BlendMode? colorBlendMode;
  final BorderRadius? borderRadius;

  static Widget heroFlightShuttleBuilder(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection flightDirection,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    final fromHero = fromHeroContext.widget as Hero;
    final toHero = toHeroContext.widget as Hero;
    final heroContext = flightDirection == HeroFlightDirection.push
        ? fromHeroContext
        : toHeroContext;
    final hero =
        flightDirection == HeroFlightDirection.push ? fromHero : toHero;

    return InheritedTheme.captureAll(
      heroContext,
      Material(
        type: MaterialType.transparency,
        child: _noFade(hero.child),
      ),
    );
  }

  /// 飞行中用「不淡入」的版本来画这张图。
  ///
  /// shuttle 是**新构建**的一棵子树：源卡片的 [NetworkImgLayer] 默认带 120ms
  /// 淡入，直接复用就等于飞行途中又淡入一次；而落地后接手的静态封面（详情页那
  /// 张）是 0 淡入。两边不一致，落位那一帧就会看见封面「闪一下」——首页点进详情
  /// 时能看出来（首页卡片、详情封面尺寸都大），时间表/收藏那种小封面几乎看不
  /// 出来。这里把飞行这一份统一成 0 淡入，起飞、飞行、落地全程同一张图。
  static Widget _noFade(Widget child) {
    // 卡片有的把图片直接交给 Hero，有的套了一层 ClipRRect 出圆角
    // （时间表卡片），两种都要能改到里面的图。
    if (child is ClipRRect && child.child is NetworkImgLayer) {
      return ClipRRect(
        borderRadius: child.borderRadius,
        clipBehavior: child.clipBehavior,
        child: _noFade(child.child!),
      );
    }
    if (child is! NetworkImgLayer) {
      return child;
    }
    return NetworkImgLayer(
      src: child.src,
      width: child.width,
      height: child.height,
      fit: child.fit,
      type: child.type,
      origAspectRatio: child.origAspectRatio,
      filterQuality: child.filterQuality,
      color: child.color,
      colorBlendMode: child.colorBlendMode,
      borderRadius: child.borderRadius,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
    );
  }

  /// 卡片 ↔ 详情页之间飞行时用的矩形插值。
  ///
  /// 不用框架默认的 [MaterialRectArcTween]：它走的是一条带弧度的路径，两端矩形
  /// 差得越多，中途偏得越远 —— 缩略图会先甩到页面外面再折回卡片，看着就是「飘
  /// 了一下」。这里改成直线插值：中心走直线、宽高各自等比，途中生成的矩形一定
  /// 落在两个端点的包围盒里，不会跑到卡片和海报之外的地方去。
  static RectTween heroRectTween(Rect? begin, Rect? end) =>
      RectTween(begin: begin, end: end);

  @override
  Widget build(BuildContext context) {
    final imageUrl = src ?? '';
    if (imageUrl.isEmpty) {
      return _placeholder(context);
    }

    final (memCacheWidth, memCacheHeight) = _cacheSize(context);
    return ClipRRect(
      clipBehavior: Clip.antiAlias,
      borderRadius: _borderRadius,
      child: CachedNetworkImage(
        imageUrl: imageUrl,
        width: width,
        height: height,
        memCacheWidth: memCacheWidth,
        memCacheHeight: memCacheHeight,
        fit: fit,
        fadeOutDuration: fadeOutDuration ?? const Duration(milliseconds: 120),
        fadeInDuration: fadeInDuration ?? const Duration(milliseconds: 120),
        filterQuality: filterQuality,
        color: color,
        colorBlendMode: colorBlendMode,
        errorListener: (e) {
          KazumiLogger().w("NetworkImage: network image load error", error: e);
        },
        errorWidget: (context, url, error) => _placeholder(context),
        placeholder: (context, url) => _placeholder(context),
      ),
    );
  }

  (int?, int?) _cacheSize(BuildContext context) {
    final cacheWidth = width.cacheSize(context);
    final cacheHeight = height.cacheSize(context);
    final aspectRatio = width / height;
    final sourceAspectRatio = origAspectRatio;

    switch (fit) {
      case BoxFit.none:
      case BoxFit.scaleDown:
        // These modes depend on the original image dimensions.
        return (null, null);
      case BoxFit.fill:
        return (cacheWidth, cacheHeight);
      case BoxFit.fitWidth:
        return (cacheWidth, null);
      case BoxFit.fitHeight:
        return (null, cacheHeight);
      case BoxFit.contain:
        // A single decode axis preserves unknown source proportions.
        return sourceAspectRatio != null && sourceAspectRatio > aspectRatio
            ? (cacheWidth, null)
            : (null, cacheHeight);
      case BoxFit.cover:
        // Decode enough pixels along the axis that fills the box.
        if (sourceAspectRatio != null) {
          if (sourceAspectRatio < aspectRatio) return (cacheWidth, null);
          if (sourceAspectRatio > aspectRatio) return (null, cacheHeight);
        } else {
          if (aspectRatio > 1) return (null, cacheHeight);
          if (aspectRatio < 1) return (cacheWidth, null);
        }
        return (cacheWidth, cacheHeight);
    }
  }

  BorderRadius get _borderRadius =>
      borderRadius ??
      BorderRadius.circular(switch (type) {
        'avatar' => 50,
        'emote' => 0,
        _ => StyleString.imgRadius.x,
      });

  Widget _placeholder(BuildContext context) {
    return Container(
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .onInverseSurface
            .withValues(alpha: 0.4),
        borderRadius: _borderRadius,
      ),
      child: type == 'bg'
          ? const SizedBox()
          : Center(
              child: Image.asset(
                type == 'avatar'
                    ? 'assets/images/noface.jpeg'
                    : 'assets/images/loading.png',
                width: width,
                height: height,
                cacheWidth: width.cacheSize(context),
                cacheHeight: height.cacheSize(context),
              ),
            ),
    );
  }
}
