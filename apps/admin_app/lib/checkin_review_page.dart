import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/shared_ui.dart';

/// 签到复核（方案 §4.8；验收 A13）。
///
/// ## 这一页决定了"防脱岗"是帮人还是冤枉人
///
/// 抽查与自动判定一定会误判——方案 §13-A5 自己就承认了
/// 「『通知没到』会被记成『人不在』」。复核页就是修正误判的地方。
///
/// 因此它的设计原则是：**把证据摊开，把判断交给人**。
///
///   * 显示服务端给出的**评分构成**（哪些项得分、哪些没得），
///     而不是只给一个总分——发布者据此能判断"没得分"是可疑还是正常；
///   * 显示**距离与精度**：室内 ±80m 的定位落在围栏外是常见现象，
///     不是作弊；
///   * **驳回必须填备注**（服务端强制），因为志愿者会看到这条说明——
///     不解释就驳回，会让人完全不知道自己哪里做错了。
class CheckinReviewPage extends StatefulWidget {
  const CheckinReviewPage({
    required this.activityId,
    required this.participant,
    super.key,
  });

  final String activityId;
  final Participant participant;

  @override
  State<CheckinReviewPage> createState() => _CheckinReviewPageState();
}

class _CheckinReviewPageState extends State<CheckinReviewPage> {
  AppController<Checkin?>? _checkin;

  final TextEditingController _note = TextEditingController();

  bool _submitting = false;
  AppError? _error;

  /// 复核结论（用于提交后显示）。
  ReviewDecision? _done;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_checkin != null) {
      return;
    }
    final AppServices services = AppScope.of(context);
    _checkin = AppController<Checkin?>(
      load: () => _fetch(services),
    )..load();
  }

  @override
  void dispose() {
    _note.dispose();
    _checkin?.dispose();
    super.dispose();
  }

  /// 取该人的签到记录。
  ///
  /// ⚠️ 服务端的 `GET /activities/{id}/checkins` 是**全量列表**，
  /// 没有"按学号查一条"的端点。这里在客户端过滤。
  ///
  /// 之所以可以接受：看板已经把名单带回来了，一个活动的签到记录数量
  /// 受名额限制（方案 §4.2）。如果将来名额放宽到几千人，
  /// 这里要改成让服务端支持 `?userNo=` 过滤。
  Future<Checkin?> _fetch(AppServices services) async {
    final ApiResult<Map<String, dynamic>> result =
        await services.api.get<Map<String, dynamic>>(
      CheckinPaths.list(widget.activityId),
      decode: (Object? data) =>
          (data! as Map<Object?, Object?>).cast<String, dynamic>(),
    );

    switch (result) {
      case ApiSuccess<Map<String, dynamic>>(:final Map<String, dynamic> value):
        final Object? raw = value['items'];
        if (raw is! List) {
          return null;
        }
        final List<Checkin> all = raw
            .whereType<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> m) =>
                Checkin.fromJson(m.cast<String, dynamic>()))
            .where((Checkin c) => c.userNo == widget.participant.userNo)
            .toList();
        if (all.isEmpty) {
          return null;
        }
        // 服务端按时间倒序；取最新一条。
        return all.first;

      case ApiFailure<Map<String, dynamic>>():
        throw AppError.fromApi(result);
    }
  }

  Future<void> _submit(ReviewDecision decision) async {
    final Checkin? c = _checkin?.value;
    if (c == null) {
      return;
    }

    final String note = _note.text.trim();
    // 本地只拦"驳回却没写原因"这一种——它是服务端强制的，
    // 本地先拦能省一次往返，也让用户不必等失败再改。
    if (decision == ReviewDecision.reject && note.isEmpty) {
      setState(() {
        _error = AppError.local(
          title: '请填写驳回原因',
          message: '志愿者会看到这条说明。不解释就驳回，他会不知道自己哪里做错了。',
          canRetry: false,
        );
      });
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    final AppServices services = AppScope.of(context);
    final ApiResult<Map<String, dynamic>> result =
        await services.api.post<Map<String, dynamic>>(
      CheckinPaths.review(c.id),
      body: <String, Object?>{
        'decision': decision.wire,
        if (note.isNotEmpty) 'note': note,
      },
      // 幂等：重复提交同一条复核不会产生两次记录（服务端已判状态）。
      idempotencyKey: services.api.newIdempotencyKey(),
      retryable: false,
      decode: (Object? data) =>
          (data! as Map<Object?, Object?>).cast<String, dynamic>(),
    );

    if (!mounted) {
      return;
    }

    switch (result) {
      case ApiSuccess<Map<String, dynamic>>():
        setState(() {
          _submitting = false;
          _done = decision;
        });
      case ApiFailure<Map<String, dynamic>>():
        setState(() {
          _submitting = false;
          _error = AppError.fromApi(result);
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('签到复核')),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    final AppController<Checkin?>? c = _checkin;
    if (c == null) {
      return const LoadingView();
    }

    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, Widget? _) {
        final AppResult<Checkin?> state = c.state;

        if (state.isLoading && !state.hasValue) {
          return const Padding(
            padding: EdgeInsets.all(Spacing.pageGutter),
            child: SkeletonList(rows: 3, height: 90),
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

        final Checkin? checkin = state.valueOrPrevious;

        if (_done != null) {
          return _DoneView(
            decision: _done!,
            participant: widget.participant,
            onClose: () => Navigator.of(context).pop(true),
          );
        }

        if (checkin == null) {
          return _NoCheckinView(participant: widget.participant);
        }

        return ListView(
          padding: const EdgeInsets.all(Spacing.pageGutter),
          children: <Widget>[
            _PersonHeader(participant: widget.participant, checkin: checkin),
            const SizedBox(height: Spacing.md),

            _EvidenceCard(checkin: checkin),
            const SizedBox(height: Spacing.md),

            // 评分构成：把"为什么是这个分"摊开。
            if (checkin.scoreItems.isNotEmpty) ...<Widget>[
              _ScoreCard(checkin: checkin),
              const SizedBox(height: Spacing.md),
            ],

            if (checkin.status != CheckinStatus.pendingReview) ...<Widget>[
              const StatusChip.detailed(
                visual: StatusVisual(
                  label: '该记录已定案',
                  tone: StatusTone.info,
                  icon: Icons.lock_outline,
                  description: '只有「待确认」的记录可以复核。'
                      '已通过的记录如需修正，请用人工补录或联系系统管理员。',
                ),
              ),
            ] else ...<Widget>[
              AppSection(
                title: '复核意见',
                subtitle: '驳回时必须填写，志愿者会看到这条说明',
                child: TextField(
                  controller: _note,
                  enabled: !_submitting,
                  maxLines: 3,
                  maxLength: 200,
                  decoration: const InputDecoration(
                    hintText: '例如：现场已核实本人在图书区，手动通过',
                  ),
                ),
              ),
              const SizedBox(height: Spacing.md),

              if (_error != null) ...<Widget>[
                _ErrorBanner(error: _error!),
                const SizedBox(height: Spacing.md),
              ],

              Row(
                children: <Widget>[
                  Expanded(
                    child: AppButton(
                      label: '驳回',
                      variant: AppButtonVariant.secondary,
                      loading: _submitting,
                      onPressed: _submitting
                          ? null
                          : () => _submit(ReviewDecision.reject),
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: AppButton(
                      label: '通过',
                      icon: Icons.check,
                      loading: _submitting,
                      loadingLabel: '提交中…',
                      onPressed: _submitting
                          ? null
                          : () => _submit(ReviewDecision.approve),
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: Spacing.lg),
            Text(
              '复核结论会立即写入记录，并显示在该志愿者的「我的记录」里。\n'
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

/// 人员与状态头部。
class _PersonHeader extends StatelessWidget {
  const _PersonHeader({required this.participant, required this.checkin});

  final Participant participant;
  final Checkin checkin;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final StatusVisual v = StatusVisuals.ofCheckin(checkin.status);
    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(participant.name, style: text.titleMedium),
                const SizedBox(height: Spacing.xxs),
                Text('${participant.userNo} · ${participant.phoneMasked ?? '未登记手机号'}',
                    style: text.bodySmall),
                const SizedBox(height: Spacing.xs),
                Text(
                  checkin.reason ?? '无说明',
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: Spacing.xs),
          StatusChip(visual: v, compact: true),
        ],
      ),
    );
  }
}

/// 证据卡片。
///
/// 刻意把**精度**与**距离**并排显示：室内定位 ±80m 时，
/// 一个"距签到点 120 米"的记录其实完全可能是本人。
/// 只看距离就驳回，是这一页最容易犯的错。
class _EvidenceCard extends StatelessWidget {
  const _EvidenceCard({required this.checkin});

  final Checkin checkin;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('客观证据', style: text.titleSmall),
          const SizedBox(height: Spacing.xs),
          InfoRow(
            label: '提交时间',
            value: checkin.serverTime == null
                ? '—'
                : TimeFormat.format(checkin.serverTime!, withSeconds: true),
            icon: Icons.access_time,
          ),
          InfoRow(label: '方式', value: checkin.method.label, icon: Icons.my_location),
          InfoRow(
            label: '距签到点',
            value: checkin.distanceMeters == null
                ? '无坐标'
                : '约 ${checkin.distanceMeters!.round()} 米',
            icon: Icons.straighten,
          ),
          InfoRow(
            label: '定位精度',
            value: checkin.accuracy == null ? '—' : '±${checkin.accuracy!.round()} 米',
            icon: Icons.gps_fixed,
          ),
          if (checkin.mockLocationDetected)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Text(
                '⚠️ 设备自报检测到模拟定位。这只是一条线索，不是结论——'
                '请结合现场情况判断。',
                style: text.bodySmall?.copyWith(color: AppColors.danger),
              ),
            ),
          if (checkin.offlineBackfill)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Text(
                '该记录是**离线补传**（签到时段之后才上传），因此一律转人工。'
                '若本人当时确实在场，通过即可。',
                style: text.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

/// 评分构成。
class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.checkin});

  final Checkin checkin;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final int total = checkin.score ?? 0;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text('证据评分', style: text.titleSmall)),
              Text(
                '$total 分',
                style: text.titleMedium?.copyWith(
                  color: total >= 60
                      ? AppColors.success
                      : total >= 30
                          ? AppColors.warning
                          : AppColors.danger,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xxs),
          Text(
            '自动通过需 ≥60 分；30–59 分转人工（就是当前这条）。'
            '评分只是辅助，最终由你判断。',
            style: text.bodySmall,
          ),
          const SizedBox(height: Spacing.sm),
          ...checkin.scoreItems.map(
            (ScoreItem item) => Padding(
              padding: const EdgeInsets.only(bottom: Spacing.xxs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 44,
                    child: Text(
                      item.points > 0 ? '+${item.points}' : '${item.points}',
                      style: text.labelMedium?.copyWith(
                        color: item.points > 0
                            ? AppColors.success
                            : item.points < 0
                                ? AppColors.danger
                                : AppColors.textTertiary,
                      ),
                    ),
                  ),
                  Expanded(child: Text(item.reason, style: text.bodySmall)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 该人没有签到记录。
class _NoCheckinView extends StatelessWidget {
  const _NoCheckinView({required this.participant});

  final Participant participant;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(Spacing.pageGutter),
      children: <Widget>[
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.1),
        EmptyState(
          title: '${participant.name} 还没有签到记录',
          message: '他没有提交过签到证据，因此没有可复核的内容。\n'
              '如果本人确实到场（例如手机故障），请用「人工补录」为他记录。',
          icon: Icons.how_to_reg_outlined,
        ),
      ],
    );
  }
}

/// 复核完成。
class _DoneView extends StatelessWidget {
  const _DoneView({
    required this.decision,
    required this.participant,
    required this.onClose,
  });

  final ReviewDecision decision;
  final Participant participant;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool approved = decision == ReviewDecision.approve;
    final StatusVisual v = StatusVisual(
      label: approved ? '已通过' : '已驳回',
      tone: approved ? StatusTone.success : StatusTone.danger,
      icon: approved ? Icons.check_circle : Icons.cancel,
    );

    return ListView(
      padding: const EdgeInsets.all(Spacing.pageGutter),
      children: <Widget>[
        const SizedBox(height: Spacing.xxl),
        Icon(v.icon, size: 64, color: v.foreground),
        const SizedBox(height: Spacing.md),
        Text(
          v.label,
          textAlign: TextAlign.center,
          style: text.headlineMedium?.copyWith(color: v.foreground),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          approved
              ? '${participant.name} 的签到已确认为有效。'
              : '${participant.name} 的签到已驳回，原因会显示在他的「我的记录」里。',
          textAlign: TextAlign.center,
          style: text.bodyMedium,
        ),
        const SizedBox(height: Spacing.xxl),
        AppButton(label: '返回看板', onPressed: onClose),
      ],
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
        ],
      ),
    );
  }
}
