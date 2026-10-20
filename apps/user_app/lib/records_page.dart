import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/shared_ui.dart';

/// 我的记录页（方案 §5.6、§9）。
///
/// ## 这一页的核心职责：让"证据有没有上传"永远可见
///
/// 弱网是常态（方案 §9），而**离线证据如果没有明确的可见性，
/// 用户会陷入两种糟糕状态**：
///   * 以为签上了，其实还在本机队列里，事后被记未签到 → 争议；
///   * 不放心，反复点签到 → 重复操作（虽有幂等键兜底，但体验很差）。
///
/// 因此本页把队列里的每一条**逐条**列出来，并给出可执行的下一步
/// （立即重试 / 查看失败原因）。这是 `SyncBanner` 的详细版。
class RecordsPage extends StatefulWidget {
  const RecordsPage({
    required this.activityId,
    this.activityTitle,
    super.key,
  });

  final String activityId;
  final String? activityTitle;

  @override
  State<RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends State<RecordsPage> {
  AppController<MyRecords>? _records;

  /// 解析出来的活动标题。
  ///
  /// 为什么需要：记录页是**随首页一起构建**的（首页三个 tab 同时建），
  /// 那时活动详情还没加载完，`activityTitle` 是 null —— 于是本机历史里
  /// 这个活动会永远显示成「活动 11」。这里在标题缺失时自己查一次详情补上。
  String? _resolvedTitle;

  bool _flushing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_records != null) {
      return;
    }
    final AppServices services = AppScope.of(context);
    _records = AppController<MyRecords>(
      load: () => _fetch(services),
    )..load();
  }

  /// 取活动标题：优先用外部传入的，其次查一次详情，最后退化到空串。
  Future<String> _resolveTitle(AppServices services) async {
    final String fromWidget = (widget.activityTitle ?? '').trim();
    if (fromWidget.isNotEmpty) {
      return fromWidget;
    }
    final String? cached = _resolvedTitle;
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    try {
      final ApiResult<Activity> r = await services.api.get<Activity>(
        ActivityPaths.detail(widget.activityId),
        decode: (Object? d) =>
            Activity.fromJson((d! as Map<Object?, Object?>).cast<String, dynamic>()),
      );
      if (r is ApiSuccess<Activity>) {
        _resolvedTitle = r.value.title;
        return r.value.title;
      }
    } catch (_) {
      // 查不到就留空，界面上会显示「活动 <编号>」，不影响记录本身
    }
    return '';
  }

  @override
  void dispose() {
    _records?.dispose();
    super.dispose();
  }

  /// 拉取本人的签到记录与在岗任务。
  ///
  /// 两个请求**并行**发：它们互不依赖，串行只会让页面慢一倍。
  Future<MyRecords> _fetch(AppServices services) async {
    final List<ApiResult<Object?>> results = await Future.wait(<Future<ApiResult<Object?>>>[
      services.api.get<Object?>(
        CheckinPaths.mine(widget.activityId),
        decode: (Object? d) => d,
      ),
      services.api.get<Object?>(
        AttendancePaths.tasks(widget.activityId),
        decode: (Object? d) => d,
      ),
    ]);

    // 第一个失败就直接抛：记录页缺了签到记录没有意义，
    // 显示半页数据会让用户以为"我的签到记录没了"。
    final ApiResult<Object?> first = results[0];
    if (first is ApiFailure<Object?>) {
      throw AppError.fromApi(first);
    }

    final Checkin? checkin = _parseCheckin((first as ApiSuccess<Object?>).value);

    List<AttendanceTask> tasks = const <AttendanceTask>[];
    final ApiResult<Object?> second = results[1];
    if (second is ApiSuccess<Object?>) {
      tasks = _parseTasks(second.value);
    }
    // 在岗任务失败**不致命**：签到记录仍然要显示。
    // 这与上面的判断是有意的区别——核心信息不可缺，附加信息可以缺。

    final Checkin? c = checkin;
    final List<AttendanceTask> taskList = tasks;

    /*
      每次成功拿到记录，就**顺手存一份到本机**。

      真机报障：换活动要重新输邀请码，重新登录后上一个活动的记录就看不到了
      （记录还在服务端，但新授权只覆盖新活动）。存一份在本机，
      解绑/换活动都不清除，用户随时能回看。
    */
    final ParticipationHistory history =
        await _cacheToDevice(services, checkin: c, tasks: taskList);
    return MyRecords(checkin: c, tasks: taskList, history: history);
  }

  /// 把当前活动的记录写入本机历史，返回更新后的整份历史。
  ///
  /// 失败**不抛异常**：这是本机缓存，写不进去不该让记录页打不开。
  Future<ParticipationHistory> _cacheToDevice(
    AppServices services, {
    required Checkin? checkin,
    required List<AttendanceTask> tasks,
  }) async {
    try {
      final VolunteerGrant? grant = await services.tokens.readVolunteerGrant();
      final String title = await _resolveTitle(services);
      final Checkin? c = checkin;
      final int done = tasks
          .where((AttendanceTask t) => t.status == AttendanceTaskStatus.done)
          .length;
      final int missed = tasks
          .where((AttendanceTask t) => t.status == AttendanceTaskStatus.missed)
          .length;

      return await services.participation.upsert(
        ParticipationRecord(
          activityId: widget.activityId,
          activityTitle: title,
          userNo: c?.userNo ?? grant?.userNo ?? '',
          name: c?.name ?? grant?.name ?? '',
          checkinStatus: c?.status.wire,
          score: c?.score,
          checkinAt: c?.serverTime ?? c?.clientTime,
          attendanceDone: done,
          attendanceMissed: missed,
          savedAt: DateTime.now(),
        ),
      );
    } catch (_) {
      return services.participation.load();
    }
  }

  /// 解析本人签到记录。
  ///
  /// 服务端的实际形状是 `{ items: [...], latest: {...}|null, grantExpiresAt }`
  /// （按时间倒序）。这里同时兼容三种形态，理由：
  ///   * `latest` —— 服务端当前实现，页面显示的就是它；
  ///   * `checkin` —— 单记录接口可能的形状；
  ///   * 直接是记录对象 —— 手工调试与将来接口收敛时可能出现的形状。
  ///
  /// 兼容不是过度设计：记录页是用户**核对"我到底签上没有"**的唯一入口，
  /// 解析形状变了却显示"尚无签到记录"，后果是用户以为自己没签上而反复操作。
  Checkin? _parseCheckin(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Map<String, dynamic> m = raw.cast<String, dynamic>();

    // `latest` 明确为 null 表示"确实没有记录"，此时不要再退化到整个 map，
    // 否则会把 items 数组当成一条记录解析出空对象。
    if (m.containsKey('latest')) {
      final Object? latest = m['latest'];
      if (latest is! Map) {
        return null;
      }
      return Checkin.fromJson(latest.cast<String, dynamic>());
    }

    final Object? inner = m['checkin'];
    final Map<String, dynamic> target =
        inner is Map ? inner.cast<String, dynamic>() : m;
    if (target['id'] == null) {
      return null;
    }
    return Checkin.fromJson(target);
  }

  List<AttendanceTask> _parseTasks(Object? raw) {
    if (raw is! Map) {
      return const <AttendanceTask>[];
    }
    final Object? items = raw.cast<String, dynamic>()['items'];
    if (items is! List) {
      return const <AttendanceTask>[];
    }
    return items
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> m) =>
            AttendanceTask.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// 手动重试补传。
  Future<void> _flush() async {
    final AppServices services = AppScope.of(context);
    setState(() => _flushing = true);
    try {
      await services.queue.flush();
    } finally {
      if (mounted) {
        setState(() => _flushing = false);
        await _records?.refreshSilently();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppServices services = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的记录'),
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
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await _records?.refresh();
          },
          child: _buildBody(context, services),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, AppServices services) {
    final AppController<MyRecords>? c = _records;
    if (c == null) {
      return const LoadingView();
    }

    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, Widget? _) {
        final AppResult<MyRecords> state = c.state;

        if (state.isLoading && !state.hasValue) {
          return const Padding(
            padding: EdgeInsets.all(Spacing.pageGutter),
            child: SkeletonList(rows: 3, height: 100),
          );
        }
        if (state.errorOrNull != null && !state.hasValue) {
          final AppError e = state.errorOrNull!;
          return ListView(
            children: <Widget>[
              SizedBox(height: MediaQuery.sizeOf(context).height * 0.15),
              ErrorView(
                title: e.title,
                message: e.message,
                detail: e.diagnostic,
                onRetry: e.canRetry ? c.refresh : null,
              ),
            ],
          );
        }

        final MyRecords data = state.valueOrPrevious!;
        final List<QueuedTask> queued =
            services.queue.tasksFor(widget.activityId);

        return ListView(
          padding: const EdgeInsets.all(Spacing.pageGutter),
          children: <Widget>[
            // ── 待上传队列（最重要，放最上面）────────────────────────
            if (queued.isNotEmpty) ...<Widget>[
              AppSection(
                title: '待上传（${queued.length}）',
                subtitle: '已保存在本机，不会丢失',
                action: TextButton(
                  onPressed: _flushing ? null : _flush,
                  child: Text(_flushing ? '上传中…' : '立即重试'),
                ),
                child: Column(
                  children: queued
                      .map((QueuedTask t) => _QueuedRow(task: t))
                      .toList(),
                ),
              ),
              const SizedBox(height: Spacing.lg),
            ],

            // ── 签到记录 ────────────────────────────────────────────
            AppSection(
              title: '签到记录',
              child: data.checkin == null
                  ? const EmptyState(
                      title: '尚无签到记录',
                      message: '活动开始后，在活动页点「去签到」即可。',
                      icon: Icons.how_to_reg_outlined,
                      compact: true,
                    )
                  : _CheckinCard(checkin: data.checkin!),
            ),

            const SizedBox(height: Spacing.lg),

            // ── 在岗抽查记录 ────────────────────────────────────────
            AppSection(
              title: '在岗抽查',
              subtitle: data.tasks.isEmpty ? null : '共 ${data.tasks.length} 次',
              child: data.tasks.isEmpty
                  ? const EmptyState(
                      title: '尚无在岗抽查记录',
                      message: '抽查只为已签到的参与者生成。签到最后会按间隔发出。',
                      icon: Icons.touch_app_outlined,
                      compact: true,
                    )
                  : Column(
                      children: (data.tasks.toList()
                            ..sort((AttendanceTask a, AttendanceTask b) =>
                                a.seq.compareTo(b.seq)))
                          .map((AttendanceTask t) => _AttendanceRow(task: t))
                          .toList(),
                    ),
            ),

            // ── 历史参与活动（本机保存，跨活动保留）─────────────────
            if (data.history.length > 1) ...<Widget>[
              const SizedBox(height: Spacing.lg),
              AppSection(
                title: '我参与过的活动（${data.history.length}）',
                subtitle: '记录保存在本机：换活动、解除绑定都不会丢',
                child: Column(
                  children: data.history.sortedByRecent
                      .map((ParticipationRecord r) => _HistoryRow(
                            record: r,
                            isCurrent: r.activityId == widget.activityId,
                          ))
                      .toList(),
                ),
              ),
            ],

            const SizedBox(height: Spacing.lg),
            Text(
              '以上记录均以服务端为准。\n'
              '考勤结果仅作现场管理参考，不作为志愿时长认定依据，不自动产生任何扣减。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        );
      },
    );
  }
}

/// 记录页需要的数据。
class MyRecords {
  const MyRecords({
    required this.checkin,
    required this.tasks,
    required this.history,
  });

  final Checkin? checkin;
  final List<AttendanceTask> tasks;

  /// 本机保存的参与记录（含**其它活动**，切换活动后仍然在）。
  final ParticipationHistory history;
}

/// 签到记录卡片。
class _CheckinCard extends StatelessWidget {
  const _CheckinCard({required this.checkin});

  final Checkin checkin;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final StatusVisual v = StatusVisuals.ofCheckin(checkin.status);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text('签到状态', style: text.titleSmall),
              ),
              StatusChip(visual: v, compact: true),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          InfoRow(
            label: '时间',
            value: checkin.serverTime == null
                ? '—'
                : TimeFormat.format(checkin.serverTime!, withSeconds: true),
            icon: Icons.access_time,
          ),
          InfoRow(label: '方式', value: checkin.method.label, icon: Icons.my_location),
          if (checkin.distanceMeters != null)
            InfoRow(
              label: '距签到点',
              value: '约 ${checkin.distanceMeters!.round()} 米',
              icon: Icons.straighten,
            ),
          if (checkin.accuracy != null)
            InfoRow(
              label: '定位精度',
              value: '±${checkin.accuracy!.round()} 米',
              icon: Icons.gps_fixed,
            ),
          if (checkin.isAwaitingSync) ...<Widget>[
            const SizedBox(height: Spacing.xs),
            StatusChip.detailed(
              visual: StatusVisuals.ofSync(checkin.syncState!),
            ),
          ],
          // 待确认时把"这句话"讲清楚，否则用户会反复来找发布者。
          if (checkin.status == CheckinStatus.pendingReview)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Text(
                '这条记录已提交，正在等发布者核实。'
                '不影响你先参加活动；核实结果会更新在这里。',
                style: text.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

/// 在岗抽查记录行。
class _AttendanceRow extends StatelessWidget {
  const _AttendanceRow({required this.task});

  final AttendanceTask task;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final StatusVisual v = StatusVisuals.ofAttendanceTask(task.status);

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: AppCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('第 ${task.seq} 次抽查', style: text.titleSmall),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    '计划 ${TimeFormat.format(task.scheduledAt)}',
                    style: text.bodySmall,
                  ),
                  if (task.manualFill) ...<Widget>[
                    const SizedBox(height: Spacing.xxs),
                    Text(
                      '由发布者人工补录${task.filledBy == null ? '' : '（${task.filledBy}）'}',
                      style: text.bodySmall,
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

/// 队列中的一条。
///
/// 刻意显示**类型与入队时间**：用户最常问的是
/// "我那条到底传上去了没有、是什么时候点的"。
class _QueuedRow extends StatelessWidget {
  const _QueuedRow({required this.task});

  final QueuedTask task;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final StatusVisual v = StatusVisuals.ofSync(task.syncState);

    final String kind = switch (task) {
      QueuedCheckin() => '签到证据',
      QueuedAttendanceResponse() => '在岗确认',
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: AppCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(kind, style: text.titleSmall),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    '入队于 ${TimeFormat.format(task.enqueuedAt, withSeconds: true)}',
                    style: text.bodySmall,
                  ),
                  if (task.lastError != null) ...<Widget>[
                    const SizedBox(height: Spacing.xxs),
                    Text(task.lastError!, style: text.bodySmall),
                  ],
                  if (task.attempts > 0) ...<Widget>[
                    const SizedBox(height: Spacing.xxs),
                    Text(
                      '已尝试 ${task.attempts} 次',
                      style: text.labelSmall,
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

/// 历史活动的一行。
///
/// 只展示**本机存过的结论**（签到状态、评分、时间），不发起网络请求 ——
/// 换掉的活动已经不在当前授权范围内，服务端也查不到了。
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.record, required this.isCurrent});

  final ParticipationRecord record;

  /// 是否是当前绑定的活动（用于打标签，避免用户以为重复）。
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    // ⚠️ 必须 toLocal()：服务端时间解析出来是 UTC，直接取 hour 会显示成差 8 小时。
    final DateTime? at = record.checkinAt?.toLocal();
    final String timeText = at == null
        ? ''
        : '${at.year}-${_two(at.month)}-${_two(at.day)} ${_two(at.hour)}:${_two(at.minute)}';

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            record.hasCheckin
                ? Icons.how_to_reg_outlined
                : Icons.event_busy_outlined,
            size: Sizes.iconMd,
            color: record.hasCheckin ? AppColors.success : AppColors.textTertiary,
          ),
          const SizedBox(width: Spacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        record.activityTitle.isEmpty
                            ? '活动 ${record.activityId}'
                            : record.activityTitle,
                        style: text.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isCurrent) ...<Widget>[
                      const SizedBox(width: Spacing.xxs),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Spacing.xxs,
                          vertical: 1,
                        ),
                        decoration: const BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
                        ),
                        child: Text('当前', style: text.labelSmall),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  <String>[
                    record.checkinStatusLabel,
                    if (record.score != null) '评分 ${record.score}',
                    if (timeText.isNotEmpty) timeText,
                    if (record.attendanceDone > 0)
                      '在岗 ${record.attendanceDone} 次',
                  ].join(' · '),
                  style: text.labelSmall?.copyWith(
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}