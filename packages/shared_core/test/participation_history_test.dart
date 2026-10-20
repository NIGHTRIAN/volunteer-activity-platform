import 'package:shared_core/shared_core.dart';
import 'package:test/test.dart';

/// 本机参与记录（跨活动保留历史）。
///
/// ## 这组测试守的真机报障
///
/// > 参加完一个活动，还有另一个活动要参加，就得重新登录输入活动编码；
/// > 重新登录后，**之前那个活动的记录就看不到了**。
///
/// 记录其实还在服务端，但用户端的新邀请码只覆盖新活动，
/// 旧活动再也调不到 —— 在用户眼里就是"记录没了"。
///
/// 所以本机存一份历史。这份数据出错的表现很隐蔽：
/// 不会崩，只是显示的顺序乱了、同一个活动出现好几遍、
/// 或者某个字段被一次"只更新状态"的写入刷成空。
void main() {
  ParticipationRecord rec(
    String id, {
    String title = '活动',
    String userNo = '2026101',
    String? status,
    int? score,
    DateTime? at,
    int done = 0,
    int missed = 0,
  }) =>
      ParticipationRecord(
        activityId: id,
        activityTitle: title,
        userNo: userNo,
        name: '张三',
        checkinStatus: status,
        score: score,
        checkinAt: at,
        attendanceDone: done,
        attendanceMissed: missed,
        savedAt: DateTime(2026, 10, 19, 10),
      );

  group('upsert：同一活动只保留一条', () {
    test('新增', () {
      final ParticipationHistory h =
          const ParticipationHistory.empty().upsert(rec('A'));
      expect(h.length, 1);
      expect(h.forActivity('A')!.activityTitle, '活动');
    });

    test('重复 upsert 同一活动 → 更新而不是追加（否则列表里会出现十几遍）', () {
      ParticipationHistory h = const ParticipationHistory.empty();
      for (int i = 0; i < 5; i += 1) {
        h = h.upsert(rec('A', status: 'success', score: 60 + i));
      }
      expect(h.length, 1);
      expect(h.forActivity('A')!.score, 64);
    });

    test('只更新状态时，原有的标题/学号不会被刷空', () {
      ParticipationHistory h = const ParticipationHistory.empty()
          .upsert(rec('A', title: '图书馆整理', userNo: '2026101'));
      // 第二次只带了状态（name/userNo/title 都是空）
      // DateTime(...) 不是 const，所以这里不能整块 const
      h = h.upsert(ParticipationRecord(
        activityId: 'A',
        activityTitle: '',
        userNo: '',
        name: '',
        savedAt: DateTime(2026, 10, 19, 11),
        checkinStatus: 'success',
        score: 80,
      ));
      final ParticipationRecord r = h.forActivity('A')!;
      expect(r.activityTitle, '图书馆整理', reason: '标题不能被空值覆盖');
      expect(r.userNo, '2026101');
      expect(r.checkinStatus, 'success');
      expect(r.score, 80);
    });

    test('不同活动各一条', () {
      final ParticipationHistory h = const ParticipationHistory.empty()
          .upsert(rec('A'))
          .upsert(rec('B'));
      expect(h.length, 2);
    });
  });

  group('排序与容量', () {
    test('按 savedAt 倒序：最近参加的在前', () {
      final ParticipationHistory h = const ParticipationHistory.empty()
          .upsert(ParticipationRecord(
            activityId: 'old',
            activityTitle: '旧',
            userNo: '1',
            name: 'x',
            savedAt: DateTime(2026, 1, 1),
          ))
          .upsert(ParticipationRecord(
            activityId: 'new',
            activityTitle: '新',
            userNo: '1',
            name: 'x',
            savedAt: DateTime(2026, 10, 1),
          ));
      expect(h.sortedByRecent.first.activityId, 'new');
    });

    test('超过上限时丢最旧的（不能无限增长）', () {
      ParticipationHistory h = const ParticipationHistory.empty();
      for (int i = 0; i < ParticipationHistory.maxRecords + 5; i += 1) {
        h = h.upsert(ParticipationRecord(
          activityId: 'act-$i',
          activityTitle: '活动 $i',
          userNo: '1',
          name: 'x',
          savedAt: DateTime(2026, 1, 1).add(Duration(days: i)),
        ));
      }
      expect(h.length, ParticipationHistory.maxRecords);
      expect(h.forActivity('act-0'), isNull, reason: '最旧的应被裁掉');
      expect(h.forActivity('act-49'), isNotNull);
    });
  });

  group('JSON 往返', () {
    test('完整字段往返一致', () {
      final ParticipationRecord r = ParticipationRecord(
        activityId: 'A',
        activityTitle: '图书馆整理',
        userNo: '2026101',
        name: '张三',
        checkinStatus: 'success',
        score: 60,
        checkinAt: DateTime.utc(2026, 10, 19, 2, 30),
        attendanceDone: 2,
        attendanceMissed: 1,
        savedAt: DateTime.utc(2026, 10, 19, 3),
      );
      final ParticipationHistory back =
          ParticipationHistory.fromJson(ParticipationHistory(<ParticipationRecord>[r]).toJsonList());
      final ParticipationRecord got = back.forActivity('A')!;
      expect(got.activityTitle, '图书馆整理');
      expect(got.checkinStatus, 'success');
      expect(got.score, 60);
      expect(got.attendanceDone, 2);
      expect(got.checkinAt, DateTime.utc(2026, 10, 19, 2, 30));
    });

    test('坏数据不让整份记录失效（单条坏 → 跳过，其余保留）', () {
      final ParticipationHistory h = ParticipationHistory.fromJson(<Object?>[
        <String, Object?>{'activityId': 'good', 'activityTitle': '好的', 'savedAt': '2026-10-19T00:00:00Z'},
        'not-a-map',
        <String, Object?>{'activityTitle': '缺 id'},
        null,
        <String, Object?>{'activityId': 'good2', 'activityTitle': '也好', 'savedAt': '2026-10-19T01:00:00Z'},
      ]);
      expect(h.length, 2);
      expect(h.forActivity('good'), isNotNull);
      expect(h.forActivity('good2'), isNotNull);
    });

    test('完全不是数组 → 空历史，不抛异常', () {
      expect(ParticipationHistory.fromJson(null).isEmpty, isTrue);
      expect(ParticipationHistory.fromJson('garbage').isEmpty, isTrue);
      expect(ParticipationHistory.fromJson(<String, Object?>{}).isEmpty, isTrue);
    });

    test('缺可选字段也能读（旧版本存下的数据）', () {
      final ParticipationHistory h = ParticipationHistory.fromJson(<Object?>[
        <String, Object?>{'activityId': 'A', 'savedAt': '2026-10-19T00:00:00Z'},
      ]);
      final ParticipationRecord r = h.forActivity('A')!;
      expect(r.activityTitle, '');
      expect(r.checkinStatus, isNull);
      expect(r.score, isNull);
    });
  });

  group('状态文案', () {
    test('已知状态给人话', () {
      expect(rec('A', status: 'success').checkinStatusLabel, '已签到');
      expect(rec('A', status: 'pending_review').checkinStatusLabel, '待确认');
      expect(rec('A', status: 'rejected').checkinStatusLabel, '已驳回');
    });

    test('没有签到记录时说清楚', () {
      expect(rec('A').checkinStatusLabel, '尚无签到记录');
      expect(rec('A').hasCheckin, isFalse);
    });

    test('不认识的状态原样显示（不显示空白）', () {
      expect(rec('A', status: 'future_state').checkinStatusLabel, 'future_state');
    });
  });

  group('移除与清空', () {
    test('removeActivity 只删指定活动', () {
      final ParticipationHistory h = const ParticipationHistory.empty()
          .upsert(rec('A'))
          .upsert(rec('B'))
          .removeActivity('A');
      expect(h.length, 1);
      expect(h.forActivity('B'), isNotNull);
    });

    test('clear 清空', () {
      expect(const ParticipationHistory.empty().upsert(rec('A')).clear().isEmpty,
          isTrue);
    });
  });
}
