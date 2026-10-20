import 'dart:async';
import 'dart:convert';

import 'package:shared_core/src/contract/api_paths.dart';
import 'package:shared_core/src/contract/error_codes.dart';
import 'package:shared_core/src/contract/field_dictionary.dart';
import 'package:shared_core/src/contract/time_and_geo.dart';
import 'package:shared_core/src/domain/checkin.dart';
import 'package:shared_core/src/domain/enums.dart';
import 'package:shared_core/src/network/api_client.dart';

/// 队列中的待办任务。
///
/// 每一种都保存**原始证据**而不是"结论"（方案 §6.4）：
/// 补传时要让服务端重新判定，而不是把客户端的猜测当成事实。
sealed class QueuedTask {
  const QueuedTask({
    required this.id,
    required this.activityId,
    required this.idempotencyKey,
    required this.enqueuedAt,
    required this.attempts,
    this.syncState = SyncState.pending,
    this.lastError,
    this.lastAttemptAt,
  });

  /// 本地任务 ID（不是服务端 ID）。
  final String id;

  /// 所属活动。
  final String activityId;

  /// **幂等键**。入队时生成一次并持久化，重传时始终复用同一个键——
  /// 这是"重传不产生重复记录"的唯一保障（方案 §9、验收 A23）。
  final String idempotencyKey;

  /// 入队时刻。
  final DateTime enqueuedAt;

  /// 已尝试次数。
  final int attempts;

  /// 同步状态。
  final SyncState syncState;

  /// 最后一次失败的原因（脱敏后），用于界面提示。
  final String? lastError;

  /// 最后一次尝试时刻。
  final DateTime? lastAttemptAt;

  /// 队列内排序用的键（入队顺序）。
  String get sortKey => enqueuedAt.toIso8601String() + id;

  /// 是否已用尽重试。
  bool get isExhausted => attempts >= ContractDefaults.retryBackoff.length + 1;

  /// 序列化为可持久化的 JSON。
  Map<String, dynamic> toJson();

  QueuedTask withAttempt({required SyncState state, String? error, DateTime? at});
}

/// 待补传的签到证据。
class QueuedCheckin extends QueuedTask {
  const QueuedCheckin({
    required super.id,
    required super.activityId,
    required super.idempotencyKey,
    required super.enqueuedAt,
    required super.attempts,
    required this.draft,
    super.syncState,
    super.lastError,
    super.lastAttemptAt,
  });

  /// 原始签到证据。
  final CheckinDraft draft;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': 'checkin',
        'id': id,
        'activityId': activityId,
        'idempotencyKey': idempotencyKey,
        'enqueuedAt': TimeFormat.toIso8601(enqueuedAt),
        'attempts': attempts,
        'syncState': syncState.wire,
        if (lastError != null) 'lastError': lastError,
        if (lastAttemptAt != null) 'lastAttemptAt': TimeFormat.toIso8601(lastAttemptAt!),
        'draft': draft.toJson(),
      };

  factory QueuedCheckin.fromJson(Map<String, dynamic> json) => QueuedCheckin(
        id: json['id']?.toString() ?? '',
        activityId: json['activityId']?.toString() ?? '',
        idempotencyKey: json['idempotencyKey']?.toString() ?? '',
        enqueuedAt: TimeFormat.tryParse(json['enqueuedAt']) ?? DateTime.now(),
        attempts: _int(json['attempts']),
        draft: CheckinDraft.fromJson(
          (json['draft'] as Map<Object?, Object?>?)?.cast<String, dynamic>() ??
              <String, dynamic>{},
        ),
        syncState: _syncState(json['syncState']),
        lastError: json['lastError']?.toString(),
        lastAttemptAt: TimeFormat.tryParse(json['lastAttemptAt']),
      );

  @override
  QueuedCheckin withAttempt({required SyncState state, String? error, DateTime? at}) =>
      QueuedCheckin(
        id: id,
        activityId: activityId,
        idempotencyKey: idempotencyKey,
        enqueuedAt: enqueuedAt,
        attempts: attempts + 1,
        draft: draft,
        syncState: state,
        lastError: error,
        lastAttemptAt: at,
      );
}

/// 待补传的在岗响应。
class QueuedAttendanceResponse extends QueuedTask {
  const QueuedAttendanceResponse({
    required super.id,
    required super.activityId,
    required super.idempotencyKey,
    required super.enqueuedAt,
    required super.attempts,
    required this.taskId,
    required this.point,
    required this.accuracy,
    required this.respondedAt,
    this.mockLocationDetected = false,
    super.syncState,
    super.lastError,
    super.lastAttemptAt,
  });

  /// 服务端任务 ID。
  final String taskId;

  /// 响应时采集的坐标（WGS-84）。
  final GeoPoint point;

  /// 精度（米）。
  final double accuracy;

  /// 志愿者点击的时刻。
  final DateTime respondedAt;

  /// 模拟定位检测结果。
  final bool mockLocationDetected;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': 'attendance',
        'id': id,
        'activityId': activityId,
        'idempotencyKey': idempotencyKey,
        'enqueuedAt': TimeFormat.toIso8601(enqueuedAt),
        'attempts': attempts,
        'syncState': syncState.wire,
        if (lastError != null) 'lastError': lastError,
        if (lastAttemptAt != null) 'lastAttemptAt': TimeFormat.toIso8601(lastAttemptAt!),
        'taskId': taskId,
        'geoLat': point.lat,
        'geoLng': point.lng,
        'accuracy': accuracy,
        'respondedAt': TimeFormat.toIso8601(respondedAt),
        'mockLocationDetected': mockLocationDetected,
      };

  factory QueuedAttendanceResponse.fromJson(Map<String, dynamic> json) =>
      QueuedAttendanceResponse(
        id: json['id']?.toString() ?? '',
        activityId: json['activityId']?.toString() ?? '',
        idempotencyKey: json['idempotencyKey']?.toString() ?? '',
        enqueuedAt: TimeFormat.tryParse(json['enqueuedAt']) ?? DateTime.now(),
        attempts: _int(json['attempts']),
        taskId: json['taskId']?.toString() ?? '',
        point: GeoPoint(
          lat: _double(json['geoLat']),
          lng: _double(json['geoLng']),
        ),
        accuracy: _double(json['accuracy']),
        respondedAt: TimeFormat.tryParse(json['respondedAt']) ?? DateTime.now(),
        mockLocationDetected: json['mockLocationDetected'] == true,
        syncState: _syncState(json['syncState']),
        lastError: json['lastError']?.toString(),
        lastAttemptAt: TimeFormat.tryParse(json['lastAttemptAt']),
      );

  @override
  QueuedAttendanceResponse withAttempt({
    required SyncState state,
    String? error,
    DateTime? at,
  }) =>
      QueuedAttendanceResponse(
        id: id,
        activityId: activityId,
        idempotencyKey: idempotencyKey,
        enqueuedAt: enqueuedAt,
        attempts: attempts + 1,
        taskId: taskId,
        point: point,
        accuracy: accuracy,
        respondedAt: respondedAt,
        mockLocationDetected: mockLocationDetected,
        syncState: state,
        lastError: error,
        lastAttemptAt: at,
      );
}

/// 一次补传的结果，供界面展示"同步状态"。
class FlushReport {
  const FlushReport({
    required this.attempted,
    required this.succeeded,
    required this.failed,
    required this.stillOffline,
    this.results = const <String, Checkin>{} ,
  });

  /// 尝试过的任务数。
  final int attempted;

  /// 成功数。
  final int succeeded;

  /// 失败且不可重试的数量。
  final int failed;

  /// 因仍离线而留在队列里的数量。
  final int stillOffline;

  /// 任务 ID → 服务端返回的签到记录（供界面更新状态）。
  final Map<String, Checkin> results;

  /// 是否什么都没做（队列为空）。
  bool get isEmpty => attempted == 0;

  @override
  String toString() =>
      'FlushReport(尝试 $attempted，成功 $succeeded，失败 $failed，待联网 $stillOffline)';
}

/// 离线证据队列。
///
/// ## 它解决什么问题
///
/// 方案 §9：「完全离线 → 浏览用缓存；**证据入队列**；明确显示『待同步』」。
///
/// 志愿活动现场经常没有信号（体育馆、地下室、郊区场地），而签到**必须留下证据**。
/// 因此签到时先落本地队列，联网后自动补传。
///
/// ## 三条不可违背的规则
///
/// 1. **幂等键入队时生成、持久化、重传复用**。每次重试现算键 = 每次都是一个
///    新请求 = 服务端产生多条记录（验收 A23 会抓到这个）。
/// 2. **超窗补传一律转人工**。补传时不试图"补上"当时的时间戳——
///    服务端会按实际服务端时间判定，并把超窗补传置为 `pending_review`（方案 §6.4）。
/// 3. **未拿到服务端终态前，界面不得显示「已确认」**（方案 §5.4）。
///    队列里的状态只有 `pending` / `syncing` / `failed`，没有"成功"——
///    成功必须来自服务端响应。
///
/// ## 持久化
///
/// 队列本身不碰磁盘：通过 [persist] / [restore] 与宿主交换 JSON 字符串。
/// 这样它保持零 Flutter 依赖（可在纯 Dart 测试里跑），而落盘交给
/// `shared_platform` 的存储能力。
class OfflineQueue {
  OfflineQueue({
    required this.client,
    BackoffWaiter? waiter,
  }) : _wait = waiter ?? _defaultWait;

  /// API 客户端。补传时用它发请求。
  final ApiClient client;

  final BackoffWaiter _wait;

  /// 队列内容变化时的回调，宿主用它落盘。
  ///
  /// ## 为什么需要这个（真机测试发现的丢数据）
  ///
  /// [persist] / [restore] 早就实现了，但**宿主从来没调用过** ——
  /// 队列实际只活在内存里。于是：
  ///
  ///   1. 用户离线签到，界面说「**已保存到本机**」；
  ///   2. 用户随手划掉 App（或 Android 回收进程）；
  ///   3. 证据凭空消失，**而用户以为自己已经交上去了**，
  ///      直到事后被判定缺席才发现。
  ///
  /// 这比直接报错更糟：错误提示会让人补救，虚假的成功提示不会。
  ///
  /// 与其在每个调用点手写 `persist()`（漏一处就静默丢数据），
  /// 不如让队列自己在内容变化后通知宿主。
  void Function()? onChanged;

  void _changed() => onChanged?.call();

  final Map<String, QueuedTask> _tasks = <String, QueuedTask>{};

  int _seq = 0;

  /// 当前队列（按入队顺序）。
  List<QueuedTask> get tasks {
    final List<QueuedTask> list = _tasks.values.toList()
      ..sort((QueuedTask a, QueuedTask b) => a.sortKey.compareTo(b.sortKey));
    return List<QueuedTask>.unmodifiable(list);
  }

  /// 队列长度。
  int get length => _tasks.length;

  /// 是否为空。
  bool get isEmpty => _tasks.isEmpty;

  /// 仍未同步的任务数（驱动界面上的"待同步"角标）。
  int get outstandingCount =>
      _tasks.values.where((QueuedTask t) => t.syncState.isOutstanding).length;

  /// 指定活动的待同步任务数。
  int outstandingCountFor(String activityId) => _tasks.values
      .where((QueuedTask t) => t.activityId == activityId && t.syncState.isOutstanding)
      .length;

  /// 指定活动的队列任务（含已同步失败的），按入队顺序。
  ///
  /// 「我的记录」页要把每一条**逐条**列出来：用户最常问的是
  /// "我那条到底传上去了没有、什么时候点的"。只给一个计数不够。
  List<QueuedTask> tasksFor(String activityId) {
    final List<QueuedTask> list = _tasks.values
        .where((QueuedTask t) => t.activityId == activityId)
        .toList()
      ..sort((QueuedTask a, QueuedTask b) => a.sortKey.compareTo(b.sortKey));
    return List<QueuedTask>.unmodifiable(list);
  }

  /// 入队一条签到证据。
  ///
  /// [idempotencyKey] 若为 `null` 则现生成一个——但**入队之后的任何重传都会复用它**，
  /// 因为键已经被写进 [QueuedCheckin]。
  QueuedCheckin enqueueCheckin({
    required String activityId,
    required CheckinDraft draft,
  }) {
    final String id = _nextId();
    final QueuedCheckin task = QueuedCheckin(
      id: id,
      activityId: activityId,
      idempotencyKey:
          draft.idempotencyKey.isEmpty ? client.newIdempotencyKey() : draft.idempotencyKey,
      enqueuedAt: draft.enqueuedAt ?? DateTime.now(),
      attempts: 0,
      draft: draft,
    );
    _tasks[id] = task;
    _changed();
    return task;
  }

  /// 入队一条在岗响应。
  QueuedAttendanceResponse enqueueAttendance({
    required String activityId,
    required String taskId,
    required GeoPoint point,
    required double accuracy,
    required DateTime respondedAt,
    bool mockLocationDetected = false,
    String? idempotencyKey,
  }) {
    final String id = _nextId();
    final QueuedAttendanceResponse task = QueuedAttendanceResponse(
      id: id,
      activityId: activityId,
      idempotencyKey: idempotencyKey ?? client.newIdempotencyKey(),
      enqueuedAt: DateTime.now(),
      attempts: 0,
      taskId: taskId,
      point: point,
      accuracy: accuracy,
      respondedAt: respondedAt,
      mockLocationDetected: mockLocationDetected,
    );
    _tasks[id] = task;
    _changed();
    return task;
  }

  /// 移除一个任务（成功后调用）。
  void remove(String id) {
    _tasks.remove(id);
    _changed();
  }

  /// 清空（退出登录 / 切换身份时调用）。
  void clear() {
    _tasks.clear();
    _seq = 0;
    _changed();
  }

  /// 清掉某个活动的任务。
  void clearFor(String activityId) {
    _tasks.removeWhere((_, QueuedTask t) => t.activityId == activityId);
    _changed();
  }

  /// 导出为 JSON 字符串，交给宿主持久化。
  String persist() => jsonEncode(<String, dynamic>{
        'seq': _seq,
        'tasks': _tasks.values.map((QueuedTask t) => t.toJson()).toList(growable: false),
      });

  /// 从 JSON 字符串恢复。
  ///
  /// 解析失败时**返回 `false` 并保持空队列**，而不是抛异常：
  /// 一个损坏的队列不该让 App 起不来（方案 §9 要求"不丢弃本地数据"，
  /// 但也没要求为了坏数据牺牲启动）。
  bool restore(String? raw) {
    if (raw == null || raw.isEmpty) {
      return false;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return false;
      }
      _tasks.clear();
      _seq = _int(decoded['seq']);

      final Object? tasks = decoded['tasks'];
      if (tasks is List) {
        for (final Object? item in tasks) {
          if (item is! Map<Object?, Object?>) {
            continue;
          }
          final Map<String, dynamic> json = item.cast<String, dynamic>();
          final QueuedTask? task = _parseTask(json);
          if (task != null) {
            // 恢复时把 syncing 降回 pending：上次进程被杀时正处于发送中，
            // 那条请求的结局未知，必须重新走一遍（幂等键保证不会重复记录）。
            _tasks[task.id] = task.syncState == SyncState.syncing
                ? task.withAttempt(state: SyncState.pending, error: task.lastError)
                : task;
          }
        }
      }
      return true;
    } catch (_) {
      _tasks.clear();
      _seq = 0;
      return false;
    }
  }

  /// 补传队列。
  ///
  /// 逐条串行发送（不并发）：志愿者一次只做一件事，并发只会让错误更难归因，
  /// 也会让服务端的"同设备多账号"检测更容易误判。
  ///
  /// [onlyActivityId] 可限制只补传某个活动的证据。
  Future<FlushReport> flush({String? onlyActivityId}) async {
    int attempted = 0;
    int succeeded = 0;
    int failed = 0;
    int stillOffline = 0;
    final Map<String, Checkin> results = <String, Checkin>{};

    // 标签是必需的：`switch` 里的 `break` 只跳出 switch，不跳出 for。
    // 早期版本正因为少了这个标签，在确认离线后仍然逐条重试，
    // 让用户白等好几轮超时。
    flushLoop:
    for (final QueuedTask task in tasks) {
      if (onlyActivityId != null && task.activityId != onlyActivityId) {
        continue;
      }
      if (task.syncState == SyncState.synced) {
        continue;
      }
      if (task.isExhausted) {
        // 已用尽：不再自动重试，等用户手动重试或联系发布者。
        // 保留本地数据，**不丢**。
        failed += 1;
        continue;
      }

      attempted += 1;
      _tasks[task.id] = task.withAttempt(state: SyncState.syncing);

      final _FlushOutcome outcome = await _send(task);

      switch (outcome) {
        case _FlushSuccess(:final Checkin? checkin):
          succeeded += 1;
          _tasks.remove(task.id);
          if (checkin != null) {
            results[task.id] = checkin;
          }
        case _FlushOffline():
          stillOffline += 1;
          _tasks[task.id] = task.withAttempt(
            state: SyncState.pending,
            error: '离线，等待联网后自动补传',
            at: DateTime.now(),
          );
          // 已经确认离线了，后面的任务不必再试——它们必然也失败，
          // 只会让用户多等几个超时。任务本身仍留在队列里。
          break flushLoop;
        case _FlushFailed(:final String message, :final bool retryable):
          if (retryable) {
            failed += 1;
            _tasks[task.id] = task.withAttempt(
              state: SyncState.failed,
              error: message,
              at: DateTime.now(),
            );
          } else {
            // 业务性拒绝（参数错、越权、不在名单、已过授权）：
            // 重试没有意义，**从队列里摘掉**，否则它会永远堵在那里。
            // 但把原因留给上层，界面要告诉用户到底怎么了。
            failed += 1;
            _tasks.remove(task.id);
          }
      }
    }

    // 补传会移除成功/被业务拒绝的任务，队列内容已变 → 通知宿主持久化，
    // 否则下次启动会把"已经传上去的证据"再传一遍
    //（幂等键能挡住重复入库，但没必要白发一次请求）。
    _changed();

    return FlushReport(
      attempted: attempted,
      succeeded: succeeded,
      failed: failed,
      stillOffline: stillOffline,
      results: results,
    );
  }

  /// 带退避的补传：用于"用户手动点重试"场景，会等到成功或用尽次数。
  Future<FlushReport> flushWithBackoff({String? onlyActivityId, int rounds = 3}) async {
    FlushReport last = await flush(onlyActivityId: onlyActivityId);
    for (int i = 1; i < rounds && last.stillOffline > 0; i++) {
      await _wait(ContractDefaults.retryBackoff[
          (i - 1).clamp(0, ContractDefaults.retryBackoff.length - 1)]);
      last = await flush(onlyActivityId: onlyActivityId);
    }
    return last;
  }

  Future<_FlushOutcome> _send(QueuedTask task) async {
    switch (task) {
      case QueuedCheckin(:final CheckinDraft draft):
        final ApiResult<Checkin> result = await client.post<Checkin>(
          // 路径常量集中管理：见 `contract/api_paths.dart` 的说明。
          CheckinPaths.submit(task.activityId),
          body: <String, Object?>{
            ...draft.toJson(),
            // 明确标记为补传：服务端据此把超窗补传转人工（移动端方案 §6.4）。
            // `CheckinDraft.toJson()` 已经带了，这里再显式覆盖一次，
            // 因为队列里的任务**一律**是补传（在线时不会入队）。
            'offlineBackfill': true,
          },
          idempotencyKey: task.idempotencyKey,
          decode: (Object? data) => Checkin.fromJson(
            _unwrap(data, 'checkin'),
          ),
          // 队列自己管重试次数，不让客户端再叠一层退避。
          retryable: false,
        );
        return _interpretResult<Checkin>(result, '签到');

      case QueuedAttendanceResponse():
        final ApiResult<Object?> result = await client.post<Object?>(
          // ⚠️ 在岗确认是**全局资源**路径 `/attendances/{taskId}:confirm`，
          // 不挂在活动下（网页方案 §6.4.6）。早期实现挂在活动下，已改正。
          AttendancePaths.confirm(task.taskId),
          body: <String, Object?>{
            'method': CheckinMethod.geo.wire,
            'location': <String, Object?>{
              'lat': task.point.lat,
              'lng': task.point.lng,
              'accuracy': task.accuracy,
            },
            'device': <String, Object?>{'mockLocationDetected': task.mockLocationDetected},
          },
          idempotencyKey: task.idempotencyKey,
          decode: (Object? data) => data,
          retryable: false,
        );
        return _interpretResult<Object?>(result, '在岗确认');
    }
  }

  _FlushOutcome _interpretResult<T>(ApiResult<T> result, String what) {
    switch (result) {
      case ApiSuccess<T>(:final T value):
        // 只有拿到服务端响应才算成功。
        return _FlushSuccess(
          what == '签到' && value is Checkin ? value : null,
        );
      case ApiFailure<T>(
          :final bool isOffline,
          :final String message,
          :final bool retryable,
          :final ApiErrorCode code,
        ):
        if (isOffline) {
          return const _FlushOffline();
        }
        if (retryable) {
          return _FlushFailed(message: message, retryable: true);
        }
        // 业务性拒绝：给出可读原因，上层展示给用户。
        return _FlushFailed(
          message: code == ApiErrorCode.alreadyCheckedIn
              // 已签到其实是"目的已达成"，按成功处理，避免队列里留一条死记录。
              ? '该签到已存在'
              : message,
          retryable: false,
        );
    }
  }

  String _nextId() {
    _seq += 1;
    return 'q$_seq-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
  }

  static QueuedTask? _parseTask(Map<String, dynamic> json) {
    switch (json['kind']) {
      case 'checkin':
        return QueuedCheckin.fromJson(json);
      case 'attendance':
        return QueuedAttendanceResponse.fromJson(json);
      default:
        return null;
    }
  }

  static Map<String, dynamic> _unwrap(Object? data, String key) {
    if (data is Map<String, dynamic>) {
      final Object? inner = data[key];
      if (inner is Map<Object?, Object?>) {
        return inner.cast<String, dynamic>();
      }
      return data;
    }
    return <String, dynamic>{};
  }

  static Future<void> _defaultWait(Duration d) => Future<void>.delayed(d);
}

/// 补传结果（内部使用）。
sealed class _FlushOutcome {
  const _FlushOutcome();
}

final class _FlushSuccess extends _FlushOutcome {
  const _FlushSuccess(this.checkin);
  final Checkin? checkin;
}

final class _FlushOffline extends _FlushOutcome {
  const _FlushOffline();
}

final class _FlushFailed extends _FlushOutcome {
  const _FlushFailed({required this.message, required this.retryable});
  final String message;
  final bool retryable;
}

int _int(Object? v) {
  if (v is int) {
    return v;
  }
  if (v is num) {
    return v.toInt();
  }
  return int.tryParse(v?.toString() ?? '') ?? 0;
}

double _double(Object? v) {
  if (v is num) {
    return v.toDouble();
  }
  return double.tryParse(v?.toString() ?? '') ?? 0;
}

SyncState _syncState(Object? v) {
  final String s = v?.toString() ?? '';
  for (final SyncState state in SyncState.values) {
    if (state.wire == s) {
      return state;
    }
  }
  return SyncState.pending;
}
