import 'package:shared_core/shared_core.dart';
import 'package:test/test.dart';

/// 活动模型与抽查时段推算。
///
/// 这里的断言直接对应**验收用例 A20**：2 小时活动默认生成 3 次抽查
/// （T+15 / T+45 / T+75）。这条规则在客户端与服务端各实现了一份，
/// 两边必须算出同一个序列，否则管理端预览的倒计时会与真实抽查错开。
void main() {
  /// 造一个活动，参数与 `ContractDefaults` 默认值一致。
  Activity activity({
    required DateTime start,
    required DateTime end,
    Duration? firstDelay,
    Duration? interval,
    Duration? windowBefore,
    Duration? windowAfter,
    double radius = 200,
  }) =>
      Activity(
        id: 'a1',
        title: '测试活动',
        organizer: '测试部门',
        durationHours: end.difference(start).inMinutes / 60,
        startTime: start,
        endTime: end,
        location: '测试地点',
        geoLat: 34.2175,
        geoLng: 117.1425,
        status: ActivityStatus.published,
        checkinRadius: radius,
        attendanceFirstDelay: firstDelay ?? ContractDefaults.attendanceFirstDelay,
        attendanceInterval: interval ?? ContractDefaults.attendanceInterval,
        checkinWindowBefore: windowBefore ?? ContractDefaults.defaultCheckinWindowBefore,
        checkinWindowAfter: windowAfter ?? ContractDefaults.defaultCheckinWindowAfter,
      );

  group('plannedAttendanceSlots（验收 A20）', () {
    test('2 小时活动 → 恰好 3 次：T+15 / T+45 / T+75', () {
      final DateTime start = DateTime(2026, 10, 16, 9, 0);
      final Activity a = activity(start: start, end: start.add(const Duration(hours: 2)));

      final List<DateTime> slots = a.plannedAttendanceSlots();
      expect(slots.length, 3, reason: '方案 §6.2 与验收 A20 都要求 2 小时活动 3 次');
      expect(
        slots.map((DateTime s) => s.difference(start).inMinutes).toList(),
        <int>[15, 45, 75],
      );
    });

    test('末次至少距活动结束 30 分钟（取 15 会让 2 小时活动变成 4 次）', () {
      final DateTime start = DateTime(2026, 10, 16, 9, 0);
      final DateTime end = start.add(const Duration(hours: 2));
      final Activity a = activity(start: start, end: end);

      final DateTime last = a.plannedAttendanceSlots().last;
      expect(
        end.difference(last).inMinutes,
        greaterThanOrEqualTo(30),
        reason: '留白必须 ≥30 分钟，否则 30 分钟间隔会在 2 小时内多塞一次',
      );
    });

    test('1.5 小时活动 → 2 次（T+15 / T+45）', () {
      final DateTime start = DateTime(2026, 10, 16, 9, 0);
      final Activity a = activity(start: start, end: start.add(const Duration(minutes: 90)));
      // 可用区间 [15, 60]（末次留白 30 分钟）→ 15 / 45
      expect(
        a.plannedAttendanceSlots().map((DateTime s) => s.difference(start).inMinutes).toList(),
        <int>[15, 45],
      );
    });

    test('3 小时活动 → 5 次（T+15/45/75/105/135）', () {
      final DateTime start = DateTime(2026, 10, 16, 9, 0);
      final Activity a = activity(start: start, end: start.add(const Duration(hours: 3)));
      // 可用区间 [15, 150] → 15/45/75/105/135
      expect(
        a.plannedAttendanceSlots().map((DateTime s) => s.difference(start).inMinutes).toList(),
        <int>[15, 45, 75, 105, 135],
      );
    });

    test('时长过短（30 分钟）→ 0 次，而不是负数或异常', () {
      final DateTime start = DateTime(2026, 10, 16, 9, 0);
      final Activity a = activity(start: start, end: start.add(const Duration(minutes: 30)));
      expect(
        a.plannedAttendanceSlots(),
        isEmpty,
        reason: '末次留白 30 分钟已经吃满整个时长，不该生成抽查',
      );
    });

    test('时长刚好 45 分钟 → 1 次（T+15）', () {
      final DateTime start = DateTime(2026, 10, 16, 9, 0);
      final Activity a = activity(start: start, end: start.add(const Duration(minutes: 45)));
      // 可用区间 [15, 15]
      final List<DateTime> slots = a.plannedAttendanceSlots();
      expect(slots.length, 1);
      expect(slots.single.difference(start).inMinutes, 15);
    });

    test('间隔为 0 时不会死循环（异常参数防御）', () {
      final DateTime start = DateTime(2026, 10, 16, 9, 0);
      final Activity a = activity(
        start: start,
        end: start.add(const Duration(hours: 2)),
        interval: Duration.zero,
      );
      final List<DateTime> slots = a.plannedAttendanceSlots();
      expect(slots, isNotEmpty);
      expect(slots.length, lessThan(100), reason: '必须靠 guard 兜住，不能无限追加');
    });

    test('自定义参数：首次 10 分钟、间隔 20 分钟、2 小时活动', () {
      final DateTime start = DateTime(2026, 10, 16, 9, 0);
      final Activity a = activity(
        start: start,
        end: start.add(const Duration(hours: 2)),
        firstDelay: const Duration(minutes: 10),
        interval: const Duration(minutes: 20),
      );
      // 可用区间 [10, 90] → 10/30/50/70/90
      expect(
        a.plannedAttendanceSlots().map((DateTime s) => s.difference(start).inMinutes).toList(),
        <int>[10, 30, 50, 70, 90],
      );
    });
  });

  group('签到时间窗（决策 D-5：采用网页方案 §4.1 的 30/60）', () {
    test('窗口 = 开始前 30 分钟 ~ 结束后 60 分钟', () {
      final DateTime start = DateTime(2026, 10, 16, 9, 0);
      final DateTime end = DateTime(2026, 10, 16, 11, 0);
      final Activity a = activity(start: start, end: end);

      // ⚠️ 两方案冲突：移动端方案 §4.2 是 15/15，网页方案 §4.1（冻结版）是 30/60。
      // 采用网页方案，因此迟到 20 分钟的志愿者仍能签到。
      expect(a.checkinOpensAt, DateTime(2026, 10, 16, 8, 30));
      expect(a.checkinClosesAt, DateTime(2026, 10, 16, 12, 0));
    });

    test('isWithinCheckinWindow 的边界是闭区间', () {
      final DateTime start = DateTime(2026, 10, 16, 9, 0);
      final DateTime end = DateTime(2026, 10, 16, 11, 0);
      final Activity a = activity(start: start, end: end);

      expect(a.isWithinCheckinWindow(DateTime(2026, 10, 16, 8, 29)), isFalse);
      // 边界时刻本身应算在窗口内，否则会出现"刚好卡在边界签不上"的争议
      expect(a.isWithinCheckinWindow(DateTime(2026, 10, 16, 8, 30)), isTrue);
      expect(a.isWithinCheckinWindow(DateTime(2026, 10, 16, 10, 0)), isTrue);
      expect(a.isWithinCheckinWindow(DateTime(2026, 10, 16, 12, 0)), isTrue);
      expect(a.isWithinCheckinWindow(DateTime(2026, 10, 16, 12, 1)), isFalse);
    });

    test('allowsCheckin 只对已发布与进行中为真', () {
      expect(ActivityStatus.published.allowsCheckin, isTrue);
      expect(ActivityStatus.ongoing.allowsCheckin, isTrue);
      expect(ActivityStatus.draft.allowsCheckin, isFalse);
      expect(ActivityStatus.finished.allowsCheckin, isFalse);
      expect(ActivityStatus.cancelled.allowsCheckin, isFalse);
      expect(ActivityStatus.unknown.allowsCheckin, isFalse);
    });
  });

  group('状态语义', () {
    test('终态只有 finished 与 cancelled', () {
      expect(ActivityStatus.finished.isTerminal, isTrue);
      expect(ActivityStatus.cancelled.isTerminal, isTrue);
      for (final ActivityStatus s in <ActivityStatus>[
        ActivityStatus.draft,
        ActivityStatus.published,
        ActivityStatus.ongoing,
        ActivityStatus.unknown,
      ]) {
        expect(s.isTerminal, isFalse, reason: '${s.label} 不应是终态');
      }
    });

    test('草稿可自由编辑，其余状态规则已冻结', () {
      expect(ActivityStatus.draft.hasFrozenRules, isFalse);
      expect(ActivityStatus.published.hasFrozenRules, isTrue);
      expect(ActivityStatus.ongoing.hasFrozenRules, isTrue);
      expect(ActivityStatus.finished.hasFrozenRules, isTrue);
    });

    test('枚举解析对未知值兜底而不是抛异常', () {
      expect(ActivityStatus.fromWire('published'), ActivityStatus.published);
      expect(ActivityStatus.fromWire('some_new_status'), ActivityStatus.unknown);
      expect(ActivityStatus.fromWire(null), ActivityStatus.unknown);
      expect(ActivityStatus.fromWire(123), ActivityStatus.unknown);
      expect(CheckinStatus.fromWire('pending_review'), CheckinStatus.pendingReview);
      expect(AttendanceTaskStatus.fromWire('excused'), AttendanceTaskStatus.excused);
      expect(SignupStatus.fromWire('bogus'), SignupStatus.unknown);
    });

    test('CheckinStatus 的终态与待定语义', () {
      // 只有服务端给出的这三种是终态；submitting / offlineQueued 是本地态
      expect(CheckinStatus.success.isServerTerminal, isTrue);
      expect(CheckinStatus.pendingReview.isServerTerminal, isTrue);
      expect(CheckinStatus.rejected.isServerTerminal, isTrue);
      expect(CheckinStatus.submitting.isServerTerminal, isFalse);
      expect(CheckinStatus.offlineQueued.isServerTerminal, isFalse);

      expect(CheckinStatus.submitting.isPending, isTrue);
      expect(CheckinStatus.offlineQueued.isPending, isTrue);
      expect(CheckinStatus.success.isPending, isFalse);

      // 只有 success 与 pending_review 算"有效到场"
      expect(CheckinStatus.success.countsAsPresent, isTrue);
      expect(CheckinStatus.pendingReview.countsAsPresent, isTrue);
      expect(CheckinStatus.rejected.countsAsPresent, isFalse);
      expect(CheckinStatus.offlineQueued.countsAsPresent, isFalse);
    });

    test('AttendanceTaskStatus：只有 pending 需要动作，done/missed/excused 已定案', () {
      expect(AttendanceTaskStatus.pending.isActionable, isTrue);
      expect(AttendanceTaskStatus.pending.isSettled, isFalse);
      for (final AttendanceTaskStatus s in <AttendanceTaskStatus>[
        AttendanceTaskStatus.done,
        AttendanceTaskStatus.missed,
        AttendanceTaskStatus.excused,
      ]) {
        expect(s.isActionable, isFalse, reason: '${s.label} 不应再需要响应');
        expect(s.isSettled, isTrue);
      }
    });

    test('SyncState.isOutstanding 用于"待同步"标记', () {
      expect(SyncState.pending.isOutstanding, isTrue);
      expect(SyncState.syncing.isOutstanding, isTrue);
      expect(SyncState.failed.isOutstanding, isTrue);
      expect(SyncState.synced.isOutstanding, isFalse);
    });
  });

  group('活动反序列化', () {
    test('完整 JSON 往返一致', () {
      final Map<String, dynamic> json = <String, dynamic>{
        'id': 'act-1',
        'title': '图书馆整理',
        'organizer': '校图书馆',
        'durationHours': 2.5,
        'startTime': '2026-10-16T09:00:00+08:00',
        'endTime': '2026-10-16T11:30:00+08:00',
        'location': '图书馆三层',
        'geoLat': 34.2175,
        'geoLng': 117.1425,
        'checkinRadius': 200,
        'checkinWindowBefore': 15,
        'checkinWindowAfter': 15,
        'attendanceFirstDelay': 15,
        'attendanceInterval': 30,
        'attendanceResponseWindow': 5,
        'quota': 20,
        'enrolled': 5,
        'status': 'ongoing',
        'tags': <String>['图书馆', '整理'],
        'summary': '简介',
        'description': '详情',
        'contact': '王老师 138****1234',
        'version': 3,
      };

      final Activity a = Activity.fromJson(json);
      expect(a.id, 'act-1');
      expect(a.durationHours, 2.5);
      expect(a.checkinRadius, 200);
      expect(a.attendanceInterval, const Duration(minutes: 30));
      expect(a.status, ActivityStatus.ongoing);
      expect(a.tags, <String>['图书馆', '整理']);
      expect(a.quota, 20);
      expect(a.version, 3);
      expect(a.duration, const Duration(hours: 2, minutes: 30));
    });

    test('缺失字段用兜底值，不抛异常（老客户端遇到新服务端必须能活）', () {
      final Activity a = Activity.fromJson(<String, dynamic>{'id': 'x', 'title': '只有标题'});
      expect(a.title, '只有标题');
      expect(a.organizer, '');
      expect(a.checkinRadius, 200, reason: '缺省半径应为契约默认值');
      expect(a.attendanceInterval, const Duration(minutes: 30));
      expect(a.status, ActivityStatus.unknown);
      expect(a.version, 1);
    });

    test('数字型编码字段也能解析（服务端可能下发字符串）', () {
      final Activity a = Activity.fromJson(<String, dynamic>{
        'id': 'x',
        'durationHours': '2.5',
        'checkinRadius': '300',
        'enrolled': '7',
      });
      expect(a.durationHours, 2.5);
      expect(a.checkinRadius, 300);
      expect(a.enrolled, 7);
    });

    test('规则快照解析与 revision 保留', () {
      final Activity a = Activity.fromJson(<String, dynamic>{
        'id': 'x',
        'ruleSnapshot': <String, dynamic>{
          'frozenAt': '2026-10-16T08:00:00+08:00',
          'startTime': '2026-10-16T09:00:00+08:00',
          'endTime': '2026-10-16T11:00:00+08:00',
          'checkinRadius': 200,
          'revision': 2,
          'reason': '场地时间延长',
          'changedBy': 'owner-1',
        },
      });
      expect(a.ruleSnapshot, isNotNull);
      expect(a.ruleSnapshot!.revision, 2);
      expect(a.ruleSnapshot!.reason, '场地时间延长');
    });

    test('copyWith 只改指定字段', () {
      final Activity a = Activity.fromJson(<String, dynamic>{
        'id': 'x',
        'title': '原标题',
        'checkinRadius': 200,
        'status': 'published',
      });
      final Activity b = a.copyWith(title: '新标题', checkinRadius: 300);
      expect(b.title, '新标题');
      expect(b.checkinRadius, 300);
      expect(b.id, 'x');
      expect(b.status, ActivityStatus.published, reason: '未指定字段应保持不变');
    });
  });

  group('留存期（验收 A21）', () {
    test('终态 + 7 天到期', () {
      final DateTime terminal = DateTime(2026, 10, 16, 11, 0);
      final Activity a = Activity(
        id: 'x',
        title: 't',
        organizer: 'o',
        durationHours: 1,
        startTime: terminal.subtract(const Duration(hours: 1)),
        endTime: terminal,
        location: 'l',
        geoLat: 34,
        geoLng: 117,
        status: ActivityStatus.finished,
        terminalAt: terminal,
      );

      expect(a.isExpiredByRetention(DateTime(2026, 10, 23, 10, 59)), isFalse);
      expect(a.isExpiredByRetention(DateTime(2026, 10, 23, 11, 0)), isFalse);
      expect(a.isExpiredByRetention(DateTime(2026, 10, 23, 11, 1)), isTrue);
    });

    test('非终态活动永不因留存期过期', () {
      final Activity a = Activity(
        id: 'x',
        title: 't',
        organizer: 'o',
        durationHours: 1,
        startTime: DateTime(2020, 1, 1),
        endTime: DateTime(2020, 1, 1, 1),
        location: 'l',
        geoLat: 34,
        geoLng: 117,
        status: ActivityStatus.ongoing,
      );
      expect(a.isExpiredByRetention(DateTime(2030, 1, 1)), isFalse);
    });

    test('retentionRemaining 给出剩余时间，可用于「到期前 48 小时提醒导出」', () {
      final DateTime terminal = DateTime(2026, 10, 16, 11, 0);
      final Activity a = Activity(
        id: 'x',
        title: 't',
        organizer: 'o',
        durationHours: 1,
        startTime: terminal.subtract(const Duration(hours: 1)),
        endTime: terminal,
        location: 'l',
        geoLat: 34,
        geoLng: 117,
        status: ActivityStatus.finished,
        terminalAt: terminal,
      );
      final Duration? left = a.retentionRemaining(DateTime(2026, 10, 23, 10, 0));
      expect(left, isNotNull);
      expect(left!.inHours, 1);
    });
  });

  group('围栏与统计聚合', () {
    test('fenceCenter 从经纬度构造 WGS-84 点', () {
      final Activity a = Activity.fromJson(<String, dynamic>{
        'id': 'x',
        'geoLat': 34.2175,
        'geoLng': 117.1425,
      });
      expect(a.fenceCenter.lat, 34.2175);
      expect(a.fenceCenter.lng, 117.1425);
    });

    test('ActivityStatsAggregator 按状态归类并累计时长', () {
      Activity make(ActivityStatus status, double hours) => Activity(
            id: 'i$status$hours',
            title: 't',
            organizer: 'o',
            durationHours: hours,
            startTime: DateTime(2026, 10, 16, 9),
            endTime: DateTime(2026, 10, 16, 9).add(Duration(minutes: (hours * 60).round())),
            location: 'l',
            geoLat: 34,
            geoLng: 117,
            status: status,
          );

      final ActivityStats stats = ActivityStatsAggregator.fromActivities(<Activity>[
        make(ActivityStatus.published, 2),
        make(ActivityStatus.ongoing, 3),
        make(ActivityStatus.finished, 1),
        make(ActivityStatus.cancelled, 4),
        make(ActivityStatus.draft, 5),
      ]);

      expect(stats.total, 5);
      expect(stats.published, 1);
      expect(stats.ongoing, 1);
      expect(stats.finished, 1);
      expect(stats.cancelled, 1);
      // draft 不计入任何状态桶，但时长仍计入总量
      expect(stats.totalDurationHours, 15);
      expect(stats.distribution.length, 4);
    });
  });

  group('ActivityQuery', () {
    test('空值不下发，避免服务端把空串当过滤条件', () {
      const ActivityQuery q = ActivityQuery();
      final Map<String, String> params = q.toQueryParameters();
      expect(params.containsKey('keyword'), isFalse);
      expect(params.containsKey('organizer'), isFalse);
      expect(params.containsKey('status'), isFalse);
      expect(params['page'], '1');
      expect(params['sortBy'], 'startTime');
      expect(params['sortDesc'], 'true');
    });

    test('状态多选拼成逗号分隔', () {
      const ActivityQuery q = ActivityQuery(
        statuses: <ActivityStatus>[ActivityStatus.finished, ActivityStatus.cancelled],
      );
      expect(q.toQueryParameters()['status'], 'finished,cancelled');
    });

    test('nextPage 只改页码', () {
      const ActivityQuery q = ActivityQuery(keyword: '图书馆', pageSize: 10);
      final ActivityQuery next = q.nextPage();
      expect(next.page, 2);
      expect(next.keyword, '图书馆');
      expect(next.pageSize, 10);
    });

    test('resetPage 回到第一页并保留筛选条件', () {
      const ActivityQuery q = ActivityQuery(keyword: 'k', page: 5);
      final ActivityQuery reset = q.resetPage();
      expect(reset.page, 1);
      expect(reset.keyword, 'k');
    });

    test('hasFilters 用于决定是否显示「清空筛选」', () {
      expect(const ActivityQuery().hasFilters, isFalse);
      expect(const ActivityQuery(keyword: '  ').hasFilters, isFalse, reason: '纯空白不算筛选');
      expect(const ActivityQuery(keyword: 'x').hasFilters, isTrue);
      expect(
        const ActivityQuery(statuses: <ActivityStatus>[ActivityStatus.published]).hasFilters,
        isTrue,
      );
    });

    test('copyWith 的 clear 开关能真正清空字段', () {
      const ActivityQuery q = ActivityQuery(keyword: 'k', organizer: 'o');
      final ActivityQuery cleared = q.copyWith(clearKeyword: true, clearOrganizer: true);
      expect(cleared.keyword, isNull);
      expect(cleared.organizer, isNull);
    });
  });
}
