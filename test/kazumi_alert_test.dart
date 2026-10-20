import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';

/// [KazumiAlert] 在 [AlertDialog] 底下垫一层玻璃。两者都是「容器」，很容易在
/// 改写时把内层误写成自己 —— 那样 `build` 会无限递归，同一帧里永远有新的
/// dirty widget，`pump` 直接不返回，测试进程只能挂死（没有任何超时能救）。
/// 这几条用例就是那道护栏。
void main() {
  testWidgets('renders its title, content and actions', (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: KazumiAlert(
          title: const Text('删除这一项？'),
          content: const Text('删除后无法恢复。'),
          actions: [
            TextButton(
              onPressed: () => tapped = true,
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    ));

    expect(find.text('删除这一项？'), findsOneWidget);
    expect(find.text('删除后无法恢复。'), findsOneWidget);

    await tester.tap(find.text('删除'));
    expect(tapped, isTrue);
  });

  testWidgets('keeps the AlertDialog inside it, not another KazumiAlert',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: KazumiAlert(title: Text('一层'))),
    ));

    // 玻璃在 Flutter 图层树里，弹窗内只需要一层真正的 AlertDialog。
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(KazumiAlert), findsOneWidget);
    // 表面交给玻璃：框架那层不再自己铺色。
    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect(dialog.backgroundColor, Colors.transparent);
    expect(dialog.insetPadding, EdgeInsets.zero);
  });

  testWidgets('opens and closes through KazumiDialog', (tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [KazumiDialog.observer],
      home: const Scaffold(body: Text('home')),
    ));

    final result = KazumiDialog.show<bool>(
      builder: (_) => KazumiAlert(
        title: const Text('确认'),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(popWith: true),
            child: const Text('好'),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('确认'), findsOneWidget);

    await tester.tap(find.text('好'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(find.text('确认'), findsNothing);
  });
}
