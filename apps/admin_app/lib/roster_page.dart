import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_platform/shared_platform.dart';
import 'package:shared_ui/shared_ui.dart';

/// 名单管理（方案 §4.6、§4.7）。
///
/// ## 核心是一件事：把"谁能来"这件事录进去，并把邀请码发出去
///
/// 两步是分开的，因为它们的**后果完全不同**：
///   * 录入名单 → 只是数据，录错了改一下就行；
///   * 发邀请码 → **一次性的**，发出去就消耗掉了（方案 §5.2）。
///
/// 因此界面上刻意把它们分成两个动作，并且邀请码明文**只显示一次**。
class RosterPage extends StatefulWidget {
  const RosterPage({
    required this.activityId,
    this.activityTitle,
    super.key,
  });

  final String activityId;
  final String? activityTitle;

  @override
  State<RosterPage> createState() => _RosterPageState();
}

class _RosterPageState extends State<RosterPage> {
  AppController<List<Participant>>? _roster;

  /// 刚生成的邀请码明文（仅本次会话可见）。
  ///
  /// 服务端明确"明文不可再次获取"，因此这里一旦离开页面就没了——
  /// 这正是设计意图：把"码被谁看到"的影响面压到最小。
  List<InviteCode> _issuedCodes = const <InviteCode>[];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_roster != null) {
      return;
    }
    final AppServices services = AppScope.of(context);
    _roster = AppController<List<Participant>>(
      load: () => _fetch(services),
    )..load();
  }

  @override
  void dispose() {
    _roster?.dispose();
    super.dispose();
  }

  Future<List<Participant>> _fetch(AppServices services) async {
    final ApiResult<Map<String, dynamic>> result =
        await services.api.get<Map<String, dynamic>>(
      ParticipantPaths.list(widget.activityId),
      decode: (Object? data) =>
          (data! as Map<Object?, Object?>).cast<String, dynamic>(),
    );

    switch (result) {
      case ApiSuccess<Map<String, dynamic>>(:final Map<String, dynamic> value):
        final Object? raw = value['items'];
        if (raw is! List) {
          return <Participant>[];
        }
        return raw
            .whereType<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> m) =>
                Participant.fromJson(m.cast<String, dynamic>()))
            .toList();
      case ApiFailure<Map<String, dynamic>>():
        throw AppError.fromApi(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('名单'),
        actions: <Widget>[
          IconButton(
            onPressed: () => _openImport(context),
            icon: const Icon(Icons.upload_file),
            tooltip: '批量导入',
          ),
          IconButton(
            onPressed: () => _openAddOne(context),
            icon: const Icon(Icons.person_add_alt),
            tooltip: '添加一人',
          ),
        ],
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
    final AppController<List<Participant>>? c = _roster;
    if (c == null) {
      return const LoadingView();
    }

    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, Widget? _) {
        final AppResult<List<Participant>> state = c.state;

        if (state.isLoading && !state.hasValue) {
          return const Padding(
            padding: EdgeInsets.all(Spacing.pageGutter),
            child: SkeletonList(rows: 4, height: 80),
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

        final List<Participant> list = state.valueOrPrevious ?? const <Participant>[];
        final List<Participant> active = list
            .where((Participant p) => p.signupStatus != SignupStatus.cancelled)
            .toList();
        final int issued = active.where((Participant p) => p.inviteCodeIssued).length;
        final int used = active.where((Participant p) => p.inviteCodeUsedAt != null).length;

        return RefreshIndicator(
          onRefresh: () async => c.refresh(),
          child: ListView(
            padding: const EdgeInsets.all(Spacing.pageGutter),
            children: <Widget>[
              // 发放进度一眼可见：发布者最关心"还有谁没拿到码"。
              AppCard(
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: _Stat(
                        label: '有效名单',
                        value: '${active.length}',
                        icon: Icons.people_outline,
                      ),
                    ),
                    Expanded(
                      child: _Stat(
                        label: '已发码',
                        value: '$issued',
                        icon: Icons.vpn_key_outlined,
                      ),
                    ),
                    Expanded(
                      child: _Stat(
                        label: '已绑定',
                        value: '$used',
                        icon: Icons.how_to_reg_outlined,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.md),

              /*
                常驻的「活动编号」行。

                邀请码明文只显示一次（安全设计），但**活动编号是永久的**，
                发布者随时可能被问"活动编号是多少"。以前它只出现在详情页，
                现场临时找不到很常见。这里放一条常驻行，随手可复制。
              */
              AppCard(
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.tag, size: Sizes.iconSm),
                    const SizedBox(width: Spacing.xs),
                    Text('活动编号', style: Theme.of(context).textTheme.labelMedium),
                    const SizedBox(width: Spacing.xs),
                    Expanded(
                      child: SelectableText(
                        widget.activityId,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              fontFamily: 'monospace',
                            ),
                      ),
                    ),
                    IconButton(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: widget.activityId),
                        );
                        if (!context.mounted) {
                          return;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('活动编号已复制：${widget.activityId}'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy, size: Sizes.iconSm),
                      tooltip: '复制活动编号',
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.md),

              if (_issuedCodes.isNotEmpty) ...<Widget>[
                _IssuedCodesCard(
                  codes: _issuedCodes,
                  activityId: widget.activityId,
                  activityTitle: widget.activityTitle,
                  onDismiss: _clearIssued,
                ),
                const SizedBox(height: Spacing.md),
              ],

              Row(
                children: <Widget>[
                  Expanded(
                    child: AppButton(
                      label: '为未发码的人生成邀请码',
                      icon: Icons.vpn_key,
                      variant: AppButtonVariant.secondary,
                      compact: true,
                      onPressed: () => _issueCodes(context, active),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.md),

              AppSection(
                title: '名单（${list.length}）',
                subtitle: '共 ${active.length} 人在有效名单中',
                child: list.isEmpty
                    ? const EmptyState(
                        title: '名单还是空的',
                        message: '点右上角的「批量导入」把报名表录进来。\n'
                            '导入时会逐行校验，有问题的行会单独列出来。',
                        icon: Icons.people_outline,
                        compact: true,
                      )
                    : Column(
                        children: list
                            .map((Participant p) => _ParticipantTile(
                                  participant: p,
                                  onRemove: p.signupStatus == SignupStatus.cancelled
                                      ? null
                                      : () => _confirmRemove(context, p),
                                ))
                            .toList(),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── 批量导入 ──────────────────────────────────────────────────────────

  Future<void> _openImport(BuildContext context) async {
    final ImportReport? report = await Navigator.of(context).push<ImportReport>(
      appSlideRoute(RosterImportPage(activityId: widget.activityId)),
    );
    // ⚠️ 这里必须用 `context.mounted` 而不是 `mounted`：
    // 跨过 await 之后要检查的是**这个传入的 context** 是否还有效，
    // 而不是 State 自己。两者在页面被弹出时可能不同步
    // （State 还在、但 context 已从树上摘除）。
    if (report == null || !context.mounted) {
      return;
    }
    await _roster?.refresh();
    if (!context.mounted) {
      return;
    }
    _showImportReport(report);
  }

  void _showImportReport(ImportReport report) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => _ImportReportSheet(report: report),
    );
  }

  // ── 添加一人 ──────────────────────────────────────────────────────────

  Future<void> _openAddOne(BuildContext context) async {
    final RosterEntry? entry = await showDialog<RosterEntry>(
      context: context,
      builder: (BuildContext context) => const _AddOneDialog(),
    );
    if (entry == null || !context.mounted) {
      return;
    }
    /*
      现场临时加人：学号与姓名必填，学院与手机号选填。

      ⚠️ 以前这里只问学号，然后拿学号当姓名提交 —— 名单里会出现一个
      叫「2026101」的"人"。现场看不出来，但导出与核对时很尴尬。
      姓名既然服务端本来就必填，就让用户一次填对。
    */
    final AppServices services = AppScope.of(context);
    final ApiResult<Map<String, dynamic>> r =
        await services.api.post<Map<String, dynamic>>(
      ParticipantPaths.add(widget.activityId),
      body: <String, Object?>{
        'userNo': entry.userNo,
        'name': entry.name,
        if (entry.college.isNotEmpty) 'college': entry.college,
        if (entry.phone.isNotEmpty) 'phone': entry.phone,
      },
      retryable: false,
      decode: (Object? data) =>
          (data! as Map<Object?, Object?>).cast<String, dynamic>(),
    );
    if (!context.mounted) {
      return;
    }
    if (r is ApiFailure<Map<String, dynamic>>) {
      _toast(AppError.fromApi(r).message);
    } else {
      await _roster?.refresh();
      _toast('已添加 ${entry.name}');
    }
  }

  // ── 生成邀请码 ────────────────────────────────────────────────────────

  Future<void> _issueCodes(BuildContext context, List<Participant> active) async {
    final List<Participant> targets = active
        .where((Participant p) => p.inviteCodeUsedAt == null)
        .toList();
    if (targets.isEmpty) {
      _toast('所有人都已绑定，无需再发码');
      return;
    }

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('为 ${targets.length} 人生成邀请码？'),
        content: const Text(
          '邀请码是**一次性**的：它只在本人设备上首次使用时有效。\n\n'
          '生成后会立即显示明文，且**只显示这一次**——'
          '请当场私下发给本人，不要贴在群里或公告栏。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('生成'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) {
      return;
    }

    final AppServices services = AppScope.of(context);
    final ApiResult<Map<String, dynamic>> r =
        await services.api.post<Map<String, dynamic>>(
      ParticipantPaths.issueInviteCodes(widget.activityId),
      body: <String, Object?>{
        'userNos': targets.map((Participant p) => p.userNo).toList(),
      },
      retryable: false,
      decode: (Object? data) =>
          (data! as Map<Object?, Object?>).cast<String, dynamic>(),
    );

    if (!context.mounted) {
      return;
    }
    switch (r) {
      case ApiSuccess<Map<String, dynamic>>(:final Map<String, dynamic> value):
        final Object? raw = value['items'];
        final List<InviteCode> codes = raw is List
            ? raw
                .whereType<Map<Object?, Object?>>()
                .map((Map<Object?, Object?> m) =>
                    InviteCode.fromJson(m.cast<String, dynamic>()))
                .toList()
            : const <InviteCode>[];
        setState(() => _issuedCodes = codes);
        await _roster?.refresh();
      case ApiFailure<Map<String, dynamic>>():
        _toast(AppError.fromApi(r).message);
    }
  }

  void _clearIssued() => setState(() => _issuedCodes = const <InviteCode>[]);

  // ── 移出名单 ──────────────────────────────────────────────────────────

  Future<void> _confirmRemove(BuildContext context, Participant p) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('把 ${p.name} 移出名单？'),
        content: const Text(
          '移出后他无法再签到，已产生的记录**不会删除**（用于对账留痕）。\n'
          '这是一次软删除，历史仍可查。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) {
      return;
    }

    final AppServices services = AppScope.of(context);
    final ApiResult<Map<String, dynamic>> r =
        await services.api.delete<Map<String, dynamic>>(
      ParticipantPaths.remove(widget.activityId, p.userNo),
      decode: (Object? data) =>
          (data! as Map<Object?, Object?>).cast<String, dynamic>(),
    );
    if (!context.mounted) {
      return;
    }
    if (r is ApiFailure<Map<String, dynamic>>) {
      _toast(AppError.fromApi(r).message);
    } else {
      await _roster?.refresh();
    }
  }

  void _toast(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 顶部统计。
class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      children: <Widget>[
        Icon(icon, size: Sizes.iconMd, color: AppColors.textSecondary),
        const SizedBox(height: Spacing.xxs),
        Text(value, style: text.titleLarge),
        Text(label, style: text.labelSmall),
      ],
    );
  }
}

/// 刚生成的邀请码（明文，仅本次可见）。
class _IssuedCodesCard extends StatelessWidget {
  const _IssuedCodesCard({
    required this.codes,
    required this.activityId,
    required this.activityTitle,
    required this.onDismiss,
  });

  final List<InviteCode> codes;

  /// 活动编号。**必须显示出来**：志愿者要填的第一个框就是它，
  /// 而发布者此前只能自己去别处找 —— 真机反馈里这是最容易卡住的一步。
  final String activityId;

  final String? activityTitle;
  final VoidCallback onDismiss;

  /// 拼出"一段就能发出去"的文本。
  ///
  /// 格式与解析规则见 `InviteShare`（两端共用）：
  /// 志愿者在绑定页点「粘贴邀请信息」即可自动填好三个框。
  String _shareTextFor(InviteCode c) => InviteShare(
        activityId: activityId,
        userNo: c.userNo,
        inviteCode: c.code,
        activityTitle: activityTitle,
        studentName: c.name.isEmpty ? null : c.name,
      ).toText();

  Future<void> _copy(BuildContext context, String text, String tip) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tip), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: const BoxDecoration(
        color: AppColors.warningContainer,
        borderRadius: BorderRadius.all(Radius.circular(Radii.md)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.warning_amber_outlined,
                  size: Sizes.iconMd, color: AppColors.warning),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Text(
                  '邀请码明文（只显示这一次）',
                  style: text.titleSmall?.copyWith(color: AppColors.onWarningContainer),
                ),
              ),
              TextButton(
                onPressed: onDismiss,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.onWarningContainer,
                  minimumSize: const Size(0, 32),
                ),
                child: const Text('我已记下'),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xxs),
          Text(
            '离开本页后无法再查看。请逐条私下发给本人——'
            '贴到群里等于把码公开，任何人都能拿它去绑定别人。',
            style: text.bodySmall?.copyWith(color: AppColors.onWarningContainer),
          ),
          const SizedBox(height: Spacing.xs),

          /*
            活动编号放在这里，并做成可复制。

            真机反馈：志愿者绑定要填的第一个框就是「活动编号」，
            而发布者此前得自己翻到详情页去找、还可能抄错
            （演示模式下它甚至形如 demo-act-library，手抄基本不可能）。
            所以：显示出来 + 一键复制 + 逐条复制整段。
          */
          Row(
            children: <Widget>[
              Text(
                '活动编号：',
                style: text.labelMedium?.copyWith(color: AppColors.onWarningContainer),
              ),
              Expanded(
                child: SelectableText(
                  activityId,
                  style: text.labelMedium?.copyWith(
                    fontFamily: 'monospace',
                    color: AppColors.onWarningContainer,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => _copy(context, activityId, '活动编号已复制：$activityId'),
                icon: const Icon(Icons.copy, size: Sizes.iconSm),
                color: AppColors.onWarningContainer,
                tooltip: '复制活动编号',
                visualDensity: VisualDensity.compact,
              ),
              if (codes.length > 1)
                TextButton.icon(
                  onPressed: () => _copy(
                    context,
                    codes.map(_shareTextFor).join('\n\n———\n\n'),
                    '已复制 ${codes.length} 人的邀请信息（各自分开发送）',
                  ),
                  icon: const Icon(Icons.copy_all, size: Sizes.iconSm),
                  label: const Text('复制全部'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.onWarningContainer,
                    minimumSize: const Size(0, 32),
                  ),
                ),
            ],
          ),
          const SizedBox(height: Spacing.xxs),
          Text(
            '点每行右侧的复制按钮，会复制**整段邀请信息**（含活动编号），'
            '志愿者在绑定页点「粘贴邀请信息」即可自动填入。',
            style: text.labelSmall?.copyWith(color: AppColors.onWarningContainer),
          ),
          const SizedBox(height: Spacing.sm),
          ...codes.map(
            (InviteCode c) => Padding(
              padding: const EdgeInsets.only(bottom: Spacing.xxs),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 88,
                    child: Text(
                      c.userNo,
                      style: text.labelMedium?.copyWith(
                        color: AppColors.onWarningContainer,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      c.code,
                      style: text.titleSmall?.copyWith(
                        fontFamily: 'monospace',
                        color: AppColors.onWarningContainer,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                  IconButton(
                    // 复制**整段邀请信息**（活动编号 + 学号 + 邀请码），
                    // 而不是只复制码：志愿者拿到一段就能在绑定页一键粘贴。
                    onPressed: () => _copy(
                      context,
                      _shareTextFor(c),
                      '已复制 ${c.userNo} 的邀请信息，可直接发给本人',
                    ),
                    icon: const Icon(Icons.copy, size: Sizes.iconSm),
                    color: AppColors.onWarningContainer,
                    tooltip: '复制邀请信息',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 名单条目。
class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({required this.participant, this.onRemove});

  final Participant participant;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool removed = participant.signupStatus == SignupStatus.cancelled;

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
                      Flexible(child: Text(participant.name, style: text.titleSmall)),
                      const SizedBox(width: Spacing.xs),
                      Text(participant.userNo, style: text.labelSmall),
                    ],
                  ),
                  // 学院（选填）：有就显示，没有就不占位 —— 不能因为字段可空就渲染一个空格子
                  if (participant.college != null &&
                      participant.college!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      participant.college!,
                      style: text.labelSmall?.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                  const SizedBox(height: Spacing.xxs),
                  Row(
                    children: <Widget>[
                      StatusChip(
                        visual: StatusVisuals.ofSignup(participant.signupStatus),
                        compact: true,
                      ),
                      const SizedBox(width: Spacing.xxs),
                      if (participant.inviteCodeUsedAt != null)
                        const _MiniTag(text: '已绑定', tone: StatusTone.success)
                      else if (participant.inviteCodeIssued)
                        const _MiniTag(text: '已发码', tone: StatusTone.info)
                      else
                        const _MiniTag(text: '未发码', tone: StatusTone.warning),
                    ],
                  ),
                ],
              ),
            ),
            if (onRemove != null)
              IconButton(
                onPressed: onRemove,
                icon: const Icon(Icons.person_remove_outlined, size: Sizes.iconMd),
                color: AppColors.textTertiary,
                tooltip: '移出名单',
                visualDensity: VisualDensity.compact,
              ),
            if (removed)
              const Padding(
                padding: EdgeInsets.only(left: Spacing.xxs),
                child: Icon(Icons.history, size: Sizes.iconSm, color: AppColors.textTertiary),
              ),
          ],
        ),
      ),
    );
  }
}

class _MiniTag extends StatelessWidget {
  const _MiniTag({required this.text, required this.tone});

  final String text;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final StatusVisual v = StatusVisual(label: text, tone: tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: 1),
      decoration: BoxDecoration(
        color: v.background,
        borderRadius: Radii.pillRadius,
      ),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: v.onBackground),
      ),
    );
  }
}

/// 添加一人的对话框。
class _AddOneDialog extends StatefulWidget {
  const _AddOneDialog();

  @override
  State<_AddOneDialog> createState() => _AddOneDialogState();
}

class _AddOneDialogState extends State<_AddOneDialog> {
  final TextEditingController _userNo = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _college = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _userNo.dispose();
    _name.dispose();
    _college.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _submit() {
    final String userNo = _userNo.text.trim();
    final String name = _name.text.trim();
    /*
      只校验"能不能提交"，不校验学号的具体形态。

      学号长度并不固定（不同学院、工号、留学生编号都不一样），
      前端写死规则只会把合法学号挡在外面。格式由服务端统一校验，
      服务端拒绝时会给出字段级错误，这里把消息显示出来即可。
    */
    if (userNo.isEmpty) {
      setState(() => _error = '请填写学号');
      return;
    }
    if (name.isEmpty) {
      setState(() => _error = '请填写姓名');
      return;
    }
    Navigator.of(context).pop(RosterEntry(
      userNo: userNo,
      name: name,
      college: _college.text.trim(),
      phone: _phone.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('临时添加一人'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('适用于现场临时加入的志愿者。学院与手机号可以只填一个，也可以都不填。'),
            const SizedBox(height: Spacing.sm),
            TextField(
              controller: _userNo,
              autofocus: true,
              textInputAction: TextInputAction.next,
              inputFormatters: <TextInputFormatter>[
                LengthLimitingTextInputFormatter(32),
              ],
              decoration: const InputDecoration(
                labelText: '学号 / 工号（必填）',
                hintText: '字母与数字，2～32 位，长度不限',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: Spacing.xs),
            TextField(
              controller: _name,
              textInputAction: TextInputAction.next,
              inputFormatters: <TextInputFormatter>[
                LengthLimitingTextInputFormatter(64),
              ],
              decoration: const InputDecoration(
                labelText: '姓名（必填）',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: Spacing.xs),
            TextField(
              controller: _college,
              textInputAction: TextInputAction.next,
              inputFormatters: <TextInputFormatter>[
                LengthLimitingTextInputFormatter(64),
              ],
              decoration: const InputDecoration(
                labelText: '学院（选填）',
                hintText: '例如：计算机学院',
                prefixIcon: Icon(Icons.school_outlined),
              ),
            ),
            const SizedBox(height: Spacing.xs),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              inputFormatters: <TextInputFormatter>[
                LengthLimitingTextInputFormatter(20),
              ],
              decoration: const InputDecoration(
                labelText: '手机号（选填）',
                hintText: '用于绑定身份核对',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: Spacing.xs),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.danger,
                    ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('添加'),
        ),
      ],
    );
  }
}

/// 导入报告底部弹层。
///
/// ## 为什么要把逐行结果摊开
///
/// 批量导入最常见的失败不是"全错"，而是**几十行里错了三行**。
/// 如果只报"导入完成"，发布者根本不知道哪三行有问题，
/// 而这三个人第二天就签不上到。
class _ImportReportSheet extends StatelessWidget {
  const _ImportReportSheet({required this.report});

  final ImportReport report;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final List<ImportRowResult> bad = report.rows
        .where((ImportRowResult r) => !r.accepted)
        .toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (BuildContext context, ScrollController controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.all(Spacing.pageGutter),
        children: <Widget>[
          Text('导入结果', style: text.titleLarge),
          const SizedBox(height: Spacing.md),
          Row(
            children: <Widget>[
              Expanded(
                child: _Stat(
                  label: '总行数',
                  value: '${report.total}',
                  icon: Icons.list_alt,
                ),
              ),
              Expanded(
                child: _Stat(
                  label: '已接受',
                  value: '${report.accepted}',
                  icon: Icons.check_circle_outline,
                ),
              ),
              Expanded(
                child: _Stat(
                  label: '被拒绝',
                  value: '${report.rejected}',
                  icon: Icons.error_outline,
                ),
              ),
              if (report.pendingConfirm > 0)
                Expanded(
                  child: _Stat(
                    label: '待确认',
                    value: '${report.pendingConfirm}',
                    icon: Icons.help_outline,
                  ),
                ),
            ],
          ),
          const SizedBox(height: Spacing.md),

          if (bad.isEmpty)
            const StatusChip.detailed(
              visual: StatusVisual(
                label: '全部接受',
                tone: StatusTone.success,
                icon: Icons.check_circle,
                description: '所有行都通过了校验，名单已更新。',
              ),
            )
          else ...<Widget>[
            Text('需要修正的行', style: text.titleSmall),
            const SizedBox(height: Spacing.xs),
            Text(
              '这些行没有被录入。修正后可以只重传这些行——'
              '重复上报同一个人不会产生重复记录。',
              style: text.bodySmall,
            ),
            const SizedBox(height: Spacing.sm),
            ...bad.map(
              (ImportRowResult r) => Padding(
                padding: const EdgeInsets.only(bottom: Spacing.xs),
                child: AppCard(
                  padding: const EdgeInsets.all(Spacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '第 ${r.row} 行${r.userNo == null ? '' : ' · ${r.userNo}'}',
                        style: text.titleSmall,
                      ),
                      const SizedBox(height: Spacing.xxs),
                      Text(r.reason ?? '校验未通过', style: text.bodySmall),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 批量导入页。
///
/// ## 交互上的一条硬要求：**能粘贴**
///
/// 发布者手上的名单来自报名表（Excel / 问卷导出），他做的最自然的事是
/// **从表格里复制一片单元格然后粘贴进来**。因此这里不做"一行一行加"，
/// 而是一个多行文本框，按行解析。
class RosterImportPage extends StatefulWidget {
  const RosterImportPage({required this.activityId, super.key});

  final String activityId;

  @override
  State<RosterImportPage> createState() => _RosterImportPageState();
}

class _RosterImportPageState extends State<RosterImportPage> {
  final TextEditingController _text = TextEditingController();

  bool _submitting = false;

  /// 正在选文件/读文件（避免连点，也让用户知道刚才那一下生效了）。
  bool _picking = false;

  AppError? _error;

  /// 最近一次解析结果（实时预览用）。
  ///
  /// 存**结果对象**而不是行数：界面要把"学号/姓名/手机号/学院"逐列显示出来，
  /// 才能让"读错行"一眼可见 —— 只显示"已识别 3 行"骗过了不少人。
  RosterParseResult? _lastParse;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onChanged);
  }

  /// 选一个 Excel / CSV 文件，解析后回填到文本框。
  ///
  /// ## 为什么不直接提交
  ///
  /// 表格里出现"多一列序号""姓名和学号顺序反了"是常事。直接提交会让
  /// 发布者看到一堆"学号格式不对"的错误，却不知道是列顺序的问题。
  /// 回填到文本框后他能**一眼看出**对不对，改两下再提交 ——
  /// 这也是原来的粘贴流程，行为一致。
  Future<void> _pickFile() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() {
      _picking = true;
      _error = null;
    });

    try {
      final SpreadsheetFile? file = await SpreadsheetImport.pick();
      if (!mounted) {
        return;
      }
      if (file == null) {
        // 用户取消：不是错误，安静收场。
        setState(() => _picking = false);
        return;
      }

      final List<List<String>> rows = SpreadsheetImport.parseRows(file);
      if (rows.isEmpty) {
        setState(() {
          _picking = false;
          _error = const AppError(
            title: '文件里没有数据',
            message: '没读到任何行。请确认表里有学号和姓名两列（表头可以是「学号/姓名/学院/手机号」）。',
            canRetry: false,
          );
        });
        return;
      }

      // 回填为制表符分隔文本，复用现有的预览与提交逻辑。
      _text.text = rowsToTsv(rows);
      setState(() => _picking = false);

      messenger.showSnackBar(
        SnackBar(
          content: Text('已从「${file.name}」读取 ${rows.length} 行，请核对后再导入'),
          duration: const Duration(seconds: 3),
        ),
      );
    } on SpreadsheetImportException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _picking = false;
        _error = AppError(title: '读取失败', message: e.message, canRetry: false);
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _picking = false;
        _error = AppError(
          title: '读取失败',
          message: '读取文件失败：${SpreadsheetImportException.debug(e)}',
          canRetry: false,
        );
      });
    }
  }

  @override
  void dispose() {
    _text.removeListener(_onChanged);
    _text.dispose();
    super.dispose();
  }

  void _onChanged() {
    final RosterParseResult result = parseRosterText(_text.text);
    setState(() => _lastParse = result);
  }

  /// 当前文本解析出来的结果。
  ///
  /// **真正的解析在 `parseRosterText` 里**（shared_platform，纯函数、有单测）。
  ///
  /// 为什么搬出去：原来这里的正则是 `[\t,，;；]+` —— **不含空格**，
  /// 于是最自然的手动输入 `2026101 张伟 13800000101` 会被当成一个字段，
  /// 报"学号或姓名为空"，用户看着自己明明填对了。这类解析逻辑必须能被单测覆盖。
  RosterParseResult get _parseResult => _lastParse ?? parseRosterText(_text.text);

  Future<void> _submit() async {
    final RosterParseResult parsed = _parseResult;
    final List<List<String>> rows = rosterToRows(parsed.entries);
    if (rows.isEmpty) {
      setState(() {
        _error = AppError.local(
          title: '没有可导入的内容',
          message: '每行至少要有「学号」和「姓名」两列。'
              '例如：2026101 张伟 13800000101 计算机学院',
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
    final ApiResult<ImportReport> result = await services.api.post<ImportReport>(
      ParticipantPaths.import(widget.activityId),
      body: <String, Object?>{'rows': rows},
      // 导入是幂等的（同一学号视为更新），重试安全；但仍不做自动重试：
      // 一次导入可能上百行，失败原因需要人看过再决定。
      retryable: false,
      decode: (Object? data) => ImportReport.fromJson(
        (data! as Map<Object?, Object?>).cast<String, dynamic>(),
      ),
    );

    if (!mounted) {
      return;
    }
    switch (result) {
      case ApiSuccess<ImportReport>(:final ImportReport value):
        setState(() => _submitting = false);
        Navigator.of(context).pop(value);
      case ApiFailure<ImportReport>():
        setState(() {
          _submitting = false;
          _error = AppError.fromApi(result);
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('批量导入名单')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(Spacing.pageGutter),
          children: <Widget>[
            Text('从报名表复制后粘贴', style: text.titleSmall),
            const SizedBox(height: Spacing.xxs),
            Text(
              '每行一人，列顺序为「学号、姓名、手机号、学院」。\n'
              '学号、姓名必须有；手机号和学院可以没有。\n'
              '**空格、制表符、逗号都算分隔**，也可以直接用「学号 姓名」两列。',
              style: text.bodySmall,
            ),
            const SizedBox(height: Spacing.xxs),
            Text(
              '学号与姓名长度不限（2–32 位学号都能用）。\n'
              '带表头（学号/姓名/学院/手机号）时会按表头顺序识别，'
              '不按位置瞎猜。',
              style: text.labelSmall,
            ),
            const SizedBox(height: Spacing.sm),

            /*
              直接选文件。

              原来的唯一入口是"从 Excel 复制一片单元格再粘贴"，
              手机上这一步很别扭：要在 Excel 和 App 之间来回切，
              表格长时还容易漏行。这里补一个选文件入口，
              解析出来的内容仍填进下面的文本框 —— 复用同一套预览与提交。

              解析在原生侧取 XML、Dart 侧做（见 `SpreadsheetImport`），
              不引入任何第三方依赖。
            */
            AppButton(
              label: _picking ? '正在读取文件…' : '从 Excel / CSV 文件导入',
              icon: Icons.upload_file,
              variant: AppButtonVariant.secondary,
              loading: _picking,
              loadingLabel: '正在读取文件…',
              onPressed: _submitting || _picking ? null : _pickFile,
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              '支持 .xlsx 与 .csv。会自动跳过表头行。\n'
              '旧版 .xls 请先在 Excel 里另存为 .xlsx 或 CSV。',
              style: text.labelSmall,
            ),
            const SizedBox(height: Spacing.md),

            TextField(
              controller: _text,
              enabled: !_submitting,
              maxLines: 12,
              minLines: 8,
              style: text.bodyMedium?.copyWith(fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: '2023001 张三 13800001234 计算机学院\n'
                    '2023002 李四\n'
                    '2023003\t王五\t\t外国语学院',
                hintStyle: text.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: AppColors.textTertiary,
                ),
              ),
            ),
            const SizedBox(height: Spacing.xs),
            _ParsePreview(result: _lastParse),

            if (_error != null) ...<Widget>[
              const SizedBox(height: Spacing.md),
              _ErrorBanner(error: _error!),
            ],

            const SizedBox(height: Spacing.lg),
            AppButton(
              label: (_lastParse?.entries.isEmpty ?? true)
                  ? '导入'
                  : '导入 ${_lastParse!.entries.length} 行',
              loading: _submitting,
              loadingLabel: '正在导入…',
              onPressed: _submitting ? null : _submit,
            ),
            const SizedBox(height: Spacing.md),
            Text(
              '导入会逐行校验。有问题的行不会被录入，但**不影响其余行**——'
              '导入结束后会列出需要修正的行。',
              textAlign: TextAlign.center,
              style: text.labelSmall,
            ),
          ],
        ),
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
        ],
      ),
    );
  }
}

/// 解析预览。
///
/// ## 为什么必须显示逐列结果
///
/// 真机报障是"手动输入读取行错误"。只显示"已识别 3 行"是不够的 ——
/// 行数对了、内容却错位（学号列放进了姓名）时，用户完全看不出来，
/// 直到导入后名单里全是错的人才发现。
///
/// 所以这里把**实际会提交的四列**摊开给用户看：
/// 认错了当场就能发现，改一下粘贴格式即可。
class _ParsePreview extends StatelessWidget {
  const _ParsePreview({required this.result});

  final RosterParseResult? result;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final RosterParseResult? r = result;

    if (r == null || r.entries.isEmpty) {
      return Text(
        r == null ? '粘贴或输入后这里会显示识别结果' : '尚未识别到有效行',
        style: text.bodySmall?.copyWith(color: AppColors.textTertiary),
      );
    }

    final List<RosterEntry> shown = r.entries.take(5).toList();
    final int missingName = r.entries.where((RosterEntry e) => e.name.isEmpty).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(Icons.check_circle_outline,
                size: Sizes.iconSm, color: AppColors.success),
            const SizedBox(width: Spacing.xxs),
            Expanded(
              child: Text(
                r.summary,
                style: text.bodySmall?.copyWith(color: AppColors.success),
              ),
            ),
          ],
        ),
        if (missingName > 0) ...<Widget>[
          const SizedBox(height: Spacing.xxs),
          Text(
            '⚠ 有 $missingName 行没识别出姓名，这些行会被跳过。',
            style: text.labelSmall?.copyWith(color: AppColors.warning),
          ),
        ],
        const SizedBox(height: Spacing.xs),

        // 逐列摊开：学号 / 姓名 / 学院 / 手机号
        Container(
          padding: const EdgeInsets.all(Spacing.xs),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '将导入的前 ${shown.length} 行（按此顺序提交）',
                style: text.labelSmall?.copyWith(color: AppColors.textTertiary),
              ),
              const SizedBox(height: Spacing.xxs),
              ...shown.map(
                (RosterEntry e) => Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '${e.userNo} ｜ ${e.name.isEmpty ? '（缺姓名）' : e.name}'
                    ' ｜ ${e.college.isEmpty ? '—' : e.college}'
                    ' ｜ ${e.phone.isEmpty ? '—' : e.phone}',
                    style: text.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                ),
              ),
              if (r.entries.length > shown.length) ...<Widget>[
                Text(
                  '… 还有 ${r.entries.length - shown.length} 行',
                  style: text.labelSmall?.copyWith(color: AppColors.textTertiary),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}