import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/shared_ui.dart';

/// 管理端业务页面测试。
///
/// 重点不在"能不能渲染"，而在三条**会让发布者做出错误判断**的规则：
///   1. 看板四态计数必须与"有效名单"自洽（不能把已移出的人算进未签到）；
///   2. 考勤汇总的「证据不足」不得呈现为「缺席」；
///   3. 「未签到」的措辞与颜色必须区分"还没开始"与"确实没来"。
void main() {
  group('看板四态计数', () {
    ActivityBoard board({
      int checkedIn = 0,
      int pendingReview = 0,
      int notCheckedIn = 0,
      int removed = 0,
    }) =>
        ActivityBoard(
          activityId: 'act-1',
          checkedIn: checkedIn,
          pendingReview: pendingReview,
          notCheckedIn: notCheckedIn,
          removed: removed,
        );

    test('有效名单 = 已签到 + 待确认 + 尚未签到（已移出不计入）', () {
      final ActivityBoard b = board(
        checkedIn: 12,
        pendingReview: 3,
        notCheckedIn: 5,
        removed: 2,
      );
      expect(b.activeTotal, 20);
      // ⚠️ 已移出的人**不能**算进未签到 —— 那会冤枉已经退出的人，
      // 也会让到场率凭空变低。
      expect(b.activeTotal, isNot(22));
    });

    test('到场率把「待确认」算作到场（尚未定案，不该算缺席）', () {
      final ActivityBoard b = board(checkedIn: 6, pendingReview: 2, notCheckedIn: 2);
      expect(b.presentRate, 0.8);
    });

    test('空名单时到场率为 0 而不是除零异常', () {
      final ActivityBoard b = board();
      expect(b.activeTotal, 0);
      expect(b.presentRate, 0);
    });

    test('从 JSON 解析服务端字段（含 disclaimer 与 dataDestroyAt）', () {
      final ActivityBoard b = ActivityBoard.fromJson(<String, dynamic>{
        'activityId': 'act-9',
        'checkedIn': 3,
        'pendingReview': 1,
        'notCheckedIn': 4,
        'removed': 0,
        'attendancePending': 2,
        'attendanceDone': 7,
        'attendanceMissed': 1,
        'attendanceExcused': 3,
        'servingNow': 7,
        'serverTime': '2026-10-16T09:00:00+08:00',
        'dataDestroyAt': '2026-10-23T09:00:00+08:00',
        'disclaimer': '考勤结果仅作现场管理参考，不作为志愿时长认定依据，不自动产生任何扣减。',
        'participants': <Object?>[
          <String, dynamic>{
            'id': '2023001',
            'userNo': '2023001',
            'name': '张三',
            'phone': '138****0001',
            'signupStatus': 'registered',
            'checkinStatus': 'success',
          },
        ],
      });

      expect(b.activeTotal, 8);
      expect(b.attendanceDone, 7);
      expect(b.attendanceMissed, 1);
      expect(b.attendanceExcused, 3);
      // ⚠️ 免责声明**由服务端下发**：它是发布者面对质疑时的依据，
      // 措辞必须与服务端记录一致，客户端不能自己写一份。
      expect(b.disclaimer, contains('不作为志愿时长认定依据'));
      expect(b.dataDestroyAt, isNotNull);
      expect(b.participants, hasLength(1));
    });

    test('名单行的 checkinStatus 按服务端词表解析（success / none）', () {
      // ⚠️ 这条守着一次实测踩到的 bug：早期客户端 enum 期望
      // `checked_in` / `not_checked_in`，而服务端下发 `success` / `none`，
      // 结果看板上所有已签到的参与者都显示成"未知状态"。
      final Participant checked = Participant.fromJson(<String, dynamic>{
        'userNo': '2023001',
        'name': '张三',
        'signupStatus': 'registered',
        'checkinStatus': 'success',
      });
      expect(checked.checkinStatus, ParticipantCheckinStatus.checkedIn);

      final Participant none = Participant.fromJson(<String, dynamic>{
        'userNo': '2023002',
        'name': '李四',
        'signupStatus': 'registered',
        'checkinStatus': 'none',
      });
      expect(none.checkinStatus, ParticipantCheckinStatus.notCheckedIn);

      // 兼容早期的旧写法，避免历史数据解析成未知。
      final Participant legacy = Participant.fromJson(<String, dynamic>{
        'userNo': '2023003',
        'name': '王五',
        'signupStatus': 'registered',
        'checkinStatus': 'checked_in',
      });
      expect(legacy.checkinStatus, ParticipantCheckinStatus.checkedIn);
    });
  });

  group('考勤汇总行解析', () {
    test('完成率为 null 时不做除法（无已定案任务）', () {
      final AttendanceSummaryRow r = AttendanceSummaryRow.fromJson(<String, dynamic>{
        'userNo': '2023001',
        'name': '张三',
        'attendanceSummary': 'insufficient',
        'attendanceDone': 0,
        'attendanceMissed': 0,
        'attendanceExcused': 5,
        'attendanceRate': null,
      });
      expect(r.summary, AttendanceSummary.insufficient);
      expect(r.rate, isNull);
      expect(r.excused, 5);
    });

    test('完成率按 0.7 阈值区分为 partial / insufficient（决策 D-7）', () {
      // 5 次里完成 4 次 = 0.8 → partial
      final AttendanceSummaryRow partial =
          AttendanceSummaryRow.fromJson(<String, dynamic>{
        'userNo': 'a',
        'name': 'A',
        'attendanceSummary': 'partial',
        'attendanceDone': 4,
        'attendanceMissed': 1,
        'attendanceExcused': 0,
        'attendanceRate': 0.8,
      });
      expect(partial.summary, AttendanceSummary.partial);
      expect(partial.rate, closeTo(0.8, 1e-9));
      expect(partial.settled, 5);
      expect(partial.ratePercent, 80);

      // 5 次里完成 3 次 = 0.6 → insufficient（不是 partial）
      final AttendanceSummaryRow low =
          AttendanceSummaryRow.fromJson(<String, dynamic>{
        'userNo': 'b',
        'name': 'B',
        'attendanceSummary': 'insufficient',
        'attendanceDone': 3,
        'attendanceMissed': 2,
        'attendanceExcused': 0,
        'attendanceRate': 0.6,
      });
      expect(low.summary, AttendanceSummary.insufficient);
    });

    test('无已定案任务时 rate 为 null 且标识为「无可判定记录」', () {
      // ⚠️ 这条区分很重要：汇总里"完成率 0%"读起来像"一次都没完成"，
      // 而实际含义是"还没有可判定的事"（抽查尚未发生）。
      final AttendanceSummaryRow r =
          AttendanceSummaryRow.fromJson(<String, dynamic>{
        'userNo': 'c',
        'name': 'C',
        'attendanceSummary': 'insufficient',
        'attendanceDone': 0,
        'attendanceMissed': 0,
        'attendanceExcused': 4,
        'attendanceRate': null,
      });
      expect(r.rate, isNull);
      expect(r.ratePercent, isNull);
      expect(r.settled, 0);
      expect(r.hasNoSettledTask, isTrue);
    });
  });

  group('考勤汇总整体', () {
    test('能统计各类人数，且「证据不足」不混进「缺席」', () {
      final AttendanceReport report = AttendanceReport.fromJson(<String, dynamic>{
        'disclaimer': '考勤结果仅作现场管理参考，不作为志愿时长认定依据。',
        'rows': <Object?>[
          <String, dynamic>{'userNo': '1', 'name': 'A', 'attendanceSummary': 'full'},
          <String, dynamic>{'userNo': '2', 'name': 'B', 'attendanceSummary': 'partial'},
          <String, dynamic>{'userNo': '3', 'name': 'C', 'attendanceSummary': 'insufficient'},
          <String, dynamic>{'userNo': '4', 'name': 'D', 'attendanceSummary': 'insufficient'},
          <String, dynamic>{'userNo': '5', 'name': 'E', 'attendanceSummary': 'absent'},
        ],
      });
      expect(report.fullCount, 1);
      expect(report.partialCount, 1);
      expect(report.insufficientCount, 2);
      expect(report.disclaimer, contains('不作为志愿时长认定依据'));
    });
  });

  group('状态呈现（防误读）', () {
    test('「证据不足」不得用危险色（它不是处罚）', () {
      final StatusVisual v = StatusVisuals.ofAttendanceSummary(
        AttendanceSummary.insufficient,
      );
      expect(v.tone, isNot(StatusTone.danger));
      expect(v.description, contains('不定性为缺席'));
    });

    test('「缺席」才是危险色', () {
      expect(
        StatusVisuals.ofAttendanceSummary(AttendanceSummary.absent).tone,
        StatusTone.danger,
      );
    });

    test('「尚未签到」的措辞不写成「未签到」', () {
      // 活动还没开始时所有人都是这个状态。说成"未签到"会让发布者
      // 以为出问题了；而这一列正是他现场最常看的一列。
      final StatusVisual v = StatusVisuals.ofParticipantCheckin(
        ParticipantCheckinStatus.notCheckedIn,
      );
      expect(v.label, '尚未签到');
      expect(v.description, isNotNull);
    });

    test('「已超时」的在岗说明写明不自动扣减时长（方案 §4.8）', () {
      final StatusVisual v =
          StatusVisuals.ofAttendanceTask(AttendanceTaskStatus.missed);
      expect(v.description, contains('不自动扣减'));
    });
  });

  group('界面渲染冒烟', () {
    testWidgets('看板四态计数能把 0 与正数都渲染出来', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(compact: true),
          home: Scaffold(
            body: Column(
              children: <Widget>[
                AppCard(
                  child: Row(
                    children: <Widget>[
                      Expanded(child: _Tile(value: 12, label: '已签到')),
                      Expanded(child: _Tile(value: 0, label: '待确认')),
                    ],
                  ),
                ),
                AppCard(
                  child: Row(
                    children: <Widget>[
                      Expanded(child: _Tile(value: 5, label: '尚未签到')),
                      Expanded(child: _Tile(value: 2, label: '已移出')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('12'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
      expect(find.text('尚未签到'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('考勤汇总行把完成率与各项计数都显示出来', (WidgetTester tester) async {
      final AttendanceSummaryRow row =
          AttendanceSummaryRow.fromJson(<String, dynamic>{
        'userNo': '2023001',
        'name': '张三',
        'attendanceSummary': 'partial',
        'attendanceDone': 4,
        'attendanceMissed': 1,
        'attendanceExcused': 2,
        'attendanceRate': 0.8,
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(compact: true),
          home: Scaffold(
            body: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(row.name),
                  // 与页面里同构的摘要文案。
                  Text(
                    row.hasNoSettledTask
                        ? '尚无已定案的抽查${row.excused > 0 ? '（豁免 ${row.excused} 次）' : ''}'
                        : '完成 ${row.done} · 超时 ${row.missed}'
                            '${row.excused > 0 ? ' · 豁免 ${row.excused}' : ''}'
                            '${row.ratePercent == null ? '' : ' · 完成率 ${row.ratePercent}%'}',
                  ),
                  StatusChip(
                    visual: StatusVisuals.ofAttendanceSummary(row.summary),
                    compact: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // 完成率必须显示出来：只给等级，读的人无法判断"差一点还是差很多"。
      expect(find.textContaining('完成率 80%'), findsOneWidget);
      expect(find.textContaining('完成 4'), findsOneWidget);
      expect(find.text('部分完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// 计数卡片的最小替身（与看板页里的结构一致）。
class _Tile extends StatelessWidget {
  const _Tile({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text('$value'),
        Text(label),
      ],
    );
  }
}
