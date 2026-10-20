import 'dart:io';

import 'package:shared_core/shared_core.dart';
import 'package:test/test.dart';

/// 端到端：管理端 A2 页面实际会调用的接口。
///
/// 覆盖：登录 → 上报活动 → 名单导入 → 发邀请码 → 看板 → 复核 →
/// 考勤汇总 → 状态流转 → 增量同步。
///
/// 需要 Mock 进程（`node mock_server/src/server.js`）；未启动时整体跳过。
///
/// ## ⚠️ 与其他 E2E 文件共享服务端状态
///
/// `dart test` **默认并行执行测试文件**，而本文件会不断创建活动与参与者。
/// 因此断言必须对"别人也在写数据"保持免疫：
///
/// * ❌ 不要断言全局计数（`total`、`items.length` 等）；
/// * ❌ 不要断言"游标之后为空"（别的文件可能刚好写了数据）；
/// * ✅ 断言**属于本次创建的那个 id 的行为**；
/// * ✅ 断言**不变量**（四态之和 = 有效名单人数、游标单调不减）。
///
/// 这一条是实测踩出来的：单独跑本文件全绿，全量跑时
/// `e2e_mock_server_test.dart` 的"游标之后应精确为空"会偶发失败。
void main() {
  /*
    ⚠️ 只有**显式**设置 `E2E_BASE_URL` 才跑这组测试。

    一开始是"探测 8080 通就自动跑"，结果：只要开发时手边开着一个 mock，
    `flutter test` 就会连上去真跑一遍并**往那个库里写数据** ——
    表现为"跑完单元测试，演示数据里多了一堆 e2e-* 活动"。
    真机联调时这些脏数据还会混进看板与导出。

    环境变量的存在本身就是"我确认要跑端到端"的意图声明，
    比隐式探测可靠得多。运行方式：
      E2E_BASE_URL=http://127.0.0.1:8080/api flutter test test/e2e_*_test.dart
  */
  final String? envBaseUrl = Platform.environment['E2E_BASE_URL'];
  final String baseUrl = envBaseUrl ?? 'http://127.0.0.1:8080/api';

  late bool serverUp;

  String newDevice(String tag) => 'e2e-$tag-${DateTime.now().microsecondsSinceEpoch}';

  Future<bool> probe() async {

    // 没有显式声明要跑端到端 → 一律跳过（不探测、不写数据）。

    if (envBaseUrl == null) {

      return false;

    }
    try {
      final HttpClient c = HttpClient()
        ..connectionTimeout = const Duration(seconds: 2);
      final HttpClientRequest r = await c.getUrl(Uri.parse('$baseUrl/health'));
      final HttpClientResponse res = await r.close();
      await res.drain<void>();
      c.close();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  setUpAll(() async {
    serverUp = await probe();
    if (!serverUp) {
      // ignore: avoid_print
      print('[e2e-a2] Mock 未启动（$baseUrl），跳过。');
    }
  });

  /// 登录一个独立发布者并返回带令牌的客户端。
  /// 第二个管理员邀请码（用于"归属隔离"这类需要两个发布者的用例）。
  ///
  /// ⚠️ **真实服务端的 ownerId 来自邀请码**，不是设备指纹。
  /// （早先按设备指纹算 ownerId，导致"我发布的活动 0 条"，已修。）
  ///
  /// 所以想让两个客户端变成**不同**发布者，必须用两个邀请码：
  /// 服务端需要以 `ADMIN_OWNERS='1111:owner-a,2222:owner-b'` 启动。
  /// 没配第二个码时，相关用例会**跳过**而不是误报失败
  /// —— 否则"单发布者部署"会被当成功能缺陷。
  const String secondAdminCode =
      String.fromEnvironment('E2E_ADMIN_CODE_B', defaultValue: '2222');

  Future<({ApiClient client, String device, String ownerId})> loginAs(
    String tag, {
    String inviteCode = '1111',
  }) async {
    final String device = newDevice(tag);
    final ApiClient anon = ApiClient(
      config: ApiConfig(baseUrl: baseUrl),
      deviceIdProvider: () async => device,
    );
    addTearDown(anon.dispose);

    final Map<String, dynamic> data = _ok(
      await anon.post<Map<String, dynamic>>(
        AuthPaths.adminLogin,
        authorized: false,
        body: <String, Object?>{'inviteCode': inviteCode, 'deviceId': device},
        decode: _map,
      ),
    );
    final String token = data['token']! as String;

    final ApiClient authed = ApiClient(
      config: ApiConfig(baseUrl: baseUrl),
      tokenProvider: () async => token,
      deviceIdProvider: () async => device,
    );
    addTearDown(authed.dispose);
    return (client: authed, device: device, ownerId: data['ownerId']! as String);
  }

  /// 建一个已发布/进行中的活动。
  Future<String> createActivity(
    ApiClient client, {
    required ActivityStatus status,
    DateTime? start,
    int durationHours = 3,
  }) async {
    final DateTime now = DateTime.now();
    final DateTime s = start ?? now.add(const Duration(hours: 2));
    final Map<String, dynamic> up = _ok(
      await client.post<Map<String, dynamic>>(
        ActivityPaths.upsert,
        body: <String, Object?>{
          'batch': <Object?>[
            <String, Object?>{
              'externalId': 'E2E-A2-${now.microsecondsSinceEpoch}',
              'title': 'A2 端到端活动',
              'organizer': '测试部门',
              'durationHours': durationHours.toDouble(),
              'startTime': TimeFormat.toIso8601(s),
              'endTime': TimeFormat.toIso8601(s.add(Duration(hours: durationHours))),
              'location': '测试场地',
              'locationType': 'outdoor',
              'geoLat': 34.2175,
              'geoLng': 117.1425,
              'checkinRadius': 300,
              'summary': 'A2 端到端',
            },
          ],
        },
        decode: _map,
      ),
    );
    final String id = (up['created']! as List<Object?>).single! as String;

    if (status != ActivityStatus.published) {
      // 发布 → 流转到目标状态（走 `:transition`，与页面同一路径）。
      final List<ActivityStatus> path = switch (status) {
        ActivityStatus.ongoing => <ActivityStatus>[
            ActivityStatus.ongoing,
          ],
        ActivityStatus.finished => <ActivityStatus>[
            ActivityStatus.ongoing,
            ActivityStatus.finished,
          ],
        ActivityStatus.cancelled => <ActivityStatus>[ActivityStatus.cancelled],
        ActivityStatus.draft => <ActivityStatus>[],
        _ => <ActivityStatus>[],
      };
      for (final ActivityStatus to in path) {
        _ok(
          await client.post<Map<String, dynamic>>(
            ActivityPaths.transition(id),
            body: <String, Object?>{
              'to': to.wire,
              if (to == ActivityStatus.cancelled) 'reason': '端到端测试取消活动',
            },
            decode: _map,
          ),
        );
      }
    }
    return id;
  }

  group('A2 登录与活动管理', () {
    test('管理端登录后可看到自己名下的活动', () async {
      if (!serverUp) {
        return;
      }
      final a = await loginAs('adm');
      final String id = await createActivity(a.client, status: ActivityStatus.published);

      final Map<String, dynamic> list = _ok(
        await a.client.get<Map<String, dynamic>>(
          ActivityPaths.list,
          query: <String, String>{'onlyMine': 'true', 'size': '50'},
          decode: _map,
        ),
      );
      final List<Map<String, dynamic>> items = (list['items']! as List<Object?>)
          .map((Object? e) => (e! as Map<Object?, Object?>).cast<String, dynamic>())
          .toList();
      expect(items.any((Map<String, dynamic> m) => m['id'] == id), isTrue);
      // 列表要回显 size，客户端才能正确分页。
      expect(list['size'], isNotNull);
    });

    test('状态流转：发布 → 进行中 → 已结束，且 from 是乐观锁', () async {
      if (!serverUp) {
        return;
      }
      final a = await loginAs('adm');
      final String id = await createActivity(a.client, status: ActivityStatus.published);

      // from 与当前状态不符 → 版本冲突（防止拿着过期认知硬写）。
      final ApiResult<Map<String, dynamic>> bad =
          await a.client.post<Map<String, dynamic>>(
        ActivityPaths.transition(id),
        body: <String, Object?>{'from': 'draft', 'to': 'ongoing'},
        retryable: false,
        decode: _map,
      );
      expect(bad.failureOrNull?.code.isConflict, isTrue,
          reason: '应为 40901：${bad.failureOrNull?.message}');

      // 正确流转
      final Map<String, dynamic> started = _ok(
        await a.client.post<Map<String, dynamic>>(
          ActivityPaths.transition(id),
          body: <String, Object?>{'from': 'published', 'to': 'ongoing'},
          decode: _map,
        ),
      );
      expect((started['activity']! as Map<Object?, Object?>)['status'], 'ongoing');

      // 宣布结束：应带回考勤汇总与留存期提示。
      final Map<String, dynamic> finished = _ok(
        await a.client.post<Map<String, dynamic>>(
          ActivityPaths.transition(id),
          body: <String, Object?>{'from': 'ongoing', 'to': 'finished'},
          decode: _map,
        ),
      );
      expect((finished['activity']! as Map<Object?, Object?>)['status'], 'finished');
      // 方案 §14.1-6：必须告知 7 天后不可恢复。
      expect(finished['dataDestroyAt'], isNotNull);
      expect(finished['reminder']?.toString(), contains('7 天'));
    });

    test('取消活动必须填原因（≥5 字），且未发生的抽查被豁免', () async {
      if (!serverUp) {
        return;
      }
      final a = await loginAs('adm');
      final String id = await createActivity(a.client, status: ActivityStatus.published);

      final ApiResult<Map<String, dynamic>> tooShort =
          await a.client.post<Map<String, dynamic>>(
        ActivityPaths.transition(id),
        body: <String, Object?>{'to': 'cancelled', 'reason': '下雨'},
        retryable: false,
        decode: _map,
      );
      expect(tooShort.isSuccess, isFalse);
      expect(tooShort.failureOrNull!.message, isNotEmpty);

      final Map<String, dynamic> ok = _ok(
        await a.client.post<Map<String, dynamic>>(
          ActivityPaths.transition(id),
          body: <String, Object?>{
            'to': 'cancelled',
            'reason': '当日持续降雨，场地湿滑，协商取消',
          },
          decode: _map,
        ),
      );
      expect(ok['irreversible'], isTrue);
    });
  });

  group('A2 名单与邀请码', () {
    test('批量导入逐行返回结果，非法行不影响合法行', () async {
      if (!serverUp) {
        return;
      }
      final a = await loginAs('adm');
      final String id = await createActivity(a.client, status: ActivityStatus.published);

      final Map<String, dynamic> report = _ok(
        await a.client.post<Map<String, dynamic>>(
          ParticipantPaths.import(id),
          body: <String, Object?>{
            'rows': <Object?>[
              <Object?>['2024001', '张三', '13800000001'],
              <Object?>['bad!!', '非法学号', '13800000002'],
              <Object?>['2024002', '李四'],
            ],
          },
          decode: _map,
        ),
      );

      expect(report['total'], 3);
      expect(report['accepted'], 2, reason: '两行合法：$report');
      expect(report['rejected'], 1);
      final List<Object?> rows = report['rows']! as List<Object?>;
      expect(rows, hasLength(3));

      final Map<Object?, Object?> bad = rows
          .cast<Map<Object?, Object?>>()
          .firstWhere((Map<Object?, Object?> m) => m['accepted'] == false);
      // 页面要把"第几行、为什么"列出来，否则发布者不知道改哪里。
      expect(bad['row'], isNotNull);
      expect(bad['reason']?.toString(), isNotEmpty);
    });

    test('发邀请码返回明文，且列表查询只回掩码（明文仅一次）', () async {
      if (!serverUp) {
        return;
      }
      final a = await loginAs('adm');
      final String id = await createActivity(a.client, status: ActivityStatus.published);
      _ok(
        await a.client.post<Map<String, dynamic>>(
          ParticipantPaths.import(id),
          body: <String, Object?>{
            'rows': <Object?>[
              <Object?>['2024001', '张三'],
            ],
          },
          decode: _map,
        ),
      );

      final Map<String, dynamic> issued = _ok(
        await a.client.post<Map<String, dynamic>>(
          ParticipantPaths.issueInviteCodes(id),
          body: <String, Object?>{'userNos': <String>['2024001']},
          decode: _map,
        ),
      );
      final List<Object?> items = issued['items']! as List<Object?>;
      expect(items, hasLength(1));
      final InviteCode code = InviteCode.fromJson(
        (items.single! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      // 明文必须在签发响应里（否则发布者拿不到码，功能就没意义）。
      expect(code.code, isNotEmpty);

      // 再查列表：**只应有掩码**。这是"明文只显示一次"的实现方式。
      final Map<String, dynamic> listed = _ok(
        await a.client.get<Map<String, dynamic>>(
          ParticipantPaths.listInviteCodes(id),
          decode: _map,
        ),
      );
      final List<Object?> listItems = listed['items']! as List<Object?>;
      expect(listItems, isNotEmpty);
      final Map<String, dynamic> first =
          (listItems.first! as Map<Object?, Object?>).cast<String, dynamic>();
      expect(first['masked'], isNotNull,
          reason: '列表查询应给掩码而不是明文：$first');
      expect(first['inviteCode'], isNull,
          reason: '列表查询不应再次下发明文（方案 §5.2）');
    });

    test('移出名单是软删除，历史记录仍可查', () async {
      if (!serverUp) {
        return;
      }
      final a = await loginAs('adm');
      final String id = await createActivity(a.client, status: ActivityStatus.published);
      _ok(
        await a.client.post<Map<String, dynamic>>(
          ParticipantPaths.add(id),
          body: <String, Object?>{'userNo': '2024009', 'name': '临时加入'},
          decode: _map,
        ),
      );

      final Map<String, dynamic> removed = _ok(
        await a.client.delete<Map<String, dynamic>>(
          ParticipantPaths.remove(id, '2024009'),
          decode: _map,
        ),
      );
      final Participant p = Participant.fromJson(
        (removed['item']! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      expect(p.signupStatus, SignupStatus.cancelled);
      expect(p.removedAt, isNotNull, reason: '应留下移出时间（对账留痕）');

      // 仍在列表里（软删除），但已是"已移出"。
      final Map<String, dynamic> list = _ok(
        await a.client.get<Map<String, dynamic>>(
          ParticipantPaths.list(id),
          decode: _map,
        ),
      );
      final List<Map<String, dynamic>> items = (list['items']! as List<Object?>)
          .map((Object? e) => (e! as Map<Object?, Object?>).cast<String, dynamic>())
          .toList();
      expect(items.any((Map<String, dynamic> m) => m['userNo'] == '2024009'), isTrue);
    });
  });

  group('A2 看板', () {
    test('四态计数自洽，且名单行的 checkinStatus 用服务端词表', () async {
      if (!serverUp) {
        return;
      }
      final a = await loginAs('adm');
      final DateTime now = DateTime.now();
      final String id = await createActivity(
        a.client,
        status: ActivityStatus.ongoing,
        // 已开始 10 分钟 → 在签到窗口内
        start: now.subtract(const Duration(minutes: 10)),
      );

      _ok(
        await a.client.post<Map<String, dynamic>>(
          ParticipantPaths.import(id),
          body: <String, Object?>{
            'rows': <Object?>[
              <Object?>['2025001', '甲'],
              <Object?>['2025002', '乙'],
            ],
          },
          decode: _map,
        ),
      );

      final Map<String, dynamic> boardJson = _ok(
        await a.client.get<Map<String, dynamic>>(
          ActivityPaths.board(id),
          query: <String, String>{'includeParticipants': 'true'},
          decode: _map,
        ),
      );
      final ActivityBoard board = ActivityBoard.fromJson(boardJson);

      // ⚠️ 四态之和必须等于有效名单人数——这是看板可信的前提。
      expect(
        board.checkedIn + board.pendingReview + board.notCheckedIn,
        2,
        reason: '四态之和应等于有效名单人数：$boardJson',
      );
      expect(board.participants, hasLength(2));
      expect(board.serverTime, isNotNull, reason: '看板需要服务端时间做校正');
      expect(board.disclaimer, contains('不作为志愿时长认定依据'),
          reason: '免责声明由服务端下发，客户端不得自己编');

      // 名单行状态必须是服务端词表（success / pending_review / none）。
      final Set<String> allowed = <String>{'success', 'pending_review', 'none'};
      for (final Object? e in boardJson['participants']! as List<Object?>) {
        final Object? s = (e! as Map<Object?, Object?>)['checkinStatus'];
        expect(allowed.contains(s), isTrue,
            reason: 'checkinStatus=$s 不在授权词表内（页面会显示成"未知"）');
      }
      // 客户端解析后不得是"未知"。
      for (final Participant p in board.participants) {
        expect(p.checkinStatus, isNot(ParticipantCheckinStatus.unknown),
            reason: '${p.userNo} 的签到状态解析成了未知');
      }
    });

    test('看板只看自己名下的活动（归属隔离）', () async {
      if (!serverUp) {
        return;
      }
      final owner = await loginAs('owner');

      /*
        两个发布者必须是**两个不同的邀请码**（真实服务端按邀请码定 ownerId）。

        先探一下第二个码能不能登录：
          * 能 → 继续校验归属隔离；
          * 不能（单发布者部署）→ 跳过。这不是缺陷，
            单发布者本来就不存在"别人的活动"。
      */
      late final ({ApiClient client, String device, String ownerId}) other;
      try {
        other = await loginAs('other', inviteCode: secondAdminCode);
      } on ApiException {
        return; // 未配置第二个管理员，跳过
      }
      if (other.ownerId == owner.ownerId) {
        return; // 两个码指向同一个 owner，隔离无从谈起
      }

      final String id = await createActivity(owner.client, status: ActivityStatus.published);

      final ApiResult<Map<String, dynamic>> r =
          await other.client.get<Map<String, dynamic>>(
        ActivityPaths.board(id),
        decode: _map,
      );
      expect(r.failureOrNull?.code.isForbidden, isTrue,
          reason: '别的发布者不应能看看板：${r.failureOrNull?.message}');
    });
  });

  group('A2 签到复核', () {
    test('复核通过 / 驳回，且驳回必须填备注', () async {
      if (!serverUp) {
        return;
      }
      final a = await loginAs('adm');
      final DateTime now = DateTime.now();
      final String id = await createActivity(
        a.client,
        status: ActivityStatus.ongoing,
        start: now.subtract(const Duration(minutes: 10)),
      );

      // 造一个待人工确认的签到：单次采样 + 精度差 → 评分落在 30–59。
      const String userNo = '2026001';
      const String volDevice = 'e2e-a2-vol-1';
      _ok(
        await a.client.post<Map<String, dynamic>>(
          ParticipantPaths.add(id),
          body: <String, Object?>{'userNo': userNo, 'name': '待复核志愿者'},
          decode: _map,
        ),
      );
      final Map<String, dynamic> codes = _ok(
        await a.client.post<Map<String, dynamic>>(
          ParticipantPaths.issueInviteCodes(id),
          body: <String, Object?>{'userNos': <String>[userNo]},
          decode: _map,
        ),
      );
      final String invite =
          ((codes['items']! as List<Object?>).single! as Map<Object?, Object?>)['inviteCode']!
              as String;

      final ApiClient anon = ApiClient(
        config: ApiConfig(baseUrl: baseUrl),
        deviceIdProvider: () async => volDevice,
      );
      addTearDown(anon.dispose);
      final VolunteerGrant grant = VolunteerGrant.fromJson(
        _ok(
          await anon.post<Map<String, dynamic>>(
            AuthPaths.bind,
            authorized: false,
            body: <String, Object?>{
              'activityId': id,
              'userNo': userNo,
              'inviteCode': invite,
              'deviceId': volDevice,
              'name': '待复核志愿者',
            },
            decode: _map,
          ),
        ),
      );
      final ApiClient vol = ApiClient(
        config: ApiConfig(baseUrl: baseUrl),
        tokenProvider: () async => grant.token,
        deviceIdProvider: () async => volDevice,
      );
      addTearDown(vol.dispose);

      final CheckinDraft draft = CheckinDraft(
        activityId: id,
        idempotencyKey: vol.newIdempotencyKey(),
        method: CheckinMethod.geo,
        clientTime: now,
        deviceId: volDevice,
        samples: <CheckinSample>[
          CheckinSample(
            point: const GeoPoint(lat: 34.21754, lng: 117.14254),
            accuracy: 12,
            capturedAt: now,
          ),
        ],
      );
      final Map<String, dynamic> submitted = _ok(
        await vol.post<Map<String, dynamic>>(
          CheckinPaths.submit(id),
          body: draft.toJson(),
          idempotencyKey: draft.idempotencyKey,
          decode: _map,
        ),
      );
      final Checkin checkin = Checkin.fromJson(
        (submitted['checkin']! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      // 单次采样只有围栏分（40）→ 应落在待人工确认区间。
      expect(checkin.status, CheckinStatus.pendingReview,
          reason: 'score=${checkin.score}：${checkin.reason}');
      expect(checkin.scoreItems, isNotEmpty, reason: '页面要展示评分构成');
      // fromJson 应解析出"为什么是这个分"。
      expect(
        checkin.scoreItems.any((ScoreItem i) => i.reason.isNotEmpty),
        isTrue,
      );

      // 驳回不填备注 → 应被拒绝（服务端强制，页面也本地拦了一次）。
      final ApiResult<Map<String, dynamic>> noNote =
          await a.client.post<Map<String, dynamic>>(
        CheckinPaths.review(checkin.id),
        body: <String, Object?>{'decision': 'reject'},
        retryable: false,
        decode: _map,
      );
      expect(noNote.isSuccess, isFalse);
      expect(noNote.failureOrNull!.message, contains('备注'));

      // 填了备注 → 通过。
      final Map<String, dynamic> approved = _ok(
        await a.client.post<Map<String, dynamic>>(
          CheckinPaths.review(checkin.id),
          body: <String, Object?>{
            'decision': 'approve',
            'note': '现场已核实本人在图书区',
          },
          decode: _map,
        ),
      );
      final Checkin after = Checkin.fromJson(
        (approved['checkin']! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      expect(after.status, CheckinStatus.success);
      expect(after.reviewNote, contains('现场已核实'));
      expect(after.reviewedBy, isNotNull, reason: '必须留痕：谁复核的');
    });
  });

  group('A2 考勤汇总', () {
    test('汇总行可解析，且完成率与各项计数都在', () async {
      if (!serverUp) {
        return;
      }
      final a = await loginAs('adm');
      final DateTime now = DateTime.now();
      final String id = await createActivity(
        a.client,
        status: ActivityStatus.ongoing,
        start: now.subtract(const Duration(minutes: 10)),
      );
      _ok(
        await a.client.post<Map<String, dynamic>>(
          ParticipantPaths.import(id),
          body: <String, Object?>{
            'rows': <Object?>[
              <Object?>['2027001', '甲'],
            ],
          },
          decode: _map,
        ),
      );

      final Map<String, dynamic> json = _ok(
        await a.client.get<Map<String, dynamic>>(
          ActivityPaths.attendance(id),
          decode: _map,
        ),
      );
      final AttendanceReport report = AttendanceReport.fromJson(json);

      expect(report.disclaimer, contains('不作为志愿时长认定依据'));
      // 还没人签到 → 没有抽查任务 → 明细为空（决策 D-6）。
      expect(report.rows, isEmpty,
          reason: '决策 D-6：抽查只为已签到者生成，因此现在应为空');
    });
  });

  group('A2 增量同步', () {
    test('游标推进：新建活动会出现在增量结果里，重复查询收敛为空', () async {
      if (!serverUp) {
        return;
      }
      final a = await loginAs('adm');

      final Map<String, dynamic> snap = _ok(
        await a.client.get<Map<String, dynamic>>(
          SyncPaths.changes,
          decode: _map,
        ),
      );
      expect(snap['fullSnapshot'], isTrue);
      final String cursor = snap['nextCursor']! as String;

      final String id = await createActivity(a.client, status: ActivityStatus.published);

      final Map<String, dynamic> inc = _ok(
        await a.client.get<Map<String, dynamic>>(
          SyncPaths.changes,
          query: <String, String>{'since': cursor},
          decode: _map,
        ),
      );
      final List<Object?> items = inc['items']! as List<Object?>;
      expect(
        items.any((Object? e) =>
            (e! as Map<Object?, Object?>)['id'] == id),
        isTrue,
        reason: '新建的活动应出现在增量结果里：$inc',
      );

      // 用新游标再查 → 收敛为空（序号游标不重不漏）。
      final Map<String, dynamic> next = _ok(
        await a.client.get<Map<String, dynamic>>(
          SyncPaths.changes,
          query: <String, String>{'since': inc['nextCursor']! as String},
          decode: _map,
        ),
      );
      expect(next['items'], isEmpty);
    });
  });
}

// ── 辅助 ────────────────────────────────────────────────────────────────

Map<String, dynamic> _map(Object? d) =>
    (d! as Map<Object?, Object?>).cast<String, dynamic>();

T _ok<T>(ApiResult<T> r) {
  if (r is ApiFailure<T>) {
    fail('调用失败：code=${r.rawCode} (${r.code.name}) msg=${r.message} '
        'http=${r.httpStatus} trace=${r.traceId}');
  }
  return (r as ApiSuccess<T>).value;
}
