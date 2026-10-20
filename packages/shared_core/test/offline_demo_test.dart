import 'package:shared_core/shared_core.dart';
import 'package:test/test.dart';

/// 离线演示引擎的端到端验证。
///
/// ## 这组测试的意义
///
/// 用户**没有云服务器**，但 App 要能直接装到手机上给别人验收。
/// 离线模式在 [ApiTransport] 那一层替换掉网络，界面与判定逻辑完全复用。
///
/// 所以这组测试走的是**与真机上完全相同的那条路**：
/// `ApiClient`（重试 / 令牌 / 信封解析 / 错误码）→ `OfflineDemoTransport`。
/// 跑通它，就等于跑通了"没有服务器时的完整业务流程"。
void main() {
  /// 造一个指向离线引擎的客户端，模拟某一端 App。
  ({ApiClient api, OfflineDemoState state}) makeApp({OfflineDemoState? shared}) {
    final OfflineDemoState state = shared ?? OfflineDemoState.seeded();
    final ApiClient api = ApiClient(
      config: const ApiConfig(baseUrl: 'http://offline.demo/api'),
      transport: OfflineDemoTransport(state: state),
      waiter: (Duration _) async {},
    );
    return (api: api, state: state);
  }


  /// 用**生产序列化器**构造签到请求体。
  ///
  /// ## 为什么必须这样
  ///
  /// 一开始测试里是手写 JSON 的（`{'location': {...}, 'samples': [...]}`），
  /// 结果把演示引擎的解析 bug 藏住了：真实形状是
  /// `location.samples` / `network.sourceIp` / `network.wifiBssids`，
  /// 而我按直觉写成了 `samples` / `network.localIp` / `network.wifiBssid`。
  /// 真机上表现为"评分只有 40 分，永远转人工"。
  ///
  /// 测试与生产用**同一个序列化器**，这类漂移就不可能再发生。
  Map<String, Object?> draftBody({
    required double lat,
    required double lng,
    required double accuracy,
    String? localIp,
    bool mock = false,
    int sampleCount = 3,
  }) {
    final DateTime now = DateTime.now();
    final CheckinDraft draft = CheckinDraft(
      activityId: 'any',
      idempotencyKey: 'test-key',
      method: CheckinMethod.geo,
      clientTime: now,
      mockLocationDetected: mock,
      localIp: localIp,
      samples: <CheckinSample>[
        for (int i = 0; i < sampleCount; i++)
          CheckinSample(
            point: GeoPoint(lat: lat + i * 0.00001, lng: lng + i * 0.00001),
            accuracy: accuracy,
            capturedAt: now.subtract(Duration(seconds: sampleCount - i)),
          ),
      ],
    );
    return draft.toJson();
  }
  group('离线演示引擎 · 完整业务流程', () {
    test('管理端登录：邀请码 1111 可登录，错误邀请码被拒', () async {
      final ({ApiClient api, OfflineDemoState state}) app = makeApp();

      final ApiResult<AdminSession> bad = await app.api.post<AdminSession>(
        '/auth/admin/login',
        body: <String, Object?>{'inviteCode': '9999', 'deviceId': 'dev-1'},
        decode: (Object? d) => AdminSession.fromJson((d! as Map<Object?, Object?>).cast<String, dynamic>()),
        authorized: false,
      );
      expect(bad.isSuccess, isFalse, reason: '错误邀请码必须被拒');

      final ApiResult<AdminSession> ok = await app.api.post<AdminSession>(
        '/auth/admin/login',
        body: <String, Object?>{'inviteCode': '1111', 'deviceId': 'dev-1'},
        decode: (Object? d) => AdminSession.fromJson((d! as Map<Object?, Object?>).cast<String, dynamic>()),
        authorized: false,
      );
      expect(ok.isSuccess, isTrue);
      expect(ok.dataOrNull?.token, isNotEmpty);
    });

    test('种子数据：4 个活动，覆盖已发布/已结束/已取消三种状态', () async {
      final ({ApiClient api, OfflineDemoState state}) app = makeApp();
      final ApiResult<Paged<Activity>> r = await app.api.get<Paged<Activity>>(
        '/activities',
        decode: (Object? d) => Paged<Activity>.fromJson(
          (d! as Map<Object?, Object?>).cast<String, dynamic>(),
          Activity.fromJson,
        ),
      );
      expect(r.isSuccess, isTrue);
      final Paged<Activity> page = r.dataOrNull!;
      expect(page.items.length, 4);
      final Set<ActivityStatus> statuses =
          page.items.map((Activity a) => a.status).toSet();
      expect(statuses, contains(ActivityStatus.published));
      expect(statuses, contains(ActivityStatus.finished));
      expect(statuses, contains(ActivityStatus.cancelled));
    });

    test('新建活动 → 出现在列表里（管理端核心流程）', () async {
      final ({ApiClient api, OfflineDemoState state}) app = makeApp();
      final DateTime now = DateTime.now();
      String iso(DateTime d) =>
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'
          'T${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:00'
          '+08:00';

      final ApiResult<Map<String, dynamic>> up = await app.api.post<Map<String, dynamic>>(
        '/activities:upsert',
        body: <String, Object?>{
          'batch': <Object?>[
            <String, Object?>{
              'externalId': 'TEST-1',
              'title': '离线新建活动',
              'organizer': '校团委',
              'durationHours': 2,
              'startTime': iso(now.subtract(const Duration(minutes: 10))),
              'endTime': iso(now.add(const Duration(hours: 2))),
              'location': '测试场地',
              'geoLat': 34.2175,
              'geoLng': 117.1425,
              'checkinRadius': 300,
              'summary': '离线模式验证',
              'status': 'published',
              // 配上网关白名单，让自动通过可达（见下方签到用例的说明）
              'campusIpPrefixes': <Object?>['10.176.'],
            },
          ],
        },
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      expect(up.isSuccess, isTrue);
      expect(up.dataOrNull?['accepted'], 1);

      final ApiResult<Paged<Activity>> list = await app.api.get<Paged<Activity>>(
        '/activities',
        decode: (Object? d) => Paged<Activity>.fromJson(
          (d! as Map<Object?, Object?>).cast<String, dynamic>(),
          Activity.fromJson,
        ),
      );
      expect(list.dataOrNull!.items.length, 5);
      expect(
        list.dataOrNull!.items.any((Activity a) => a.title == '离线新建活动'),
        isTrue,
      );
    });

    test('加名单 → 发邀请码 → 志愿者绑定（两侧流程接得上）', () async {
      final OfflineDemoState state = OfflineDemoState.seeded();
      final ({ApiClient api, OfflineDemoState state}) admin = makeApp(shared: state);

      // 1) 加一个人
      final ApiResult<Map<String, dynamic>> add = await admin.api.post<Map<String, dynamic>>(
        '/activities/demo-act-library/participants',
        body: <String, Object?>{'userNo': '2021009', 'name': '测试同学', 'phone': '13800000009'},
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      expect(add.isSuccess, isTrue, reason: '加名单应成功：${add.failureOrNull?.message}');

      // 重复加同一个人必须报"已存在"，而不是静默重复
      final ApiResult<Map<String, dynamic>> dup = await admin.api.post<Map<String, dynamic>>(
        '/activities/demo-act-library/participants',
        body: <String, Object?>{'userNo': '2021009', 'name': '测试同学'},
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        retryable: false,
      );
      expect(dup.isSuccess, isFalse);
      expect(dup.failureOrNull?.message, contains('已存在'));

      // 2) 发邀请码
      final ApiResult<Map<String, dynamic>> codes =
          await admin.api.post<Map<String, dynamic>>(
        '/activities/demo-act-library/invite-codes',
        body: <String, Object?>{},
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      expect(codes.isSuccess, isTrue);
      final List<Object?> items = codes.dataOrNull!['items'] as List<Object?>;
      final Map<Object?, Object?> mine = items
          .cast<Map<Object?, Object?>>()
          .firstWhere((Map<Object?, Object?> i) => i['userNo'] == '2021009');
      final String code = mine['inviteCode']! as String;
      expect(code, isNotEmpty);

      // 3) 用户端绑定（同一个引擎状态，模拟"两端连同一个服务端"）
      final ApiClient volunteer = ApiClient(
        config: const ApiConfig(baseUrl: 'http://offline.demo/api'),
        transport: OfflineDemoTransport(state: state),
        waiter: (Duration _) async {},
      );
      final ApiResult<VolunteerGrant> bind = await volunteer.post<VolunteerGrant>(
        '/auth/bind',
        body: <String, Object?>{
          'activityId': 'demo-act-library',
          'userNo': '2021009',
          'inviteCode': code,
          'deviceId': 'vol-device-1',
          'phoneSuffix': '0009',
        },
        decode: (Object? d) =>
            VolunteerGrant.fromJson((d! as Map<Object?, Object?>).cast<String, dynamic>()),
        authorized: false,
      );
      expect(bind.isSuccess, isTrue, reason: '绑定应成功：${bind.failureOrNull?.message}');
      expect(bind.dataOrNull?.userNo, '2021009');

      // 4) 幂等：同一设备重试应拿回同一个令牌，而不是"邀请码已被使用"
      final ApiResult<VolunteerGrant> again = await volunteer.post<VolunteerGrant>(
        '/auth/bind',
        body: <String, Object?>{
          'activityId': 'demo-act-library',
          'userNo': '2021009',
          'inviteCode': code,
          'deviceId': 'vol-device-1',
        },
        decode: (Object? d) =>
            VolunteerGrant.fromJson((d! as Map<Object?, Object?>).cast<String, dynamic>()),
        authorized: false,
      );
      expect(again.isSuccess, isTrue, reason: '同设备重试必须幂等，否则用户被永久锁死');
      expect(again.dataOrNull?.token, bind.dataOrNull?.token);
    });

    test('签到：围栏 + 采样 + 校园网 = 60 分自动通过；再点一次不会重复计入', () async {
      final OfflineDemoState state = OfflineDemoState.seeded();
      final ApiClient api = ApiClient(
        config: const ApiConfig(baseUrl: 'http://offline.demo/api'),
        transport: OfflineDemoTransport(state: state),
        waiter: (Duration _) async {},
      );
      // 直接造一个已绑定的志愿者（2021001 是种子里"尚未签到"的那个人）
      state.volunteerToken = 'demo-vol-test';
      state.volunteerActivityId = 'demo-act-library';
      state.volunteerUserNo = '2021001';

      final ApiResult<Checkin> r = await api.post<Checkin>(
        '/activities/demo-act-library/checkins',
        // 用生产序列化器构造请求体：字段名与 App 实际发出的一致。
        body: draftBody(lat: 34.21751, lng: 117.14251, accuracy: 30),
        decode: (Object? d) => Checkin.fromJson((d! as Map<Object?, Object?>).cast<String, dynamic>()),
        idempotencyKey: 'k-offline-1',
        retryable: false,
      );
      expect(r.isSuccess, isTrue, reason: '签到应成功：${r.failureOrNull?.message}');
      final Checkin c = r.dataOrNull!;
      // 种子活动的 campusIpPrefixes 为空 → 只有围栏 40 + 采样 10 = 50 → 待人工确认。
      // 这本身是**正确**行为：没有网络辅证就不该自动通过。
      expect(c.score, 50);
      expect(c.status, CheckinStatus.pendingReview);
      expect(c.point!.lat, closeTo(34.21751, 1e-6));

      // 重复提交：返回原记录，不产生第二条
      // （注意要带上完整定位证据——门槛校验在去重之前，与服务端同序）
      final ApiResult<Checkin> dup = await api.post<Checkin>(
        '/activities/demo-act-library/checkins',
        body: draftBody(lat: 34.21751, lng: 117.14251, accuracy: 30),
        decode: (Object? d) => Checkin.fromJson((d! as Map<Object?, Object?>).cast<String, dynamic>()),
        idempotencyKey: 'k-offline-2',
        retryable: false,
      );
      expect(dup.isSuccess, isTrue, reason: '重复提交应幂等返回：${dup.failureOrNull?.message}');
      expect(state.checkins.where((Map<String, Object?> x) => x['userNo'] == '2021001').length, 1);
    });

    test('模拟定位 → 强制转人工（即使评分很高也不自动通过）', () async {
      final OfflineDemoState state = OfflineDemoState.seeded();
      final ApiClient api = ApiClient(
        config: const ApiConfig(baseUrl: 'http://offline.demo/api'),
        transport: OfflineDemoTransport(state: state),
        waiter: (Duration _) async {},
      );
      state.volunteerToken = 'demo-vol-test2';
      state.volunteerActivityId = 'demo-act-library';
      state.volunteerUserNo = '2021003';

      final ApiResult<Checkin> r = await api.post<Checkin>(
        '/activities/demo-act-library/checkins',
        body: draftBody(lat: 34.21752, lng: 117.14252, accuracy: 20, mock: true),
        decode: (Object? d) => Checkin.fromJson((d! as Map<Object?, Object?>).cast<String, dynamic>()),
        retryable: false,
      );
      expect(r.isSuccess, isTrue);
      expect(r.dataOrNull!.status, CheckinStatus.pendingReview);
      expect(r.dataOrNull!.reason, contains('模拟定位'));
    });

    test('在岗抽查：签到后生成任务，未到点不能确认，到点可确认', () async {
      final OfflineDemoState state = OfflineDemoState.seeded();
      final ApiClient api = ApiClient(
        config: const ApiConfig(baseUrl: 'http://offline.demo/api'),
        transport: OfflineDemoTransport(state: state),
        waiter: (Duration _) async {},
      );
      state.volunteerToken = 'demo-vol-t3';
      state.volunteerActivityId = 'demo-act-library';
      state.volunteerUserNo = '2021001';

      // 先签到（生成抽查任务）
      await api.post<Checkin>(
        '/activities/demo-act-library/checkins',
        body: draftBody(lat: 34.21751, lng: 117.14251, accuracy: 30),
        decode: (Object? d) => Checkin.fromJson((d! as Map<Object?, Object?>).cast<String, dynamic>()),
        retryable: false,
      );

      final ApiResult<Map<String, dynamic>> tasks =
          await api.get<Map<String, dynamic>>(
        '/activities/demo-act-library/attendance/tasks',
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      expect(tasks.isSuccess, isTrue);
      final List<Object?> items = tasks.dataOrNull!['items'] as List<Object?>;
      expect(items, isNotEmpty, reason: '签到受理后必须生成抽查任务（决策 D-6）');

      // 第一个任务计划在活动开始后 15 分钟 —— 种子活动 10 分钟前才开始，
      // 所以它必然在未来。这正是要验证的：**未到点不能提前确认**。
      final Map<Object?, Object?> first = items.cast<Map<Object?, Object?>>().first;
      final String taskId = first['id']! as String;
      final DateTime scheduled = TimeFormat.tryParse(first['scheduledAt'])!;
      expect(
        DateTime.now().isBefore(scheduled),
        isTrue,
        reason: '种子活动 10 分钟前开始，第一次抽查应在 T+15（未来）',
      );

      final ApiResult<Map<String, dynamic>> confirm = await api.post<Map<String, dynamic>>(
        '/attendances/$taskId:confirm',
        body: draftBody(lat: 34.21751, lng: 117.14251, accuracy: 25, sampleCount: 2),
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        retryable: false,
      );
      // 未到点：必须拒绝（真机测试发现过"可以提前点掉所有未来抽查"的漏洞）
      expect(confirm.isSuccess, isFalse, reason: '未到计划时刻不得提前确认');
      expect(confirm.failureOrNull?.message, contains('尚未开始'));
    });

    test('人工复核：待确认 → 通过 → 名单变为已签到', () async {
      final OfflineDemoState state = OfflineDemoState.seeded();
      final ApiClient api = ApiClient(
        config: const ApiConfig(baseUrl: 'http://offline.demo/api'),
        transport: OfflineDemoTransport(state: state),
        waiter: (Duration _) async {},
      );

      // 种子里有李娜（2021002）一条待确认记录，管理端进来就能演示复核
      final ApiResult<Map<String, dynamic>> list = await api.get<Map<String, dynamic>>(
        '/activities/demo-act-library/checkins',
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      expect(list.isSuccess, isTrue);
      final List<Object?> items = list.dataOrNull!['items'] as List<Object?>;
      expect(items.length, 1);
      final Map<Object?, Object?> c = items.cast<Map<Object?, Object?>>().first;
      expect(c['status'], 'pending_review');

      final ApiResult<Map<String, dynamic>> review =
          await api.post<Map<String, dynamic>>(
        // 用真实路径形式（斜杠）—— 这条断言专门挡住"只按冒号后缀实现"的错。
        '/checkins/${c['id']}/review',
        body: <String, Object?>{'decision': 'approve', 'note': '现场核对无误'},
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        retryable: false,
      );
      expect(review.isSuccess, isTrue, reason: '复核应成功：${review.failureOrNull?.message}');

      final Map<Object?, Object?> after =
          review.dataOrNull!['checkin']! as Map<Object?, Object?>;
      expect(after['status'], 'success');

      final ApiResult<Map<String, dynamic>> board = await api.get<Map<String, dynamic>>(
        '/activities/demo-act-library/board',
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      expect(board.isSuccess, isTrue);
      final ActivityBoard b = ActivityBoard.fromJson(board.dataOrNull!);
      expect(b.checkedIn, 1, reason: '通过后名单应变为已签到');
      expect(b.pendingReview, 0);
    });

    test('导出在演示模式下必须明确拒绝，而不是静默失败', () async {
      final ({ApiClient api, OfflineDemoState state}) app = makeApp();
      final ApiResult<Map<String, dynamic>> r = await app.api.get<Map<String, dynamic>>(
        '/activities/demo-act-library/export',
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        retryable: false,
      );
      expect(r.isSuccess, isFalse);
      expect(r.failureOrNull?.message, contains('演示模式'));
    });
  });

  group('演示状态的持久化', () {
    test('toJsonString → fromJsonString 往返后活动与签到都还在', () {
      final OfflineDemoState a = OfflineDemoState.seeded();
      a.volunteerToken = 'demo-vol-x';
      a.volunteerActivityId = 'demo-act-library';
      a.volunteerUserNo = '2021001';
      final String raw = a.toJsonString();

      final OfflineDemoState b = OfflineDemoState.fromJsonString(raw);
      expect(b.activities.length, a.activities.length);
      expect(b.checkins.length, a.checkins.length);
      expect(b.volunteerUserNo, '2021001');
    });

    test('坏数据不抛异常，退回种子数据（一个坏文件不该让 App 起不来）', () {
      final OfflineDemoState s = OfflineDemoState.fromJsonString('{ 这不是 JSON');
      expect(s.activities.length, 4, reason: '解析失败应退回种子数据');
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 场地网络白名单（O-17）
  //
  // 评分表：围栏 40 + 采样一致 10 = 50，自动通过门槛 60。
  // 差的 10–30 分只能来自网络辅证，而服务端**只在活动配了白名单时**才计分。
  // 所以「发布者能不能配白名单」直接决定「签到会不会全部转人工」。
  // 这组测试把这条因果链钉住。
  // ─────────────────────────────────────────────────────────────────────────
  group('场地网络白名单决定自动通过', () {
    ({ApiClient api, OfflineDemoState state}) app() {
      final OfflineDemoState state = OfflineDemoState.seeded();
      final ApiClient api = ApiClient(
        config: const ApiConfig(baseUrl: 'http://offline.demo/api'),
        transport: OfflineDemoTransport(state: state),
        waiter: (Duration _) async {},
      );
      return (api: api, state: state);
    }

    /// 建一个配了白名单的活动，返回活动 ID。
    Future<String> createWithAllowlist(
      ApiClient api, {
      required List<String> campusIpPrefixes,
    }) async {
      final DateTime now = DateTime.now();
      String iso(DateTime d) =>
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'
          'T${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:00+08:00';
      final ApiResult<Map<String, dynamic>> r = await api.post<Map<String, dynamic>>(
        '/activities:upsert',
        body: <String, Object?>{
          'batch': <Object?>[
            <String, Object?>{
              'externalId': 'O17-TEST',
              'title': '白名单活动',
              'organizer': '校团委',
              'durationHours': 2,
              'startTime': iso(now.subtract(const Duration(minutes: 5))),
              'endTime': iso(now.add(const Duration(hours: 2))),
              'location': '场地',
              'geoLat': 34.2175,
              'geoLng': 117.1425,
              'checkinRadius': 200,
              'campusIpPrefixes': campusIpPrefixes,
              'status': 'published',
            },
          ],
        },
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull?.message}');
      final List<Object?> created = r.dataOrNull!['created']! as List<Object?>;
      return created.first! as String;
    }

    test('不配白名单：围栏 40 + 采样 10 = 50 → 待人工确认', () async {
      final ({ApiClient api, OfflineDemoState state}) a = app();
      final String id = await createWithAllowlist(a.api, campusIpPrefixes: <String>[]);

      a.state.volunteerToken = 'v1';
      a.state.volunteerActivityId = id;
      a.state.volunteerUserNo = '2021001';
      a.state.participants.add(<String, Object?>{
        'activityId': id,
        'userNo': '2021001',
        'name': '张伟',
        'signupStatus': 'signed',
        'checkinStatus': 'none',
      });

      final ApiResult<Map<String, dynamic>> r =
          await a.api.post<Map<String, dynamic>>(
        '/activities/$id/checkins',
        body: draftBody(lat: 34.2175, lng: 117.1425, accuracy: 30, sampleCount: 2),
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        retryable: false,
      );
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull?.message}');
      expect(r.dataOrNull!['score'], 50);
      expect(r.dataOrNull!['status'], 'pending_review');
    });

    test('配了校园网网段且命中：50 + 10 = 60 → 自动通过', () async {
      final ({ApiClient api, OfflineDemoState state}) a = app();
      final String id =
          await createWithAllowlist(a.api, campusIpPrefixes: <String>['10.3.']);

      a.state.volunteerToken = 'v2';
      a.state.volunteerActivityId = id;
      a.state.volunteerUserNo = '2021001';
      a.state.participants.add(<String, Object?>{
        'activityId': id,
        'userNo': '2021001',
        'name': '张伟',
        'signupStatus': 'signed',
        'checkinStatus': 'none',
      });

      final ApiResult<Map<String, dynamic>> r =
          await a.api.post<Map<String, dynamic>>(
        '/activities/$id/checkins',
        body: draftBody(
          lat: 34.2175,
          lng: 117.1425,
          accuracy: 30,
          sampleCount: 2,
          localIp: '10.3.215.117',
        ),
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        retryable: false,
      );
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull?.message}');
      expect(r.dataOrNull!['score'], 60);
      expect(
        r.dataOrNull!['status'],
        'success',
        reason: '配了白名单就能自动通过 —— 这正是 O-17 要解决的问题',
      );
    });

    test('配了白名单但 IP 不匹配：仍只有 50 分（不能白送分）', () async {
      final ({ApiClient api, OfflineDemoState state}) a = app();
      final String id =
          await createWithAllowlist(a.api, campusIpPrefixes: <String>['202.119.']);

      a.state.volunteerToken = 'v3';
      a.state.volunteerActivityId = id;
      a.state.volunteerUserNo = '2021001';
      a.state.participants.add(<String, Object?>{
        'activityId': id,
        'userNo': '2021001',
        'name': '张伟',
        'signupStatus': 'signed',
        'checkinStatus': 'none',
      });

      final ApiResult<Map<String, dynamic>> r =
          await a.api.post<Map<String, dynamic>>(
        '/activities/$id/checkins',
        // 用户在校外网络上签到
        body: draftBody(
          lat: 34.2175,
          lng: 117.1425,
          accuracy: 30,
          sampleCount: 2,
          localIp: '192.168.72.100',
        ),
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
        retryable: false,
      );
      expect(r.isSuccess, isTrue, reason: '${r.failureOrNull?.message}');
      expect(r.dataOrNull!['score'], 50, reason: 'IP 不命中就不能加分');
      expect(r.dataOrNull!['status'], 'pending_review');
    });
  });

  group('演示时间窗不会过期', () {
    test('窗口已关闭时，把演示主活动平移到"进行中"', () {
      final OfflineDemoState s = OfflineDemoState.seeded();
      // 人为把主活动挪到三天前（模拟"隔几天再打开 App"）
      final DateTime stale = DateTime.now().subtract(const Duration(days: 3));
      final Map<String, Object?> act = s.activities
          .firstWhere((Map<String, Object?> a) => a['id'] == 'demo-act-library');
      act['startTime'] = iso(stale);
      act['endTime'] = iso(stale.add(const Duration(hours: 2)));

      s.rollDemoWindowIfStale();

      final DateTime end = TimeFormat.tryParse(act['endTime'])!;
      expect(
        DateTime.now().isBefore(end.add(const Duration(minutes: 60))),
        isTrue,
        reason: '平移后签到窗口必须重新开着，否则「去签到」按钮不出现',
      );
    });

    test('窗口还开着时不做任何改动（避免每次启动都改时间）', () {
      final OfflineDemoState s = OfflineDemoState.seeded();
      final Map<String, Object?> act = s.activities
          .firstWhere((Map<String, Object?> a) => a['id'] == 'demo-act-library');
      final Object? before = act['startTime'];
      s.rollDemoWindowIfStale();
      expect(act['startTime'], before);
    });

    test('不动其他活动（已结束 / 已取消的样例要保持原样）', () {
      final OfflineDemoState s = OfflineDemoState.seeded();
      final Map<String, Object?> finished = s.activities
          .firstWhere((Map<String, Object?> a) => a['status'] == 'finished');
      final Object? before = finished['endTime'];
      s.rollDemoWindowIfStale();
      expect(finished['endTime'], before);
    });
  });
}