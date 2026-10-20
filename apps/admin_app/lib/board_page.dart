import 'dart:async';

import 'package:admin_app/checkin_review_page.dart';
import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/shared_ui.dart';

/// 现场看板（方案 §4.8；验收 A10、A13）。
///
/// ## 这是发布者**在现场盯着的那一屏**
///
/// 它的设计目标只有一个：**让人站在活动现场，一手拿手机，一眼看出
/// "谁到了、谁没到、谁需要我处理"**。
///
/// 因此：
///   * 四个数字放在最上方，字号最大（已签到 / 待确认 / 尚未签到 / 已移出）；
///   * 「待确认」是**唯一需要行动**的类别，点击可直接进复核；
///   * 名单可按状态筛选，默认不筛选（现场想知道的是全貌）。
///
/// ## 前台轮询，不做推送（方案 §6.2）
///
/// 页面在前台时每 20 秒静默刷新一次。刻意**不用定时器做判定**——
/// 超时结算是服务端的事，客户端只负责显示。
///
/// 静默刷新的含义：失败**不打断**当前界面（见 `AppController.refreshSilently`）。
/// 现场一块正在被人看的看板，因为一次网络抖动变成错误页，是很糟的体验。
class BoardPage extends StatefulWidget {
  const BoardPage({
    required this.activityId,
    this.activityTitle,
    this.autoRefresh = true,
    super.key,
  });

  final String activityId;
  final String? activityTitle;

  /// 是否前台自动刷新（测试里关掉，避免依赖真实计时）。
  final bool autoRefresh;

  @override
  State<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends State<BoardPage> with WidgetsBindingObserver {
  AppController<ActivityBoard>? _board;

  Timer? _poll;

  /// 上次刷新的时刻（显示"更新于 N 分钟前"）。
  DateTime? _lastUpdated;
  bool _refreshing = false;
  /// 正在发起手动抽查（防连点）。
  bool _manualing = false;

  /// 名单筛选：`null` 表示不筛选。
  ParticipantCheckinStatus? _filter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_board != null) {
      return;
    }
    final AppServices services = AppScope.of(context);
    _board = AppController<ActivityBoard>(
      load: () => _fetch(services),
    )..load().then((_) {
        if (mounted) {
          setState(() => _lastUpdated = DateTime.now());
        }
      });
    _startPolling();
  }

  /// 启动前台轮询。
  ///
  /// 20 秒是刻意的折中：短于一次抽查的响应窗口（5 分钟）很多，
  /// 足够让发布者及时发现"有人点了确认"；又不至于持续耗电。
  void _startPolling() {
    if (!widget.autoRefresh) {
      return;
    }
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 20), (_) async {
      // 只在**前台**轮询：后台时系统可能已经冻结了网络，
      // 继续发请求既无效也耗电。
      if (!mounted || _lifecycle != AppLifecycleState.resumed) {
        return;
      }
      if (_refreshing) {
        return;
      }
      await _refresh(silent: true);
    });
  }

  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    // 回到前台立刻刷一次：用户切回来时最想看的是"现在"的数据，
    // 而不是离开前那一刻的。这正是方案 §6.5「端到端延迟 ≤60s」的落点之一。
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(_refresh(silent: true));
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _board?.dispose();
    super.dispose();
  }

  Future<ActivityBoard> _fetch(AppServices services) async {
    final ApiResult<ActivityBoard> result = await services.api.get<ActivityBoard>(
      ActivityPaths.board(widget.activityId),
      query: <String, String>{
        // 看板需要名单才能显示"谁没到"，因此一次把名单带上。
        // 数据量受活动名额限制（方案 §4.2 上限），不会过大。
        'includeParticipants': 'true',
      },
      decode: (Object? data) => ActivityBoard.fromJson(
        (data! as Map<Object?, Object?>).cast<String, dynamic>(),
      ),
    );

    return switch (result) {
      ApiSuccess<ActivityBoard>(:final ActivityBoard value) => value,
      // 不吞异常：交给 AppController 转成界面状态。
      ApiFailure<ActivityBoard>() => throw AppError.fromApi(result),
    };
  }

  /// 轻提示（看板页没有统一的 toast 助手，这里就地实现）。
  void _toast(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }
  /// 手动发起一次在岗抽查。
  ///
  /// 默认抽查"已签到、且当前没有待响应任务"的人（服务端决定），
  /// 避免同一个人被叠两条待确认。
  Future<void> _triggerManual() async {
    final AppServices services = AppScope.of(context);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('现在发起一次抽查？'),
        content: const Text(
          '会给**已签到**的志愿者发一条「在岗确认」，'
          '他们需要在响应窗口内点一下。\n\n'
          '已经有一条待响应的人不会重复收到。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('发起'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }

    setState(() => _manualing = true);
    final ApiResult<Map<String, dynamic>> r =
        await services.api.post<Map<String, dynamic>>(
      AttendancePaths.manual(widget.activityId),
      body: const <String, Object?>{},
      // 抽查会产生实际记录，不做自动重试（避免重复发两条）。
      retryable: false,
      decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, dynamic>(),
    );
    if (!mounted) {
      return;
    }
    setState(() => _manualing = false);

    if (r is ApiFailure<Map<String, dynamic>>) {
      _toast(AppError.fromApi(r).message);
      return;
    }
    if (r is ApiSuccess<Map<String, dynamic>>) {
      final Map<String, dynamic> data = r.value;
      final int total = (data['total'] as num?)?.toInt() ?? 0;
      final int skipped = (data['skipped'] as List<Object?>?)?.length ?? 0;
      _toast(
        total == 0
            ? (skipped > 0 ? '这些人都已有待确认的抽查' : '还没有已签到的人，暂不抽查')
            : '已发起 $total 人的在岗抽查',
      );
      await _refresh(silent: true);
    }
  }
  Future<void> _refresh({bool silent = false}) async {
    final AppController<ActivityBoard>? c = _board;
    if (c == null) {
      return;
    }
    if (mounted) {
      setState(() => _refreshing = true);
    }
    try {
      if (silent) {
        await c.refreshSilently();
      } else {
        await c.refresh();
      }
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
          _lastUpdated = DateTime.now();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('现场看板'),
        actions: <Widget>[
          /*
            手动抽查入口。

            自动抽查按间隔铺满整个活动，适合常规场景；但短活动会被反复打断，
            或者发布者只想对某个人点一次名 —— 那时需要"我现在就查一次"。
          */
          IconButton(
            onPressed: _manualing ? null : _triggerManual,
            icon: const Icon(Icons.touch_app_outlined),
            tooltip: '手动抽查',
          ),
          IconButton(
            onPressed: _refreshing ? null : () => _refresh(),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
        bottom: widget.activityTitle == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(26),
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: Spacing.md,
                    right: Spacing.md,
                    bottom: Spacing.xs,
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          widget.activityTitle!,
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      RefreshIndicatorRow(
                        lastUpdated: _lastUpdated,
                        onRefresh: _refreshing ? null : () => _refresh(),
                        isRefreshing: _refreshing,
                      ),
                    ],
                  ),
                ),
              ),
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    final AppController<ActivityBoard>? c = _board;
    if (c == null) {
      return const LoadingView();
    }

    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, Widget? _) {
        final AppResult<ActivityBoard> state = c.state;

        if (state.isLoading && !state.hasValue) {
          return const Padding(
            padding: EdgeInsets.all(Spacing.pageGutter),
            child: SkeletonList(rows: 4, height: 90),
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

        final ActivityBoard board = state.valueOrPrevious!;
        final List<Participant> shown = _filter == null
            ? board.participants
            : board.participants
                .where((Participant p) => p.checkinStatus == _filter)
                .toList();

        return RefreshIndicator(
          onRefresh: () => _refresh(),
          child: ListView(
            padding: const EdgeInsets.all(Spacing.pageGutter),
            children: <Widget>[
              // 静默刷新失败时**不换页**，只在顶部说明。
              // 现场看板正在被人看，闪成错误页会让人以为活动出问题了。
              if (state.errorOrNull != null) ...<Widget>[
                StatusChip.detailed(
                  visual: StatusVisual(
                    label: '刷新失败，显示的是上次数据',
                    tone: StatusTone.warning,
                    icon: Icons.cloud_off,
                    description: state.errorOrNull!.message,
                  ),
                ),
                const SizedBox(height: Spacing.md),
              ],

              _CountGrid(board: board, onTap: _onCountTap),
              const SizedBox(height: Spacing.md),

              // 免责声明必须显眼（方案 §4.8 / README §3.3）：
              // 它是发布者面对"你为什么扣我时长"这类质疑时的依据。
              _Disclaimer(text: board.disclaimer),
              const SizedBox(height: Spacing.md),

              AppSection(
                title: '名单（${shown.length}）',
                subtitle: _filter == null ? '共 ${board.participants.length} 人' : '已筛选',
                action: _filter == null
                    ? null
                    : TextButton(
                        onPressed: () => setState(() => _filter = null),
                        child: const Text('清除筛选'),
                      ),
                child: Column(
                  children: shown
                      .map((Participant p) => _ParticipantRow(
                            participant: p,
                            onReview: p.checkinStatus ==
                                    ParticipantCheckinStatus.pendingReview
                                ? () => _openReview(context, p)
                                : null,
                          ))
                      .toList(),
                ),
              ),

              if (board.dataDestroyAt != null) ...<Widget>[
                const SizedBox(height: Spacing.lg),
                _RetentionNotice(destroyAt: board.dataDestroyAt!),
              ],
            ],
          ),
        );
      },
    );
  }

  void _onCountTap(ParticipantCheckinStatus? status) {
    setState(() {
      // 再次点击同一项即取消筛选——比强制用户去找"清除筛选"更顺手。
      _filter = _filter == status ? null : status;
    });
  }

  Future<void> _openReview(BuildContext context, Participant p) async {
    final bool? changed = await Navigator.of(context).push<bool>(
      appRoute(
        CheckinReviewPage(
          activityId: widget.activityId,
          participant: p,
        ),
        name: Routes.adminActivity,
      ),
    );
    if (changed == true) {
      await _refresh(silent: true);
    }
  }
}

/// 四态计数网格。
///
/// 「待确认」单独用警示色并**可点击**：它是唯一需要发布者行动的一项。
class _CountGrid extends StatelessWidget {
  const _CountGrid({required this.board, required this.onTap});

  final ActivityBoard board;
  final void Function(ParticipantCheckinStatus?) onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: _CountTile(
                value: board.checkedIn,
                label: '已签到',
                tone: StatusTone.success,
                icon: Icons.check_circle_outline,
                onTap: () => onTap(ParticipantCheckinStatus.checkedIn),
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: _CountTile(
                value: board.pendingReview,
                label: '待确认',
                tone: board.pendingReview > 0
                    ? StatusTone.warning
                    : StatusTone.neutral,
                icon: Icons.visibility_outlined,
                emphasised: board.pendingReview > 0,
                onTap: () => onTap(ParticipantCheckinStatus.pendingReview),
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.xs),
        Row(
          children: <Widget>[
            Expanded(
              child: _CountTile(
                value: board.notCheckedIn,
                label: '尚未签到',
                tone: StatusTone.neutral,
                icon: Icons.radio_button_unchecked,
                onTap: () => onTap(ParticipantCheckinStatus.notCheckedIn),
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: _CountTile(
                value: board.removed,
                label: '已移出',
                tone: StatusTone.neutral,
                icon: Icons.person_remove_outlined,
                // 「已移出」不参与筛选：它已经不在有效名单里，
                // 看成"未签到"会冤枉人。
                onTap: null,
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.xs),
        // 在岗抽查的汇总单独一行：它与签到是两件事，混在一起会让人误读。
        AppCard(
          child: Row(
            children: <Widget>[
              const Icon(Icons.touch_app_outlined,
                  size: Sizes.iconMd, color: AppColors.textSecondary),
              const SizedBox(width: Spacing.xs),
              Text('在岗抽查', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              _MiniStat(label: '在岗', value: board.attendanceDone),
              _MiniStat(label: '待确认', value: board.attendancePending),
              _MiniStat(
                label: '超时',
                value: board.attendanceMissed,
                danger: board.attendanceMissed > 0,
              ),
              _MiniStat(label: '豁免', value: board.attendanceExcused),
            ],
          ),
        ),
      ],
    );
  }
}

class _CountTile extends StatelessWidget {
  const _CountTile({
    required this.value,
    required this.label,
    required this.tone,
    required this.icon,
    this.onTap,
    this.emphasised = false,
  });

  final int value;
  final String label;
  final StatusTone tone;
  final IconData icon;
  final VoidCallback? onTap;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final StatusVisual v = StatusVisual(label: label, tone: tone);

    return AppCard(
      onTap: onTap,
      highlight: emphasised,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.sm,
      ),
      semanticLabel: '$label $value 人${onTap != null ? '，点击筛选' : ''}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: Sizes.iconSm, color: v.foreground),
              const SizedBox(width: Spacing.xxs),
              Text(label, style: text.labelMedium?.copyWith(color: AppColors.textSecondary)),
            ],
          ),
          const SizedBox(height: Spacing.xxs),
          Text(
            '$value',
            style: text.headlineMedium?.copyWith(
              color: v.foreground,
              fontSize: 30,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value, this.danger = false});

  final String label;
  final int value;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(left: Spacing.sm),
      child: Column(
        children: <Widget>[
          Text(
            '$value',
            style: text.titleMedium?.copyWith(
              color: danger ? AppColors.danger : AppColors.textPrimary,
            ),
          ),
          Text(label, style: text.labelSmall),
        ],
      ),
    );
  }
}

/// 名单行。
class _ParticipantRow extends StatelessWidget {
  const _ParticipantRow({required this.participant, this.onReview});

  final Participant participant;

  /// 待确认时可点进复核。
  final VoidCallback? onReview;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final StatusVisual v =
        StatusVisuals.ofParticipantCheckin(participant.checkinStatus);

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: AppCard(
        onTap: onReview,
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
                      Text(participant.name, style: text.titleSmall),
                      const SizedBox(width: Spacing.xs),
                      Text(participant.userNo, style: text.labelSmall),
                    ],
                  ),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    // 手机号是**掩码**下发的。发布者要打电话时需要完整号码，
                    // 那条路径是导出（默认脱敏、可显式开启并留审计，决策 D-3）。
                    participant.phoneMasked ?? '未登记手机号',
                    style: text.bodySmall,
                  ),
                  if (participant.attendanceDone > 0 ||
                      participant.attendanceMissed > 0) ...<Widget>[
                    const SizedBox(height: Spacing.xxs),
                    Text(
                      '在岗：完成 ${participant.attendanceDone} · '
                      '超时 ${participant.attendanceMissed}'
                      '${participant.attendanceExcused > 0 ? ' · 豁免 ${participant.attendanceExcused}' : ''}',
                      style: text.labelSmall,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                StatusChip(visual: v, compact: true),
                if (onReview != null) ...<Widget>[
                  const SizedBox(height: Spacing.xxs),
                  Text('点击复核', style: text.labelSmall?.copyWith(color: AppColors.warning)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 免责声明。
class _Disclaimer extends StatelessWidget {
  const _Disclaimer({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: const BoxDecoration(
        color: AppColors.infoContainer,
        borderRadius: BorderRadius.all(Radius.circular(Radii.md)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.info_outline, size: Sizes.iconMd, color: AppColors.info),
          const SizedBox(width: Spacing.xs),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.onInfoContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// 留存期提醒。
///
/// 方案 §14.1-6 要求"请在 7 天内完成导出与对账，逾期不可恢复"。
/// 这句话必须在**数据还在的时候**说，而不是等销毁之后。
class _RetentionNotice extends StatelessWidget {
  const _RetentionNotice({required this.destroyAt});

  final DateTime destroyAt;

  @override
  Widget build(BuildContext context) {
    final Duration left = destroyAt.difference(DateTime.now());
    final bool urgent = left.inDays <= 2;
    return StatusChip.detailed(
      visual: StatusVisual(
        label: urgent ? '数据即将清理' : '数据留存期',
        tone: urgent ? StatusTone.danger : StatusTone.info,
        icon: Icons.schedule,
        description: '活动数据将于 ${TimeFormat.format(destroyAt)} 不可访问'
            '（剩约 ${left.inDays} 天）。请在此之前完成导出与对账，逾期不可恢复。',
      ),
    );
  }
}
