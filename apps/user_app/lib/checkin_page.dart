import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_platform/shared_platform.dart';
import 'package:shared_ui/shared_ui.dart';

/// 签到页（方案 §5.3、§6.1；验收 A11–A16）。
///
/// ## 判定完全在服务端（方案 §2）
///
/// 客户端的职责只有两件：**采集证据**、**展示服务端的结论**。
/// 它不计算"是否在围栏内"，也不预测结果。
///
/// 唯一的例外是**本地距离显示**（"距签到点约 120 米"）——
/// 那是给用户看的辅助信息，帮他在还没提交前判断要不要再走近一点。
/// 它**不是判定**，界面措辞也刻意区分（"约"、"仅供参考"）。
///
/// ## 验收 A15：提交后不得自行宣布成功
///
/// 服务端响应到达前，界面只能显示「提交中，正在由服务端判定」。
/// 这是硬要求：如果客户端自己先显示"签到成功"，一旦服务端判为
/// 待确认或被驳回，用户已经走开了 —— 而他会以为自己签上了。
class CheckinPage extends StatefulWidget {
  const CheckinPage({
    required this.activity,
    this.onDone,
    super.key,
  });

  final Activity activity;

  /// 完成（或被驳回）后的回调，用于让上一页刷新。
  final VoidCallback? onDone;

  @override
  State<CheckinPage> createState() => _CheckinPageState();
}

/// 签到页的阶段。
enum _Stage {
  /// 尚未采集：显示活动信息与"开始签到"按钮。
  ///
  /// 刻意**不自动采集**：方案 §7 要求"定位只按需采集"。
  /// 一进页面就取定位，等于把权限弹窗与位置读取强加给只是来浏览的用户。
  ready,

  /// 正在采集定位与设备证据。
  collecting,

  /// 已提交，等待服务端判定（验收 A15：此时不得宣布成功）。
  submitting,

  /// 已有结论。
  done,
}

class _CheckinPageState extends State<CheckinPage> {
  _Stage _stage = _Stage.ready;
  AppError? _error;
  Checkin? _result;

  /// 本地采集到的证据（仅用于展示与提交，不作为判定）。
  PositionFix? _fix;
  List<PositionFix> _samples = const <PositionFix>[];

  /// 本地估算的距离（仅供参考）。
  double? _approxDistance;

  /// 采集到的网络/设备辅证。
  String? _wifiBssid;
  String? _localIp;
  String? _deviceId;

  /// 离线入队后的提示。
  bool _queuedOffline = false;

  /// 倒计时用的当前时间（由 Timer 驱动刷新）。
  DateTime _now = DateTime.now();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 每 30 秒刷新一次倒计时。间隔刻意不短于 30 秒：
    // 秒级跳动会让人盯着屏幕等，而这里的时间尺度是分钟。
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        setState(() => _now = DateTime.now());
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// 是否在签到时间窗内（**本地判断，仅用于界面提示**）。
  ///
  /// 真正的窗口校验在服务端。这里只是为了在窗口关闭时
  /// 不去做一次注定失败的定位采集 —— 省电，也省得用户白等。
  bool get _inWindow {
    final DateTime now = _now;
    return !now.isBefore(widget.activity.checkinOpensAt) &&
        !now.isAfter(widget.activity.checkinClosesAt);
  }

  /// 距窗口关闭还有多久。已关闭返回 `null`。
  Duration? get _timeLeft {
    final Duration d = widget.activity.checkinClosesAt.difference(_now);
    return d.isNegative ? null : d;
  }

  Future<void> _collect() async {
    setState(() {
      _stage = _Stage.collecting;
      _error = null;
      _queuedOffline = false;
    });

    final AppServices services = AppScope.of(context);

    // ── 1. 权限 ────────────────────────────────────────────────────────
    final LocationPermissionState perm = await services.location.ensurePermission();
    if (!mounted) {
      return;
    }
    if (perm == LocationPermissionState.deniedForever) {
      // 「永久拒绝」必须给一条**能自救**的路径（方案 §7 不得出现死路）。
      //
      // 文案里点名「发布者现场核实」而不是笼统说"联系管理员"：
      // 本平台不启用动态签到码（决策 D-2），这是唯一真正可走的降级路径，
      // 必须让志愿者知道该找谁。
      setState(() {
        _stage = _Stage.ready;
        _error = AppError.local(
          title: '定位权限被永久拒绝',
          message: '本平台不启用签到码，签到需要定位作为在场证据。'
              '你可以请发布者现场核实（他可以在管理端为你记录），'
              '或在系统设置里重新开启定位权限。',
          actionHint: '点下方按钮可直接打开本应用的系统设置页。',
          canRetry: false,
        );
      });
      return;
    }
    if (perm == LocationPermissionState.denied) {
      setState(() {
        _stage = _Stage.ready;
        _error = AppError.local(
          title: '需要定位权限',
          message: '签到需要一次定位作为在场证据（不采集持续轨迹）。'
              '若你不方便开启定位，可以请发布者现场核实。',
          actionHint: '点击「开始签到」会再次弹出系统授权框。',
          canRetry: true,
        );
      });
      return;
    }

    // ── 2. 采样（3 次约 3 秒，方案 §5.3）────────────────────────────
    try {
      final List<PositionFix> samples = await services.location.collectSamples();
      if (!mounted) {
        return;
      }
      final PositionFix best = LocationService.bestOf(samples);
      _samples = samples;
      _fix = best;

      // 本地距离估算（仅供界面参考，见类文档的说明）。
      if (_hasUsableFix(best)) {
        _approxDistance = best.point.distanceTo(
          GeoPoint(lat: widget.activity.geoLat, lng: widget.activity.geoLng),
        );
      }
    } on LocationException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _stage = _Stage.ready;
        _error = _locationError(e);
      });
      return;
    }

    // ── 3. 网络与设备辅证（加分项，取不到不影响提交）─────────────────
    try {
      final String? bssid = await services.connectivity.wifiBssid();
      final String? ip = await services.connectivity.localIp();
      _wifiBssid = bssid;
      _localIp = ip;
    } catch (_) {
      // 辅证取不到就跳过：它是加分项，不是必需项。
      // 这里**刻意吞掉异常**（与"不吞业务异常"的原则不冲突）：
      // 读 Wi-Fi 名称在部分 ROM 上需要额外权限，失败不该阻断签到。
    }
    _deviceId = await services.device.deviceId();

    if (!mounted) {
      return;
    }
    await _submit();
  }

  Future<void> _submit() async {
    final PositionFix? fix = _fix;
    if (fix == null || !_hasUsableFix(fix)) {
      setState(() {
        _stage = _Stage.ready;
        _error = AppError.local(
          title: '未取得有效定位',
          message: '本次没有取到可用坐标。请到室外或窗边重试；'
              '若一直失败，请发布者现场核实。',
          canRetry: true,
        );
      });
      return;
    }

    setState(() {
      _stage = _Stage.submitting;
      _error = null;
    });

    final AppServices services = AppScope.of(context);
    final CheckinDraft draft = CheckinDraft(
      activityId: widget.activity.id,
      idempotencyKey: services.api.newIdempotencyKey(),
      method: CheckinMethod.geo,
      clientTime: services.clock.now(),
      // 上报**完整采样序列**（而不是只报数量）：
      // 服务端要靠"多次采样是否一致"识别伪造坐标（评分表的 +10 项）。
      samples: _samples.map((PositionFix p) => p.toSample()).toList(),
      wifiBssid: _wifiBssid,
      localIp: _localIp,
      deviceId: _deviceId,
      mockLocationDetected: LocationService.anyMockDetected(_samples),
    );

    // 离线时直接入队，不等超时（方案 §9）。
    final ConnectivityState conn = await services.connectivity.state();
    if (!mounted) {
      return;
    }
    if (!conn.isOnline) {
      services.queue.enqueueCheckin(activityId: widget.activity.id, draft: draft);
      setState(() {
        _stage = _Stage.ready;
        _queuedOffline = true;
        _error = AppError.local(
          title: '当前离线，已保存在本机',
          message: '联网后会自动上传并补判。'
              '注意：过了签到时段才上传的，会转人工确认（这是为了防止事后补造证据）。',
          actionHint: '你也可以稍后在「我的记录」里手动重试。',
          canRetry: false,
        );
      });
      return;
    }

    final ApiResult<Checkin> result = await services.api.post<Checkin>(
      CheckinPaths.submit(widget.activity.id),
      body: draft.toJson(),
      idempotencyKey: draft.idempotencyKey,
      // 签到是幂等的（服务端按幂等键去重），重试安全；
      // 但这里不用客户端重试——一次超时后用户自己再点更可控。
      retryable: false,
      decode: (Object? data) {
        final Map<String, dynamic> m = (data! as Map<Object?, Object?>)
            .cast<String, dynamic>();
        final Object? inner = m['checkin'];
        return Checkin.fromJson(
          (inner is Map ? inner.cast<String, dynamic>() : m),
        );
      },
    );

    if (!mounted) {
      return;
    }

    switch (result) {
      case ApiSuccess<Checkin>(:final Checkin value):
        setState(() {
          _stage = _Stage.done;
          _result = value;
        });
        widget.onDone?.call();

      case ApiFailure<Checkin>():
        // 网络类失败：入队，让用户不必重填。
        final AppError err = AppError.fromApi(result);
        if (result.isOffline || result.isTimeout) {
          services.queue.enqueueCheckin(activityId: widget.activity.id, draft: draft);
          setState(() {
            _stage = _Stage.ready;
            _queuedOffline = true;
            _error = err;
          });
        } else {
          setState(() {
            _stage = _Stage.ready;
            _error = err;
          });
        }
    }
  }

  /// 坐标是否可用于提交。
  ///
  /// 与服务端 `respondAttendance` 里的 `hasFix` 判定同口径：
  /// 经纬度必须是有限数，且不能是 (0,0)（那通常表示"没定位到"，
  /// 而不是"在几内亚湾"）。本地只做这一层粗筛，**判定仍在服务端**。
  static bool _hasUsableFix(PositionFix fix) {
    final double lat = fix.point.lat;
    final double lng = fix.point.lng;
    if (!lat.isFinite || !lng.isFinite) {
      return false;
    }
    if (lat == 0 && lng == 0) {
      return false;
    }
    return true;
  }

  AppError _locationError(LocationException e) {
    final String reason = e.reason.label;
    return switch (e.reason) {
      LocationFailureReason.serviceDisabled => AppError.local(
          title: '定位服务未开启',
          message: '请在系统设置中打开定位开关后重试。',
          actionHint: '本平台不启用签到码，无法用别的方式替代定位证据。',
          canRetry: true,
        ),
      LocationFailureReason.timeout => AppError.local(
          title: '定位超时',
          message: '信号较弱。请到开阔处或窗边再试一次。',
          canRetry: true,
        ),
      LocationFailureReason.permissionDenied => AppError.local(
          title: '未获得定位权限',
          message: '签到需要一次定位作为在场证据。',
          canRetry: true,
        ),
      _ => AppError.local(
          title: '定位失败',
          message: reason,
          actionHint: '若反复失败，请请发布者现场核实。',
          canRetry: true,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('签到')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Spacing.pageGutter),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: Sizes.maxContentWidth),
              child: _buildBody(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final Checkin? result = _result;
    if (_stage == _Stage.done && result != null) {
      return _ResultView(
        checkin: result,
        activity: widget.activity,
        approxDistance: _approxDistance,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _ActivitySummary(activity: widget.activity),
        const SizedBox(height: Spacing.md),
        _WindowCard(
          activity: widget.activity,
          now: _now,
          inWindow: _inWindow,
          timeLeft: _timeLeft,
        ),
        const SizedBox(height: Spacing.md),
        if (_fix != null) _EvidenceCard(fix: _fix!, distance: _approxDistance),
        if (_fix != null) const SizedBox(height: Spacing.md),
        if (_queuedOffline) ...<Widget>[
          const StatusChip.detailed(
            visual: StatusVisual(
              label: '已保存到本机',
              tone: StatusTone.warning,
              icon: Icons.cloud_off,
              description: '联网后自动上传。上传时会由服务端判定，可能转人工确认。',
            ),
          ),
          const SizedBox(height: Spacing.md),
        ],
        if (_error != null) ...<Widget>[
          _ErrorBanner(
            error: _error!,
            // ⚠️ 只在**重试无意义**时才给"打开系统设置"。
            //
            // 临时拒绝（canRetry = true）时正确的动作是**再点一次**
            // （系统会重新弹授权框）。同时给出"去设置"会把用户引到
            // 一条多余的路上——而那条路更长、更容易走错。
            onOpenSettings: _error!.canRetry ? null : _openSystemSettings,
          ),
          const SizedBox(height: Spacing.md),
        ],
        _ActionArea(
          stage: _stage,
          inWindow: _inWindow,
          onStart: _collect,
          onRetry: _submit,
        ),
        const SizedBox(height: Spacing.md),
        const _Disclaimer(),
      ],
    );
  }

  Future<void> _openSystemSettings() async {
    final AppServices services = AppScope.of(context);
    await services.location.openAppSettings();
  }
}

/// 活动摘要。
class _ActivitySummary extends StatelessWidget {
  const _ActivitySummary({required this.activity});

  final Activity activity;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(activity.title, style: text.titleMedium),
          const SizedBox(height: Spacing.xs),
          InfoRow(label: '地点', value: activity.location, icon: Icons.place_outlined),
          InfoRow(
            label: '时间',
            value: TimeFormat.format(activity.checkinOpensAt),
            icon: Icons.schedule,
          ),
        ],
      ),
    );
  }
}

/// 时间窗卡片：明确告诉用户"现在能不能签、还剩多久"。
///
/// 这一段的存在是为了消除现场最常见的困惑：
/// "为什么按钮点不动？" —— 直接告诉他窗口什么时候开/关。
class _WindowCard extends StatelessWidget {
  const _WindowCard({
    required this.activity,
    required this.now,
    required this.inWindow,
    required this.timeLeft,
  });

  final Activity activity;
  final DateTime now;
  final bool inWindow;
  final Duration? timeLeft;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    final StatusVisual visual;
    final String message;
    if (inWindow) {
      visual = const StatusVisual(
        label: '可以签到',
        tone: StatusTone.success,
        icon: Icons.check_circle_outline,
      );
      final Duration? left = timeLeft;
      message = left == null
          ? '签到时段开放中。'
          : '签到将于 ${TimeFormat.format(activity.checkinClosesAt)} 关闭'
              '（还剩 ${_humanize(left)}）。';
    } else if (now.isBefore(activity.checkinOpensAt)) {
      visual = const StatusVisual(
        label: '尚未开放',
        tone: StatusTone.info,
        icon: Icons.schedule,
      );
      message = '签到将于 ${TimeFormat.format(activity.checkinOpensAt)} 开放。'
          '到时回到本页即可签到。';
    } else {
      visual = const StatusVisual(
        label: '签到时段已结束',
        tone: StatusTone.danger,
        icon: Icons.timer_off_outlined,
      );
      // ⚠️ 必须给出下一步，否则就是死路（方案 §7）。
      message = '签到时段已于 ${TimeFormat.format(activity.checkinClosesAt)} 结束。'
          '如你确实到场了，请请发布者现场为你确认。';
    }

    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: visual.background,
        borderRadius: Radii.cardRadius,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(visual.icon, size: Sizes.iconLg, color: visual.foreground),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  visual.label,
                  style: text.titleSmall?.copyWith(color: visual.onBackground),
                ),
                const SizedBox(height: Spacing.xxs),
                Text(
                  message,
                  style: text.bodySmall?.copyWith(color: visual.onBackground),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _humanize(Duration d) {
    if (d.inHours >= 1) {
      final int h = d.inHours;
      final int m = d.inMinutes % 60;
      return m == 0 ? '$h 小时' : '$h 小时 $m 分钟';
    }
    if (d.inMinutes >= 1) {
      return '${d.inMinutes} 分钟';
    }
    return '不到 1 分钟';
  }
}

/// 证据卡片：把"采集到了什么"如实展示出来。
///
/// 为什么要把精度、距离都摆出来：签约判定的争议大多来自
/// "我觉得我在里面啊"。把定位精度（例如 ±35m）与估算距离摆出来，
/// 用户自己就能理解为什么会被判待确认 —— 这比事后解释有效得多。
class _EvidenceCard extends StatelessWidget {
  const _EvidenceCard({required this.fix, this.distance});

  final PositionFix fix;
  final double? distance;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('已采集的证据', style: text.titleSmall),
          const SizedBox(height: Spacing.xs),
          InfoRow(
            label: '定位精度',
            value: '±${fix.accuracy.round()} 米',
            icon: Icons.gps_fixed,
          ),
          if (distance != null)
            InfoRow(
              label: '距签到点',
              value: '约 ${distance!.round()} 米（仅供参考）',
              icon: Icons.straighten,
            ),
          if (fix.isMock)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: StatusChip.detailed(
                visual: const StatusVisual(
                  label: '检测到模拟定位',
                  tone: StatusTone.danger,
                  icon: Icons.warning_amber_outlined,
                  description: '本次签到会转人工确认。若你未使用模拟定位软件，'
                      '请检查是否开启了「开发者选项」中的模拟位置。',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 操作区。
class _ActionArea extends StatelessWidget {
  const _ActionArea({
    required this.stage,
    required this.inWindow,
    required this.onStart,
    required this.onRetry,
  });

  final _Stage stage;
  final bool inWindow;
  final Future<void> Function() onStart;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    // 提交中：**禁止任何操作**，并明确说明正在等谁（验收 A15）。
    if (stage == _Stage.submitting) {
      return Column(
        children: <Widget>[
          const AppButton(
            label: '提交中',
            loading: true,
            loadingLabel: '正在由服务端判定…',
            onPressed: null,
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            '请勿关闭页面。判定结果由服务端给出，此处不会提前显示成功。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      );
    }

    if (stage == _Stage.collecting) {
      return const AppButton(
        label: '正在采集定位…',
        loading: true,
        loadingLabel: '正在采集定位（约 3 秒）…',
        onPressed: null,
      );
    }

    // 窗口未开：按钮禁用，但**说明为什么**（在 _WindowCard 里）。
    if (!inWindow) {
      return const AppButton(label: '不在签到时段', onPressed: null);
    }

    return AppButton(
      label: '开始签到',
      icon: Icons.my_location,
      onPressed: onStart,
    );
  }
}

/// 结果页。
class _ResultView extends StatelessWidget {
  const _ResultView({
    required this.checkin,
    required this.activity,
    this.approxDistance,
  });

  final Checkin checkin;
  final Activity activity;
  final double? approxDistance;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final StatusVisual visual = StatusVisuals.ofCheckin(checkin.status);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: Spacing.lg),
        Icon(
          visual.icon ?? Icons.info_outline,
          size: 64,
          color: visual.foreground,
        ),
        const SizedBox(height: Spacing.md),
        Text(
          visual.label,
          textAlign: TextAlign.center,
          style: text.headlineMedium?.copyWith(color: visual.foreground),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          activity.title,
          textAlign: TextAlign.center,
          style: text.bodyMedium,
        ),

        const SizedBox(height: Spacing.lg),
        if (visual.description != null)
          StatusChip.detailed(
            visual: StatusVisual(
              label: '说明',
              tone: visual.tone,
              icon: Icons.info_outline,
              description: visual.description,
            ),
          ),

        // 被驳回时给出服务端的具体原因（它知道为什么），并指向补救路径。
        if (checkin.status == CheckinStatus.rejected) ...<Widget>[
          const SizedBox(height: Spacing.md),
          _ErrorBanner(
            error: AppError.local(
              title: '未通过',
              message: (checkin.reason ?? '').isNotEmpty
                  ? checkin.reason!
                  : '服务端未通过本次签到。',
              actionHint: '如你确实到场，请请发布者现场为你确认。',
              canRetry: false,
            ),
          ),
        ],

        const SizedBox(height: Spacing.lg),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('记录详情', style: text.titleSmall),
              const SizedBox(height: Spacing.xs),
              InfoRow(
                label: '签到时间',
                // serverTime 是服务端时间（方案 §9：不信任设备时间）。
                // 空值只可能出现在极端的解析异常下，退回"服务端未返回"。
                value: checkin.serverTime == null
                    ? '服务端未返回'
                    : TimeFormat.format(checkin.serverTime!, withSeconds: true),
                icon: Icons.access_time,
              ),
              InfoRow(
                label: '签到方式',
                value: checkin.method.label,
                icon: Icons.my_location,
              ),
              if (approxDistance != null)
                InfoRow(
                  label: '距签到点',
                  value: '约 ${approxDistance!.round()} 米',
                  icon: Icons.straighten,
                ),
              if (checkin.score != null)
                InfoRow(
                  label: '证据评分',
                  value: '${checkin.score}（服务端计算，仅供参考）',
                  icon: Icons.rule,
                ),
            ],
          ),
        ),

        const SizedBox(height: Spacing.lg),
        Text(
          '本次记录已由服务端确认。结果仅作现场管理参考，不自动产生任何时长扣减。',
          textAlign: TextAlign.center,
          style: text.bodySmall,
        ),
      ],
    );
  }
}

/// 免责与隐私说明。
///
/// 方案 §7 与 README §3.3 都要求明示采集范围。放在**签到按钮下方**而不是
/// 藏在设置里：用户按下按钮前就应该知道要采集什么。
class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) {
    return Text(
      '签到时会获取一次定位作为在场证据，不采集持续轨迹。'
      '位置信息仅用于本次签到判定，不对外公开。',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.labelSmall,
    );
  }
}

/// 错误提示条（可带"打开系统设置"动作）。
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.error, this.onOpenSettings});

  final AppError error;
  final Future<void> Function()? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: const BoxDecoration(
        color: AppColors.dangerContainer,
        borderRadius: BorderRadius.all(Radius.circular(Radii.md)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.error_outline, size: Sizes.iconMd, color: AppColors.danger),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Text(
                  error.title,
                  style: text.titleSmall?.copyWith(color: AppColors.onDangerContainer),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xxs),
          Text(
            error.message,
            style: text.bodySmall?.copyWith(color: AppColors.onDangerContainer),
          ),
          if (error.actionHint != null) ...<Widget>[
            const SizedBox(height: Spacing.xxs),
            Text(
              error.actionHint!,
              style: text.bodySmall?.copyWith(color: AppColors.onDangerContainer),
            ),
          ],
          if (onOpenSettings != null) ...<Widget>[
            const SizedBox(height: Spacing.xs),
            TextButton.icon(
              onPressed: onOpenSettings,
              icon: const Icon(Icons.settings, size: Sizes.iconSm),
              label: const Text('打开系统设置'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.onDangerContainer,
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
              ),
            ),
          ],
          if (error.diagnostic != null) ...<Widget>[
            const SizedBox(height: Spacing.xs),
            SelectableText(
              error.diagnostic!,
              style: text.labelSmall?.copyWith(
                fontFamily: 'monospace',
                color: AppColors.onDangerContainer,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
