import 'package:admin_app/board_page.dart';
import 'package:admin_app/roster_page.dart';
import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/shared_ui.dart';

/// 活动详情（管理端工作台的入口）。
///
/// ## 为什么先做这个壳
///
/// 管理端的功能是**围绕一个活动**展开的：看板、名单、考勤、导出、
/// 状态流转。如果把它们平铺在活动列表页上，列表会变得极难扫读
/// （每行五六个按钮）。
///
/// 因此结构是：列表 → 详情 → 各功能页。详情页只负责
/// "这个活动现在什么状态、我能做什么"。
class AdminActivityPage extends StatefulWidget {
  const AdminActivityPage({
    required this.activityId,
    this.initialTitle,
    super.key,
  });

  final String activityId;
  final String? initialTitle;

  @override
  State<AdminActivityPage> createState() => _AdminActivityPageState();
}

class _AdminActivityPageState extends State<AdminActivityPage> {
  AppController<ActivityBoard>? _board;

  bool _transitioning = false;
  AppError? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_board != null) {
      return;
    }
    final AppServices services = AppScope.of(context);
    // 详情页用看板接口作为数据源：它一次带回活动概况与四态计数，
    // 比"详情 + 单独计数"两次请求更省，也不会出现两处数字不一致。
    _board = AppController<ActivityBoard>(
      load: () => _fetchBoard(services),
    )..load();
  }

  @override
  void dispose() {
    _board?.dispose();
    super.dispose();
  }

  Future<ActivityBoard> _fetchBoard(AppServices services) async {
    final ApiResult<ActivityBoard> result = await services.api.get<ActivityBoard>(
      ActivityPaths.board(widget.activityId),
      decode: (Object? data) => ActivityBoard.fromJson(
        (data! as Map<Object?, Object?>).cast<String, dynamic>(),
      ),
    );
    return switch (result) {
      ApiSuccess<ActivityBoard>(:final ActivityBoard value) => value,
      ApiFailure<ActivityBoard>() => throw AppError.fromApi(result),
    };
  }

  /// 拉活动本身（拿状态与时间，用于状态流转按钮）。
  Future<Activity> _fetchActivity(AppServices services) async {
    final ApiResult<Activity> result = await services.api.get<Activity>(
      ActivityPaths.detail(widget.activityId),
      decode: (Object? data) => Activity.fromJson(
        (data! as Map<Object?, Object?>).cast<String, dynamic>(),
      ),
    );
    return switch (result) {
      ApiSuccess<Activity>(:final Activity value) => value,
      ApiFailure<Activity>() => throw AppError.fromApi(result),
    };
  }

  /// 状态流转（`POST /activities/{id}:transition`）。
  ///
  /// `from` 是乐观锁：带上它，服务端会在状态已被别人改过时返回 40901，
  /// 而不是把一次基于过期认知的流转硬写进去。
  Future<void> _transition(Activity activity, ActivityStatus to) async {
    // 取消必须填原因（服务端强制 ≥5 字），且要二次确认。
    String? reason;
    if (to == ActivityStatus.cancelled) {
      reason = await showDialog<String>(
        context: context,
        builder: (BuildContext context) => const _CancelReasonDialog(),
      );
      if (reason == null || !mounted) {
        return;
      }
    } else {
      final bool? ok = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text(_transitionTitle(to)),
          content: Text(_transitionHint(to)),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确认'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) {
        return;
      }
    }

    setState(() {
      _transitioning = true;
      _error = null;
    });

    final AppServices services = AppScope.of(context);
    final ApiResult<Map<String, dynamic>> r =
        await services.api.post<Map<String, dynamic>>(
      ActivityPaths.transition(widget.activityId),
      body: <String, Object?>{
        'from': activity.status.wire,
        'to': to.wire,
        // 用条件展开而不是 `if`：`?'reason': value` 会把 null-aware
        // 作用在**键**上（键不能为 null），而 `if (reason != null)` 又会被
        // lint 要求改成前者。条件展开同时满足语义与检查。
        ...?(reason == null ? null : <String, Object?>{'reason': reason}),
      },
      retryable: false,
      decode: (Object? data) =>
          (data! as Map<Object?, Object?>).cast<String, dynamic>(),
    );

    if (!mounted) {
      return;
    }
    setState(() {
      _transitioning = false;
      if (r is ApiFailure<Map<String, dynamic>>) {
        _error = AppError.fromApi(r);
      }
    });
    if (r is ApiSuccess<Map<String, dynamic>>) {
      await _board?.refresh();
    }
  }

  String _transitionTitle(ActivityStatus to) => switch (to) {
        ActivityStatus.published => '发布活动？',
        ActivityStatus.ongoing => '开始活动？',
        ActivityStatus.finished => '宣布结束？',
        _ => '确认变更状态？',
      };

  String _transitionHint(ActivityStatus to) => switch (to) {
        ActivityStatus.published =>
          '发布后名单与判定规则会被冻结；之后修改关键字段需要填写原因并留痕。',
        ActivityStatus.ongoing =>
          '开始后志愿者可以签到，系统会按间隔生成在岗抽查。',
        ActivityStatus.finished =>
          '结束后签到与抽查关闭，未响应的抽查立即结算。'
              '**此操作不可撤销**，请确认现场确已结束。',
        ActivityStatus.cancelled =>
          '取消不可撤销。未发生的抽查会被豁免（不影响到场者记录）。',
        _ => '请确认。',
      };

  Future<void> _export(AppServices services) async {
    final AppServices s = services;
    final Uri uri = Uri.parse('${s.api.config.baseUrl}${ActivityPaths.export(widget.activityId)}')
        .replace(queryParameters: <String, String>{
      'kind': 'checkin_list',
      'format': 'csv',
    });
    // 导出是**直接下载**（网页方案 §6.4.8），不是"建任务→轮询"。
    //
    // 这里把 URL 与获取方式一起展示出来，而不是假装能"帮用户下载"：
    // 在移动端拿到一个 CSV 之后，用户真正需要的是**把它发到自己的电脑或邮箱**。
    // 直接打开浏览器/下载器是系统的事，不该由 App 代劳（也没有权限静默完成）。
    if (!mounted) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext context) => _ExportSheet(
        url: uri.toString(),
        activityId: widget.activityId,
        baseUrl: s.api.config.baseUrl,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppServices services = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initialTitle ?? '活动'),
        actions: <Widget>[
          IconButton(
            onPressed: () => _board?.refresh(),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<Activity>(
          future: _fetchActivity(services),
          builder: (BuildContext context, AsyncSnapshot<Activity> snap) {
            final Activity? activity = snap.data;
            return RefreshIndicator(
              onRefresh: () async => _board?.refresh(),
              child: ListView(
                padding: const EdgeInsets.all(Spacing.pageGutter),
                children: <Widget>[
                  if (_error != null) ...<Widget>[
                    _ErrorBanner(error: _error!),
                    const SizedBox(height: Spacing.md),
                  ],

                  if (activity != null) _StatusCard(activity: activity),
                  const SizedBox(height: Spacing.md),

                  _ActionGrid(
                    activity: activity,
                    transitioning: _transitioning,
                    onTransition: (ActivityStatus to) =>
                        activity == null ? null : _transition(activity, to),
                    onOpenBoard: () => _openBoard(context, activity),
                    onOpenRoster: () => _openRoster(context),
                    onExport: () => _export(services),
                  ),

                  const SizedBox(height: Spacing.md),
                  _BoardSummary(controller: _board),

                  const SizedBox(height: Spacing.lg),
                  Text(
                    '所有判定都以服务端记录为准。考勤结果仅作现场管理参考，'
                    '不作为志愿时长认定依据，不自动产生任何扣减。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openBoard(BuildContext context, Activity? activity) async {
    await Navigator.of(context).push<void>(
      appRoute(
        BoardPage(
          activityId: widget.activityId,
          activityTitle: activity?.title ?? widget.initialTitle,
        ),
        name: Routes.adminActivity,
      ),
    );
    await _board?.refreshSilently();
  }

  Future<void> _openRoster(BuildContext context) async {
    await Navigator.of(context).push<void>(
      appRoute(
        RosterPage(
          activityId: widget.activityId,
          activityTitle: widget.initialTitle,
        ),
        name: Routes.adminActivity,
      ),
    );
    await _board?.refreshSilently();
  }
}

/// 状态卡片 + 流转按钮。
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.activity});

  final Activity activity;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final StatusVisual v = StatusVisuals.ofActivity(activity.status);

    return AppCard(
      highlight: activity.status == ActivityStatus.ongoing,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(activity.title, style: text.titleMedium)),
              const SizedBox(width: Spacing.xs),
              StatusChip(visual: v, compact: true),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          InfoRow(
            label: '时间',
            value: '${TimeFormat.format(activity.startTime)} ~ '
                '${TimeFormat.format(activity.endTime)}',
            icon: Icons.schedule,
          ),
          InfoRow(
            label: '签到窗口',
            value: '${TimeFormat.format(activity.checkinOpensAt)} ~ '
                '${TimeFormat.format(activity.checkinClosesAt)}',
            icon: Icons.login,
          ),
          InfoRow(label: '地点', value: activity.location, icon: Icons.place_outlined),
          InfoRow(
            label: '抽查间隔',
            value: '首次 ${activity.attendanceFirstDelay.inMinutes} 分钟后，'
                '之后每 ${activity.attendanceInterval.inMinutes} 分钟',
            icon: Icons.touch_app_outlined,
          ),
        ],
      ),
    );
  }
}

/// 操作网格。
class _ActionGrid extends StatelessWidget {
  const _ActionGrid({
    required this.activity,
    required this.transitioning,
    required this.onTransition,
    required this.onOpenBoard,
    required this.onOpenRoster,
    required this.onExport,
  });

  final Activity? activity;
  final bool transitioning;
  final void Function(ActivityStatus) onTransition;
  final VoidCallback onOpenBoard;
  final VoidCallback onOpenRoster;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final ActivityStatus? s = activity?.status;

    // 合法流转表与服务端一致（方案 §5.1）。客户端先过滤只是为了让
    // 用户看不到点了必然失败的按钮——**判定仍在服务端**。
    final bool canPublish = s == ActivityStatus.draft;
    final bool canStart = s == ActivityStatus.published;
    final bool canFinish = s == ActivityStatus.ongoing;
    final bool canCancel = s == ActivityStatus.draft ||
        s == ActivityStatus.published ||
        s == ActivityStatus.ongoing;

    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: AppButton(
                label: '现场看板',
                icon: Icons.dashboard_outlined,
                variant: AppButtonVariant.secondary,
                compact: true,
                onPressed: onOpenBoard,
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: AppButton(
                label: '名单',
                icon: Icons.people_outline,
                variant: AppButtonVariant.secondary,
                compact: true,
                onPressed: onOpenRoster,
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.xs),
        Row(
          children: <Widget>[
            Expanded(
              child: AppButton(
                label: '导出 CSV',
                icon: Icons.download_outlined,
                variant: AppButtonVariant.secondary,
                compact: true,
                onPressed: onExport,
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: AppButton(
                label: '考勤汇总',
                icon: Icons.fact_check_outlined,
                variant: AppButtonVariant.secondary,
                compact: true,
                onPressed: () => _openSummary(context),
              ),
            ),
          ],
        ),

        const SizedBox(height: Spacing.md),

        if (canStart)
          AppButton(
            label: '开始活动',
            icon: Icons.play_arrow,
            loading: transitioning,
            onPressed: () => onTransition(ActivityStatus.ongoing),
          )
        else if (canPublish)
          AppButton(
            label: '发布活动',
            icon: Icons.campaign_outlined,
            loading: transitioning,
            onPressed: () => onTransition(ActivityStatus.published),
          )
        else if (canFinish)
          AppButton(
            label: '宣布结束',
            icon: Icons.flag_outlined,
            loading: transitioning,
            onPressed: () => onTransition(ActivityStatus.finished),
          ),

        if (canCancel) ...<Widget>[
          const SizedBox(height: Spacing.xs),
          AppButton(
            label: '取消活动',
            icon: Icons.cancel_outlined,
            variant: AppButtonVariant.text,
            compact: true,
            onPressed: () => onTransition(ActivityStatus.cancelled),
          ),
        ],
      ],
    );
  }

  void _openSummary(BuildContext context) {
    final Activity? a = activity;
    if (a == null) {
      return;
    }
    Navigator.of(context).push<void>(
      appRoute(
        AttendanceSummaryPage(
          activityId: a.id,
          activityTitle: a.title,
        ),
        name: Routes.adminActivity,
      ),
    );
  }
}

/// 看板摘要（挂在详情页上，省一次跳转）。
class _BoardSummary extends StatelessWidget {
  const _BoardSummary({required this.controller});

  final AppController<ActivityBoard>? controller;

  @override
  Widget build(BuildContext context) {
    final AppController<ActivityBoard>? c = controller;
    if (c == null) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, Widget? _) {
        final ActivityBoard? b = c.value;
        if (b == null) {
          return const SizedBox.shrink();
        }
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('签到概况', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Spacing.xs),
              InfoRow(
                label: '已签到',
                value: '${b.checkedIn} / ${b.activeTotal} 人'
                    '（到场率 ${(b.presentRate * 100).round()}%）',
                icon: Icons.check_circle_outline,
              ),
              if (b.pendingReview > 0)
                InfoRow(
                  label: '待确认',
                  value: '${b.pendingReview} 人需要你复核',
                  icon: Icons.visibility_outlined,
                ),
              InfoRow(
                label: '在岗',
                value: '完成 ${b.attendanceDone} · 超时 ${b.attendanceMissed}'
                    '${b.attendanceExcused > 0 ? ' · 豁免 ${b.attendanceExcused}' : ''}',
                icon: Icons.touch_app_outlined,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 取消原因对话框。
class _CancelReasonDialog extends StatefulWidget {
  const _CancelReasonDialog();

  @override
  State<_CancelReasonDialog> createState() => _CancelReasonDialogState();
}

class _CancelReasonDialogState extends State<_CancelReasonDialog> {
  final TextEditingController _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final int len = _c.text.trim().length;
    // 服务端要求 ≥5 字（`CANCEL_REASON_MIN_LENGTH`）。
    final bool ok = len >= 5;

    return AlertDialog(
      title: const Text('取消活动'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '取消**不可撤销**。取消后志愿者无法签到，未发生的抽查会被豁免'
            '（不影响到场者的记录）。\n\n'
            '原因会记录在活动里，是争议时的依据。',
          ),
          const SizedBox(height: Spacing.sm),
          TextField(
            controller: _c,
            autofocus: true,
            maxLines: 2,
            maxLength: 100,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: '取消原因',
              hintText: '例如：场地临时被占用，改期举行',
              errorText: len == 0
                  ? null
                  : ok
                      ? null
                      : '至少 5 个字（当前 $len）',
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('返回'),
        ),
        TextButton(
          onPressed: ok ? () => Navigator.of(context).pop(_c.text.trim()) : null,
          child: const Text('确认取消活动'),
        ),
      ],
    );
  }
}

/// 考勤汇总页（方案 §4.8、§6.4.7；决策 D-7）。
///
/// ## 这一页的措辞比数据更重要
///
/// 汇总会被人当作"谁干得好、谁在摸鱼"的依据。因此：
///   * 「证据不足」与「缺席」严格区分——完成率不足**不定性为缺席**；
///   * 成绩标签旁直接给出**完成率**，让读的人自己判断；
///   * 免责声明放在最上方，而不是藏在页脚。
class AttendanceSummaryPage extends StatefulWidget {
  const AttendanceSummaryPage({
    required this.activityId,
    this.activityTitle,
    super.key,
  });

  final String activityId;
  final String? activityTitle;

  @override
  State<AttendanceSummaryPage> createState() => _AttendanceSummaryPageState();
}

class _AttendanceSummaryPageState extends State<AttendanceSummaryPage> {
  AppController<AttendanceReport>? _summary;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_summary != null) {
      return;
    }
    final AppServices services = AppScope.of(context);
    _summary = AppController<AttendanceReport>(
      load: () async {
        final ApiResult<AttendanceReport> r =
            await services.api.get<AttendanceReport>(
          ActivityPaths.attendance(widget.activityId),
          decode: (Object? data) => AttendanceReport.fromJson(
            (data! as Map<Object?, Object?>).cast<String, dynamic>(),
          ),
        );
        return switch (r) {
          ApiSuccess<AttendanceReport>(:final AttendanceReport value) => value,
          ApiFailure<AttendanceReport>() => throw AppError.fromApi(r),
        };
      },
    )..load();
  }

  @override
  void dispose() {
    _summary?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('考勤汇总'),
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
    final AppController<AttendanceReport>? c = _summary;
    if (c == null) {
      return const LoadingView();
    }
    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, Widget? _) {
        final AppResult<AttendanceReport> state = c.state;
        if (state.isLoading && !state.hasValue) {
          return const Padding(
            padding: EdgeInsets.all(Spacing.pageGutter),
            child: SkeletonList(rows: 4, height: 70),
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
        final AttendanceReport data = state.valueOrPrevious!;
        final List<AttendanceSummaryRow> rows = data.rows;

        return RefreshIndicator(
          onRefresh: () async => c.refresh(),
          child: ListView(
            padding: const EdgeInsets.all(Spacing.pageGutter),
            children: <Widget>[
              // 免责声明放最上方：这一页最容易被误用为"考核依据"。
              StatusChip.detailed(
                visual: StatusVisual(
                  label: '仅供参考',
                  tone: StatusTone.info,
                  icon: Icons.info_outline,
                  description: data.disclaimer.isEmpty
                      ? '考勤结果仅作现场管理参考，不作为志愿时长认定依据，不自动产生任何扣减。'
                      : data.disclaimer,
                ),
              ),
              const SizedBox(height: Spacing.md),

              // 分类计数。刻意把"证据不足"与"缺席"分开列。
              AppCard(
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: _Mini(label: '全勤', value: data.fullCount),
                    ),
                    Expanded(
                      child: _Mini(label: '部分完成', value: data.partialCount),
                    ),
                    Expanded(
                      child: _Mini(label: '证据不足', value: data.insufficientCount),
                    ),
                    Expanded(
                      child: _Mini(label: '总人数', value: rows.length),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.md),

              AppSection(
                title: '在岗明细（${rows.length}）',
                subtitle: '完成率 = 已完成 / (已完成 + 已超时)；豁免不计入分母',
                child: rows.isEmpty
                    ? const EmptyState(
                        title: '还没有在岗抽查数据',
                        message: '在岗抽查只为已签到的参与者生成。'
                            '活动开始后，签到的人会按间隔被抽查。',
                        icon: Icons.fact_check_outlined,
                        compact: true,
                      )
                    : Column(
                        children: rows
                            .map((AttendanceSummaryRow r) => _SummaryRow(row: r))
                            .toList(),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 分类计数。
class _Mini extends StatelessWidget {
  const _Mini({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      children: <Widget>[
        Text('$value', style: text.titleLarge),
        Text(label, style: text.labelSmall),
      ],
    );
  }
}

/// 考勤汇总的一行。
///
/// ## 为什么把「完成率」显示出来而不是只给等级
///
/// 决策 D-7 定的判据是"完成率 ≥0.7 记 partial"。只给一个标签，
/// 读的人无法判断"这个 partial 到底是差一点还是差很多"。
/// 把百分比摆出来，争议时双方看的是同一个数字。
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.row});

  final AttendanceSummaryRow row;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final StatusVisual v = StatusVisuals.ofAttendanceSummary(row.summary);

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: AppCard(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.sm,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(child: Text(row.name, style: text.titleSmall)),
                      const SizedBox(width: Spacing.xs),
                      Text(row.userNo, style: text.labelSmall),
                    ],
                  ),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    // 没有任何已定案任务时**不显示"完成率 0%"** ——
                    // 那会被读成"一次都没完成"，而实际含义是"还没有可判定的事"。
                    row.hasNoSettledTask
                        ? '尚无已定案的抽查${row.excused > 0 ? '（豁免 ${row.excused} 次）' : ''}'
                        : '完成 ${row.done} · 超时 ${row.missed}'
                            '${row.excused > 0 ? ' · 豁免 ${row.excused}' : ''}'
                            '${row.ratePercent == null ? '' : ' · 完成率 ${row.ratePercent}%'}',
                    style: text.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: Spacing.xs),
            StatusChip(visual: v, compact: true),
          ],
        ),
      ),
    );
  }
}

/// 导出说明弹层。
class _ExportSheet extends StatelessWidget {
  const _ExportSheet({
    required this.url,
    required this.activityId,
    required this.baseUrl,
  });

  final String url;
  final String activityId;
  final String baseUrl;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(Spacing.pageGutter),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('导出签到名单', style: text.titleLarge),
          const SizedBox(height: Spacing.xs),
          Text(
            '导出由**服务端**生成（三端共用同一份格式），默认对手机号脱敏。\n'
            '文件带「仅限内部使用」提示，请勿外传或公开张贴。',
            style: text.bodySmall,
          ),
          const SizedBox(height: Spacing.md),

          Container(
            padding: const EdgeInsets.all(Spacing.sm),
            decoration: const BoxDecoration(
              color: AppColors.neutralContainer,
              borderRadius: BorderRadius.all(Radius.circular(Radii.md)),
            ),
            child: SelectableText(
              url,
              style: text.labelSmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            '在电脑浏览器里打开这个地址会直接下载 CSV（需要带管理端登录令牌）。\n'
            '移动端浏览器打开通常会保存到「下载」目录。',
            style: text.bodySmall,
          ),

          const SizedBox(height: Spacing.md),
          const StatusChip.detailed(
            visual: StatusVisual(
              label: '需要完整手机号？',
              tone: StatusTone.warning,
              icon: Icons.phone_android_outlined,
              description: '现场催人需要在电脑端导出时显式勾选「包含完整联系方式」。'
                  '那次导出会被记入敏感导出审计（谁、何时、多少行）。',
            ),
          ),
        ],
      ),
    );
  }
}

/// 错误提示条。
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.error});

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
