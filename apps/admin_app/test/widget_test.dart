import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/shared_ui.dart';

/// 管理端冒烟测试。
///
/// 除骨架渲染外，专门验证管理端特有的界面要求：
///   * 紧凑主题下按钮仍不低于无障碍最小高度（现场戴手套点屏幕的人不止一个）；
///   * 窄屏下长标题不溢出；
///   * 主按钮加载时禁止重复点击。
void main() {
  testWidgets('活动行能渲染名称与状态', (WidgetTester tester) async {
    const String title = '实验室安全巡查志愿岗';

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(compact: true),
        home: Scaffold(
          body: AppCard(
            highlight: true,
            child: Row(
              children: <Widget>[
                const Expanded(child: Text(title)),
                StatusChip(
                  visual: StatusVisuals.ofActivity(ActivityStatus.ongoing),
                  compact: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text(title), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏下长标题不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(compact: true),
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(Spacing.md),
            child: AppCard(
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '图书馆书架整理与破损图书登记志愿服务活动（含读者引导）',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SizedBox(width: Spacing.xs),
                  StatusChip(
                    visual: StatusVisual(
                      label: '已发布',
                      tone: StatusTone.info,
                    ),
                    compact: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // 溢出会在测试里报 overflow 异常。
    expect(tester.takeException(), isNull);
  });

  testWidgets('紧凑主题的按钮高度不低于无障碍最小值', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(compact: true),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              AppButton(label: '发布活动', onPressed: () {}),
              AppButton(label: '小按钮', onPressed: () {}, compact: true),
            ],
          ),
        ),
      ),
    );

    final Size big = tester.getSize(find.widgetWithText(FilledButton, '发布活动'));
    final Size small = tester.getSize(find.widgetWithText(FilledButton, '小按钮'));

    // ⚠️ 这条断言的价值：管理端主题用 `VisualDensity.compact`，
    // 而 Flutter 会在 `minimumSize` **之后**再减掉密度带来的高度
    //（每级 −4）。所以"主题里写 52"实际会渲染成 44，
    // 且读 `theme.filledButtonTheme.style.minimumSize` 仍显示 52 ——
    // 只有真的量尺寸才能发现。AppTheme 里做了补偿（见 _minHeightFor）。
    expect(big.height, greaterThanOrEqualTo(Sizes.buttonHeight));
    // ⚠️ 紧凑按钮可以矮一点，但不能低于 44。
    expect(small.height, greaterThanOrEqualTo(Sizes.buttonHeightCompact));
    expect(Sizes.buttonHeightCompact, greaterThanOrEqualTo(44));
  });

  testWidgets('AppButton 加载时禁止重复点击', (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(),
        home: Scaffold(
          body: AppButton(
            label: '提交',
            loading: true,
            loadingLabel: '提交中…',
            onPressed: () => taps += 1,
          ),
        ),
      ),
    );

    expect(find.text('提交中…'), findsOneWidget);
    await tester.tap(find.byType(FilledButton), warnIfMissed: false);
    await tester.pump();
    expect(taps, 0, reason: '加载中必须禁止再次点击，否则会出现两个并行的提交中');
  });
}
