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

  /// Hero 飞行途中画什么。
  ///
  /// 用**目的地**那一端的 child（和框架默认一致）：飞行中画的这一份，和落地后
  /// 接手的静态封面是同一个 widget —— 同一张图、同一个解码尺寸、同一个
  /// [CachedNetworkImage] 状态。落地那一帧不需要重建、不需要换图、不需要重新
  /// 解码，也就不会闪。
  ///
  /// （之前这里改用「出发卡片」那一端的 child 重建一份 0 淡入的图。问题在于卡片
  /// 和封面的尺寸差很多：飞行时按卡片尺寸解码一份，落地又得按封面尺寸重解一次，
  /// 尺寸比越大越明显 —— 首页大卡片进详情页能看出闪，时间表/收藏那种小封面几乎
  /// 看不出。用目的地 child 就没有这次重解码。）
  static Widget heroFlightShuttleBuilder(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection flightDirection,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    // 只用目的地的 child，就顺手 capture 目的地的主题；不再做 MediaQuery
    // padding 补间（框架默认会补，导致底部导航栏内边距不同时图片上下漂移）。
    final Hero toHero = toHeroContext.widget as Hero;
    return InheritedTheme.captureAll(
      toHeroContext,
      Material(
        type: MaterialType.transparency,
        child: toHero.child,
      ),
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
      borderRadius: _borderRadiusOf(context),
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

  BorderRadius _borderRadiusOf(BuildContext context) =>
      borderRadius ??
      BorderRadius.circular(switch (type) {
        // 头像要正圆，不受圆角设置影响
        'avatar' => 50,
        'emote' => 0,
        // 缩略图 / 封面：沿用原来的 12，不跟全局屏幕圆角走。
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
        borderRadius: _borderRadiusOf(context),
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
