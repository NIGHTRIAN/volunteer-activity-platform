import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/shared_ui.dart';

/// 用户端冒烟测试。
///
/// 目的不是覆盖业务（那是 A3 的事），而是保证**骨架能起来**：
/// 主题能构建、卡片与状态标签能渲染、每种领域状态都不会漏映射。
void main() {
  testWidgets('活动卡片能把活动信息渲染出来', (WidgetTester tester) async {
    final Activity activity = Activity(
      id: 'act-1',
      externalId: 'ACT-1',
      title: '图书馆书架整理',
      organizer: '校团委',
      durationHours: 3,
      startTime: DateTime(2026, 10, 16, 9),
      endTime: DateTime(2026, 10, 16, 12),
      location: '南湖校区图书馆三层',
      geoLat: 34.2175,
      geoLng: 117.1425,
      status: ActivityStatus.ongoing,
      summary: '整理社科类书架',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(),
        home: Scaffold(
          body: AppCard(
            highlight: activity.status == ActivityStatus.ongoing,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(activity.title),
                StatusChip(
                  visual: StatusVisuals.ofActivity(activity.status),
                  compact: true,
                ),
                InfoRow(label: '时间', value: TimeFormat.format(activity.startTime)),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('图书馆书架整理'), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('每种签到状态都能渲染（不漏映射）', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: CheckinStatus.values
                  .map(
                    (CheckinStatus s) => StatusChip(
                      visual: StatusVisuals.ofCheckin(s),
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('空状态给出可执行的下一步，而不是只说"暂无数据"', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(),
        home: const Scaffold(
          body: EmptyState(
            title: '还没有可以签到的活动',
            message: '活动发布后，发布者会把邀请码发给你。',
          ),
        ),
      ),
    );

    expect(find.text('还没有可以签到的活动'), findsOneWidget);
    // ⚠️ 关键：空状态必须告诉用户"下一步做什么"。
    // 只说"暂无数据"会让人分不清"正常"还是"出故障了"。
    expect(find.textContaining('邀请码'), findsOneWidget);
  });
}
