import 'package:shared_core/shared_core.dart';
import 'package:test/test.dart';

/// 客户端接口路径的**形态**锁定。
///
/// ## 为什么值得单独测
///
/// 真机报障：管理端「通过」复核签到提示「接口不存在」。
/// 根因是路径形态对不上：
///
/// ```
/// 客户端 CheckinPaths.review('5')  →  /checkins/5/review     ← 路径段
/// 服务端注册的                     →  /checkins/:id:review   ← 动作后缀（错）
/// ```
///
/// 而**当时的测试也用了错形态**，于是两边一起错、测试全绿。
///
/// 所以这里把"构造器到底拼出什么"逐字钉住：
/// 服务端那边有 `server/test/routes.test.mjs` 用同样的字符串做匹配校验，
/// 任一侧改动都会让其中一个测试变红。
///
/// ⚠️ 改这些断言等于改契约 —— 必须同时确认服务端与 mock 都改了。
void main() {
  group('AuthPaths', () {
    test('登录与绑定', () {
      expect(AuthPaths.adminLogin, '/auth/admin/login');
      expect(AuthPaths.bind, '/auth/bind');
    });
  });

  group('ActivityPaths', () {
    test('列表 / 上报用字面量与动作后缀', () {
      expect(ActivityPaths.list, '/activities');
      expect(ActivityPaths.upsert, '/activities:upsert');
    });

    test('详情与流转：流转是**动作后缀**（冒号贴着 id）', () {
      expect(ActivityPaths.detail('7'), '/activities/7');
      expect(ActivityPaths.transition('7'), '/activities/7:transition');
    });

    test('子资源用路径段', () {
      expect(ActivityPaths.board('7'), '/activities/7/board');
      expect(ActivityPaths.attendance('7'), '/activities/7/attendance');
      expect(ActivityPaths.export('7'), '/activities/7/export');
    });
  });

  group('ParticipantPaths', () {
    test('名单与导入', () {
      expect(ParticipantPaths.list('7'), '/activities/7/participants');
      expect(ParticipantPaths.add('7'), '/activities/7/participants');
      // 导入是动作后缀：`:import` 贴在 `participants` 后面
      expect(ParticipantPaths.import('7'), '/activities/7/participants:import');
    });

    test('发码与移出', () {
      expect(ParticipantPaths.issueInviteCodes('7'), '/activities/7/invite-codes');
      expect(ParticipantPaths.remove('7', '2021001'), '/activities/7/participants/2021001');
    });
  });

  group('CheckinPaths', () {
    test('签到提交与查询用路径段', () {
      expect(CheckinPaths.submit('7'), '/activities/7/checkins');
      expect(CheckinPaths.list('7'), '/activities/7/checkins');
      expect(CheckinPaths.mine('7'), '/activities/7/checkins/mine');
    });

    test('复核是**路径段** `/checkins/{id}/review`（本次报障点）', () {
      /*
        这一条是重点。同一个 API 里，在岗确认用的是 `:confirm` 动作后缀，
        很容易照着抄成 `/checkins/5:review`。服务端若按 `:review` 注册，
        客户端拿到的是 404「接口不存在」。
      */
      expect(
        CheckinPaths.review('5'),
        '/checkins/5/review',
        reason: '复核是路径段形式；改成冒号后缀会与服务端/契约不符',
      );
      expect(CheckinPaths.review('5'), isNot(contains(':')));
    });
  });

  group('AttendancePaths', () {
    test('任务用路径段；确认用**动作后缀**（与复核相反，别抄错）', () {
      expect(AttendancePaths.tasks('7'), '/activities/7/attendance/tasks');
      expect(
        AttendancePaths.confirm('42'),
        '/attendances/42:confirm',
        reason: '在岗确认确实是冒号动作后缀 —— 和复核形态不同',
      );
    });
  });

  group('全量形态自检：两种形态不能混用', () {
    test('每个路径都以 / 开头，且不含双斜杠', () {
      final List<String> all = <String>[
        AuthPaths.adminLogin,
        AuthPaths.bind,
        ActivityPaths.list,
        ActivityPaths.upsert,
        ActivityPaths.detail('1'),
        ActivityPaths.transition('1'),
        ActivityPaths.board('1'),
        ActivityPaths.export('1'),
        ParticipantPaths.list('1'),
        ParticipantPaths.import('1'),
        ParticipantPaths.issueInviteCodes('1'),
        CheckinPaths.submit('1'),
        CheckinPaths.mine('1'),
        CheckinPaths.review('1'),
        AttendancePaths.tasks('1'),
        AttendancePaths.confirm('1'),
      ];
      for (final String p in all) {
        expect(p.startsWith('/'), isTrue, reason: '$p 应以 / 开头');
        expect(p.contains('//'), isFalse, reason: '$p 不该出现双斜杠');
      }
    });

    test('只有约定好的那几个路径使用冒号动作后缀', () {
      /*
        冒号后缀是"动作"，路径段是"资源"。混用是这次故障的根源，
        所以这里把"哪些该有冒号"列出来：新增冒号后缀的接口时，
        这条测试会强制你思考一次它到底该用哪种形态。
      */
      final Map<String, String> actionSuffixPaths = <String, String>{
        'activities:upsert': ActivityPaths.upsert,
        'transition': ActivityPaths.transition('1'),
        'participants:import': ParticipantPaths.import('1'),
        'confirm': AttendancePaths.confirm('1'),
      };
      actionSuffixPaths.forEach((String name, String path) {
        expect(path.contains(':'), isTrue, reason: '$name 应是动作后缀');
      });

      // 复核**不**在这个集合里 —— 它是路径段。
      expect(CheckinPaths.review('1').contains(':'), isFalse);
    });
  });
}
