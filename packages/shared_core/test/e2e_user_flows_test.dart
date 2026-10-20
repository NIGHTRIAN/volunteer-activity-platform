import 'dart:io';

import 'package:shared_core/shared_core.dart';
import 'package:test/test.dart';

/// 端到端：用户端 A3 页面实际会调用的那几个接口。
///
/// ## 为什么单独写这一层
///
/// 页面用的是 `ApiPaths` + `toJson()`，而这两个东西**只有在真实服务端
/// 面前才能证明是对的**。填充到页面前的单测（假 HTTP 客户端）只能证明
/// "我的解析自洽"。
///
/// 这个文件覆盖 A3 会用到的**全部**端点：
///   绑定 → 提交签到 → 查本人签到 → 在岗任务列表 → 确认在岗 → 记录页解析。
///
/// 需要 Mock 进程（`node mock_server/src/server.js`）；未启动时整体跳过。
void main() {
  /*
    ⚠️ 只有**显式**设置 `E2E_BASE_URL` 才跑这组测试。

    一开始是"探测 8080 通就自动跑"，结果：只要开发时手边开着一个 mock，
    `flutter test` 就会连上去真跑一遍并**往那个库里写数据**。
    环境变量的存在本身就是"我确认要跑端到端"的意图声明。
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
      print('[e2e-a3] Mock 未启动（$baseUrl），跳过。');
    }
  });

  /// 造一个"正在进行中、可直接签到"的活动，返回绑定所需的一切。
  Future<({String activityId, String userNo, String inviteCode, String device})>
      prepareActivity(String adminDevice) async {
    final ApiClient a = ApiClient(
      config: ApiConfig(baseUrl: baseUrl),
      deviceIdProvider: () async => adminDevice,
    );
    addTearDown(a.dispose);

    final Map<String, dynamic> login = _ok(
      await a.post<Map<String, dynamic>>(
        AuthPaths.adminLogin,
        authorized: false,
        body: <String, Object?>{'inviteCode': '1111', 'deviceId': adminDevice},
        decode: _map,
      ),
    );
    final ApiClient auth = ApiClient(
      config: ApiConfig(baseUrl: baseUrl),
      tokenProvider: () async => login['token']! as String,
      deviceIdProvider: () async => adminDevice,
    );
    addTearDown(auth.dispose);

    final DateTime now = DateTime.now();
    final Map<String, dynamic> up = _ok(
      await auth.post<Map<String, dynamic>>(
        ActivityPaths.upsert,
        body: <String, Object?>{
          'batch': <Object?>[
            <String, Object?>{
              'externalId': 'E2E-A3-${now.microsecondsSinceEpoch}',
              'title': 'A3 端到端活动',
              'organizer': '测试部门',
              'durationHours': 3.0,
              // 已开始 10 分钟 → 在签到窗口内
              'startTime': TimeFormat.toIso8601(now.subtract(const Duration(minutes: 10))),
              'endTime': TimeFormat.toIso8601(now.add(const Duration(hours: 3))),
              'location': '测试场地',
              'locationType': 'outdoor',
              'geoLat': 34.2175,
              'geoLng': 117.1425,
              'checkinRadius': 300,
              'summary': 'A3 端到端',
              'wifiBssids': <String>['a4:2b:8c:11:22:33'],
              'campusIpPrefixes': <String>['202.119.'],
            },
          ],
        },
        decode: _map,
      ),
    );
    final String activityId = (up['created']! as List<Object?>).single! as String;

    const String userNo = 'a3e2e0001';
    _ok(
      await auth.post<Map<String, dynamic>>(
        ParticipantPaths.add(activityId),
        body: <String, Object?>{'userNo': userNo, 'name': 'A3 志愿者'},
        decode: _map,
      ),
    );

    final Map<String, dynamic> codes = _ok(
      await auth.post<Map<String, dynamic>>(
        ParticipantPaths.issueInviteCodes(activityId),
        body: <String, Object?>{'userNos': <String>[userNo]},
        decode: _map,
      ),
    );
    final String code =
        ((codes['items']! as List<Object?>).single! as Map<Object?, Object?>)['inviteCode']!
            as String;

    return (
      activityId: activityId,
      userNo: userNo,
      inviteCode: code,
      device: newDevice('vol'),
    );
  }

  /// 绑定并返回可用的志愿者客户端 + 授权。
  Future<({ApiClient client, VolunteerGrant grant})> bind({
    required ({String activityId, String userNo, String inviteCode, String device}) prep,
  }) async {
    final ApiClient anon = ApiClient(
      config: ApiConfig(baseUrl: baseUrl),
      deviceIdProvider: () async => prep.device,
    );
    addTearDown(anon.dispose);

    final Map<String, dynamic> data = _ok(
      await anon.post<Map<String, dynamic>>(
        AuthPaths.bind,
        authorized: false,
        body: <String, Object?>{
          'activityId': prep.activityId,
          'userNo': prep.userNo,
          'inviteCode': prep.inviteCode,
          'deviceId': prep.device,
          'name': 'A3 志愿者',
        },
        decode: _map,
      ),
    );
    final VolunteerGrant grant = VolunteerGrant.fromJson(data);

    final ApiClient client = ApiClient(
      config: ApiConfig(baseUrl: baseUrl),
      tokenProvider: () async => grant.token,
      deviceIdProvider: () async => prep.device,
    );
    addTearDown(client.dispose);

    return (client: client, grant: grant);
  }

  group('A3 绑定页', () {
    test('绑定成功且授权字段可解析（页面据此决定是否进主页）', () async {
      if (!serverUp) {
        return;
      }
      final prep = await prepareActivity(newDevice('adm'));
      final bound = await bind(prep: prep);

      expect(bound.grant.token, isNotEmpty);
      expect(bound.grant.activityId, prep.activityId);
      expect(bound.grant.userNo, prep.userNo);
      expect(bound.grant.expiresAt.isAfter(DateTime.now()), isTrue);
    });

    test('姓名不匹配 → 带 field=name 的字段级错误（页面据此高亮该字段）', () async {
      if (!serverUp) {
        return;
      }
      final prep = await prepareActivity(newDevice('adm'));
      final ApiClient anon = ApiClient(
        config: ApiConfig(baseUrl: baseUrl),
        deviceIdProvider: () async => prep.device,
      );
      addTearDown(anon.dispose);

      final ApiResult<Object?> r = await anon.post<Object?>(
        AuthPaths.bind,
        authorized: false,
        retryable: false,
        body: <String, Object?>{
          'activityId': prep.activityId,
          'userNo': prep.userNo,
          'inviteCode': prep.inviteCode,
          'deviceId': prep.device,
          'name': '明显不是本人',
          'phoneSuffix': '0000',
        },
        decode: (Object? d) => d,
      );
      final ApiFailure<Object?> f = r.failureOrNull!;

      // ⚠️ 页面**不能**按错误码判断这一点。
      //
      // 契约只授权 8 个码值，`40301` 同时代表"越权 / 不在名单 /
      // 二次校验失败 / 设备不符"。实测确认：这里拿到的是 `forbidden`
      // 而不是 `identityMismatch` —— 按码值判断就会把"不在名单"
      // 也误认为"需要核对身份"。
      //
      // 正确依据是**字段级错误**。
      expect(
        f.fieldErrors.map((FieldError e) => e.field),
        contains('name'),
        reason: '服务端应下发字段级错误：${f.fieldErrors}',
      );
      expect(f.message, isNotEmpty);
    });
  });

  group('A3 签到页', () {
    test('嵌套报文可完成签到，且返回可解析的 Checkin', () async {
      if (!serverUp) {
        return;
      }
      final prep = await prepareActivity(newDevice('adm'));
      final bound = await bind(prep: prep);
      final DateTime now = DateTime.now();

      final CheckinDraft draft = CheckinDraft(
        activityId: prep.activityId,
        idempotencyKey: bound.client.newIdempotencyKey(),
        method: CheckinMethod.geo,
        clientTime: now,
        deviceId: prep.device,
        wifiBssid: 'a4:2b:8c:11:22:33',
        localIp: '202.119.1.77',
        samples: <CheckinSample>[
          CheckinSample(
            point: const GeoPoint(lat: 34.21754, lng: 117.14254),
            accuracy: 12,
            capturedAt: now,
          ),
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

      final Map<String, dynamic> data = _ok(
        await bound.client.post<Map<String, dynamic>>(
          CheckinPaths.submit(prep.activityId),
          body: draft.toJson(),
          idempotencyKey: draft.idempotencyKey,
          decode: _map,
        ),
      );

      final Checkin checkin = Checkin.fromJson(
        (data['checkin']! as Map<Object?, Object?>).cast<String, dynamic>(),
      );

      expect(checkin.status, CheckinStatus.success,
          reason: '围栏内+多采样+Wi-Fi/校园网辅证应达 60 分：'
              'score=${checkin.score} reason=${checkin.reason}');
      expect(checkin.point, isNotNull);
      expect(checkin.method, CheckinMethod.geo);
      // 页面用 serverTime 显示"签到时间"（以服务端为准）。
      expect(checkin.serverTime, isNotNull);
    });

    test('本人签到记录可查（记录页解析用）', () async {
      if (!serverUp) {
        return;
      }
      final prep = await prepareActivity(newDevice('adm'));
      final bound = await bind(prep: prep);
      final DateTime now = DateTime.now();

      final CheckinDraft draft = CheckinDraft(
        activityId: prep.activityId,
        idempotencyKey: bound.client.newIdempotencyKey(),
        method: CheckinMethod.geo,
        clientTime: now,
        deviceId: prep.device,
        samples: <CheckinSample>[
          CheckinSample(
            point: const GeoPoint(lat: 34.21754, lng: 117.14254),
            accuracy: 12,
            capturedAt: now,
          ),
        ],
      );
      _ok(
        await bound.client.post<Map<String, dynamic>>(
          CheckinPaths.submit(prep.activityId),
          body: draft.toJson(),
          idempotencyKey: draft.idempotencyKey,
          decode: _map,
        ),
      );

      final Map<String, dynamic> mine = _ok(
        await bound.client.get<Map<String, dynamic>>(
          CheckinPaths.mine(prep.activityId),
          decode: _map,
        ),
      );

      // 记录页同时兼容 `latest` / `checkin` / 直接记录三种形态。
      // 服务端实际给的是 `{items, latest, grantExpiresAt}`，这里把它锁住。
      final Object? latest = mine['latest'];
      expect(latest, isA<Map<Object?, Object?>>(),
          reason: '服务端应给出 latest 字段：$mine');
      final Map<String, dynamic> target =
          (latest! as Map<Object?, Object?>).cast<String, dynamic>();
      expect(target['id'], isNotNull, reason: '应能取到记录 id');
      expect(target['status'], anyOf('success', 'pending_review'));
    });

    test('无定位证据的签到被拒（A19 同口径：只点不算数）', () async {
      if (!serverUp) {
        return;
      }
      final prep = await prepareActivity(newDevice('adm'));
      final bound = await bind(prep: prep);

      final ApiResult<Map<String, dynamic>> r =
          await bound.client.post<Map<String, dynamic>>(
        CheckinPaths.submit(prep.activityId),
        body: <String, Object?>{
          'method': 'geo',
          // 空 location：模拟"只按了按钮、定位没取到"
          'location': <String, Object?>{},
          'device': <String, Object?>{'mockLocationDetected': false},
        },
        idempotencyKey: bound.client.newIdempotencyKey(),
        retryable: false,
        decode: _map,
      );

      // 服务端不会静默算通过；它要么拒绝，要么转人工。
      switch (r) {
        case ApiFailure<Map<String, dynamic>>():
          // 被拒绝也算正确行为——关键是**没有**返回"成功"。
          expect(r.failureOrNull!.message, isNotEmpty);
        case ApiSuccess<Map<String, dynamic>>(:final Map<String, dynamic> value):
          final Checkin c = Checkin.fromJson(
            (value['checkin']! as Map<Object?, Object?>).cast<String, dynamic>(),
          );
          expect(c.status, isNot(CheckinStatus.success),
              reason: '没有位置证据不得自动通过（验收 A19）');
      }
    });
  });

  group('A3 在岗确认页', () {
    test('签到后任务列表可解析，且服务端返回 serverTime（倒计时校正用）', () async {
      if (!serverUp) {
        return;
      }
      final prep = await prepareActivity(newDevice('adm'));
      final bound = await bind(prep: prep);
      final DateTime now = DateTime.now();

      // 先签到（决策 D-6：抽查只为已签到者生成）。
      _ok(
        await bound.client.post<Map<String, dynamic>>(
          CheckinPaths.submit(prep.activityId),
          body: CheckinDraft(
            activityId: prep.activityId,
            idempotencyKey: bound.client.newIdempotencyKey(),
            method: CheckinMethod.geo,
            clientTime: now,
            deviceId: prep.device,
            samples: <CheckinSample>[
              CheckinSample(
                point: const GeoPoint(lat: 34.21754, lng: 117.14254),
                accuracy: 12,
                capturedAt: now,
              ),
            ],
          ).toJson(),
          idempotencyKey: bound.client.newIdempotencyKey(),
          decode: _map,
        ),
      );

      final Map<String, dynamic> data = _ok(
        await bound.client.get<Map<String, dynamic>>(
          AttendancePaths.tasks(prep.activityId),
          decode: _map,
        ),
      );

      // ⚠️ 页面用 `serverTime` 校正倒计时；缺了它倒计时只能用本机时间，
      // 而本机时间可能不准（方案 §9）。这里确保服务端确实下发了它。
      expect(data['serverTime'], isNotNull, reason: '倒计时依赖服务端时间：$data');

      final List<Object?> items = data['items']! as List<Object?>;
      expect(items, isNotEmpty, reason: '签到后应生成在岗抽查任务');
      for (final Object? e in items) {
        final AttendanceTask t =
            AttendanceTask.fromJson((e! as Map<Object?, Object?>).cast<String, dynamic>());
        expect(t.id, isNotEmpty);
        expect(t.seq, greaterThan(0));
        // 页面按 deadlineAt 算倒计时，必须能解析出时间。
        expect(t.deadlineAt.isAfter(DateTime(2000)), isTrue);
      }
    });

    test('确认在岗返回 task 或转人工（两种都不是错误，页面要能接住）', () async {
      if (!serverUp) {
        return;
      }
      final prep = await prepareActivity(newDevice('adm'));
      final bound = await bind(prep: prep);
      final DateTime now = DateTime.now();

      _ok(
        await bound.client.post<Map<String, dynamic>>(
          CheckinPaths.submit(prep.activityId),
          body: CheckinDraft(
            activityId: prep.activityId,
            idempotencyKey: bound.client.newIdempotencyKey(),
            method: CheckinMethod.geo,
            clientTime: now,
            deviceId: prep.device,
            samples: <CheckinSample>[
              CheckinSample(
                point: const GeoPoint(lat: 34.21754, lng: 117.14254),
                accuracy: 12,
                capturedAt: now,
              ),
            ],
          ).toJson(),
          idempotencyKey: bound.client.newIdempotencyKey(),
          decode: _map,
        ),
      );

      final Map<String, dynamic> tasks = _ok(
        await bound.client.get<Map<String, dynamic>>(
          AttendancePaths.tasks(prep.activityId),
          decode: _map,
        ),
      );
      final List<Object?> items = tasks['items']! as List<Object?>;
      final AttendanceTask first = AttendanceTask.fromJson(
        (items.first! as Map<Object?, Object?>).cast<String, dynamic>(),
      );

      final ApiResult<Map<String, dynamic>> r =
          await bound.client.post<Map<String, dynamic>>(
        AttendancePaths.confirm(first.id),
        body: <String, Object?>{
          'method': 'geo',
          'location': <String, Object?>{
            'lat': 34.21754,
            'lng': 117.14254,
            'accuracy': 15,
          },
          'device': <String, Object?>{'mockLocationDetected': false},
        },
        idempotencyKey: bound.client.newIdempotencyKey(),
        decode: _map,
      );

      switch (r) {
        case ApiSuccess<Map<String, dynamic>>(:final Map<String, dynamic> value):
          // 页面读 `task` 来就地显示终态；读 `needsManualReview` + `message`
          // 来显示"待发布者确认"（这不是错误）。
          expect(value.containsKey('task'), isTrue, reason: '响应应带 task：$value');
        case ApiFailure<Map<String, dynamic>>():
          // 响应窗口已过或状态冲突是合理结果；页面会展示 msg。
          expect(r.failureOrNull!.message, isNotEmpty);
      }
    });
  });

  group('A3 记录页', () {
    test('待上传队列能按活动过滤（tasksFor 供记录页逐条列出）', () {
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x')),
      );
      final DateTime now = DateTime.now();
      q.enqueueCheckin(
        activityId: 'act-a',
        draft: CheckinDraft(
          activityId: 'act-a',
          idempotencyKey: 'k1',
          method: CheckinMethod.geo,
          clientTime: now,
          samples: <CheckinSample>[
            CheckinSample(
              point: const GeoPoint(lat: 34.2, lng: 117.1),
              accuracy: 10,
              capturedAt: now,
            ),
          ],
        ),
      );
      q.enqueueCheckin(
        activityId: 'act-b',
        draft: CheckinDraft(
          activityId: 'act-b',
          idempotencyKey: 'k2',
          method: CheckinMethod.geo,
          clientTime: now,
          samples: <CheckinSample>[
            CheckinSample(
              point: const GeoPoint(lat: 34.2, lng: 117.1),
              accuracy: 10,
              capturedAt: now,
            ),
          ],
        ),
      );

      expect(q.tasksFor('act-a').length, 1);
      expect(q.tasksFor('act-a').single.activityId, 'act-a');
      expect(q.tasksFor('act-b').length, 1);
      expect(q.tasksFor('act-none').isEmpty, isTrue);
      expect(q.outstandingCountFor('act-a'), 1);
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
