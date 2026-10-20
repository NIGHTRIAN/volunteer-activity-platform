import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:user_app/checkin_availability.dart';

/// 签到入口可用性判定。
///
/// ## 为什么这组测试必须存在
///
/// 这是**真机测试抓到的阻塞性 bug**：原先只看 `status == ongoing` 决定
/// 是否显示「去签到」，而服务端不会自动把 `published` 转成 `ongoing`
/// （docs/open-issues-app.md O-3）。于是活动到点了，界面却一直说
/// "活动尚未开始"，签到按钮永远不出现 —— 志愿者根本没法签到。
///
/// 单元测试当时全绿，因为测试数据里的 status 都是手工设好的。
/// 只有在真机上按真实时间走一遍才会暴露。
///
/// 现在口径改为"按签到时间窗"，这组测试逐条锁住它。
void main() {
  const Duration before = Duration(minutes: 30);
  const Duration after = Duration(minutes: 60);

  Activity act({
    required ActivityStatus status,
    required DateTime start,
    required DateTime end,
  }) =>
      Activity(
        id: 'act-1',
        externalId: 'ACT-1',
        title: '图书馆书架整理',
        organizer: '校团委',
        durationHours: 2,
        startTime: start,
        endTime: end,
        location: '南湖校区图书馆三层',
        geoLat: 34.2175,
        geoLng: 117.1425,
        status: status,
        checkinWindowBefore: before,
        checkinWindowAfter: after,
      );

  test('状态仍是 published 但已过开始时刻 → 应可签到（O-3 的核心场景）', () {
    final DateTime now = DateTime.now();
    final CheckinAvailability r = checkinAvailability(
      act(
        status: ActivityStatus.published,
        start: now.subtract(const Duration(minutes: 10)),
        end: now.add(const Duration(hours: 2)),
      ),
      now,
    );

    expect(
      r.canCheckin,
      isTrue,
      reason: '服务端不自动流转状态，到点了就必须能签到，否则功能不可用',
    );
  });

  test('开始前但已进入签到窗口（提前 30 分钟）→ 可签到', () {
    final DateTime now = DateTime.now();
    final CheckinAvailability r = checkinAvailability(
      act(
        status: ActivityStatus.published,
        // 10 分钟后开始，窗口已提前 30 分钟开放
        start: now.add(const Duration(minutes: 10)),
        end: now.add(const Duration(hours: 2)),
      ),
      now,
    );
    expect(r.canCheckin, isTrue);
  });

  test('窗口未开放 → 不可签到，并给出具体开放时刻', () {
    final DateTime now = DateTime.now();
    final DateTime start = now.add(const Duration(hours: 3));
    final CheckinAvailability r = checkinAvailability(
      act(status: ActivityStatus.published, start: start, end: start.add(const Duration(hours: 2))),
      now,
    );

    expect(r.canCheckin, isFalse);
    // 只说"暂不可用"没有信息量；必须给出可以直接对照手表的时刻。
    expect(r.message, contains('开放'));
    expect(r.message, contains(TimeFormat.format(start.subtract(before))));
    expect(r.tone, StatusTone.info);
  });

  test('窗口已关闭但状态未终结 → 不可签到，并指向发布者补录', () {
    final DateTime now = DateTime.now();
    final DateTime end = now.subtract(const Duration(hours: 3));
    final CheckinAvailability r = checkinAvailability(
      act(status: ActivityStatus.published, start: end.subtract(const Duration(hours: 2)), end: end),
      now,
    );

    expect(r.canCheckin, isFalse);
    // 必须给出下一步，否则志愿者不知道该怎么办。
    expect(r.message, contains('关闭'));
    expect(r.message, contains('发布者'));
    // 用 warning 而不是 danger：这是"错过时机"，不是"你被判定为缺席"。
    expect(r.tone, StatusTone.warning);
  });

  test('已结束 → 不可签到，并提示留存期', () {
    final DateTime now = DateTime.now();
    final CheckinAvailability r = checkinAvailability(
      act(
        status: ActivityStatus.finished,
        start: now.subtract(const Duration(hours: 5)),
        end: now.subtract(const Duration(hours: 3)),
      ),
      now,
    );

    expect(r.canCheckin, isFalse);
    expect(r.message, contains('7 天'));
    expect(r.tone, StatusTone.neutral);
  });

  test('已取消 → 不可签到，且说明已到场记录不受影响', () {
    final DateTime now = DateTime.now();
    final CheckinAvailability r = checkinAvailability(
      act(
        status: ActivityStatus.cancelled,
        start: now.subtract(const Duration(minutes: 10)),
        end: now.add(const Duration(hours: 2)),
      ),
      now,
    );

    expect(
      r.canCheckin,
      isFalse,
      reason: '即使处在时间窗内，已取消的活动也不该显示签到按钮',
    );
    expect(r.message, contains('已到场的记录不受影响'));
    expect(r.tone, StatusTone.danger);
  });

  test('已终结的活动优先于时间窗判断', () {
    // 防回归：若有人把"是否在窗口内"提到最前面，已结束的活动
    // 在窗口内会错误地显示签到按钮。
    final DateTime now = DateTime.now();
    for (final ActivityStatus s in <ActivityStatus>[
      ActivityStatus.finished,
      ActivityStatus.cancelled,
    ]) {
      final CheckinAvailability r = checkinAvailability(
        act(
          status: s,
          start: now.subtract(const Duration(minutes: 5)),
          end: now.add(const Duration(hours: 2)),
        ),
        now,
      );
      expect(r.canCheckin, isFalse, reason: '状态 $s 不应可签到');
    }
  });
}
