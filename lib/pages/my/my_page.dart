import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/pages/menu/route_visibility.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/pages/my/my_space_view.dart';

class MyPage extends StatefulWidget {
  const MyPage({super.key, required this.controller});

  final MyController controller;

  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  bool _attached = false;

  /// 顶栏玻璃的出现进度（见 [SysAppBar.scrollProgress]）。
  final KazumiScrollProgress _scrollProgress = KazumiScrollProgress();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _setAttached(!RouteVisibility.isCoveredOf(context));
  }

  @override
  void didUpdateWidget(covariant MyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_attached && oldWidget.controller != widget.controller) {
      oldWidget.controller.detach();
      widget.controller.attach();
    }
  }

  @override
  void dispose() {
    _setAttached(false);
    _scrollProgress.dispose();
    super.dispose();
  }

  void _setAttached(bool value) {
    if (_attached == value) return;
    _attached = value;
    if (value) {
      widget.controller.attach();
    } else {
      widget.controller.detach();
    }
  }

  void _open(MyDestination destination) =>
      context.pushNamed(switch (destination) {
        MyDestination.notification => '/settings/notification',
        MyDestination.player => '/settings/player',
        MyDestination.danmaku => '/settings/danmaku/',
        MyDestination.rules => '/settings/plugin/',
        MyDestination.history => '/settings/history/',
        MyDestination.downloads => '/settings/download/',
        MyDestination.sync => '/settings/sync',
        MyDestination.storage => '/settings/storage',
        MyDestination.about => '/settings/about/',
      });

  @override
  Widget build(BuildContext context) {
    final SysAppBar appBar = SysAppBar(
      toolbarHeight: 72,
      // 大标题画在列表里（KazumiLargeTitle），顶栏这里让出位置给折叠标题。
      title: const SizedBox.shrink(),
      collapsedTitle: const Text('我的'),
      needTopOffset: false,
      scrollProgress: _scrollProgress,
      actions: [
        // 顶栏右侧统一是 40×40 的圆形玻璃图标按钮（SysAppBar 自动给每个
        // action 铺玻璃底）。上游这里原本是一个带「设置」文字的宽带按钮，
        // 塞进圆形玻璃里会溢出、也破坏了这套玻璃顶栏的形状语言，所以还原成本
        // 分支一贯的图标按钮 —— 玻璃里的图标按钮才是这里该有的样子，
        // 点击行为（打开 /settings/）不变。
        IconButton(
          tooltip: '全部设置',
          onPressed: () => context.pushNamed('/settings/'),
          icon: const Icon(Icons.tune_rounded, size: 22),
        ),
      ],
    );
    return Scaffold(
      appBar: appBar,
      // 内容从顶栏底下滑过去，玻璃才采得到东西（详见 SysAppBar.glassOverlay）。
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          SafeArea(
            top: false,
            bottom: false,
            child: KazumiScrollProgressObserver(
              progress: _scrollProgress,
              child: Observer(
                builder: (context) => MySpaceView(
                  stats: widget.controller.watchStats,
                  onOpen: _open,
                  topInset: appBar.bodyTopInset(context),
                ),
              ),
            ),
          ),
          appBar.glassOverlay(context),
        ],
      ),
    );
  }
}
