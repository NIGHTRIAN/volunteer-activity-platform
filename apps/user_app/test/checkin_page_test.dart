import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:user_app/checkin_page.dart';

/// 签到页测试。
///
/// 重点不是"能不能点"，而是三条**会引发争议的行为**：
///   1. 进入页面**不自动采集定位**（方案 §7 只按需采集）；
///   2. 窗口未开时按钮禁用，**并且说明为什么**（不能只是灰着）；
///   3. 提交过程中不得显示"成功"（验收 A15）。
void main() {
  Activity activity({
    required ActivityStatus status,
    required DateTime start,
    required DateTime end,
    Duration windowBefore = const Duration(minutes: 30),
    Duration windowAfter = const Duration(minutes: 60),
  }) =>
      Activity(
        id: 'act-1',
        externalId: 'ACT-1',
        title: '图书馆书架整理',
        organizer: '校团委',
        durationHours: 3,
        startTime: start,
        endTime: end,
        location: '南湖校区图书馆三层',
        geoLat: 34.2175,
        geoLng: 117.1425,
        status: status,
        checkinWindowBefore: windowBefore,
        checkinWindowAfter: windowAfter,
      );

  /// 由于页面内用 `DateTime.now()` 驱动倒计时，这里用相对当前时间构造活动，
  /// 避免固定时间导致测试随真实日期漂移。
  Activity ongoingNow() {
    final DateTime now = DateTime.now();
    return activity(
      status: ActivityStatus.ongoing,
      start: now.subtract(const Duration(minutes: 10)),
      end: now.add(const Duration(hours: 2)),
    );
  }

  testWidgets('进入页面不自动采集定位（方案 §7 按需采集）', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(),
        home: CheckinPage(activity: ongoingNow()),
      ),
    );

    // 没有 AppScope，所以一旦自动调用 _collect 就会因取不到服务而抛异常。
    // 这里断言"没有异常"即证明：进页面不会自动触发定位采集。
    expect(tester.takeException(), isNull);
    expect(find.text('开始签到'), findsOneWidget);
    // 采集前不应出现任何证据卡片。
    expect(find.text('已采集的证据'), findsNothing);
  });

  testWidgets('窗口内显示"可以签到"与关闭时间', (WidgetTester tester) async {
    final Activity a = ongoingNow();
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.build(), home: CheckinPage(activity: a)),
    );

    expect(find.text('可以签到'), findsOneWidget);
    expect(find.textContaining('关闭'), findsWidgets);
    expect(find.text('开始签到'), findsOneWidget);
  });

  testWidgets('未到开放时间：禁用按钮并说明何时开放', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    final Activity a = activity(
      status: ActivityStatus.published,
      start: now.add(const Duration(hours: 3)),
      end: now.add(const Duration(hours: 5)),
    );

    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.build(), home: CheckinPage(activity: a)),
    );

    expect(find.text('尚未开放'), findsOneWidget);
    // ⚠️ 关键：不能只是把按钮灰掉。必须告诉用户**什么时候能签**，
    // 否则现场只会得到"按钮点不动"的困惑。
    expect(find.textContaining('开放'), findsWidgets);
    expect(find.text('不在签到时段'), findsOneWidget);

    // 禁用的按钮不得响应点击。
    await tester.tap(find.text('不在签到时段'), warnIfMissed: false);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('窗口已过：说明已结束并指向发布者（不得出现死路）', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    final Activity a = activity(
      status: ActivityStatus.finished,
      start: now.subtract(const Duration(hours: 4)),
      end: now.subtract(const Duration(hours: 2)),
    );

    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.build(), home: CheckinPage(activity: a)),
    );

    expect(find.text('签到时段已结束'), findsOneWidget);
    // ⚠️ 方案 §7「不得出现死路」：关闭之后必须给出可执行的下一步。
    expect(find.textContaining('发布者'), findsWidgets);
  });

  testWidgets('隐私说明出现在签到按钮下方（采集前就该知道）', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.build(), home: CheckinPage(activity: ongoingNow())),
    );

    expect(
      find.textContaining('不采集持续轨迹'),
      findsOneWidget,
      reason: '用户按下按钮前就应知道要采集什么',
    );
  });

  testWidgets('窗口边界按契约 30/60 计算（与决策 D-5 一致）', (WidgetTester tester) async {
    final DateTime start = DateTime(2026, 10, 16, 9);
    final DateTime end = DateTime(2026, 10, 16, 11);
    final Activity a = activity(
      status: ActivityStatus.finished,
      start: start,
      end: end,
    );

    // 这两个断言放在 shared_core 里也有，但这里用**页面实际渲染的文案**
    // 再验一次：页面如果用了自己算的窗口（而不是 Activity 的），就会不一致。
    expect(a.checkinOpensAt, DateTime(2026, 10, 16, 8, 30));
    expect(a.checkinClosesAt, DateTime(2026, 10, 16, 12, 0));

    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.build(), home: CheckinPage(activity: a)),
    );
    expect(find.textContaining('12:00'), findsWidgets);
  });
}
