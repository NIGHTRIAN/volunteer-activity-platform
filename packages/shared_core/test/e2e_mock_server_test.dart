import 'dart:convert';
import 'dart:io';

import 'package:shared_core/shared_core.dart';
import 'package:test/test.dart';

/// 端到端联调测试：**真实 Dart 客户端** ↔ **真实 Mock 服务端**。
///
/// ## 为什么必须有这一层
///
/// 单测里我用手写的假 HTTP 客户端，它验证的是"我的解析逻辑自洽"，
/// **验证不了**"我发的报文服务端真的认"。这正是契约类 bug 的藏身处：
/// 路径写错、字段名写错、嵌套层级写错——单测全绿，一联调就 404 或参数错误。
///
/// 这层测试因此刻意**不做任何 mock**：起一个真的 Mock 进程，
/// 用真的 `ApiClient` 打过去，断言真的响应。
///
/// ## 设备指纹即身份（Mock 的简化实现）
///
/// Mock 的类型是：**设备指纹决定 `ownerId`**（新设备 = 新发布者）。
/// 真实实现应由"系统所有者按人发码"决定 `ownerId`（方案 §13-A1 的收紧路径），
/// Mock 不做人员识别。
///
/// 因此每个测试组要用**自己的设备指纹**，否则看不到自己建的活动
///（`ownerId` 隔离会把别人的活动判成 40301）。这不是测试取巧，
/// 而正是归属隔离生效的表现。
void main() {
  /*
    ⚠️ 只有**显式**设置 `E2E_BASE_URL` 才跑这组测试。

    一开始是"探测 8080 通就自动跑"，结果：只要开发时手边开着一个 mock，
    `flutter test` 就会连上去真跑一遍并**往那个库里写数据**。
    环境变量的存在本身就是"我确认要跑端到端"的意图声明。
  */
  final String? envBaseUrl = Platform.environment['E2E_BASE_URL'];
  final String baseUrl = envBaseUrl ?? 'http://127.0.0.1:8080/api';
  late ApiClient client;
  late bool serverUp;

  /// 当前测试的**管理端设备指纹**（在 Mock 里 = 一个独立发布者）。
  ///
  /// 每个测试用自己的指纹，否则 `ownerId` 归属隔离会把别的测试建的活动
  /// 判成 40301——那不是 bug，正是隔离生效。
  late String adminDevice;

  /// 分配一个独立设备指纹。
  String newDeviceId() => 'e2e-${DateTime.now().microsecondsSinceEpoch}';

  /// 探活。
  Future<bool> probe() async {
    // 没有显式声明要跑端到端 → 一律跳过（不探测、不写数据）。
    if (envBaseUrl == null) {
      return false;
    }
    try {
      final HttpClient probeClient = HttpClient()
        ..connectionTimeout = const Duration(seconds: 2);
      final Uri uri = Uri.parse('$baseUrl/health');
      final HttpClientRequest req = await probeClient.getUrl(uri);
      final HttpClientResponse res = await req.close();
      await res.drain<void>();
      probeClient.close();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  setUpAll(() async {
    serverUp = await probe();
    if (!serverUp) {
      // ignore: avoid_print
      print('[e2e] Mock 服务端未启动（$baseUrl），跳过端到端测试。'
          '启动方式：node mock_server/src/server.js');
    }
  });

  setUp(() {
    adminDevice = newDeviceId();
    client = ApiClient(
      config: ApiConfig(
        baseUrl: baseUrl,
        environment: ApiEnvironment.dev,
        clientVersion: '0.1.0-e2e',
      ),
      tokenProvider: () async => null,
      deviceIdProvider: () async => 'e2e-anonymous',
    );
  });

  tearDown(() => client.dispose());

  /// 便捷断言：必须成功，否则把错误打印出来（比 "expected true, got false" 有用得多）。
  T mustSucceed<T>(ApiResult<T> r) {
    if (r is ApiFailure<T>) {
      fail('调用失败：code=${r.rawCode} (${r.code.name}) msg=${r.message} '
          'http=${r.httpStatus} trace=${r.traceId}');
    }
    return (r as ApiSuccess<T>).value;
  }

  group('端到端：健康检查与契约自述', () {
    test('GET /health 可达', () async {
      if (!serverUp) {
        return;
      }
      final Map<String, dynamic> data = mustSucceed(
        await client.get<Map<String, dynamic>>(
          '/health',
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      expect(data['status'], 'ok');

      // 顺带验证 ApiClient 真的读到了 serverTime（倒计时基准）。
      expect(client.lastServerTime, isNotNull, reason: '未取到服务端时间');
    });

    test('响应信封字段名是 msg（网页方案 §6.1）', () async {
      if (!serverUp) {
        return;
      }
      // 故意打一个不存在的路径，拿到错误信封
      final ApiResult<Object?> r =
          await client.get<Object?>('/__no_such_endpoint__', decode: (Object? d) => d);
      expect(r.isSuccess, isFalse);
      expect(r.failureOrNull!.message, isNotEmpty, reason: 'msg 字段应被解析出文案');
    });
  });

  group('端到端：管理端登录与归属隔离', () {
    test('默认邀请码 1111 登录成功，令牌可用', () async {
      if (!serverUp) {
        return;
      }
      final Map<String, dynamic> data = mustSucceed(
        await client.post<Map<String, dynamic>>(
          AuthPaths.adminLogin,
          authorized: false,
          body: <String, Object?>{'inviteCode': '1111', 'deviceId': adminDevice},
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      final String token = data['token'] as String;
      expect(token, isNotEmpty);
      expect(data['ownerId'], isNotEmpty);

      // 用令牌取身份
      final ApiClient authed = ApiClient(
        config: client.config,
        tokenProvider: () async => token,
        deviceIdProvider: () async => adminDevice,
      );
      addTearDown(authed.dispose);

      final Map<String, dynamic> me = mustSucceed(
        await authed.get<Map<String, dynamic>>(
          AuthPaths.adminMe,
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      expect(me['ownerId'], data['ownerId']);
    });

    test('错误邀请码 → 未认证族，且文案可读', () async {
      if (!serverUp) {
        return;
      }
      final ApiResult<Object?> r = await client.post<Object?>(
        AuthPaths.adminLogin,
        authorized: false,
        body: <String, Object?>{'inviteCode': '0000', 'deviceId': 'e2e-bad'},
        decode: (Object? d) => d,
        // 登录失败是业务性错误，重试无意义
        retryable: false,
      );
      final ApiFailure<Object?> f = r.failureOrNull!;
      expect(f.code.isAuthFailure, isTrue, reason: '应为 40101 族');
      expect(f.message, contains('邀请码'));
    });
  });

  group('端到端：活动列表与增量同步', () {
    /// 取一个可用令牌。
    Future<String> adminToken() async {
      final Map<String, dynamic> data = mustSucceed(
        await client.post<Map<String, dynamic>>(
          AuthPaths.adminLogin,
          authorized: false,
          body: <String, Object?>{'inviteCode': '1111', 'deviceId': adminDevice},
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      return data['token'] as String;
    }

    test('GET /activities 分页字段用 size（方案 §6.1）', () async {
      if (!serverUp) {
        return;
      }
      final String token = await adminToken();
      final ApiClient authed = ApiClient(
        config: client.config,
        tokenProvider: () async => token,
        deviceIdProvider: () async => adminDevice,
      );
      addTearDown(authed.dispose);

      // 用 ActivityQuery 生成查询参数，验证它发的是 `size` 而不是 `pageSize`
      const ActivityQuery q = ActivityQuery(onlyMine: true, pageSize: 3);
      final Map<String, String> params = q.toQueryParameters();
      expect(params['size'], '3');
      expect(params.containsKey('pageSize'), isFalse);

      final Map<String, dynamic> data = mustSucceed(
        await authed.get<Map<String, dynamic>>(
          ActivityPaths.list,
          query: params,
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      expect(data['total'], isA<int>());
      expect(data['items'], isA<List<Object?>>());

      // 用 Paged 解析，验证字段名对得上
      final Paged<Activity> page = Paged<Activity>.fromJson(
        data,
        (Map<String, dynamic> j) => Activity.fromJson(j),
      );
      expect(page.pageSize, 3, reason: 'size 字段应被解析出来');
      for (final Activity a in page.items) {
        expect(a.title, isNotEmpty, reason: '活动标题不应为空');
        expect(a.externalId, isNotEmpty, reason: 'externalId 是必填幂等键');
      }
    });

    test('GET /changes 增量同步可用，游标能推进', () async {
      if (!serverUp) {
        return;
      }
      final String token = await adminToken();
      final ApiClient authed = ApiClient(
        config: client.config,
        tokenProvider: () async => token,
        deviceIdProvider: () async => adminDevice,
      );
      addTearDown(authed.dispose);

      final Map<String, dynamic> first = mustSucceed(
        await authed.get<Map<String, dynamic>>(
          SyncPaths.changes,
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      expect(first['fullSnapshot'], isTrue);
      final String cursor = first['nextCursor'] as String;
      expect(cursor, isNotEmpty);

      // 用游标再查：不应再返回全量快照。
      final Map<String, dynamic> second = mustSucceed(
        await authed.get<Map<String, dynamic>>(
          SyncPaths.changes,
          query: <String, String>{'since': cursor},
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      expect(second['fullSnapshot'], isFalse, reason: '给了有效游标就不该再返回全量');

      // ⚠️ 这里**不**断言 `items` 为空。
      //
      // 原来的写法断言了"没有新写入时应精确为空"，但那是错的：
      // `dart test` 默认**并行跑多个测试文件**，而
      // `e2e_admin_flows_test.dart` 会持续创建活动。
      // 于是"这一次查询为空"变成了一个时序假设 ——
      // 单独跑通过、全量跑偶发失败，典型的 flaky。
      //
      // 可靠的断言是**游标语义本身**：新游标必须不早于旧游标
      // （要么推进、要么原地不动）。这在不重不漏的前提下恒成立，
      // 也正是我真正想验证的东西。
      final int oldSeq = int.parse(cursor.substring(1));
      final int newSeq =
          int.parse((second['nextCursor']! as String).substring(1));
      expect(
        newSeq,
        greaterThanOrEqualTo(oldSeq),
        reason: '游标必须单调不减：$cursor → ${second['nextCursor']}',
      );
    });

    test('GET /changes 幂等：同一游标两次查询返回同一批变更', () async {
      if (!serverUp) {
        return;
      }
      final String token = await adminToken();
      final ApiClient authed = ApiClient(
        config: client.config,
        tokenProvider: () async => token,
        deviceIdProvider: () async => 'e2e-device-0001',
      );
      addTearDown(authed.dispose);

      final Map<String, dynamic> snap = mustSucceed(
        await authed.get<Map<String, dynamic>>(
          SyncPaths.changes,
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      final String cursor = snap['nextCursor']! as String;

      // 用**同一个游标**查两次，结果必须一致。
      // 这比"断言为空"更本质，也不会被并行测试创建的数据干扰。
      Future<Map<String, dynamic>> at(String since) async => mustSucceed(
            await authed.get<Map<String, dynamic>>(
              SyncPaths.changes,
              query: <String, String>{'since': since},
              decode: (Object? d) =>
                  (d! as Map<Object?, Object?>).cast<String, dynamic>(),
            ),
          );

      final Map<String, dynamic> a = await at(cursor);
      final Map<String, dynamic> b = await at(cursor);

      List<Object?> ids(Map<String, dynamic> m) => (m['items']! as List<Object?>)
          .map((Object? e) => (e! as Map<Object?, Object?>)['id'])
          .toList();

      expect(ids(b), ids(a), reason: '同一游标两次查询应返回同一批变更');
      expect(a['nextCursor'], b['nextCursor'], reason: '同一游标两次查询应给出同一游标');
    });
  });

  group('端到端：志愿者绑定与签到全链路', () {
    /// 造一个"现在正处于签到窗口内"的活动，并返回其 id 与邀请码。
    Future<({String activityId, String userNo, String inviteCode})> prepareActivity(
      String token,
    ) async {
      final ApiClient admin = ApiClient(
        config: client.config,
        tokenProvider: () async => token,
        deviceIdProvider: () async => adminDevice,
      );
      addTearDown(admin.dispose);

      final DateTime now = DateTime.now();
      final String extId = 'E2E-${now.microsecondsSinceEpoch}';

      final Map<String, dynamic> upserted = mustSucceed(
        await admin.post<Map<String, dynamic>>(
          ActivityPaths.upsert,
          body: <String, Object?>{
            'source': 'e2e-test',
            'batch': <Object?>[
              <String, Object?>{
                'externalId': extId,
                'title': '端到端联调活动',
                'organizer': '测试部门',
                'durationHours': 3.0,
                'startTime': TimeFormat.toIso8601(now.subtract(const Duration(minutes: 10))),
                'endTime': TimeFormat.toIso8601(now.add(const Duration(hours: 3))),
                'location': '测试场地',
                'locationType': 'outdoor',
                'geoLat': 34.2175,
                'geoLng': 117.1425,
                'checkinRadius': 300,
                'summary': '端到端联调用',
                'wifiBssids': <String>['a4:2b:8c:11:22:33'],
                'campusIpPrefixes': <String>['202.119.'],
              },
            ],
          },
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      final List<Object?> created = upserted['created']! as List<Object?>;
      expect(created, hasLength(1), reason: '上报应被受理：$upserted');
      final String activityId = created.single as String;

      // 加名单
      const String userNo = 'e2e2024001';
      mustSucceed(
        await admin.post<Map<String, dynamic>>(
          ParticipantPaths.add(activityId),
          body: <String, Object?>{'userNo': userNo, 'name': '联调志愿者'},
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );

      // 发邀请码
      final Map<String, dynamic> codes = mustSucceed(
        await admin.post<Map<String, dynamic>>(
          ParticipantPaths.issueInviteCodes(activityId),
          body: <String, Object?>{'userNos': <String>[userNo]},
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      final List<Object?> items = codes['items']! as List<Object?>;
      expect(items, hasLength(1));
      final String inviteCode =
          ((items.single as Map<Object?, Object?>)['inviteCode']! as String);

      return (activityId: activityId, userNo: userNo, inviteCode: inviteCode);
    }

    test('绑定 → 签到 → 在岗任务生成的完整链路', () async {
      if (!serverUp) {
        return;
      }

      // 1) 管理端登录并准备活动
      final Map<String, dynamic> login = mustSucceed(
        await client.post<Map<String, dynamic>>(
          AuthPaths.adminLogin,
          authorized: false,
          body: <String, Object?>{'inviteCode': '1111', 'deviceId': adminDevice},
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      final String adminToken = login['token'] as String;
      final ({String activityId, String userNo, String inviteCode}) prep =
          await prepareActivity(adminToken);

      // 2) 志愿者绑定（学号 + 一次性邀请码）
      const String deviceId = 'e2e-vol-device';
      final ApiClient anon = ApiClient(
        config: client.config,
        deviceIdProvider: () async => deviceId,
      );
      addTearDown(anon.dispose);

      final Map<String, dynamic> bound = mustSucceed(
        await anon.post<Map<String, dynamic>>(
          AuthPaths.bind,
          authorized: false,
          body: <String, Object?>{
            'activityId': prep.activityId,
            'userNo': prep.userNo,
            'inviteCode': prep.inviteCode,
            'name': '联调志愿者',
            'deviceId': deviceId,
          },
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      final VolunteerGrant grant = VolunteerGrant.fromJson(bound);
      expect(grant.token, isNotEmpty);
      expect(grant.activityId, prep.activityId);
      expect(grant.expiresAt.isAfter(DateTime.now()), isTrue, reason: '授权应在有效期内');

      // 3) 用设备令牌签到（**嵌套报文**，契约 §6.4.5）
      final ApiClient vol = ApiClient(
        config: client.config,
        tokenProvider: () async => grant.token,
        deviceIdProvider: () async => deviceId,
      );
      addTearDown(vol.dispose);

      final DateTime now = DateTime.now();
      const GeoPoint at = GeoPoint(lat: 34.21754, lng: 117.14254); // 围栏内
      final CheckinDraft draft = CheckinDraft(
        activityId: prep.activityId,
        idempotencyKey: vol.newIdempotencyKey(),
        method: CheckinMethod.geo,
        clientTime: now,
        deviceId: deviceId,
        wifiBssid: 'a4:2b:8c:11:22:33',
        localIp: '202.119.1.50',
        recentInsideFence: true,
        samples: <CheckinSample>[
          CheckinSample(point: at, accuracy: 12, capturedAt: now),
          CheckinSample(
            point: const GeoPoint(lat: 34.217545, lng: 117.142545),
            accuracy: 14,
            capturedAt: now,
          ),
          CheckinSample(
            point: const GeoPoint(lat: 34.21755, lng: 117.14255),
            accuracy: 11,
            capturedAt: now,
          ),
        ],
      );

      final Map<String, dynamic> checkinData = mustSucceed(
        await vol.post<Map<String, dynamic>>(
          CheckinPaths.submit(prep.activityId),
          body: draft.toJson(),
          idempotencyKey: draft.idempotencyKey,
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      final Map<String, dynamic> inner =
          (checkinData['checkin']! as Map<Object?, Object?>).cast<String, dynamic>();
      final Checkin checkin = Checkin.fromJson(inner);

      expect(
        checkin.status,
        CheckinStatus.success,
        reason: '围栏内 + 采样一致 + Wi-Fi/校园网辅证 + 停留验证应达 60 分：'
            'score=${checkin.score} reason=${checkin.reason}',
      );
      expect(checkin.score, isNotNull);
      expect(checkin.score! >= 60, isTrue);
      expect(checkin.point, isNotNull, reason: '嵌套 location.lat/lng 应被服务端解析成坐标');
      expect(checkin.point!.isPlausible, isTrue);

      // 4) 抽查任务应已生成（决策 D-6 的配套钩子）
      final Map<String, dynamic> tasks = mustSucceed(
        await vol.get<Map<String, dynamic>>(
          AttendancePaths.tasks(prep.activityId),
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      final List<Object?> taskItems = tasks['items']! as List<Object?>;
      expect(
        taskItems,
        isNotEmpty,
        reason: '签到成功后应立即生成本人的在岗抽查任务',
      );

      final AttendanceTask task = AttendanceTask.fromJson(
        (taskItems.first as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      expect(task.activityId, prep.activityId);

      // 5) 找一个当前可响应的任务并确认（零输入）
      final AttendanceTask? actionable = taskItems
          .map((Object? e) =>
              AttendanceTask.fromJson((e! as Map<Object?, Object?>).cast<String, dynamic>()))
          .where((AttendanceTask t) => !t.scheduledAt.isAfter(DateTime.now()))
          .firstOrNull;
      if (actionable == null) {
        // 夹具的第一个时段可能还没到点；这不影响前面几步的验证。
        return;
      }

      final Map<String, dynamic> confirmed = mustSucceed(
        await vol.post<Map<String, dynamic>>(
          AttendancePaths.confirm(actionable.id),
          body: <String, Object?>{
            'method': 'geo',
            'location': <String, Object?>{'lat': 34.21754, 'lng': 117.14254, 'accuracy': 15},
            'device': <String, Object?>{'mockLocationDetected': false},
          },
          idempotencyKey: vol.newIdempotencyKey(),
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      // 契约允许两种结果：直接完成，或精度/越界转人工。两者都不是错误。
      expect(confirmed.containsKey('task'), isTrue, reason: '响应应带 task：$confirmed');
    });

    test('非名单用户即使拿到合法邀请码也被拒绝，文案明确（验收 A10）', () async {
      if (!serverUp) {
        return;
      }
      final Map<String, dynamic> login = mustSucceed(
        await client.post<Map<String, dynamic>>(
          AuthPaths.adminLogin,
          authorized: false,
          body: <String, Object?>{'inviteCode': '1111', 'deviceId': adminDevice},
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      final String adminToken = login['token']! as String;
      final ({String activityId, String userNo, String inviteCode}) prep =
          await prepareActivity(adminToken);

      // ⚠️ 关键：要给"外人"发一个**属于他自己学号**的邀请码。
      //
      // 如果直接拿名单内某人的邀请码来试，服务端会先在
      //「邀请码 ↔ 学号配对」这一步就拒掉（40101），
      // 于是根本测不到"在名单外"这个分支。
      // 这条测试要验证的是后者，所以必须先绕过配对校验。
      const String outsiderNo = 'outsider9999';
      final ApiClient admin = ApiClient(
        config: client.config,
        tokenProvider: () async => adminToken,
        deviceIdProvider: () async => adminDevice,
      );
      addTearDown(admin.dispose);

      mustSucceed(
        await admin.post<Map<String, dynamic>>(
          ParticipantPaths.import(prep.activityId),
          body: <String, Object?>{
            'rows': <Object?>[
              <Object?>[outsiderNo, '名单外人'],
            ],
          },
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      final Map<String, dynamic> codes = mustSucceed(
        await admin.post<Map<String, dynamic>>(
          ParticipantPaths.issueInviteCodes(prep.activityId),
          body: <String, Object?>{
            'userNos': <String>[outsiderNo],
          },
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      final List<Object?> issued = codes['items']! as List<Object?>;
      expect(issued, hasLength(1), reason: '应为外人签发邀请码：$codes');
      final String outsiderCode =
          (issued.single as Map<Object?, Object?>)['inviteCode']! as String;

      // 把外人从名单里移出 → 他现在"有合法邀请码但不在名单"
      mustSucceed(
        await admin.delete<Map<String, dynamic>>(
          ParticipantPaths.remove(prep.activityId, outsiderNo),
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );

      final ApiClient anon = ApiClient(
        config: client.config,
        deviceIdProvider: () async => 'e2e-outsider',
      );
      addTearDown(anon.dispose);

      final ApiResult<Map<String, dynamic>> r = await anon.post<Map<String, dynamic>>(
        AuthPaths.bind,
        authorized: false,
        retryable: false,
        body: <String, Object?>{
          'activityId': prep.activityId,
          'userNo': outsiderNo,
          'inviteCode': outsiderCode,
          'deviceId': 'e2e-outsider',
        },
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      final ApiFailure<Map<String, dynamic>> f = r.failureOrNull!;
      expect(
        f.code.isForbidden,
        isTrue,
        reason: '应为 40301 族（不在名单），实际 ${f.code.name} / ${f.message}',
      );
      expect(f.message, contains('名单'), reason: '文案必须指出"不在名单"，便于志愿者自查');
    });

    test('验收 A23：同一幂等键重复提交，服务端不产生第二条记录', () async {
      if (!serverUp) {
        return;
      }
      final Map<String, dynamic> login = mustSucceed(
        await client.post<Map<String, dynamic>>(
          AuthPaths.adminLogin,
          authorized: false,
          body: <String, Object?>{'inviteCode': '1111', 'deviceId': adminDevice},
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      final ({String activityId, String userNo, String inviteCode}) prep =
          await prepareActivity(login['token']! as String);

      const String deviceId = 'e2e-idem-device';
      final ApiClient anon = ApiClient(
        config: client.config,
        deviceIdProvider: () async => deviceId,
      );
      addTearDown(anon.dispose);

      final Map<String, dynamic> bound = mustSucceed(
        await anon.post<Map<String, dynamic>>(
          AuthPaths.bind,
          authorized: false,
          body: <String, Object?>{
            'activityId': prep.activityId,
            'userNo': prep.userNo,
            'inviteCode': prep.inviteCode,
            'name': '联调志愿者',
            'deviceId': deviceId,
          },
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      final VolunteerGrant grant = VolunteerGrant.fromJson(bound);

      final ApiClient vol = ApiClient(
        config: client.config,
        tokenProvider: () async => grant.token,
        deviceIdProvider: () async => deviceId,
      );
      addTearDown(vol.dispose);

      final String key = vol.newIdempotencyKey();
      final DateTime now = DateTime.now();
      final Map<String, Object?> body = CheckinDraft(
        activityId: prep.activityId,
        idempotencyKey: key,
        method: CheckinMethod.geo,
        clientTime: now,
        deviceId: deviceId,
        samples: <CheckinSample>[
          CheckinSample(
            point: const GeoPoint(lat: 34.21754, lng: 117.14254),
            accuracy: 12,
            capturedAt: now,
          ),
        ],
      ).toJson();

      final Map<String, dynamic> first = mustSucceed(
        await vol.post<Map<String, dynamic>>(
          CheckinPaths.submit(prep.activityId),
          body: body,
          idempotencyKey: key,
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      final Map<String, dynamic> second = mustSucceed(
        await vol.post<Map<String, dynamic>>(
          CheckinPaths.submit(prep.activityId),
          body: body,
          idempotencyKey: key,
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );

      final String id1 =
          ((first['checkin']! as Map<Object?, Object?>)['id']! as String);
      final String id2 =
          ((second['checkin']! as Map<Object?, Object?>)['id']! as String);
      expect(id2, id1, reason: '同一幂等键必须落到同一条记录（验收 A23）');
    });
  });

  group('端到端：导出直接下载（网页 §6.4.8）', () {
    test('GET /activities/{id}/export 返回 CSV 且带 BOM', () async {
      if (!serverUp) {
        return;
      }

      // ⚠️ 登录必须用**这个管理员自己的设备指纹**。
      //
      // 服务端取设备指纹的优先级是「`X-Device-Id` 请求头 > 请求体里的 deviceId」，
      // 而 ApiClient 会自动带上自己的 `deviceIdProvider` 值。所以如果复用
      // 上面那个 `client`（指纹是 e2e-anonymous）来登录，服务端会用
      // **e2e-anonymous** 去算 ownerId，而请求体里写的 adminDevice 被忽略——
      // 结果就是"登录成功、但看不到自己的活动、导出 403"。
      //
      // 这个坑很典型：登录成功给了假的安全感，故障却出现在下一个接口上。
      final ApiClient admin = ApiClient(
        config: client.config,
        deviceIdProvider: () async => adminDevice,
      );
      addTearDown(admin.dispose);

      final Map<String, dynamic> login = mustSucceed(
        await admin.post<Map<String, dynamic>>(
          AuthPaths.adminLogin,
          authorized: false,
          body: <String, Object?>{'inviteCode': '1111', 'deviceId': adminDevice},
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      final String token = login['token']! as String;
      final String ownerId = login['ownerId']! as String;

      // 拿到令牌后要换一个**带令牌**的客户端来调业务接口。
      // 登录那个客户端没有 tokenProvider，匿名建活动会被拒 40101。
      final ApiClient authed = ApiClient(
        config: client.config,
        tokenProvider: () async => token,
        deviceIdProvider: () async => adminDevice,
      );
      addTearDown(authed.dispose);

      // 这个管理员是新建的，名下没有活动。先自己建一个已结束的活动，
      // 这样导出一定有内容可断言（空 CSV 也能过，但测不出脱敏与提示）。
      final DateTime now = DateTime.now();
      final Map<String, dynamic> upserted = mustSucceed(
        await authed.post<Map<String, dynamic>>(
          ActivityPaths.upsert,
          body: <String, Object?>{
            'batch': <Object?>[
              <String, Object?>{
                'externalId': 'E2E-EXPORT-$ownerId',
                'title': '导出联调活动',
                'organizer': '测试部门',
                'durationHours': 2.0,
                'startTime': TimeFormat.toIso8601(now.subtract(const Duration(hours: 4))),
                'endTime': TimeFormat.toIso8601(now.subtract(const Duration(hours: 2))),
                'location': '测试场地',
                'geoLat': 34.2175,
                'geoLng': 117.1425,
                'checkinRadius': 300,
                'summary': '用于导出断言',
              },
            ],
          },
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );
      final String activityId = (upserted['created']! as List<Object?>).single! as String;

      // 加一个有手机号的名单成员，才能验证"默认脱敏"。
      // 注意学号格式：服务端按 `^[A-Za-z0-9]{4,20}$` 校验，不能带连字符。
      mustSucceed(
        await authed.post<Map<String, dynamic>>(
          ParticipantPaths.add(activityId),
          body: <String, Object?>{
            'userNo': 'e2e0001',
            'name': '导出志愿者',
            'phone': '13800001234',
          },
          decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        ),
      );

      // 直接 GET 拿文件（不走 ApiClient，因为它按 JSON 解析；导出是二进制流）。
      final Uri uri = Uri.parse('$baseUrl${ActivityPaths.export(activityId)}')
          .replace(queryParameters: <String, String>{'kind': 'checkin_list', 'format': 'csv'});
      final HttpClient http = HttpClient();
      addTearDown(http.close);
      final HttpClientRequest req = await http.getUrl(uri);
      req.headers.set('Authorization', 'Bearer $token');
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 200, reason: '导出应直接返回文件，而不是"建任务"');
      expect(res.headers.contentType?.mimeType, 'text/csv');

      final List<int> bytes = <int>[];
      await for (final List<int> chunk in res) {
        bytes.addAll(chunk);
      }
      expect(bytes.length, greaterThan(3));
      // UTF-8 BOM
      expect(bytes.sublist(0, 3), <int>[0xef, 0xbb, 0xbf], reason: 'Excel 中文需要 BOM');

      final String text = utf8.decode(bytes.sublist(3));
      expect(text, contains('仅限内部使用'), reason: '必须带使用提示');
      // 默认脱敏：名单里有 13800001234，导出里必须只出现掩码形式。
      expect(text, contains('138****'), reason: '默认导出必须脱敏手机号');
      expect(
        text.contains('13800001234'),
        isFalse,
        reason: '默认导出不得出现完整手机号（决策 D-3）',
      );
    });
  });

  group('端到端：时钟偏差监控', () {
    test('从真实响应中取到 serverTime 并算出偏差', () async {
      if (!serverUp) {
        return;
      }
      final ClockSkewMonitor monitor = ClockSkewMonitor();
      final ApiResult<Map<String, dynamic>> r = await client.get<Map<String, dynamic>>(
        '/health',
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      final ApiSuccess<Map<String, dynamic>> ok = r as ApiSuccess<Map<String, dynamic>>;
      expect(ok.serverTime, isNotNull);
      monitor.observe(ok.serverTime!);
      // 本机与 Mock 同一台机器，偏差应很小
      expect(monitor.isSkewed, isFalse, reason: '同一台机器上不应报时钟偏差：${monitor.skew}');
    });
  });
}
