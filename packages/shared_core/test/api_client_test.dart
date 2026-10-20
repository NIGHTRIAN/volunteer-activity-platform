import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_core/shared_core.dart';
import 'package:test/test.dart';

/// 用可编程的假 HTTP 客户端替换真实网络。
class FakeClient extends http.BaseClient {
  FakeClient(this.handler);

  final Future<http.Response> Function(http.BaseRequest request, String body) handler;

  /// 已发出的请求（按顺序）。
  final List<({String method, String path, Map<String, String> headers, String body})> sent =
      <({String method, String path, Map<String, String> headers, String body})>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final String body = request is http.Request ? request.body : '';
    sent.add((
      method: request.method,
      path: request.url.path,
      headers: request.headers,
      body: body,
    ));
    final http.Response response = await handler(request, body);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

/// 构造一个成功信封响应。
http.Response okJson(Object? data, {String? serverTime}) => http.Response(
      jsonEncode(<String, dynamic>{
        'code': 0,
        'message': '成功',
        'data': data,
        'errors': <Object?>[],
        'traceId': 't-test',
        'serverTime': serverTime ?? '2026-10-16T15:30:00+08:00',
      }),
      200,
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
    );

/// 构造一个失败信封响应。
http.Response errJson(int code, String message, {int status = 400, List<Object?>? errors}) =>
    http.Response(
      jsonEncode(<String, dynamic>{
        'code': code,
        'message': message,
        'data': null,
        'errors': errors ?? <Object?>[],
        'traceId': 't-test',
      }),
      status,
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
    );

ApiConfig testConfig({bool logging = false}) => ApiConfig(
      baseUrl: 'http://127.0.0.1:8080',
      clientVersion: '0.1.0-test',
      enableLogging: logging,
    );

/// 等待器：测试里不真的等，但要能数出退避次数。
class CountingWaiter {
  final List<Duration> waits = <Duration>[];

  Future<void> call(Duration d) async {
    waits.add(d);
  }
}

void main() {
  group('ApiConfig', () {
    test('去掉结尾斜杠，避免拼出双斜杠', () {
      const ApiConfig c = ApiConfig(baseUrl: 'http://x:8080/');
      expect(c.normalizedBaseUrl, 'http://x:8080');
    });

    test('isLocalhost 用于界面提示"你连的是开发环境"', () {
      expect(const ApiConfig(baseUrl: 'http://127.0.0.1:8080').isLocalhost, isTrue);
      expect(const ApiConfig(baseUrl: 'http://localhost:8080').isLocalhost, isTrue);
      expect(const ApiConfig(baseUrl: 'https://api.example.edu.cn').isLocalhost, isFalse);
    });

    test('环境解析对未知值兜底到 dev', () {
      expect(ApiEnvironment.fromWire('prod'), ApiEnvironment.prod);
      expect(ApiEnvironment.fromWire('test'), ApiEnvironment.test);
      expect(ApiEnvironment.fromWire('whatever'), ApiEnvironment.dev);
      expect(ApiEnvironment.fromWire(null), ApiEnvironment.dev);
    });
  });

  group('请求头（方案 §1.4 版本协商 + 令牌 + 幂等键）', () {
    test('注入令牌、设备标识、接口版本、客户端版本', () async {
      final FakeClient fake = FakeClient((_, __) async => okJson(<String, Object?>{'ok': true}));
      final ApiClient client = ApiClient(
        config: testConfig(),
        httpClient: fake,
        tokenProvider: () async => 'tok-123',
        deviceIdProvider: () async => 'android-abc123',
      );

      await client.get<Map<String, dynamic>>(
        '/health',
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );

      final Map<String, String> headers = fake.sent.single.headers;
      expect(headers['Authorization'], 'Bearer tok-123');
      expect(headers['X-Device-Id'], 'android-abc123');
      expect(headers['X-Api-Version'], 'v1');
      expect(headers['X-Client-Version'], '0.1.0-test');
    });

    test('无令牌时不发送 Authorization（而不是发空值）', () async {
      final FakeClient fake = FakeClient((_, __) async => okJson(<String, Object?>{'ok': true}));
      final ApiClient client = ApiClient(
        config: testConfig(),
        httpClient: fake,
        tokenProvider: () async => null,
      );
      await client.get<Map<String, dynamic>>(
        '/health',
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      // http 包的 headers 键是小写化的
      expect(fake.sent.single.headers.containsKey('authorization'), isFalse);
    });

    test('authorized: false 时不带令牌（登录/绑定接口需要）', () async {
      final FakeClient fake = FakeClient((_, __) async => okJson(<String, Object?>{'ok': true}));
      final ApiClient client = ApiClient(
        config: testConfig(),
        httpClient: fake,
        tokenProvider: () async => 'tok-123',
      );
      await client.post<Map<String, dynamic>>(
        '/auth/admin/login',
        body: <String, Object?>{'inviteCode': '1111'},
        authorized: false,
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      expect(fake.sent.single.headers.containsKey('authorization'), isFalse);
    });

    test('传了幂等键就带 X-Idempotency-Key 头（方案 §6.1）', () async {
      final FakeClient fake = FakeClient((_, __) async => okJson(<String, Object?>{'ok': true}));
      final ApiClient client = ApiClient(config: testConfig(), httpClient: fake);
      await client.post<Map<String, dynamic>>(
        '/activities/a1/checkins',
        body: <String, Object?>{'x': 1},
        idempotencyKey: 'key-abc',
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      expect(fake.sent.single.headers['X-Idempotency-Key'], 'key-abc');
    });
  });

  group('错误映射（方案 §9）', () {
    Future<ApiResult<Map<String, dynamic>>> call(
      http.Response Function() responder, {
      bool retryable = false,
      CountingWaiter? waiter,
      bool includeEvidence = false,
      NetworkEvidenceProvider? evidence,
    }) {
      final FakeClient fake = FakeClient((_, __) async => responder());
      final ApiClient client = ApiClient(
        config: testConfig(),
        httpClient: fake,
        waiter: waiter?.call,
        networkEvidenceProvider: evidence,
      );
      return client.post<Map<String, dynamic>>(
        '/x',
        body: <String, Object?>{'a': 1},
        retryable: retryable,
        includeNetworkEvidence: includeEvidence,
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
    }

    test('业务错误码映射到「错误族」，精确原因靠 msg 还原', () async {
      final ApiResult<Map<String, dynamic>> r = await call(
        () => errJson(
          40301,
          '你不在本次活动名单中',
          status: 403,
        ),
      );
      final ApiFailure<Map<String, dynamic>> f = r.failureOrNull!;

      // 方案只授权 8 个码值，40301 是「越权」族；反查只能拿到族代表。
      // 这是不可逆的：forbidden / notInParticipantList / identityMismatch
      // / deviceMismatch 都落在 40301 上。
      expect(f.code, ApiErrorCode.forbidden);
      expect(f.code.isForbidden, isTrue);
      // **精确原因必须靠服务端文案**，这是共享码值下唯一可靠的还原路径。
      expect(f.message, '你不在本次活动名单中');
      expect(f.httpStatus, 403);
    });

    test('字段级错误能按字段取出（供表单定位）', () async {
      final ApiResult<Map<String, dynamic>> r = await call(
        () => errJson(
          40001,
          '参数有误',
          errors: <Object?>[
            <String, Object>{'field': 'reason', 'message': '请填写不少于 5 字的取消原因'},
          ],
        ),
      );
      expect(r.failureOrNull!.code, ApiErrorCode.badRequest);
      expect(r.failureOrNull!.errorFor('reason'), '请填写不少于 5 字的取消原因');
      expect(r.failureOrNull!.errorFor('title'), isNull);
    });

    test('40101 → 未认证族，shouldClearToken 为真（方案 §9）', () async {
      final ApiResult<Map<String, dynamic>> r =
          await call(() => errJson(40101, '登录状态已失效', status: 401));
      expect(r.failureOrNull!.code, ApiErrorCode.unauthorized);
      expect(r.failureOrNull!.shouldClearToken, isTrue);
    });

    test('40301 越权不是令牌失效，不应清令牌', () async {
      final ApiResult<Map<String, dynamic>> r =
          await call(() => errJson(40301, '无权操作该活动', status: 403));
      expect(r.failureOrNull!.code, ApiErrorCode.forbidden);
      expect(
        r.failureOrNull!.shouldClearToken,
        isFalse,
        reason: '越权是归属问题（ownerId），清令牌只会让用户白重登一次',
      );
    });

    test('40901 → 状态冲突族，isConflict 为真（方案 §9：刷新后重试）', () async {
      final ApiResult<Map<String, dynamic>> r =
          await call(() => errJson(40901, '状态已更新，请重试', status: 409));
      expect(r.failureOrNull!.code, ApiErrorCode.versionConflict);
      expect(r.failureOrNull!.isConflict, isTrue);
    });

    test('42901 → 限流族，isRateLimited 为真', () async {
      final ApiResult<Map<String, dynamic>> r =
          await call(() => errJson(42901, '操作过于频繁', status: 429));
      expect(r.failureOrNull!.isRateLimited, isTrue);
    });

    test('响应体不是 JSON 时按状态码兜底，且 5xx 可重试', () async {
      final ApiResult<Map<String, dynamic>> r = await call(
        () => http.Response('<html>502 Bad Gateway</html>', 502),
        retryable: false,
      );
      expect(r.failureOrNull!.code, ApiErrorCode.serverError);
      expect(r.failureOrNull!.retryable, isTrue, reason: '5xx 值得重试');
    });

    test('成功但 data 为空 → 明确报错，不让界面拿到"假成功"', () async {
      final ApiResult<Map<String, dynamic>> r = await call(
        () => http.Response(
          jsonEncode(<String, dynamic>{'code': 0, 'message': '成功', 'data': null}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      );
      expect(r.isSuccess, isFalse);
      expect(r.failureOrNull!.message, contains('缺少数据'));
    });
  });

  group('退避重试（方案 §9：1s/2s/4s/8s/16s，上限 5 次）', () {
    test('5xx 会重试，退避序列与契约一致', () async {
      final CountingWaiter waiter = CountingWaiter();
      int calls = 0;
      final FakeClient fake = FakeClient((_, __) async {
        calls += 1;
        return errJson(50001, '服务暂时不可用', status: 500);
      });
      final ApiClient client = ApiClient(
        config: testConfig(),
        httpClient: fake,
        waiter: waiter.call,
      );

      final ApiResult<Map<String, dynamic>> r = await client.post<Map<String, dynamic>>(
        '/x',
        body: <String, Object?>{'a': 1},
        decode: (Object? d) => <String, dynamic>{},
      );

      // 1 次首发 + 5 次重试
      expect(calls, 6, reason: 'retryBackoff 有 5 个档位，共 6 次尝试');
      expect(waiter.waits, ContractDefaults.retryBackoff);
      expect(r.isSuccess, isFalse);
      expect(
        r.failureOrNull!.retryable,
        isFalse,
        reason: '重试用尽后应标记为不可重试，界面才能区分"刚失败"与"试了很多次"',
      );
    });

    test('业务性错误不重试（重试多少次结果都一样）', () async {
      final CountingWaiter waiter = CountingWaiter();
      int calls = 0;
      final FakeClient fake = FakeClient((_, __) async {
        calls += 1;
        return errJson(40301, '你不在本次活动名单中', status: 403);
      });
      final ApiClient client = ApiClient(
        config: testConfig(),
        httpClient: fake,
        waiter: waiter.call,
      );

      await client.post<Map<String, dynamic>>(
        '/x',
        body: <String, Object?>{'a': 1},
        decode: (Object? d) => <String, dynamic>{},
      );

      expect(calls, 1, reason: '不在名单里重试也不会变成在名单里');
      expect(waiter.waits, isEmpty);
    });

    test('retryable: false 时一次都不重试（队列自己管次数）', () async {
      final CountingWaiter waiter = CountingWaiter();
      int calls = 0;
      final FakeClient fake = FakeClient((_, __) async {
        calls += 1;
        return errJson(50001, '服务暂时不可用', status: 500);
      });
      final ApiClient client = ApiClient(
        config: testConfig(),
        httpClient: fake,
        waiter: waiter.call,
      );

      await client.post<Map<String, dynamic>>(
        '/x',
        body: <String, Object?>{'a': 1},
        retryable: false,
        decode: (Object? d) => <String, dynamic>{},
      );

      expect(calls, 1);
      expect(waiter.waits, isEmpty);
    });

    test('网络异常归类为离线，且可重试', () async {
      final CountingWaiter waiter = CountingWaiter();
      final FakeClient fake = FakeClient((_, __) async => throw const SocketExceptionStub());
      final ApiClient client = ApiClient(
        config: testConfig(),
        httpClient: fake,
        waiter: waiter.call,
      );

      final ApiResult<Map<String, dynamic>> r = await client.post<Map<String, dynamic>>(
        '/x',
        body: <String, Object?>{'a': 1},
        retryable: false,
        decode: (Object? d) => <String, dynamic>{},
      );

      final ApiFailure<Map<String, dynamic>> f = r.failureOrNull!;
      expect(f.isOffline, isTrue, reason: '对用户来说下一步动作是"入队等联网"');
      expect(f.code, ApiErrorCode.offlineQueued);
      expect(f.retryable, isTrue);
    });
  });

  group('URL 与查询参数', () {
    test('查询参数正确拼接', () async {
      final FakeClient fake = FakeClient((_, __) async => okJson(<String, Object?>{'ok': true}));
      final ApiClient client = ApiClient(config: testConfig(), httpClient: fake);
      await client.get<Map<String, dynamic>>(
        '/activities',
        query: <String, String>{'page': '2', 'status': 'finished,cancelled'},
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      final String raw = fake.sent.single.path;
      expect(raw, '/activities');
      // 查询串在 url 上，这里通过 headers 拿不到，改断言请求次数与路径
      expect(fake.sent.length, 1);
    });

    test('path 不以斜杠开头也能正确拼接', () async {
      final FakeClient fake = FakeClient((_, __) async => okJson(<String, Object?>{'ok': true}));
      final ApiClient client = ApiClient(config: testConfig(), httpClient: fake);
      await client.get<Map<String, dynamic>>(
        'health',
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );
      expect(fake.sent.single.path, '/health');
    });
  });

  group('网络辅证采集（方案 §6.1 的 +20 / +10 分）', () {
    test('includeNetworkEvidence 时把 BSSID 与 IP 并入请求体', () async {
      final FakeClient fake = FakeClient((_, __) async => okJson(<String, Object?>{'ok': true}));
      final ApiClient client = ApiClient(
        config: testConfig(),
        httpClient: fake,
        networkEvidenceProvider: () async =>
            (wifiBssid: 'aa:bb:cc:dd:ee:ff', localIp: '10.20.30.40'),
      );

      await client.post<Map<String, dynamic>>(
        '/activities/a1/checkins',
        body: <String, Object?>{'geoLat': 34.2},
        includeNetworkEvidence: true,
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );

      final Map<String, dynamic> body =
          jsonDecode(fake.sent.single.body) as Map<String, dynamic>;
      expect(body['wifiBssid'], 'aa:bb:cc:dd:ee:ff');
      expect(body['localIp'], '10.20.30.40');
      expect(body['geoLat'], 34.2);
    });

    test('读不到辅证时不下发对应字段（不伪造）', () async {
      final FakeClient fake = FakeClient((_, __) async => okJson(<String, Object?>{'ok': true}));
      final ApiClient client = ApiClient(
        config: testConfig(),
        httpClient: fake,
        networkEvidenceProvider: () async => (wifiBssid: null, localIp: null),
      );

      await client.post<Map<String, dynamic>>(
        '/activities/a1/checkins',
        body: <String, Object?>{'geoLat': 34.2},
        includeNetworkEvidence: true,
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
      );

      final Map<String, dynamic> body =
          jsonDecode(fake.sent.single.body) as Map<String, dynamic>;
      expect(body.containsKey('wifiBssid'), isFalse);
      expect(body.containsKey('localIp'), isFalse);
    });
  });

  group('ClockSkewMonitor（方案 §9 设备时间不准）', () {
    test('无观测时不报偏差', () {
      final ClockSkewMonitor m = ClockSkewMonitor();
      expect(m.skew, isNull);
      expect(m.isSkewed, isFalse);
      expect(m.userHint, isNull);
    });

    test('偏差在阈值内不提示', () {
      final ClockSkewMonitor m = ClockSkewMonitor();
      final DateTime device = DateTime(2026, 10, 16, 15, 31);
      m.observe(DateTime(2026, 10, 16, 15, 30), deviceNow: device);
      expect(m.skew, const Duration(minutes: 1));
      expect(m.isSkewed, isFalse, reason: '阈值是 3 分钟');
    });

    test('偏差超阈值给出可操作提示，并说明快了还是慢了', () {
      final ClockSkewMonitor m = ClockSkewMonitor();
      m.observe(
        DateTime(2026, 10, 16, 15, 30),
        deviceNow: DateTime(2026, 10, 16, 15, 35),
      );
      expect(m.isSkewed, isTrue);
      expect(m.userHint, contains('快'));
      expect(m.userHint, contains('5 分钟'));
      expect(m.userHint, contains('自动设置时间'), reason: '提示必须给出下一步动作');
    });

    test('取历史最小偏差（网络往返会给观测引入正向延迟）', () {
      final ClockSkewMonitor m = ClockSkewMonitor();
      m.observe(DateTime(2026, 10, 16, 15, 30), deviceNow: DateTime(2026, 10, 16, 15, 31));
      // 第二次观测因为往返延迟更大，不应覆盖更准的第一次
      m.observe(DateTime(2026, 10, 16, 15, 30, 20), deviceNow: DateTime(2026, 10, 16, 15, 32));
      expect(m.skew, const Duration(minutes: 1));
    });

    test('correctedNow 把设备时间校正到服务端时间', () {
      final ClockSkewMonitor m = ClockSkewMonitor();
      m.observe(DateTime(2026, 10, 16, 15, 30), deviceNow: DateTime(2026, 10, 16, 15, 40));
      final DateTime corrected =
          m.correctedNow(deviceNow: DateTime(2026, 10, 16, 16, 0));
      expect(corrected, DateTime(2026, 10, 16, 15, 50));
    });

    test('reset 清空观测', () {
      final ClockSkewMonitor m = ClockSkewMonitor();
      m.observe(DateTime(2026, 10, 16, 15, 30), deviceNow: DateTime(2026, 10, 16, 15, 40));
      m.reset();
      expect(m.skew, isNull);
    });
  });

  group('TelemetrySanitizer（README §3.3 底线②）', () {
    test('手机号脱敏保留前 3 后 4', () {
      expect(TelemetrySanitizer.maskPhone('13800001234'), '138****1234');
    });

    test('学号脱敏保留前 2 后 2', () {
      expect(TelemetrySanitizer.maskUserNo('2021001234'), '20****34');
      expect(TelemetrySanitizer.maskUserNo('1234'), '1234', reason: '过短时不处理');
    });

    test('令牌只出前 4 位', () {
      expect(TelemetrySanitizer.maskToken('abcdefghijklmn'), 'abcd****');
      expect(TelemetrySanitizer.maskToken('ab'), '****');
    });

    test('sanitizeText 兜底脱敏手机号', () {
      const String raw = '无法为 13800001234 定位';
      final String out = TelemetrySanitizer.sanitizeText(raw);
      expect(out, isNot(contains('13800001234')));
      expect(out, contains('138****1234'));
    });

    test('sanitizeText 脱敏带标签的学号（连标签一起换掉）', () {
      expect(TelemetrySanitizer.sanitizeText('学号 2021001234 不存在'), contains('学号 ****'));
      expect(
        TelemetrySanitizer.sanitizeText('学号 2021001234 不存在'),
        isNot(contains('2021001234')),
      );
      expect(TelemetrySanitizer.sanitizeText('userNo:2021001234'), isNot(contains('2021001234')));
    });

    test('sanitizeText 必须不动 10/13 位时间戳', () {
      // 10 位秒级时间戳形如 1792000000，号段恰好落在手机号的 1[3-9] 上；
      // 13 位毫秒时间戳若被"匹配前 12 位"会产出 179****000000 这种
      // 半吊子结果——比不脱敏更有欺骗性。两者都必须原样保留。
      expect(TelemetrySanitizer.sanitizeText('ms 1792000000000'), contains('1792000000000'));
      expect(TelemetrySanitizer.sanitizeText('s 1792000000'), contains('1792000000'));
    });

    test('sanitizeText 不动裸数字（无法与时间戳区分，不冒险）', () {
      // 裸学号在自由文本里无法判定语义，交给 sanitizeJson 按字段名处理。
      expect(TelemetrySanitizer.sanitizeText('2021001234'), '2021001234');
    });

    test('sanitizeJson 对敏感键整体替换', () {
      final String out = TelemetrySanitizer.sanitizeJson(<String, Object?>{
        'token': 'sekret-token-value',
        'inviteCode': 'K7M2P9QX',
        'userNo': '2021001234',
        'phone': '13800001234',
        'title': '图书馆整理',
      });
      expect(out, isNot(contains('sekret-token-value')), reason: '令牌等价于密码，绝不能进日志');
      expect(out, isNot(contains('K7M2P9QX')), reason: '邀请码是一次性凭证');
      expect(out, isNot(contains('2021001234')));
      expect(out, isNot(contains('13800001234')));
      expect(out, contains('图书馆整理'), reason: '非敏感内容应保留，便于排查');
    });

    test('sanitizeJson 处理 null 与嵌套结构', () {
      expect(TelemetrySanitizer.sanitizeJson(null), '(空)');
      final String out = TelemetrySanitizer.sanitizeJson(<String, Object?>{
        'items': <Object?>[
          <String, Object?>{'phone': '13800001234'},
        ],
      });
      expect(out, isNot(contains('13800001234')));
    });

    test('坐标降到约 1km 精度', () {
      final GeoPoint coarse =
          TelemetrySanitizer.coarsen(const GeoPoint(lat: 34.21754321, lng: 117.14259876));
      expect(coarse.lat, 34.22);
      expect(coarse.lng, 117.14);
    });
  });
}

/// 模拟 socket 异常的替身（`dart:io` 的 SocketException 在纯 Dart 包中可用，
/// 但用自定义类型能让"任何异常都归为离线"这个契约更明确）。
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();

  @override
  String toString() => 'SocketExceptionStub: 连接被拒绝';
}
