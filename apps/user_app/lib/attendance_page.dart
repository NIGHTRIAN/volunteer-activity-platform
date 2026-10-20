import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_platform/shared_platform.dart';
import 'package:shared_ui/shared_ui.dart';

/// 在岗确认页（方案 §5.4、§6.2；验收 A17–A19）。
///
/// ## 交互的唯一定位：**一个按钮，零输入**（验收 A17）
///
/// 页面上只有一个主操作「我在现场」。用户不需要输入、不需要扫码、
/// 不需要选择任何东西。定位由 App 在后台自动采集。
///
/// 这条要求不是"体验优化"，而是**现场可用性的前提**：
/// 志愿者可能正在搬书、正在引导读者、手上戴着手套。
/// 要求他做任何输入，这个功能在真实场景里就不会被用。
///
/// ## 两条不能妥协的规则
///
/// 1. **倒计时必须显示**，而且以**服务端时间**为基准（方案 §9：
///    设备时间可能不准）。让人盯着一个不知道还剩多久的按钮，
///    是现场抱怨的主要来源。
/// 2. **没有定位证据就不算完成**（验收 A19：仅点按"我在"而无现场证据
///    不得通过）。客户端不能因为"用户点了"就认为成功 ——
///    它会明确显示"正在采集/正在判定"，结果由服务端给。
class AttendancePage extends StatefulWidget {
  const AttendancePage({
    required this.activityId,
    this.activityTitle,
    super.key,
  });

  final String activityId;
  final String? activityTitle;

  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage> {
  AppController<List<AttendanceTask>>? _tasks;

  /// 正在确认的任务 ID（防止连点）。
  String? _confirmingId;

  /// 已完成的确认结果（用于在卡片上就地显示结论）。
  final Map<String, AttendanceTask> _results = <String, AttendanceTask>{};

  final Map<String, AppError> _errors = <String, AppError>{};

  /// 倒计时刷新用的当前时间。
  DateTime _now = DateTime.now();
  Timer? _ticker;

  /// 服务端时间与本机时间的偏差。
  ///
  /// 方案 §9 明确"设备时间可能不准"，因此倒计时以服务端时间为准。
  /// 这里持续观测，取最近一次的偏差。
  final ClockSkewMonitor _skew = ClockSkewMonitor();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _now = DateTime.now());
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_tasks != null) {
      return;
    }
    final AppServices services = AppScope.of(context);
    _tasks = AppController<List<AttendanceTask>>(
      load: () => _fetch(services),
    )..load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _tasks?.dispose();
    super.dispose();
  }

  /// 「服务端校正后」的当前时间。
  ///
  /// 若从未拿到服务端时间（例如一直离线），退回本机时间并
  /// 由界面标注"时间可能不准"。**不假装准确**：
  /// 倒计时错了会让用户错过响应窗口，那比不显示倒计时更糟。
  DateTime get _serverNow => _skew.correctedNow(deviceNow: _now);

  /// 是否已观测到服务端时间。
  ///
  /// `ClockSkewMonitor.skew` 为 `null` 即表示还没拿到过服务端时间。
  bool get _hasServerTime => _skew.skew != null;

  Future<List<AttendanceTask>> _fetch(AppServices services) async {
    final ApiResult<Map<String, dynamic>> result =
        await services.api.get<Map<String, dynamic>>(
      AttendancePaths.tasks(widget.activityId),
      decode: (Object? data) =>
          (data! as Map<Object?, Object?>).cast<String, dynamic>(),
    );

    switch (result) {
      case ApiSuccess<Map<String, dynamic>>(:final Map<String, dynamic> value):
        // 记录服务端时间，供倒计时校正。
        final DateTime? serverTime = TimeFormat.tryParse(value['serverTime']);
        if (serverTime != null) {
          _skew.observe(serverTime);
        }
        final Object? raw = value['items'];
        if (raw is! List) {
          return <AttendanceTask>[];
        }
        return raw
            .whereType<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> m) =>
                AttendanceTask.fromJson(m.cast<String, dynamic>()))
            .toList();

      case ApiFailure<Map<String, dynamic>>():
        throw AppError.fromApi(result);
    }
  }

  /// 确认在岗。**用户唯一需要做的动作就是点这个按钮。**
  Future<void> _confirm(AttendanceTask task) async {
    if (_confirmingId != null) {
      // 已有一个在途：直接忽略后续点击，避免并发提交。
      return;
    }
    setState(() {
      _confirmingId = task.id;
      _errors.remove(task.id);
    });

    final AppServices services = AppScope.of(context);

    try {
      // ── 自动采集证据（用户无需做任何输入）────────────────────────
      final LocationPermissionState perm =
          await services.location.ensurePermission();
      if (!mounted) {
        return;
      }
      if (perm == LocationPermissionState.deniedForever) {
        setState(() {
          _confirmingId = null;
          _errors[task.id] = AppError.local(
            title: '定位权限被永久拒绝',
            message: '在岗确认需要一次定位作为在岗证据。'
                '请在系统设置中重新开启，或请发布者现场为你补录。',
            actionHint: '点下方按钮打开系统设置。',
            canRetry: false,
          );
        });
        return;
      }
      if (perm == LocationPermissionState.denied) {
        setState(() {
          _confirmingId = null;
          _errors[task.id] = AppError.local(
            title: '需要定位权限',
            message: '在岗确认需要一次定位作为在岗证据。',
            canRetry: true,
          );
        });
        return;
      }

      final List<PositionFix> samples = await services.location.collectSamples();
      if (!mounted) {
        return;
      }
      final PositionFix best = LocationService.bestOf(samples);

      // 离线：入队，联网后自动补传（方案 §9）。
      final ConnectivityState conn = await services.connectivity.state();
      if (!mounted) {
        return;
      }
      if (!conn.isOnline) {
        services.queue.enqueueAttendance(
          activityId: widget.activityId,
          taskId: task.id,
          point: best.point,
          accuracy: best.accuracy,
          respondedAt: services.clock.now(),
          mockLocationDetected: LocationService.anyMockDetected(samples),
        );
        setState(() {
          _confirmingId = null;
          _errors[task.id] = AppError.local(
            title: '当前离线，已保存到本机',
            message: '联网后会自动上传。注意：响应窗口不会因为你离线而延长，'
                '超时上传的会按服务端规则结算。',
            canRetry: false,
          );
        });
        return;
      }

      // ── 提交（服务端判定，客户端不预测结果）─────────────────────
      final ApiResult<Map<String, dynamic>> result =
          await services.api.post<Map<String, dynamic>>(
        AttendancePaths.confirm(task.id),
        body: <String, Object?>{
          'method': CheckinMethod.geo.wire,
          'location': <String, Object?>{
            'lat': best.point.lat,
            'lng': best.point.lng,
            'accuracy': best.accuracy,
          },
          'device': <String, Object?>{
            'mockLocationDetected': LocationService.anyMockDetected(samples),
          },
          // 完整采样用于服务端交叉验证（与签到同一口径）。
          'samples': samples
              .map((PositionFix p) => <String, Object?>{
                    'lat': p.point.lat,
                    'lng': p.point.lng,
                    'accuracy': p.accuracy,
                    'capturedAt': TimeFormat.toIso8601(p.capturedAt),
                  })
              .toList(),
        },
        idempotencyKey: services.api.newIdempotencyKey(),
        retryable: false,
        decode: (Object? data) =>
            (data! as Map<Object?, Object?>).cast<String, dynamic>(),
      );

      if (!mounted) {
        return;
      }

      switch (result) {
        case ApiSuccess<Map<String, dynamic>>(:final Map<String, dynamic> value):
          final Object? rawTask = value['task'];
          if (rawTask is Map) {
            _results[task.id] =
                AttendanceTask.fromJson(rawTask.cast<String, dynamic>());
          }
          // 服务端可能返回"精度不足，转人工"——那不是错误，
          // 但必须让用户知道，否则他会以为自己已经完成了。
          final Object? msg = value['message'];
          setState(() {
            _confirmingId = null;
            if (value['needsManualReview'] == true && msg != null) {
              _errors[task.id] = AppError.local(
                title: '已提交，待发布者确认',
                message: msg.toString(),
                actionHint: '你可以继续参加活动，发布者会现场核对。',
                canRetry: false,
              );
            }
          });

        case ApiFailure<Map<String, dynamic>>():
          setState(() {
            _confirmingId = null;
            _errors[task.id] = AppError.fromApi(result);
          });
      }
    } on LocationException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _confirmingId = null;
        _errors[task.id] = AppError.local(
          title: '定位失败',
          message: e.reason.label,
          actionHint: '请到开阔处重试；若一直失败，请请发布者现场为你补录。',
          canRetry: true,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('在岗确认'),
        bottom: widget.activityTitle == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(24),
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: Spacing.md,
                    right: Spacing.md,
                    bottom: Spacing.xs,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      widget.activityTitle!,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    final AppController<List<AttendanceTask>>? c = _tasks;
    if (c == null) {
      return const LoadingView();
    }

    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, Widget? _) {
        final AppResult<List<AttendanceTask>> state = c.state;

        if (state.isLoading && !state.hasValue) {
          return const Padding(
            padding: EdgeInsets.all(Spacing.pageGutter),
            child: SkeletonList(rows: 2, height: 140),
          );
        }
        if (state.errorOrNull != null && !state.hasValue) {
          final AppError e = state.errorOrNull!;
          return ErrorView(
            title: e.title,
            message: e.message,
            detail: e.diagnostic,
            onRetry: e.canRetry ? c.refresh : null,
          );
        }

        final List<AttendanceTask> tasks =
            state.valueOrPrevious ?? const <AttendanceTask>[];

        // 只看**待确认**的任务：已完成的显示在下方历史区。
        final List<AttendanceTask> pending = tasks
            .where((AttendanceTask t) => t.status == AttendanceTaskStatus.pending)
            .toList()
          ..sort((AttendanceTask a, AttendanceTask b) =>
              a.deadlineAt.compareTo(b.deadlineAt));
        final List<AttendanceTask> history = tasks
            .where((AttendanceTask t) => t.status != AttendanceTaskStatus.pending)
            .toList()
          ..sort((AttendanceTask a, AttendanceTask b) =>
              b.scheduledAt.compareTo(a.scheduledAt));

        return RefreshIndicator(
          onRefresh: () async => c.refresh(),
          child: ListView(
            padding: const EdgeInsets.all(Spacing.pageGutter),
            children: <Widget>[
              if (!_hasServerTime)
                const Padding(
                  padding: EdgeInsets.only(bottom: Spacing.sm),
                  child: StatusChip.detailed(
                    visual: StatusVisual(
                      label: '时间可能不准',
                      tone: StatusTone.warning,
                      icon: Icons.access_time,
                      description: '尚未取到服务端时间，倒计时以本机时间为准。'
                          '若本机时间不准，请以发布者的通知为准。',
                    ),
                  ),
                ),

              if (pending.isEmpty)
                const EmptyState(
                  title: '当前没有待确认的在岗抽查',
                  message: '抽查会在活动进行中按间隔发出，届时本页会出现确认按钮，'
                      '发布者也会现场提醒你。',
                  icon: Icons.check_circle_outline,
                )
              else
                ...pending.map(
                  (AttendanceTask t) => _TaskCard(
                    task: t,
                    serverNow: _serverNow,
                    confirming: _confirmingId == t.id,
                    result: _results[t.id],
                    error: _errors[t.id],
                    onConfirm: () => _confirm(t),
                  ),
                ),

              if (history.isNotEmpty) ...<Widget>[
                const SizedBox(height: Spacing.lg),
                AppSection(
                  title: '历史记录',
                  subtitle: '已结算的抽查',
                  child: Column(
                    children: history
                        .map((AttendanceTask t) => _HistoryRow(task: t))
                        .toList(),
                  ),
                ),
              ],

              const SizedBox(height: Spacing.lg),
              const _Disclaimer(),
            ],
          ),
        );
      },
    );
  }
}

/// 待确认任务卡片。
///
/// 信息层级刻意如此：**倒计时最大最醒目** → 确认按钮 → 说明。
/// 现场用户扫一眼就知道还剩多久、该点哪里。
class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.serverNow,
    required this.confirming,
    required this.onConfirm,
    this.result,
    this.error,
  });

  final AttendanceTask task;
  final DateTime serverNow;
  final bool confirming;
  final VoidCallback onConfirm;
  final AttendanceTask? result;
  final AppError? error;

  /// 距响应截止还剩多久（可为负）。
  Duration get _remaining => task.deadlineAt.difference(serverNow);

  bool get _expired => _remaining.isNegative;

  /// 距**计划开始**还有多久（可为负）。
  ///
  /// 抽查任务在签到时就把后续所有时段预创建好了，所以列表里会同时出现
  /// "现在就能确认的"和"几十分钟之后才该确认的"。
  ///
  /// 真机测试发现的问题：原先只判断"是否已过截止"，于是**未开始的任务
  /// 也显示成可点的「我在现场」**。用户点下去会被服务端拒绝
  ///（"该在岗确认尚未开始"），白采集一次定位、还弹一个红色错误，
  /// 而且暗示"可以提前点" —— 与防脱岗抽查的设计目的相悖。
  Duration get _untilStart => task.scheduledAt.difference(serverNow);

  bool get _notStarted => !_untilStart.isNegative && _untilStart > Duration.zero;

  /// 紧迫度：剩余不足 1 分钟用危险色。
  StatusTone get _tone {
    if (_notStarted) {
      // 尚未开始属于"正常等待"，给中性色而不是警告色，
      // 否则用户会以为出了问题。
      return StatusTone.neutral;
    }
    if (_expired) {
      return StatusTone.danger;
    }
    if (_remaining.inSeconds <= 60) {
      return StatusTone.danger;
    }
    if (_remaining.inSeconds <= 180) {
      return StatusTone.warning;
    }
    return StatusTone.info;
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    // 已有结果：显示服务端给出的终态。
    final AttendanceTask? done = result;
    if (done != null && done.status != AttendanceTaskStatus.pending) {
      final StatusVisual v = StatusVisuals.ofAttendanceTask(done.status);
      return Padding(
        padding: const EdgeInsets.only(bottom: Spacing.sm),
        child: AppCard(
          child: Row(
            children: <Widget>[
              Icon(v.icon, color: v.foreground, size: Sizes.iconLg),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('第 ${task.seq} 次抽查：${v.label}',
                        style: text.titleSmall),
                    if (v.description != null) ...<Widget>[
                      const SizedBox(height: Spacing.xxs),
                      Text(v.description!, style: text.bodySmall),
                    ],
                  ],
                ),
              ),
              StatusChip(visual: v, compact: true),
            ],
          ),
        ),
      );
    }

    final StatusTone tone = _tone;
    final Color container = StatusVisual(label: '', tone: tone).background;
    final Color onContainer = StatusVisual(label: '', tone: tone).onBackground;

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Container(
        padding: const EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: container,
          borderRadius: Radii.cardRadius,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '第 ${task.seq} 次在岗抽查',
              style: text.titleMedium?.copyWith(color: onContainer),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              _notStarted
                  ? '本次抽查将于 ${TimeFormat.format(task.scheduledAt)} 开始'
                  : _expired
                      ? '响应窗口已过，正在等待服务端结算'
                      : '请在 ${TimeFormat.format(task.deadlineAt)} 前确认',
              style: text.bodySmall?.copyWith(color: onContainer),
            ),
            const SizedBox(height: Spacing.sm),

            // 倒计时：这一屏最重要的信息。
            // 未开始时倒数的是"距开始"，已开始后倒数的是"距截止" ——
            // 同一个位置、两种含义，所以后缀必须跟着变。
            _Countdown(
              remaining: _notStarted ? _untilStart : _remaining,
              expired: _expired,
              upcoming: _notStarted,
              onContainer: onContainer,
            ),

            const SizedBox(height: Spacing.md),

            // 唯一的主操作。零输入。
            AppButton(
              label: confirming ? '正在确认' : '我在现场',
              icon: Icons.touch_app,
              loading: confirming,
              loadingLabel: '正在采集定位并提交…',
              // 未开始 / 已超时都禁用：服务端两样都会拒，提前让按钮点不动，
              // 用户就不会白等一次定位采集。
              onPressed: confirming || _expired || _notStarted ? null : onConfirm,
            ),

            if (_notStarted) ...<Widget>[
              const SizedBox(height: Spacing.xs),
              Text(
                '到点后按钮会自动变为可点。本平台不启用推送，'
                '请留意本页或听从发布者现场提醒。',
                style: text.labelSmall?.copyWith(color: onContainer),
              ),
            ],

            if (_expired) ...<Widget>[
              const SizedBox(height: Spacing.xs),
              Text(
                '已超时。记录仅作现场管理参考，不自动扣减时长；'
                '若你确实在岗，可请发布者补录。',
                style: text.labelSmall?.copyWith(color: onContainer),
              ),
            ],

            if (error != null) ...<Widget>[
              const SizedBox(height: Spacing.sm),
              _InlineError(error: error!),
            ],
          ],
        ),
      ),
    );
  }
}

/// 倒计时显示。
class _Countdown extends StatelessWidget {
  const _Countdown({
    required this.remaining,
    required this.expired,
    this.upcoming = false,
    required this.onContainer,
  });

  final Duration remaining;
  final bool expired;

  /// true 表示倒数的是"距本次抽查开始"，false 表示"距响应截止"。
  final bool upcoming;

  final Color onContainer;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    final String display;
    if (expired) {
      display = '00:00';
    } else {
      final int m = remaining.inMinutes;
      final int s = remaining.inSeconds % 60;
      display = '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Text(
          display,
          style: text.headlineMedium?.copyWith(
            color: onContainer,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            fontSize: 40,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: Spacing.xs),
        Text(
          expired
              ? '已超时'
              : upcoming
                  ? '后开始'
                  : '后截止',
          style: text.bodyMedium?.copyWith(color: onContainer),
        ),
      ],
    );
  }
}

/// 历史记录行。
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.task});

  final AttendanceTask task;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final StatusVisual v = StatusVisuals.ofAttendanceTask(task.status);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: AppCard(
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('第 ${task.seq} 次抽查', style: text.titleSmall),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    task.status == AttendanceTaskStatus.excused && task.excusedAt != null
                        ? TimeFormat.format(task.excusedAt!)
                        : TimeFormat.format(task.scheduledAt),
                    style: text.bodySmall,
                  ),
                  // 豁免原因要说清楚：否则用户看到"已豁免"会以为是自己做错了什么。
                  if (task.status == AttendanceTaskStatus.excused &&
                      (task.excusedReason ?? '').isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      task.excusedReason!,
                      style: text.labelSmall?.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            StatusChip(visual: v, compact: true),
          ],
        ),
      ),
    );
  }
}

/// 卡片内的错误/提示条。
class _InlineError extends StatelessWidget {
  const _InlineError({required this.error});

  final AppError error;

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
          Text(
            error.title,
            style: text.titleSmall?.copyWith(color: AppColors.onDangerContainer),
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
        ],
      ),
    );
  }
}

/// 免责与隐私说明。
class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) {
    return Text(
      '在岗确认时会获取一次定位作为在岗证据，不采集持续轨迹。\n'
      '考勤结果仅作现场管理参考，不作为志愿时长认定依据，不自动产生任何扣减。',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.labelSmall,
    );
  }
}
