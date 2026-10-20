import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_core/shared_core.dart';
import 'package:test/test.dart';

/// 离线队列测试。
///
/// 这里的断言直接对应**验收用例 A15 与 A23**：
///   * A23 —— 幂等键在重传之间复用，不产生重复记录；
///   * A15 —— 补传期间**不得显示"成功"**，只有服务端响应才算成功。

/// 可编程的假客户端。
class FakeClient extends http.BaseClient {
  FakeClient(this.handler);

  final Future<http.Response> Function(int callIndex, http.BaseRequest req, String body) handler;

  final List<({String method, String path, Map<String, String> headers, String body})> sent =
      <({String method, String path, Map<String, String> headers, String body})>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final String body = request is http.Request ? request.body : '';
    final int index = sent.length;
    sent.add((
      method: request.method,
      path: request.url.path,
      headers: request.headers,
      body: body,
    ));
    final http.Response response = await handler(index, request, body);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

http.Response okCheckin(String id) => http.Response(
      jsonEncode(<String, dynamic>{
        'code': 0,
        'message': '成功',
        'data': <String, dynamic>{
          'checkin': <String, dynamic>{
            'id': id,
            'activityId': 'act-1',
            'method': 'gps',
            'status': 'pending_review',
            'reason': '离线补传：已过签到时段，转人工确认',
            'offlineBackfill': true,
          },
        },
        'errors': <Object?>[],
        'traceId': 't1',
        'serverTime': '2026-10-16T15:30:00+08:00',
      }),
      200,
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
    );

http.Response okAttendance() => http.Response(
      jsonEncode(<String, dynamic>{
        'code': 0,
        'message': '成功',
        'data': <String, dynamic>{'task': <String, dynamic>{'id': 't1', 'status': 'done'}},
        'errors': <Object?>[],
        'serverTime': '2026-10-16T15:30:00+08:00',
      }),
      200,
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
    );

http.Response serverError() => http.Response(
      jsonEncode(<String, dynamic>{
        'code': 50001,
        'message': '服务暂时不可用，请稍后重试',
        'data': null,
        'errors': <Object?>[],
      }),
      500,
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
    );

http.Response rejected(int code, String message, {int status = 403}) => http.Response(
      jsonEncode(<String, dynamic>{
        'code': code,
        'message': message,
        'data': null,
        'errors': <Object?>[],
      }),
      status,
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
    );

/// 造一份签到证据。
CheckinDraft draft({String? key, bool backfill = false}) => CheckinDraft(
      activityId: 'act-1',
      idempotencyKey: key ?? 'key-preset',
      samples: <CheckinSample>[
        CheckinSample(
          point: const GeoPoint(lat: 34.21755, lng: 117.14255),
          accuracy: 12,
          capturedAt: DateTime(2026, 10, 16, 9, 0),
        ),
      ],
      clientTime: DateTime(2026, 10, 16, 9, 0),
      method: CheckinMethod.geo,
      enqueuedAt: DateTime(2026, 10, 16, 9, 0),
      isBackfill: backfill,
    );

/// 零延迟等待器（测试里不真的等）。
Future<void> noWait(Duration d) async {}

void main() {
  group('入队与持久化', () {
    /*
      队列变更必须通知宿主落盘（真机回归）。

      ## 为什么这条测试必须存在

      `OfflineQueue` 一直是**纯内存**的：`persist()` / `restore()` 都实现了，
      但宿主从来没调用过。于是用户离线签到、界面写着「已保存到本机」，
      随手划掉 App 之后证据就没了 —— 而他以为已经交上去了。

      虚假的成功提示比直接报错更糟：报错会让人补救，假成功不会。

      现在队列在每次内容变更后调用 `onChanged`，宿主借此落盘。
      这条测试锁住"变更一定通知"，避免以后新增变更方法时漏掉。
    */
    test('任何队列变更都要触发 onChanged（宿主据此落盘）', () {
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x')),
        waiter: noWait,
      );
      int notified = 0;
      q.onChanged = () => notified += 1;

      q.enqueueCheckin(activityId: 'act-1', draft: draft());
      expect(notified, 1, reason: '入队签到应立即通知落盘');

      q.enqueueAttendance(
        activityId: 'act-1',
        taskId: 'task-1',
        point: const GeoPoint(lat: 34.2, lng: 117.1),
        accuracy: 20,
        respondedAt: DateTime(2026, 10, 16, 9, 5),
      );
      expect(notified, 2, reason: '入队在岗响应也应通知');

      final String id = q.tasks.first.id;
      q.remove(id);
      expect(notified, 3, reason: '移除任务要通知（否则下次启动会重复撞幂等键）');

      q.clearFor('act-1');
      expect(notified, 4, reason: '按活动清空要通知');

      q.clear();
      expect(notified, 5, reason: '全清要通知');
    });

    test('persist → restore 往返后队列内容一致（含幂等键）', () {
      final OfflineQueue a = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x')),
        waiter: noWait,
      );
      a.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'k-1'));
      final String raw = a.persist();

      final OfflineQueue b = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x')),
        waiter: noWait,
      );
      expect(b.restore(raw), isTrue);
      expect(b.length, 1);
      expect(b.tasks.single.idempotencyKey, 'k-1');
      expect(b.outstandingCountFor('act-1'), 1);
    });

    test('入队后队列长度与待同步数正确', () {
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x')),
        waiter: noWait,
      );
      expect(q.isEmpty, isTrue);
      expect(q.outstandingCount, 0);

      q.enqueueCheckin(activityId: 'act-1', draft: draft());
      expect(q.length, 1);
      expect(q.outstandingCount, 1);
      expect(q.tasks.single.syncState, SyncState.pending);
    });

    test('入队时保留 draft 自带的幂等键（不在入队时重算）', () {
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x')),
        waiter: noWait,
      );
      final QueuedCheckin t =
          q.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'my-key'));
      expect(t.idempotencyKey, 'my-key');
    });

    test('draft 没有幂等键时生成一个', () {
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x')),
        waiter: noWait,
      );
      final QueuedCheckin t =
          q.enqueueCheckin(activityId: 'act-1', draft: draft(key: ''));
      expect(t.idempotencyKey, isNotEmpty);
    });

    test('persist → restore 往返保持任务与幂等键', () {
      final OfflineQueue q1 = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x')),
        waiter: noWait,
      );
      q1.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'k-1'));
      q1.enqueueAttendance(
        activityId: 'act-1',
        taskId: 'task-9',
        point: const GeoPoint(lat: 34.2, lng: 117.1),
        accuracy: 15,
        respondedAt: DateTime(2026, 10, 16, 9, 30),
      );
      final String blob = q1.persist();

      final OfflineQueue q2 = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x')),
        waiter: noWait,
      );
      expect(q2.restore(blob), isTrue);
      expect(q2.length, 2);

      final QueuedCheckin restored = q2.tasks.whereType<QueuedCheckin>().single;
      expect(restored.idempotencyKey, 'k-1');
      // 采样序列必须原样保留：补传时要让服务端重新判定，
      // 只存"结论"或只存数量都会让反作弊判据失效。
      expect(restored.draft.samples.length, 1);
      expect(restored.draft.samples.single.accuracy, 12);

      final QueuedAttendanceResponse att =
          q2.tasks.whereType<QueuedAttendanceResponse>().single;
      expect(att.taskId, 'task-9');
      expect(att.accuracy, 15);
      expect(att.point.lat, 34.2);
    });

    test('restore 遇到损坏数据不抛异常，保持空队列', () {
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x')),
        waiter: noWait,
      );
      expect(q.restore('{不是合法 json'), isFalse);
      expect(q.isEmpty, isTrue);
      expect(q.restore(null), isFalse);
      expect(q.restore(''), isFalse);
    });

    test('restore 把 syncing 降回 pending（上次进程被杀时请求结局未知）', () {
      final String blob = jsonEncode(<String, dynamic>{
        'seq': 1,
        'tasks': <Object?>[
          <String, dynamic>{
            'kind': 'checkin',
            'id': 'q1',
            'activityId': 'act-1',
            'idempotencyKey': 'k',
            'enqueuedAt': '2026-10-16T09:00:00+08:00',
            'attempts': 1,
            'syncState': 'syncing',
            'draft': draft(key: 'k').toJson(),
          },
        ],
      });
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x')),
        waiter: noWait,
      );
      expect(q.restore(blob), isTrue);
      expect(
        q.tasks.single.syncState,
        SyncState.pending,
        reason: 'syncing 是"发送中"的临时态，重启后必须重走（幂等键保证不重复记录）',
      );
    });

    test('clearFor 只清指定活动', () {
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x')),
        waiter: noWait,
      );
      q.enqueueCheckin(activityId: 'act-1', draft: draft());
      q.enqueueCheckin(activityId: 'act-2', draft: draft());
      q.clearFor('act-1');
      expect(q.length, 1);
      expect(q.tasks.single.activityId, 'act-2');
    });
  });

  group('补传成功路径（验收 A15 / A23）', () {
    test('补传成功后从队列移除，并返回服务端记录', () async {
      final FakeClient fake = FakeClient((_, __, ___) async => okCheckin('chk-1'));
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x'), httpClient: fake),
        waiter: noWait,
      );
      q.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'k-1'));

      final FlushReport report = await q.flush();
      expect(report.attempted, 1);
      expect(report.succeeded, 1);
      expect(report.failed, 0);
      expect(q.isEmpty, isTrue);
      expect(report.results.values.single.id, 'chk-1');
    });

    test('补传请求带 offlineBackfill: true（服务端据此转人工，方案 §6.4）', () async {
      final FakeClient fake = FakeClient((_, __, ___) async => okCheckin('chk-1'));
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x'), httpClient: fake),
        waiter: noWait,
      );
      q.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'k-1'));
      await q.flush();

      final Map<String, dynamic> body =
          jsonDecode(fake.sent.single.body) as Map<String, dynamic>;
      expect(body['offlineBackfill'], isTrue);
      expect(body['idempotencyKey'], 'k-1');
    });

    test('验收 A23：重传复用同一幂等键，不产生新键', () async {
      // 第一次 500（可重试），第二次成功 —— 两次必须带同一个幂等键。
      final FakeClient fake = FakeClient((int i, _, __) async =>
          i == 0 ? serverError() : okCheckin('chk-1'));
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x'), httpClient: fake),
        waiter: noWait,
      );
      q.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'stable-key'));

      // 第一次补传：服务端 500，任务留在队列
      await q.flush();
      expect(q.length, 1);
      expect(q.tasks.single.syncState, SyncState.failed);
      expect(q.tasks.single.idempotencyKey, 'stable-key');

      // 第二次补传：成功
      final FlushReport second = await q.flush();
      expect(second.succeeded, 1);
      expect(q.isEmpty, isTrue);

      // 两次请求的幂等键必须一致
      expect(fake.sent.length, 2);
      expect(fake.sent[0].headers['X-Idempotency-Key'], 'stable-key');
      expect(
        fake.sent[1].headers['X-Idempotency-Key'],
        'stable-key',
        reason: '每次重试现算新键 = 每次都是新请求 = 服务端产生多条记录（验收 A23 会抓到）',
      );
    });

    test('验收 A15：补传成功前不得视为已完成（队列状态不含"成功"）', () async {
      final FakeClient fake = FakeClient((_, __, ___) async => serverError());
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x'), httpClient: fake),
        waiter: noWait,
      );
      q.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'k'));

      await q.flush();
      // 服务端没给终态，任务必须留在队列里，状态不是 synced
      expect(q.length, 1);
      expect(q.tasks.single.syncState, isNot(SyncState.synced));
      expect(q.tasks.single.syncState.isOutstanding, isTrue);
    });
  });

  group('补传失败路径', () {
    test('离线时任务留在队列，状态回到 pending 并给出原因', () async {
      final FakeClient fake = FakeClient((_, __, ___) async => throw const _Offline());
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x'), httpClient: fake),
        waiter: noWait,
      );
      q.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'k'));

      final FlushReport report = await q.flush();
      expect(report.stillOffline, 1);
      expect(q.length, 1);
      final QueuedTask t = q.tasks.single;
      expect(t.syncState, SyncState.pending);
      expect(t.lastError, contains('离线'));
    });

    test('离线时后面的任务不再尝试（避免无意义的连续超时）', () async {
      final FakeClient fake = FakeClient((_, __, ___) async => throw const _Offline());
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x'), httpClient: fake),
        waiter: noWait,
      );
      q.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'k1'));
      q.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'k2'));
      q.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'k3'));

      await q.flush();
      expect(fake.sent.length, 1, reason: '第一条就确认离线了，不必再试后两条');
      expect(q.length, 3, reason: '但三条都必须留在队列里，不能丢');
    });

    test('业务性拒绝（不在名单）从队列摘除，不留死记录', () async {
      final FakeClient fake = FakeClient(
        (_, __, ___) async => rejected(20005, '你不在本次活动名单中'),
      );
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x'), httpClient: fake),
        waiter: noWait,
      );
      q.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'k'));

      final FlushReport report = await q.flush();
      expect(report.failed, 1);
      expect(q.isEmpty, isTrue, reason: '业务性拒绝重试没有意义，留着会永远堵住队列');
    });

    test('已签到的重复提交按"目的已达成"处理并摘除', () async {
      final FakeClient fake = FakeClient(
        (_, __, ___) async => rejected(30004, '你已完成签到', status: 409),
      );
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x'), httpClient: fake),
        waiter: noWait,
      );
      q.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'k'));
      final FlushReport report = await q.flush();
      expect(report.failed, 1);
      expect(q.isEmpty, isTrue);
    });

    test('重试次数用尽后不再自动重试，但**保留本地数据**', () async {
      final FakeClient fake = FakeClient((_, __, ___) async => serverError());
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x'), httpClient: fake),
        waiter: noWait,
      );
      q.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'k'));

      // 反复 flush，累计尝试次数会到上限
      for (int i = 0; i < 8; i++) {
        await q.flush();
      }
      final QueuedTask t = q.tasks.single;
      expect(t.isExhausted, isTrue);
      expect(q.length, 1, reason: '方案 §9 要求"不丢弃本地数据"');
      expect(t.attempts, greaterThanOrEqualTo(ContractDefaults.retryBackoff.length + 1));
    });

    test('onlyActivityId 限制只补传指定活动', () async {
      final FakeClient fake = FakeClient((_, __, ___) async => okCheckin('c'));
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x'), httpClient: fake),
        waiter: noWait,
      );
      q.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'k1'));
      q.enqueueCheckin(activityId: 'act-2', draft: draft(key: 'k2'));

      final FlushReport report = await q.flush(onlyActivityId: 'act-1');
      expect(report.attempted, 1);
      expect(q.length, 1);
      expect(q.tasks.single.activityId, 'act-2');
    });

    test('outstandingCountFor 只数指定活动的待同步数（驱动角标）', () {
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x')),
        waiter: noWait,
      );
      q.enqueueCheckin(activityId: 'act-1', draft: draft());
      q.enqueueCheckin(activityId: 'act-1', draft: draft());
      q.enqueueCheckin(activityId: 'act-2', draft: draft());
      expect(q.outstandingCountFor('act-1'), 2);
      expect(q.outstandingCountFor('act-2'), 1);
      expect(q.outstandingCountFor('act-3'), 0);
    });
  });

  group('在岗响应补传（网页 §6.4.6：全局资源路径）', () {
    test('在岗确认走 /attendances/{taskId}:confirm，不挂在活动下', () async {
      final FakeClient fake = FakeClient((_, __, ___) async => okAttendance());
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x'), httpClient: fake),
        waiter: noWait,
      );
      q.enqueueAttendance(
        activityId: 'act-1',
        taskId: 'task-7',
        point: const GeoPoint(lat: 34.2, lng: 117.1),
        accuracy: 20,
        respondedAt: DateTime(2026, 10, 16, 9, 30),
      );
      final FlushReport report = await q.flush();
      expect(report.succeeded, 1);
      // ⚠️ 契约是全局资源路径：确认动作的主体是"某次抽查任务"而不是"某活动"。
      expect(
        fake.sent.single.path,
        '/attendances/task-7:confirm',
        reason: '早期实现挂在 /activities/{id}/attendance/tasks/{tid}/respond，已按契约改正',
      );

      final Map<String, dynamic> body =
          jsonDecode(fake.sent.single.body) as Map<String, dynamic>;
      // 零输入：请求体里只有自动采集的证据，没有任何需要用户填写的字段
      expect(body.keys.toSet(), <String>{'method', 'location', 'device'});
      expect(body['method'], 'geo');
      final Map<String, dynamic> loc = body['location'] as Map<String, dynamic>;
      expect(loc['lat'], 34.2);
      expect(loc['lng'], 117.1);
      expect(loc['accuracy'], 20);
    });

    test('在岗响应携带模拟定位标记，且放在 device 节点里（服务端据此转人工）', () async {
      final FakeClient fake = FakeClient((_, __, ___) async => okAttendance());
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x'), httpClient: fake),
        waiter: noWait,
      );
      q.enqueueAttendance(
        activityId: 'act-1',
        taskId: 't1',
        point: const GeoPoint(lat: 34.2, lng: 117.1),
        accuracy: 10,
        respondedAt: DateTime(2026, 10, 16, 9, 30),
        mockLocationDetected: true,
      );
      await q.flush();
      final Map<String, dynamic> body =
          jsonDecode(fake.sent.single.body) as Map<String, dynamic>;
      // 契约把设备证据收在 device 节点下。
      expect((body['device'] as Map<String, dynamic>)['mockLocationDetected'], isTrue);
    });
  });

  group('flushWithBackoff', () {
    test('离线时按退避重试，联网后成功', () async {
      // 前两次离线，第三次成功
      final FakeClient fake = FakeClient((int i, _, __) async {
        if (i < 2) {
          throw const _Offline();
        }
        return okCheckin('chk-ok');
      });
      final List<Duration> waits = <Duration>[];
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x'), httpClient: fake),
        waiter: (Duration d) async => waits.add(d),
      );
      q.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'k'));

      final FlushReport report = await q.flushWithBackoff(rounds: 4);
      expect(report.succeeded, 1);
      expect(q.isEmpty, isTrue);
      expect(waits, isNotEmpty, reason: '应实际等待过，而不是忙等');
    });

    test('始终离线时不会无限循环', () async {
      final FakeClient fake = FakeClient((_, __, ___) async => throw const _Offline());
      final OfflineQueue q = OfflineQueue(
        client: ApiClient(config: const ApiConfig(baseUrl: 'http://x'), httpClient: fake),
        waiter: noWait,
      );
      q.enqueueCheckin(activityId: 'act-1', draft: draft(key: 'k'));
      final FlushReport report = await q.flushWithBackoff(rounds: 3);
      expect(report.stillOffline, greaterThanOrEqualTo(1));
      expect(q.length, 1);
    });
  });
}

/// 模拟网络不可达。
class _Offline implements Exception {
  const _Offline();

  @override
  String toString() => 'SocketException: 网络不可达';
}
