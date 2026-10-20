import 'dart:convert';

import 'package:shared_core/src/contract/error_codes.dart';
import 'package:shared_core/src/contract/time_and_geo.dart';
import 'package:shared_core/src/network/api_transport.dart';

/// 离线演示引擎：**没有服务端也能完整跑通两端流程**。
///
/// ## 为什么需要它
///
/// 用户没有云服务器，服务端只能跑在他自己电脑上。但 App 必须能直接装到
/// 手机上给别人看（验收 / 演示 / 评审）—— 不能要求对方先架服务器、
/// 配 IP、再连同一个 Wi-Fi。
///
/// 同时，**接真服务器的能力必须完整保留**：以后租了服务器，改个地址切回去即可，
/// 不能有任何功能是"只有离线模式才有"。
///
/// ## 怎么兼得
///
/// 在 [ApiTransport] 这一层做接缝：
///
/// ```
///   页面 → ApiClient（重试 / 幂等 / 令牌 / 信封解析 / 错误码映射）
///                 ↓
///           ApiTransport  ← 只替换这一层
///             ├── 真实 HTTP（默认）
///             └── OfflineDemoTransport（本文件）
/// ```
///
/// 界面代码一行都不用改：同一个签到页、同一套错误码、同一份离线队列，
/// 离线与在线走的是**完全相同**的那条代码路径。
///
/// ## 诚实性约束
///
/// * 这里**确实执行**方案 §6.1 的评分表（围栏 / 网络辅证 / 采样一致 /
///   反作弊扣分 / 阈值），不是"假装成功"；
/// * 但它是演示：用本机时间、本机数据，**两个 App 之间不共享**（Android 沙箱）；
/// * 所以界面必须显著标注「演示模式」，不能让验收者误以为这是服务端判定。
class OfflineDemoTransport implements ApiTransport {
  OfflineDemoTransport({OfflineDemoState? state})
      : state = state ?? OfflineDemoState.seeded();

  final OfflineDemoState state;

  static const String demoDisclaimer = '本机演示模式：数据存在这台手机上，未连接任何服务器。';

  @override
  Future<TransportResponse> send({
    required String method,
    required String path,
    Map<String, String>? query,
    required Map<String, String> headers,
    Object? body,
  }) async {
    try {
      final _Req r = _Req(method, path, query, headers, body);
      return _ok(_route(r));
    } on _Fail catch (e) {
      return _err(e);
    } catch (e) {
      return _err(_Fail(ApiErrorCode.serverError, '本机演示引擎出错：$e'));
    }
  }

  // ── 路由 ────────────────────────────────────────────────────────────────

  Object? _route(_Req r) {
    if (r.method == 'GET' && r.path == '/health') {
      return <String, Object?>{
        'status': 'ok',
        'service': 'offline-demo',
        'apiVersion': 'v1',
        'demo': true,
        'disclaimer': demoDisclaimer,
      };
    }
    if (r.method == 'POST' && r.path == '/auth/admin/login') return _adminLogin(r);
    if (r.method == 'POST' && r.path == '/auth/bind') return _bind(r);
    if (r.method == 'GET' && r.path == '/activities/organizers') {
      return <String, Object?>{
        'items': state.organizers,
      };
    }
    if (r.method == 'GET' && r.path == '/activities') return _listActivities(r);
    if (r.method == 'POST' && r.path == '/activities:upsert') return _upsert(r);

    // 活动子资源 / 动作
    if (r.path.startsWith('/activities/')) {
      final String rest = r.path.substring('/activities/'.length);
      if (rest.endsWith(':transition') && r.method == 'POST') {
        return _transition(r, rest.substring(0, rest.length - ':transition'.length));
      }
      final int slash = rest.indexOf('/');
      if (slash > 0) {
        final String id = rest.substring(0, slash);
        final String tail = rest.substring(slash + 1);
        switch (tail) {
          case 'participants':
            return r.method == 'GET' ? _participants(r, id) : _addParticipant(r, id);
          case 'participants:import':
            return _importParticipants(r, id);
          case 'invite-codes':
            return _inviteCodes(r, id);
          case 'board':
            return _board(id);
          case 'checkins':
            return r.method == 'POST' ? _submitCheckin(r, id) : _listCheckins(id);
          case 'checkins/mine':
            return _myCheckin(id);
          case 'attendance/tasks':
            return _tasks(id);
          case 'attendance':
            return _attendanceReport(id);
        }
      } else if (r.method == 'GET') {
        return _activityDetail(rest);
      }
    }

    // 全局资源：复核 / 在岗确认
    // 复核：真实路径是 `/checkins/{id}/review`（斜杠形式）。
    // 一开始只按 `:review` 处理后缀式写法，结果真机上一直报"演示模式未实现该接口"——
    // 演示模式的价值就是"点得通"，这类路径不匹配必须一次对齐。
    if (r.method == 'POST' && r.path.startsWith('/checkins/')) {
      final String rest = r.path.substring('/checkins/'.length);
      if (rest.endsWith('/review')) {
        return _review(r, rest.substring(0, rest.length - '/review'.length));
      }
      if (rest.endsWith(':review')) {
        return _review(r, rest.substring(0, rest.length - ':review'.length));
      }
    }
    if (r.method == 'POST' &&
        r.path.startsWith('/attendances/') &&
        r.path.endsWith(':confirm')) {
      return _confirm(
        r,
        r.path.substring('/attendances/'.length, r.path.length - ':confirm'.length),
      );
    }

    if (r.path.contains('/export')) {
      throw _Fail(
        ApiErrorCode.activityNotFound,
        '演示模式不支持导出文件（没有服务端）。连接服务器后可用。',
      );
    }
    throw _Fail(ApiErrorCode.activityNotFound, '演示模式未实现该接口：${r.method} ${r.path}');
  }

  // ── 鉴权 ────────────────────────────────────────────────────────────────

  Map<String, Object?> _adminLogin(_Req r) {
    final String? code = r.body['inviteCode'] as String?;
    final String? deviceId = (r.body['deviceId'] as String?) ?? r.headers['x-device-id'];
    if (code == null || code.trim() != OfflineDemoState.adminInviteCode) {
      throw _Fail(
        ApiErrorCode.forbidden,
        '邀请码不正确（演示模式固定为 ${OfflineDemoState.adminInviteCode}）',
      );
    }
    if (deviceId == null || deviceId.isEmpty) {
      throw _Fail(ApiErrorCode.badRequest, '缺少设备标识');
    }
    final String token = 'demo-adm-${state.nextSeq()}';
    state.adminToken = token;
    state.adminDeviceId = deviceId;
    state.save();
    final int active = state.activities
        .where((Map<String, Object?> a) =>
            a['status'] != 'finished' && a['status'] != 'cancelled')
        .length;
    return <String, Object?>{
      'token': token,
      'deviceId': deviceId,
      'ownerId': OfflineDemoState.ownerId,
      'expiresAt': iso(DateTime.now().add(const Duration(days: 30))),
      'serverTime': iso(DateTime.now()),
      'activeActivityCount': active,
    };
  }

  Map<String, Object?> _bind(_Req r) {
    final String? activityId = _resolveActivityId(r.body['activityId'] as String?);
    final String? userNo = (r.body['userNo'] as String?)?.trim();
    final String? code = (r.body['inviteCode'] as String?)?.trim();
    final String deviceId =
        (r.body['deviceId'] as String?) ?? r.headers['x-device-id'] ?? 'demo-device';
    if (activityId == null || userNo == null || code == null || code.isEmpty) {
      throw _Fail(ApiErrorCode.badRequest, '绑定信息不完整');
    }
    final Map<String, Object?>? act = state.findActivity(activityId);
    if (act == null) {
      throw _Fail(ApiErrorCode.activityNotFound, '活动不存在或已过留存期');
    }
    final Map<String, Object?>? invite = state.invites
        .where((Map<String, Object?> i) => i['activityId'] == activityId && i['code'] == code)
        .firstOrNull;
    if (invite == null) {
      throw _Fail(ApiErrorCode.forbidden, '邀请码无效');
    }
    if (invite['userNo'] != userNo) {
      throw _Fail(ApiErrorCode.forbidden, '该邀请码不属于此学号');
    }
    final Map<String, Object?>? p = state.participants
        .where((Map<String, Object?> x) => x['activityId'] == activityId && x['userNo'] == userNo)
        .firstOrNull;
    if (p == null) {
      throw _Fail(ApiErrorCode.forbidden, '你不在该活动的名单中');
    }

    // 二次校验：填了姓名或手机后四位就必须对上一个（与服务端同口径）。
    final Object? name = r.body['name'];
    final Object? suffix = r.body['phoneSuffix'];
    if (name != null || suffix != null) {
      final bool nameOk = name != null && '$name'.trim() == p['name'];
      final bool suffixOk =
          suffix != null && p['phoneSuffix'] != null && '$suffix'.trim() == p['phoneSuffix'];
      if (!nameOk && !suffixOk) {
        throw _Fail(ApiErrorCode.forbidden, '姓名或手机号后四位不匹配');
      }
    }

    // 幂等：同设备重复绑定返回原授权（真机踩过"响应丢了就永久锁死"）。
    if (state.volunteerToken != null &&
        state.volunteerActivityId == activityId &&
        state.volunteerUserNo == userNo) {
      return <String, Object?>{
        'token': state.volunteerToken,
        'activityId': activityId,
        'activityTitle': act['title'],
        'userNo': userNo,
        'name': p['name'],
        'deviceId': deviceId,
        'expiresAt': iso(DateTime.now().add(const Duration(days: 7))),
        'serverTime': iso(DateTime.now()),
        'idempotentReplay': true,
      };
    }

    final String token = 'demo-vol-${state.nextSeq()}';
    state.volunteerToken = token;
    state.volunteerActivityId = activityId;
    state.volunteerUserNo = userNo;
    invite['usedAt'] = iso(DateTime.now());
    state.save();
    return <String, Object?>{
      'token': token,
      'activityId': activityId,
      'activityTitle': act['title'],
      'userNo': userNo,
      'name': p['name'],
      'deviceId': deviceId,
      'expiresAt': iso(DateTime.now().add(const Duration(days: 7))),
      'serverTime': iso(DateTime.now()),
    };
  }

  // ── 活动 ────────────────────────────────────────────────────────────────

  Map<String, Object?> _listActivities(_Req r) {
    final int page = int.tryParse(r.query?['page'] ?? '1') ?? 1;
    final int size = int.tryParse(r.query?['size'] ?? '20') ?? 20;
    final List<Map<String, Object?>> all = state.activities;
    final int start = ((page - 1) * size).clamp(0, all.length);
    final List<Map<String, Object?>> slice = all.skip(start).take(size).toList();
    return <String, Object?>{
      'items': <Object?>[for (final Map<String, Object?> a in slice) _activityWire(a)],
      'total': all.length,
      'page': page,
      'size': size,
      'hasMore': start + slice.length < all.length,
      'stats': <String, Object?>{
        'total': all.length,
        'published': all.where((Map<String, Object?> a) => a['status'] == 'published').length,
        'ongoing': all.where((Map<String, Object?> a) => a['status'] == 'ongoing').length,
        'finished': all.where((Map<String, Object?> a) => a['status'] == 'finished').length,
        'cancelled': all.where((Map<String, Object?> a) => a['status'] == 'cancelled').length,
        'totalDurationHours': all.fold<double>(
          0,
          (double s, Map<String, Object?> a) => s + ((a['durationHours'] as num?)?.toDouble() ?? 0),
        ),
      },
    };
  }

  Map<String, Object?> _activityDetail(String idOrExternal) {
    final Map<String, Object?>? a = state.findActivity(idOrExternal);
    if (a == null) {
      throw _Fail(ApiErrorCode.activityNotFound, '活动不存在或已过留存期');
    }
    return _activityWire(a);
  }

  Map<String, Object?> _upsert(_Req r) {
    final List<Object?> batch = (r.body['batch'] as List<Object?>?) ?? <Object?>[];
    if (batch.isEmpty) {
      throw _Fail(ApiErrorCode.badRequest, '缺少 batch');
    }
    final List<Object?> created = <Object?>[];
    final List<Object?> updated = <Object?>[];
    final List<Object?> rejected = <Object?>[];

    for (int i = 0; i < batch.length; i++) {
      final Map<String, Object?> row =
          (batch[i] as Map<Object?, Object?>).cast<String, Object?>();
      final String externalId = (row['externalId'] as String?)?.trim() ?? '';
      final String title = (row['title'] as String?)?.trim() ?? '';
      if (externalId.isEmpty) {
        rejected.add(_reject(i, 'externalId', '缺少外部编号'));
        continue;
      }
      if (title.isEmpty) {
        rejected.add(_reject(i, 'title', '请填写活动名称'));
        continue;
      }
      final Map<String, Object?>? existing = state.activities
          .where((Map<String, Object?> a) => a['externalId'] == externalId)
          .firstOrNull;
      final Map<String, Object?> built = _buildActivity(row, existing);
      if (existing == null) {
        state.activities.insert(0, built);
        created.add(built['id']);
      } else {
        state.activities[state.activities.indexOf(existing)] = built;
        updated.add(built['id']);
      }
    }
    state.save();
    return <String, Object?>{
      'accepted': created.length + updated.length,
      'created': created,
      'updated': updated,
      'rejected': rejected,
      'note': rejected.isEmpty ? '全部受理' : '部分行被拒绝',
    };
  }

  Map<String, Object?> _reject(int index, String field, String message) => <String, Object?>{
        'index': index,
        'errors': <Object?>[
          <String, Object?>{'field': field, 'message': message},
        ],
      };

  Map<String, Object?> _buildActivity(Map<String, Object?> row, Map<String, Object?>? existing) {
    final DateTime now = DateTime.now();
    final DateTime start = TimeFormat.tryParse(row['startTime']) ?? now;
    final DateTime end =
        TimeFormat.tryParse(row['endTime']) ?? start.add(const Duration(hours: 2));
    return <String, Object?>{
      'id': existing?['id'] ?? 'demo-act-${state.nextSeq()}',
      'externalId': row['externalId'] ?? existing?['externalId'] ?? '',
      'title': row['title'] ?? existing?['title'] ?? '',
      'organizer': row['organizer'] ?? existing?['organizer'] ?? '',
      'durationHours': (row['durationHours'] as num?)?.toDouble() ??
          (end.difference(start).inMinutes / 60.0),
      'startTime': iso(start),
      'endTime': iso(end),
      'location': row['location'] ?? existing?['location'] ?? '',
      'geoLat': (row['geoLat'] as num?)?.toDouble() ?? existing?['geoLat'] ?? 0,
      'geoLng': (row['geoLng'] as num?)?.toDouble() ?? existing?['geoLng'] ?? 0,
      'checkinRadius': (row['checkinRadius'] as num?)?.toDouble() ??
          existing?['checkinRadius'] ??
          200,
      'locationType': row['locationType'] ?? existing?['locationType'] ?? 'outdoor',
      'wifiBssids': row['wifiBssids'] ?? existing?['wifiBssids'] ?? <Object?>[],
      'campusIpPrefixes': row['campusIpPrefixes'] ?? existing?['campusIpPrefixes'] ?? <Object?>[],
      'checkinWindowBefore': existing?['checkinWindowBefore'] ?? 30,
      'checkinWindowAfter': existing?['checkinWindowAfter'] ?? 60,
      'attendanceFirstDelay': existing?['attendanceFirstDelay'] ?? 15,
      'attendanceInterval': existing?['attendanceInterval'] ?? 30,
      'attendanceResponseWindow': existing?['attendanceResponseWindow'] ?? 5,
      'quota': (row['quota'] as num?)?.toInt() ?? existing?['quota'],
      'enrolled': state.participantCount('${existing?['id'] ?? ''}'),
      'status': existing?['status'] ?? (row['status'] as String?) ?? 'published',
      'summary': row['summary'] ?? existing?['summary'] ?? '',
      'description': row['description'] ?? existing?['description'] ?? '',
      'contact': row['contact'] ?? existing?['contact'],
      'ownerId': OfflineDemoState.ownerId,
      'version': ((existing?['version'] as int?) ?? 0) + 1,
      'createdAt': existing?['createdAt'] ?? iso(now),
      'updatedAt': iso(now),
    };
  }

  Map<String, Object?> _transition(_Req r, String id) {
    final Map<String, Object?>? a = state.findActivity(id);
    if (a == null) {
      throw _Fail(ApiErrorCode.activityNotFound, '活动不存在');
    }
    final String to = (r.body['to'] as String?) ?? '';
    final String from = '${a['status']}';
    a['status'] = to;
    if (to == 'finished' || to == 'cancelled') {
      a['terminalAt'] = iso(DateTime.now());
    }
    state.save();
    return <String, Object?>{'activity': _activityWire(a), 'from': from, 'to': to};
  }

  // ── 名单 / 邀请码 ───────────────────────────────────────────────────────

  Map<String, Object?> _participants(_Req r, String id) {
    _requireActivity(id);
    final List<Map<String, Object?>> list =
        state.participants.where((Map<String, Object?> p) => p['activityId'] == id).toList();
    return <String, Object?>{
      'items': <Object?>[for (final Map<String, Object?> p in list) _participantWire(p)],
      'total': list.length,
      'counts': _counts(id),
    };
  }

  Map<String, Object?> _counts(String id) {
    final List<Map<String, Object?>> ps =
        state.participants.where((Map<String, Object?> p) => p['activityId'] == id).toList();
    final List<Map<String, Object?>> ts =
        state.tasks.where((Map<String, Object?> t) => t['activityId'] == id).toList();
    int countStatus(String s) => ps.where((Map<String, Object?> p) => p['checkinStatus'] == s).length;
    return <String, Object?>{
      'activityId': id,
      'checkedIn': countStatus('success'),
      'pendingReview': countStatus('pending_review'),
      'notCheckedIn': countStatus('none'),
      'removed': 0,
      'attendancePending': ts.where((Map<String, Object?> t) => t['status'] == 'pending').length,
      'attendanceDone': ts.where((Map<String, Object?> t) => t['status'] == 'done').length,
      'attendanceMissed': ts.where((Map<String, Object?> t) => t['status'] == 'missed').length,
      'attendanceExcused': ts.where((Map<String, Object?> t) => t['status'] == 'excused').length,
      'servingNow': 0,
    };
  }

  Map<String, Object?> _addParticipant(_Req r, String id) {
    _requireActivity(id);
    final String userNo = (r.body['userNo'] as String?)?.trim() ?? '';
    final String name = (r.body['name'] as String?)?.trim() ?? '';
    if (userNo.isEmpty || name.isEmpty) {
      throw _Fail(ApiErrorCode.badRequest, '学号与姓名必填');
    }
    if (state.participants
        .any((Map<String, Object?> p) => p['activityId'] == id && p['userNo'] == userNo)) {
      throw _Fail(ApiErrorCode.participantDuplicated, '名单中已存在该学号');
    }
    final String? phone = (r.body['phone'] as String?)?.trim();
    final Map<String, Object?> p = <String, Object?>{
      'activityId': id,
      'userNo': userNo,
      'name': name,
      'phoneSuffix': (phone != null && phone.length >= 4) ? phone.substring(phone.length - 4) : null,
      'phone': _maskPhone(phone),
      'signupStatus': 'signed',
      'checkinStatus': 'none',
      'inviteCodeIssued': false,
    };
    state.participants.add(p);
    state.save();
    return <String, Object?>{'item': _participantWire(p)};
  }

  Map<String, Object?> _importParticipants(_Req r, String id) {
    _requireActivity(id);
    final List<Object?> rows = (r.body['rows'] as List<Object?>?) ?? <Object?>[];
    final List<Object?> accepted = <Object?>[];
    final List<Object?> failures = <Object?>[];
    for (int i = 0; i < rows.length; i++) {
      final List<Object?> cells = (rows[i] as List<Object?>?) ?? <Object?>[];
      final String userNo = cells.isNotEmpty ? '${cells[0]}'.trim() : '';
      final String name = cells.length > 1 ? '${cells[1]}'.trim() : '';
      final String phone = cells.length > 2 ? '${cells[2]}'.trim() : '';
      if (userNo.isEmpty || name.isEmpty) {
        failures.add(<String, Object?>{'row': i + 1, 'reason': '学号或姓名为空'});
        continue;
      }
      if (state.participants
          .any((Map<String, Object?> p) => p['activityId'] == id && p['userNo'] == userNo)) {
        failures.add(<String, Object?>{
          'row': i + 1,
          'userNo': userNo,
          'reason': '名单中已存在该学号',
        });
        continue;
      }
      state.participants.add(<String, Object?>{
        'activityId': id,
        'userNo': userNo,
        'name': name,
        'phoneSuffix': phone.length >= 4 ? phone.substring(phone.length - 4) : null,
        'phone': _maskPhone(phone),
        'signupStatus': 'signed',
        'checkinStatus': 'none',
        'inviteCodeIssued': false,
      });
      accepted.add(<String, Object?>{'row': i + 1, 'userNo': userNo, 'name': name});
    }
    state.save();
    return <String, Object?>{
      'accepted': accepted.length,
      'rejected': failures.length,
      'rows': accepted,
      'failures': failures,
    };
  }

  Map<String, Object?> _inviteCodes(_Req r, String id) {
    _requireActivity(id);
    final List<Object?> issued = <Object?>[];
    for (final Map<String, Object?> p in state.participants
        .where((Map<String, Object?> x) => x['activityId'] == id)) {
      Map<String, Object?>? code = state.invites
          .where((Map<String, Object?> i) =>
              i['activityId'] == id && i['userNo'] == p['userNo'] && i['usedAt'] == null)
          .firstOrNull;
      if (code == null) {
        code = <String, Object?>{
          'activityId': id,
          'userNo': p['userNo'],
          'name': p['name'],
          'code': 'DEMO${state.nextSeq().toString().padLeft(4, '0')}',
          'expiresAt': iso(DateTime.now().add(const Duration(days: 7))),
          'usedAt': null,
        };
        state.invites.add(code);
      }
      issued.add(<String, Object?>{
        'userNo': code['userNo'],
        'name': code['name'],
        'inviteCode': code['code'],
        'expiresAt': code['expiresAt'],
        if (code['usedAt'] != null) 'usedAt': code['usedAt'],
      });
    }
    state.save();
    return <String, Object?>{
      'items': issued,
      'skipped': <Object?>[],
      'warning': '演示模式：邀请码只在本机有效。',
      'displayOnce': false,
    };
  }

  // ── 签到 ────────────────────────────────────────────────────────────────

  Map<String, Object?> _submitCheckin(_Req r, String id) {
    final Map<String, Object?> a = _requireActivity(id);
    final DateTime now = DateTime.now();
    final DateTime start = TimeFormat.tryParse(a['startTime']) ?? now;
    final DateTime end = TimeFormat.tryParse(a['endTime']) ?? now;
    final DateTime opens =
        start.subtract(Duration(minutes: (a['checkinWindowBefore'] as int?) ?? 30));
    final DateTime closes =
        end.add(Duration(minutes: (a['checkinWindowAfter'] as int?) ?? 60));
    if (now.isBefore(opens)) {
      throw _Fail(ApiErrorCode.activityStateInvalid, '签到尚未开放（${TimeFormat.format(opens)} 开放）');
    }
    if (now.isAfter(closes)) {
      throw _Fail(ApiErrorCode.activityStateInvalid, '签到时段已结束（${TimeFormat.format(closes)} 关闭）');
    }

    final _Ev ev = _Ev.from(r.body);
    if (!ev.hasFix) {
      throw _Fail(ApiErrorCode.badRequest, '未收到定位坐标，无法判定是否在场');
    }
    if (ev.accuracy > 100) {
      throw _Fail(
        ApiErrorCode.badRequest,
        '定位精度 ${ev.accuracy.toStringAsFixed(0)} 米，超过 100 米门槛',
      );
    }

    final String? userNo = state.volunteerUserNo;
    if (userNo == null || state.volunteerActivityId != id) {
      throw _Fail(ApiErrorCode.unauthorized, '登录状态已失效');
    }
    final Map<String, Object?>? p = state.participants
        .where((Map<String, Object?> x) => x['activityId'] == id && x['userNo'] == userNo)
        .firstOrNull;
    if (p == null) {
      throw _Fail(ApiErrorCode.forbidden, '你不在该活动的名单中');
    }
    final Map<String, Object?>? already = state.checkins
        .where((Map<String, Object?> c) => c['activityId'] == id && c['userNo'] == userNo)
        .firstOrNull;
    if (already != null) {
      return <String, Object?>{
        ..._checkinWire(already),
        'checkin': _checkinWire(already),
        'alreadySubmitted': true,
      };
    }

    final _Score sc = _score(a, ev);
    final Map<String, Object?> checkin = <String, Object?>{
      'id': 'demo-chk-${state.nextSeq()}',
      'activityId': id,
      'userNo': userNo,
      'name': p['name'],
      'method': 'geo',
      'status': sc.status,
      'reason': sc.reason,
      'geoLat': ev.lat,
      'geoLng': ev.lng,
      'accuracy': ev.accuracy,
      'score': sc.score,
      'scoreBreakdown': sc.breakdown,
      'distanceMeters': sc.distance,
      'mockLocationDetected': sc.mockDetected,
      'serverTime': iso(now),
      'clientTime': iso(ev.clientTime ?? now),
      'offlineBackfill': false,
    };
    state.checkins.add(checkin);
    p['checkinStatus'] = sc.status;

    // 决策 D-6：签到受理（success / pending_review）后生成在岗抽查。
    if (sc.status != 'rejected') {
      _ensureTasks(a, userNo);
    }
    state.save();
    // ⚠️ 平铺返回：`checkin_page` 把 `data` **直接**当 `Checkin.fromJson` 的输入，
    // 再包一层 `{checkin: ...}` 会让它解析出一个空对象（状态变 unknown）。
    // 同时保留嵌套键，兼容其他调用方。
    return <String, Object?>{
      ..._checkinWire(checkin),
      'checkin': _checkinWire(checkin),
    };
  }

  Map<String, Object?> _listCheckins(String id) {
    _requireActivity(id);
    final List<Map<String, Object?>> list =
        state.checkins.where((Map<String, Object?> c) => c['activityId'] == id).toList();
    return <String, Object?>{
      'items': <Object?>[for (final Map<String, Object?> c in list) _checkinWire(c)],
      'total': list.length,
      'counts': <String, Object?>{
        'success': list.where((Map<String, Object?> c) => c['status'] == 'success').length,
        'pendingReview':
            list.where((Map<String, Object?> c) => c['status'] == 'pending_review').length,
        'rejected': list.where((Map<String, Object?> c) => c['status'] == 'rejected').length,
      },
    };
  }

  /// 本人签到记录。**没有记录时返回空对象而不是 null**
  /// （契约要求"成功必有 data"，返回 null 会被客户端判成契约违约）。
  Map<String, Object?> _myCheckin(String id) {
    final String? userNo = state.volunteerUserNo;
    final Map<String, Object?>? c = state.checkins
        .where((Map<String, Object?> x) => x['activityId'] == id && x['userNo'] == userNo)
        .firstOrNull;
    return <String, Object?>{
      'items': c == null ? <Object?>[] : <Object?>[_checkinWire(c)],
      'latest': c == null ? null : _checkinWire(c),
      if (c != null) 'checkin': _checkinWire(c),
    };
  }

  Map<String, Object?> _review(_Req r, String checkinId) {
    final Map<String, Object?>? c = state.checkins
        .where((Map<String, Object?> x) => x['id'] == checkinId)
        .firstOrNull;
    if (c == null) {
      throw _Fail(ApiErrorCode.activityNotFound, '签到记录不存在');
    }
    final String decision = (r.body['decision'] as String?) ?? '';
    final String? note = r.body['note'] as String?;
    final String next = decision == 'reject' ? 'rejected' : 'success';
    c['status'] = next;
    c['reviewedAt'] = iso(DateTime.now());
    if (note != null && note.isNotEmpty) {
      c['reviewNote'] = note;
    }
    final Map<String, Object?>? p = state.participants
        .where((Map<String, Object?> x) =>
            x['activityId'] == c['activityId'] && x['userNo'] == c['userNo'])
        .firstOrNull;
    if (p != null) {
      p['checkinStatus'] = next;
    }
    state.save();
    return <String, Object?>{'checkin': _checkinWire(c)};
  }

  // ── 在岗抽查 ────────────────────────────────────────────────────────────

  Map<String, Object?> _tasks(String id) {
    final Map<String, Object?> a = _requireActivity(id);
    _settle(a);
    final List<Map<String, Object?>> list =
        state.tasks.where((Map<String, Object?> t) => t['activityId'] == id).toList()
          ..sort((Map<String, Object?> x, Map<String, Object?> y) =>
              ((x['seq'] as int?) ?? 0).compareTo((y['seq'] as int?) ?? 0));
    return <String, Object?>{
      'activityId': id,
      'activityTitle': a['title'],
      'serverTime': iso(DateTime.now()),
      'items': <Object?>[for (final Map<String, Object?> t in list) _taskWire(t)],
    };
  }

  Map<String, Object?> _confirm(_Req r, String taskId) {
    final Map<String, Object?>? t =
        state.tasks.where((Map<String, Object?> x) => x['id'] == taskId).firstOrNull;
    if (t == null) {
      throw _Fail(ApiErrorCode.activityNotFound, '在岗任务不存在');
    }
    final Map<String, Object?> a = _requireActivity('${t['activityId']}');
    _settle(a);
    final DateTime now = DateTime.now();

    if (t['status'] == 'done') {
      return <String, Object?>{'task': _taskWire(t), 'alreadyDone': true};
    }
    if (t['status'] != 'pending') {
      throw _Fail(ApiErrorCode.activityStateInvalid, '该在岗确认已超时，请联系发布者人工补录');
    }
    // 窗口**两侧**都要校验：真机测试发现过"可以提前点掉所有未来抽查"的漏洞。
    final DateTime scheduled = TimeFormat.tryParse(t['scheduledAt']) ?? now;
    if (now.isBefore(scheduled)) {
      throw _Fail(
        ApiErrorCode.activityStateInvalid,
        '该在岗确认尚未开始，请在 ${TimeFormat.format(scheduled)} 之后再确认',
      );
    }
    final DateTime deadline = TimeFormat.tryParse(t['deadlineAt']) ?? now;
    if (now.isAfter(deadline)) {
      throw _Fail(ApiErrorCode.activityStateInvalid, '该在岗确认已超时，请联系发布者人工补录');
    }

    final _Ev ev = _Ev.from(r.body);
    if (!ev.hasFix) {
      throw _Fail(ApiErrorCode.badRequest, '未收到定位证据，无法完成在岗确认');
    }
    t['status'] = 'done';
    t['respondedAt'] = iso(now);
    t['geoLat'] = ev.lat;
    t['geoLng'] = ev.lng;
    t['accuracy'] = ev.accuracy;
    state.save();
    return <String, Object?>{'task': _taskWire(t)};
  }

  Map<String, Object?> _attendanceReport(String id) {
    final Map<String, Object?> a = _requireActivity(id);
    _settle(a);
    final List<Object?> rows = <Object?>[];
    for (final Map<String, Object?> p in state.participants
        .where((Map<String, Object?> x) => x['activityId'] == id)) {
      final List<Map<String, Object?>> mine = state.tasks
          .where((Map<String, Object?> t) => t['activityId'] == id && t['userNo'] == p['userNo'])
          .toList();
      final int done = mine.where((Map<String, Object?> t) => t['status'] == 'done').length;
      final int missed = mine.where((Map<String, Object?> t) => t['status'] == 'missed').length;
      final int excused = mine.where((Map<String, Object?> t) => t['status'] == 'excused').length;
      final int total = done + missed;
      rows.add(<String, Object?>{
        'userNo': p['userNo'],
        'name': p['name'],
        'attendanceSummary': total == 0 ? 'no_task' : ((total - missed) / total >= 0.7 ? 'ok' : 'partial'),
        'attendanceDone': done,
        'attendanceMissed': missed,
        'attendanceExcused': excused,
        if (total > 0) 'attendanceRate': (total - missed) / total,
        'checkinStatus': p['checkinStatus'],
      });
    }
    return <String, Object?>{
      'rows': rows,
      'disclaimer': '考勤结果仅作现场管理参考，不作为志愿时长认定依据。',
      'serverTime': iso(DateTime.now()),
    };
  }

  Map<String, Object?> _board(String id) {
    final Map<String, Object?> a = _requireActivity(id);
    _settle(a);
    final Map<String, Object?> counts = _counts(id);
    final List<Map<String, Object?>> ps =
        state.participants.where((Map<String, Object?> p) => p['activityId'] == id).toList();
    return <String, Object?>{
      ...counts,
      'serverTime': iso(DateTime.now()),
      'participants': <Object?>[for (final Map<String, Object?> p in ps) _participantWire(p)],
      'disclaimer': '考勤结果仅作现场管理参考，不作为志愿时长认定依据。',
      'activityTitle': a['title'],
    };
  }

  // ── 判定（方案 §6.1 的移植）─────────────────────────────────────────────

  _Score _score(Map<String, Object?> a, _Ev ev) {
    final List<Map<String, Object?>> breakdown = <Map<String, Object?>>[];
    final double lat = (a['geoLat'] as num?)?.toDouble() ?? 0;
    final double lng = (a['geoLng'] as num?)?.toDouble() ?? 0;
    final double radius = (a['checkinRadius'] as num?)?.toDouble() ?? 200;
    final double dist = GeoPoint(lat: ev.lat, lng: ev.lng).distanceTo(GeoPoint(lat: lat, lng: lng));

    if (dist <= radius) {
      final bool tight = ev.accuracy <= 50;
      breakdown.add(<String, Object?>{
        'reason': '围栏内且距中心 ${dist.toStringAsFixed(0)}m（${tight ? '≤50m' : '>50m'}）',
        'points': tight ? 40 : 25,
      });
    } else {
      breakdown.add(<String, Object?>{
        'reason': '距围栏中心 ${dist.toStringAsFixed(0)}m，超出签到范围',
        'points': 0,
      });
    }

    // 网络辅证只在活动配了白名单时才参与（"无法证明就不参与判定"）。
    final List<Object?> wifi = (a['wifiBssids'] as List<Object?>?) ?? <Object?>[];
    if (wifi.isNotEmpty && ev.wifiBssid != null) {
      final String got = ev.wifiBssid!.toLowerCase();
      if (wifi.map((Object? b) => '$b'.toLowerCase()).contains(got)) {
        breakdown.add(<String, Object?>{'reason': 'Wi-Fi 命中场地', 'points': 20});
      }
    }
    final List<Object?> ips = (a['campusIpPrefixes'] as List<Object?>?) ?? <Object?>[];
    if (ips.isNotEmpty && ev.localIp != null) {
      if (ips.any((Object? pre) => ev.localIp!.startsWith('$pre'))) {
        breakdown.add(<String, Object?>{'reason': '校园网 IP 命中', 'points': 10});
      }
    }

    if (ev.samples.length >= 2) {
      breakdown.add(<String, Object?>{'reason': '多次采样一致', 'points': 10});
    }

    // 反作弊：与真机修复后的口径一致 —— 完全一致**且**精度异常理想才算伪造。
    bool mock = ev.mockFlagged;
    if (ev.samples.length >= 2) {
      final List<_Sm> s = ev.samples;
      final bool allSame = s.every((_Sm x) =>
          (x.lat - s.first.lat).abs() < 1e-9 && (x.lng - s.first.lng).abs() < 1e-9);
      final bool sameAcc = s.every((_Sm x) => x.accuracy == s.first.accuracy);
      if (allSame && sameAcc && s.first.accuracy > 0 && s.first.accuracy <= 5) {
        mock = true;
      }
    }
    if (mock) {
      breakdown.add(<String, Object?>{'reason': '模拟定位，命中即转人工', 'points': -60});
    }

    final int score =
        breakdown.fold<int>(0, (int s, Map<String, Object?> i) => s + ((i['points'] as int?) ?? 0));
    final String status;
    final String reason;
    if (mock) {
      status = 'pending_review';
      reason = '检测到疑似模拟定位，已转人工确认';
    } else if (score >= 60) {
      status = 'success';
      reason = '定位证据充分，自动通过';
    } else if (score >= 30) {
      status = 'pending_review';
      reason = '证据强度不足（评分 $score），已转人工确认';
    } else {
      status = 'rejected';
      reason = '定位证据不足（评分 $score），未通过';
    }
    return _Score(
      score: score,
      status: status,
      reason: reason,
      breakdown: breakdown,
      distance: dist,
      mockDetected: mock,
    );
  }

  // ── 工具 ────────────────────────────────────────────────────────────────


  Map<String, Object?> _requireActivity(String id) {
    final Map<String, Object?>? a = state.findActivity(id);
    if (a == null) {
      throw _Fail(ApiErrorCode.activityNotFound, '活动不存在或已过留存期');
    }
    return a;
  }

  String? _resolveActivityId(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return state.findActivity(raw)?['id'] as String?;
  }

  void _ensureTasks(Map<String, Object?> a, String userNo) {
    final DateTime start = TimeFormat.tryParse(a['startTime']) ?? DateTime.now();
    final int firstDelay = (a['attendanceFirstDelay'] as int?) ?? 15;
    final int interval = (a['attendanceInterval'] as int?) ?? 30;
    final int window = (a['attendanceResponseWindow'] as int?) ?? 5;
    final DateTime end = TimeFormat.tryParse(a['endTime']) ?? start.add(const Duration(hours: 2));
    for (int seq = 1;; seq++) {
      final DateTime slot =
          start.add(Duration(minutes: firstDelay + (seq - 1) * interval));
      if (slot.isAfter(end.subtract(const Duration(minutes: 30)))) {
        break;
      }
      final bool exists = state.tasks.any((Map<String, Object?> t) =>
          t['activityId'] == a['id'] && t['userNo'] == userNo && t['seq'] == seq);
      if (exists) {
        continue;
      }
      state.tasks.add(<String, Object?>{
        'id': 'demo-task-${state.nextSeq()}',
        'activityId': a['id'],
        'userNo': userNo,
        'seq': seq,
        'scheduledAt': iso(slot),
        'deadlineAt': iso(slot.add(Duration(minutes: window))),
        'status': 'pending',
        'activityTitle': a['title'],
        'notifiedAt': null,
        'respondedAt': null,
        'geoLat': null,
        'geoLng': null,
        'accuracy': null,
        'manualFill': false,
        'filledBy': null,
      });
    }
  }

  void _settle(Map<String, Object?> a) {
    final DateTime now = DateTime.now();
    for (final Map<String, Object?> t in state.tasks) {
      if (t['activityId'] != a['id'] || t['status'] != 'pending') {
        continue;
      }
      final DateTime deadline = TimeFormat.tryParse(t['deadlineAt']) ?? now;
      if (now.isAfter(deadline)) {
        t['status'] = 'missed';
      }
    }
  }

  // ── 报文（形状对齐各模型的 fromJson）──────────────────────────────────

  Map<String, Object?> _activityWire(Map<String, Object?> a) => <String, Object?>{
        ...a,
        'myCheckinStatus': state.volunteerUserNo == null
            ? null
            : state.checkins
                .where((Map<String, Object?> c) =>
                    c['activityId'] == a['id'] && c['userNo'] == state.volunteerUserNo)
                .firstOrNull?['status'],
        'pendingAttendanceCount': state.tasks
            .where((Map<String, Object?> t) =>
                t['activityId'] == a['id'] &&
                t['userNo'] == state.volunteerUserNo &&
                t['status'] == 'pending')
            .length,
      };

  Map<String, Object?> _participantWire(Map<String, Object?> p) => <String, Object?>{
        'userNo': p['userNo'],
        'name': p['name'],
        if (p['phone'] != null) 'phone': p['phone'],
        'signupStatus': p['signupStatus'],
        'checkinStatus': p['checkinStatus'],
        'inviteCodeIssued': p['inviteCodeIssued'] ?? false,
        'attendanceDone': 0,
        'attendanceMissed': 0,
        'attendanceExcused': 0,
      };

  Map<String, Object?> _checkinWire(Map<String, Object?> c) => <String, Object?>{
        'id': c['id'],
        'activityId': c['activityId'],
        'userNo': c['userNo'],
        'name': c['name'],
        'method': c['method'],
        'status': c['status'],
        'reason': c['reason'],
        if (c['geoLat'] != null) 'geoLat': c['geoLat'],
        if (c['geoLng'] != null) 'geoLng': c['geoLng'],
        if (c['accuracy'] != null) 'accuracy': c['accuracy'],
        if (c['score'] != null) 'score': c['score'],
        if (c['scoreBreakdown'] != null) 'scoreBreakdown': c['scoreBreakdown'],
        if (c['distanceMeters'] != null) 'distanceMeters': c['distanceMeters'],
        'mockLocationDetected': c['mockLocationDetected'] ?? false,
        if (c['serverTime'] != null) 'serverTime': c['serverTime'],
        if (c['clientTime'] != null) 'clientTime': c['clientTime'],
        if (c['reviewedAt'] != null) 'reviewedAt': c['reviewedAt'],
        if (c['reviewNote'] != null) 'reviewNote': c['reviewNote'],
        'offlineBackfill': c['offlineBackfill'] ?? false,
      };

  Map<String, Object?> _taskWire(Map<String, Object?> t) => <String, Object?>{
        'id': t['id'],
        'activityId': t['activityId'],
        'userNo': t['userNo'],
        'seq': t['seq'],
        'scheduledAt': t['scheduledAt'],
        'deadlineAt': t['deadlineAt'],
        'status': t['status'],
        if (t['activityTitle'] != null) 'activityTitle': t['activityTitle'],
        if (t['geoLng'] != null) 'geoLat': t['geoLat'],
        if (t['geoLng'] != null) 'geoLng': t['geoLng'],
        if (t['accuracy'] != null) 'accuracy': t['accuracy'],
        if (t['respondedAt'] != null) 'respondedAt': t['respondedAt'],
        'manualFill': t['manualFill'] ?? false,
      };

  String _maskPhone(String? phone) {
    if (phone == null || phone.length != 11) {
      return '';
    }
    return '${phone.substring(0, 3)}****${phone.substring(7)}';
  }

  TransportResponse _ok(Object? data) => TransportResponse(
        statusCode: 200,
        body: jsonEncode(<String, Object?>{
          'code': 0,
          'msg': '成功',
          'message': '成功',
          'data': data,
          'errors': <Object?>[],
          'traceId': 'demo-${state.nextSeq()}',
          'serverTime': iso(DateTime.now()),
          'demo': true,
        }),
      );

  TransportResponse _err(_Fail e) => TransportResponse(
        statusCode: _httpStatusFor(e.code),
        body: jsonEncode(<String, Object?>{
          'code': e.code.value,
          'msg': e.message,
          'message': e.message,
          'data': null,
          'errors': <Object?>[],
          'traceId': 'demo-${state.nextSeq()}',
          'serverTime': iso(DateTime.now()),
          'demo': true,
        }),
      );
}

/// 演示数据状态（可序列化，跨启动保留）。
class OfflineDemoState {
  OfflineDemoState({
    required this.activities,
    required this.participants,
    required this.checkins,
    required this.tasks,
    required this.invites,
    this.adminToken,
    this.adminDeviceId,
    this.volunteerToken,
    this.volunteerActivityId,
    this.volunteerUserNo,
    this.counter = 0,
  });

  /// 管理端邀请码（演示固定，与真服务端默认值一致）。
  static const String adminInviteCode = '1111';

  /*
    演示凭据：**唯一来源**。

    真机测试反馈："演示模式下该填什么"是测试人员最常卡住的一步，
    而 `demo-act-library` 这种编号根本没法手抄。

    所以把这些值集中成常量：引导弹窗的「复制演示凭据」、绑定页的
    「演示数据」提示都从这里取 —— 三处写死字符串迟早会不一致，
    而那种不一致表现为"提示里写的码填进去说无效"，极难查。
  */
  static const String demoActivityId = 'demo-act-library';
  static const String demoActivityTitle = '图书馆书架整理志愿服务';
  static const String demoUserNo = '2021001';
  static const String demoStudentName = '张伟';
  static const String demoInviteCode = 'DEMO0001';

  /// 演示发布者 ID。
  static const String ownerId = 'demo-owner-0001';

  final List<Map<String, Object?>> activities;
  final List<Map<String, Object?>> participants;
  final List<Map<String, Object?>> checkins;
  final List<Map<String, Object?>> tasks;
  final List<Map<String, Object?>> invites;
  String? adminToken;
  String? adminDeviceId;
  String? volunteerToken;
  String? volunteerActivityId;
  String? volunteerUserNo;
  int counter;

  /// 变更回调（宿主用它落盘）。
  void Function()? onChanged;

  void save() => onChanged?.call();

  int nextSeq() => ++counter;

  Map<String, Object?>? findActivity(String? idOrExternal) {
    if (idOrExternal == null || idOrExternal.isEmpty) {
      return null;
    }
    return activities
        .where((Map<String, Object?> a) =>
            a['id'] == idOrExternal || a['externalId'] == idOrExternal)
        .firstOrNull;
  }

  int participantCount(String activityId) =>
      participants.where((Map<String, Object?> p) => p['activityId'] == activityId).length;

  /// 把演示主活动的时间窗平移到"当前进行中"（仅在窗口已关闭时）。
  ///
  /// ## 为什么必须做
  ///
  /// 种子数据的时间是**首次进入演示模式那一刻**算出来的
  /// （开始时间 = 当时 −10 分钟，结束 = 当时 +110 分钟）。
  /// 但只要隔一天再打开，窗口就过期了：
  ///
  ///   * 用户端「去签到」按钮**根本不出现**（按时间窗判定）；
  ///   * 演示者会以为"签到功能坏了"，而实际是数据过期。
  ///
  /// 演示数据必须**随时打开都能走完流程**，否则验收会卡在第一步。
  /// 所以启动时检查一次：窗口关了就把活动整体平移到现在。
  ///
  /// 只动演示主活动（`demo-act-library`）—— 其余活动本来就是
  /// "未来 / 已结束 / 已取消"的样例，不该被改。
  void rollDemoWindowIfStale({DateTime? now}) {
    final DateTime t = now ?? DateTime.now();
    for (final Map<String, Object?> a in activities) {
      if (a['id'] != 'demo-act-library') {
        continue;
      }
      final DateTime? end = TimeFormat.tryParse(a['endTime']);
      if (end == null) {
        continue;
      }
      final int after = (a['checkinWindowAfter'] as int?) ?? 60;
      // 窗口还开着就什么都不做，避免每次启动都改时间。
      if (!t.isAfter(end.add(Duration(minutes: after)))) {
        continue;
      }
      final DateTime start = t.subtract(const Duration(minutes: 10));
      final DateTime newEnd = t.add(const Duration(minutes: 110));
      a['startTime'] = iso(start);
      a['endTime'] = iso(newEnd);
      a['durationHours'] = 2.0;
      a['updatedAt'] = iso(t);
    }
  }

  List<String> get organizers {
    final Set<String> set = <String>{};
    for (final Map<String, Object?> a in activities) {
      final String? o = a['organizer'] as String?;
      if (o != null && o.isNotEmpty) {
        set.add(o);
      }
    }
    return set.toList();
  }

  // ── 播种 ──────────────────────────────────────────────────────────────

  /// 确定性演示数据：**两端 App 播种完全相同的初始状态**。
  ///
  /// 为什么必须确定性：Android 两个 App 的沙箱互相隔离，离线模式下
  /// A 端建的活动 B 端看不到。所以两端各自播种同一份数据，
  /// 各自演示自己那一侧的流程（管理端看名单/复核，用户端签到/在岗）。
  /// 这个限制在界面上已标注为「演示模式」。
  static OfflineDemoState seeded() {
    final DateTime now = DateTime.now();
    final DateTime ongoingStart = now.subtract(const Duration(minutes: 10));
    final DateTime ongoingEnd = now.add(const Duration(minutes: 110));

    Map<String, Object?> act({
      required String id,
      required String title,
      required String organizer,
      required DateTime start,
      required DateTime end,
      required String location,
      required double lat,
      required double lng,
      required double radius,
      required String status,
      required String summary,
      int? quota,
    }) =>
        <String, Object?>{
          'id': id,
          'externalId': 'DEMO-$id',
          'title': title,
          'organizer': organizer,
          'durationHours': end.difference(start).inMinutes / 60.0,
          'startTime': iso(start),
          'endTime': iso(end),
          'location': location,
          'geoLat': lat,
          'geoLng': lng,
          'checkinRadius': radius,
          'locationType': 'outdoor',
          'wifiBssids': <Object?>[],
          'campusIpPrefixes': <Object?>[],
          'checkinWindowBefore': 30,
          'checkinWindowAfter': 60,
          'attendanceFirstDelay': 15,
          'attendanceInterval': 30,
          'attendanceResponseWindow': 5,
          'quota': quota,
          'enrolled': 0,
          'status': status,
          'summary': summary,
          'description': '',
          'contact': null,
          'ownerId': ownerId,
          'version': 1,
          'createdAt': iso(now),
          'updatedAt': iso(now),
        };

    final List<Map<String, Object?>> acts = <Map<String, Object?>>[
      act(
        id: 'demo-act-library',
        title: '图书馆书架整理志愿服务',
        organizer: '校青年志愿者协会',
        start: ongoingStart,
        end: ongoingEnd,
        location: '南湖校区图书馆三层',
        lat: 34.2175,
        lng: 117.1425,
        radius: 200,
        status: 'published',
        summary: '整理书架、引导读者，分组进行。',
        quota: 20,
      ),
      act(
        id: 'demo-act-guide',
        title: '校园文明劝导志愿活动',
        organizer: '校团委',
        start: now.add(const Duration(days: 1)),
        end: now.add(const Duration(days: 1, hours: 3)),
        location: '南湖校区东门广场',
        lat: 34.2168,
        lng: 117.1441,
        radius: 300,
        status: 'published',
        summary: '在东门广场开展文明劝导与秩序维护。',
        quota: 30,
      ),
      act(
        id: 'demo-act-lab',
        title: '实验室安全巡查志愿岗',
        organizer: '安全工程学院',
        start: now.subtract(const Duration(days: 3)),
        end: now.subtract(const Duration(days: 3, hours: -2)),
        location: '理科楼 A 座',
        lat: 34.2182,
        lng: 117.1395,
        radius: 150,
        status: 'finished',
        summary: '实验室安全隐患排查。',
      ),
      act(
        id: 'demo-act-sports',
        title: '运动会志愿服务（因雨天取消）',
        organizer: '体育部',
        start: now.subtract(const Duration(days: 1)),
        end: now.subtract(const Duration(days: 1, hours: -6)),
        location: '南湖校区田径场',
        lat: 34.2161,
        lng: 117.1466,
        radius: 300,
        status: 'cancelled',
        summary: '因连续降雨取消。',
      ),
    ];

    final List<Map<String, Object?>> people = <Map<String, Object?>>[
      <String, Object?>{
        'activityId': 'demo-act-library',
        'userNo': '2021001',
        'name': '张伟',
        'phone': '138****0001',
        'phoneSuffix': '0001',
        'signupStatus': 'signed',
        'checkinStatus': 'none',
        'inviteCodeIssued': false,
      },
      <String, Object?>{
        'activityId': 'demo-act-library',
        'userNo': '2021002',
        'name': '李娜',
        'phone': '139****0002',
        'phoneSuffix': '0002',
        'signupStatus': 'signed',
        // 预置一条"待人工确认"，让管理端一进来就能演示复核流程。
        'checkinStatus': 'pending_review',
        'inviteCodeIssued': false,
      },
      <String, Object?>{
        'activityId': 'demo-act-library',
        'userNo': '2021003',
        'name': '王强',
        'phone': '137****0003',
        'phoneSuffix': '0003',
        'signupStatus': 'signed',
        'checkinStatus': 'none',
        'inviteCodeIssued': false,
      },
    ];

    final List<Map<String, Object?>> seededCheckins = <Map<String, Object?>>[
      <String, Object?>{
        'id': 'demo-chk-seed-1',
        'activityId': 'demo-act-library',
        'userNo': '2021002',
        'name': '李娜',
        'method': 'geo',
        'status': 'pending_review',
        'reason': '证据强度不足（评分 45），已转人工确认',
        'geoLat': 34.21753,
        'geoLng': 117.14255,
        'accuracy': 35,
        'score': 45,
        'scoreBreakdown': <Object?>[
          <String, Object?>{'reason': '围栏内且距中心 8m（≤50m）', 'points': 40},
          <String, Object?>{'reason': '多次采样一致', 'points': 10},
          <String, Object?>{'reason': '定位精度 35m，未达加分档', 'points': -5},
        ],
        'distanceMeters': 8,
        'mockLocationDetected': false,
        'serverTime': iso(now.subtract(const Duration(minutes: 25))),
        'clientTime': iso(now.subtract(const Duration(minutes: 25))),
        'offlineBackfill': false,
      },
    ];

    for (final Map<String, Object?> a in acts) {
      a['enrolled'] = people.where((Map<String, Object?> p) => p['activityId'] == a['id']).length;
    }

    // 预置邀请码：演示模式下用户端要能**直接绑定**，
    // 否则验收者拿到 App 却卡在绑定页，还得先开管理端发码
    //（而两端沙箱隔离，管理端发的码在用户端看不见）。
    final List<Map<String, Object?>> seededInvites = <Map<String, Object?>>[
      for (int i = 0; i < people.length; i++)
        <String, Object?>{
          'activityId': people[i]['activityId'],
          'userNo': people[i]['userNo'],
          'name': people[i]['name'],
          'code': 'DEMO000${i + 1}',
          'expiresAt': iso(now.add(const Duration(days: 30))),
          'usedAt': null,
        },
    ];

    return OfflineDemoState(
      activities: acts,
      participants: people,
      checkins: seededCheckins,
      tasks: <Map<String, Object?>>[],
      invites: seededInvites,
      counter: 100,
    );
  }

  // ── 持久化 ────────────────────────────────────────────────────────────

  String toJsonString() => jsonEncode(<String, Object?>{
        'counter': counter,
        'activities': activities,
        'participants': participants,
        'checkins': checkins,
        'tasks': tasks,
        'invites': invites,
        if (adminToken != null) 'adminToken': adminToken,
        if (adminDeviceId != null) 'adminDeviceId': adminDeviceId,
        if (volunteerToken != null) 'volunteerToken': volunteerToken,
        if (volunteerActivityId != null) 'volunteerActivityId': volunteerActivityId,
        if (volunteerUserNo != null) 'volunteerUserNo': volunteerUserNo,
      });

  /// 恢复。解析失败时**退回种子数据**而不是抛异常 ——
  /// 一个坏文件不该让 App 起不来。
  static OfflineDemoState fromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return seeded();
    }
    try {
      final Map<String, Object?> m =
          (jsonDecode(raw) as Map<Object?, Object?>).cast<String, Object?>();
      List<Map<String, Object?>> list(Object? v) => ((v as List<Object?>?) ?? <Object?>[])
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> e) => e.cast<String, Object?>())
          .toList();
      return OfflineDemoState(
        activities: list(m['activities']),
        participants: list(m['participants']),
        checkins: list(m['checkins']),
        tasks: list(m['tasks']),
        invites: list(m['invites']),
        adminToken: m['adminToken'] as String?,
        adminDeviceId: m['adminDeviceId'] as String?,
        volunteerToken: m['volunteerToken'] as String?,
        volunteerActivityId: m['volunteerActivityId'] as String?,
        volunteerUserNo: m['volunteerUserNo'] as String?,
        counter: (m['counter'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return seeded();
    }
  }
}

/// 统一的 ISO-8601（带本地偏移，绝不输出 `Z`）。
String iso(DateTime d) {
  final int off = d.timeZoneOffset.inMinutes;
  String two(int n) => n.toString().padLeft(2, '0');
  final String sign = off >= 0 ? '+' : '-';
  final int abs = off.abs();
  return '${d.year}-${two(d.month)}-${two(d.day)}T'
      '${two(d.hour)}:${two(d.minute)}:${two(d.second)}'
      '$sign${two(abs ~/ 60)}:${two(abs % 60)}';
}

class _Req {
  _Req(this.method, this.path, this.query, this.headers, Object? rawBody)
      : body = rawBody is Map
            ? (rawBody as Map<Object?, Object?>).cast<String, Object?>()
            : <String, Object?>{};

  final String method;
  final String path;
  final Map<String, String>? query;
  final Map<String, String> headers;

  /// 已归一成 `Map`，避免各处对 `Object?` 取下标。
  final Map<String, Object?> body;
}

class _Ev {
  _Ev({
    required this.lat,
    required this.lng,
    required this.accuracy,
    required this.hasFix,
    this.wifiBssid,
    this.localIp,
    this.samples = const <_Sm>[],
    this.clientTime,
    this.mockFlagged = false,
  });

  final double lat;
  final double lng;
  final double accuracy;
  final bool hasFix;
  final String? wifiBssid;
  final String? localIp;
  final List<_Sm> samples;
  final DateTime? clientTime;
  final bool mockFlagged;

  /// 解析客户端上送的证据。
  ///
  /// ## 字段名必须与**生产序列化器**一致
  ///
  /// 真实形状（`CheckinDraft.toJson`）：
  ///
  /// ```json
  /// { "location": { "lat":, "lng":, "accuracy":, "samples": [...] },
  ///   "network":  { "wifiBssids": ["aa:bb:..."], "sourceIp": "10.3.229.13" },
  ///   "device":   { "mockLocationDetected": false } }
  /// ```
  ///
  /// 我最初按"直觉"写成 `body.samples` / `network.wifiBssid` / `network.localIp`，
  /// 真机结果就是评分只有 40 分（只剩围栏），采样与校园网两项**静默失分**，
  /// 于是永远转人工确认。测试当时没抓到，因为测试里也是手写的扁平载荷 ——
  /// **没有用生产序列化器**。现在测试已改为直接喂 `CheckinDraft.toJson()`。
  ///
  /// 同时保留扁平字段兜底：本地离线队列里可能还躺着按旧格式
  /// 序列化的证据（`geoLat`/`samples` 在顶层），那些数据尚未补传，不能丢。
  static _Ev from(Object? body) {
    final Map<String, Object?> b = body is Map
        ? (body as Map<Object?, Object?>).cast<String, Object?>()
        : <String, Object?>{};
    Map<String, Object?> sub(String key) => b[key] is Map
        ? (b[key]! as Map<Object?, Object?>).cast<String, Object?>()
        : <String, Object?>{};

    final Map<String, Object?> loc = sub('location');
    final Map<String, Object?> dev = sub('device');
    final Map<String, Object?> net = sub('network');

    final double? lat = (loc['lat'] as num?)?.toDouble() ?? (b['geoLat'] as num?)?.toDouble();
    final double? lng = (loc['lng'] as num?)?.toDouble() ?? (b['geoLng'] as num?)?.toDouble();
    final double acc =
        (loc['accuracy'] as num?)?.toDouble() ?? (b['accuracy'] as num?)?.toDouble() ?? 999;

    // 采样：契约在 `location.samples`，早期扁平在顶层 `samples`。
    final Object? rawSamples = loc['samples'] ?? b['samples'];
    final List<_Sm> samples = <_Sm>[];
    if (rawSamples is List) {
      for (final Object? s in rawSamples) {
        if (s is Map) {
          final Map<String, Object?> sm = s.cast<String, Object?>();
          samples.add(_Sm(
            lat: (sm['lat'] as num?)?.toDouble() ?? 0,
            lng: (sm['lng'] as num?)?.toDouble() ?? 0,
            accuracy: (sm['accuracy'] as num?)?.toDouble() ?? 0,
          ));
        }
      }
    }

    // Wi-Fi：契约是**数组** `network.wifiBssids`；单值写法是早期形态。
    String? wifi;
    final Object? rawWifi = net['wifiBssids'] ?? b['wifiBssids'];
    if (rawWifi is List && rawWifi.isNotEmpty) {
      wifi = '${rawWifi.first}';
    }
    wifi ??= (net['wifiBssid'] as String?) ?? (b['wifiBssid'] as String?);

    // 源 IP：契约叫 `sourceIp`（不是 `localIp`）。
    final String? localIp = (net['sourceIp'] as String?) ??
        (net['localIp'] as String?) ??
        (b['sourceIp'] as String?) ??
        (b['localIp'] as String?);

    return _Ev(
      lat: lat ?? 0,
      lng: lng ?? 0,
      accuracy: acc,
      hasFix: lat != null && lng != null && lat != 0 && lng != 0,
      wifiBssid: wifi,
      localIp: localIp,
      samples: samples,
      clientTime: TimeFormat.tryParse(b['clientTime']),
      mockFlagged: (dev['mockLocationDetected'] as bool?) ??
          (b['mockLocationDetected'] as bool?) ??
          false,
    );
  }
}
class _Sm {
  _Sm({required this.lat, required this.lng, required this.accuracy});
  final double lat;
  final double lng;
  final double accuracy;
}

class _Score {
  _Score({
    required this.score,
    required this.status,
    required this.reason,
    required this.breakdown,
    required this.distance,
    required this.mockDetected,
  });

  final int score;
  final String status;
  final String reason;
  final List<Map<String, Object?>> breakdown;
  final double distance;
  final bool mockDetected;
}

/// 错误码 → HTTP 语义状态码。
///
/// `ApiErrorCode` 只有平台错误码（8 个授权值），**没有** HTTP 状态；
/// 真实服务端是在 `envelope.js` 里单独维护映射。演示引擎需要同一套语义，
/// 否则客户端按 HTTP 状态做的兜底分支会在离线模式下表现不一致。
int _httpStatusFor(ApiErrorCode code) => switch (code.value) {
      0 => 200,
      40001 || -1 || -2 || -99 => 400,
      40101 => 401,
      40301 => 403,
      40401 => 404,
      40901 => 409,
      42901 => 429,
      _ => 500,
    };

class _Fail implements Exception {
  _Fail(this.code, this.message);
  final ApiErrorCode code;
  final String message;
  @override
  String toString() => message;
}
