import 'package:admin_app/activity_page.dart';
import 'package:admin_app/create_activity_page.dart';
import 'package:admin_app/login_page.dart';
import 'package:admin_app/startup.dart';
import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/shared_ui.dart';

/// 管理端主页。
///
/// **当前是 A1 阶段的可运行骨架**：把"登录 → 拉取名下活动 → 渲染"整条链路
/// 接起来，用来验证构建配置、服务接线与真实请求没有断点。
/// A2 阶段会在这里挂上活动管理、名单、看板、复核与导出。
class AdminHomePage extends StatefulWidget {
  const AdminHomePage({
    required this.startup,
    this.configProblems = const <String>[],
    super.key,
  });

  final AdminStartupState startup;
  final List<String> configProblems;

  @override
  State<AdminHomePage> createState() => _AdminHomePageState();
}

class _AdminHomePageState extends State<AdminHomePage> {
  /// 未登录时显示登录页；登录成功后切到活动列表。
  AdminSession? _session;

  @override
  void initState() {
    super.initState();
    _session = widget.startup.session;
  }

  @override
  Widget build(BuildContext context) {
    final AdminSession? session = _session;
    if (session == null) {
      return AdminLoginPage(
        notice: widget.startup.notice,
        configProblems: widget.configProblems,
        onSignedIn: (AdminSession s) => setState(() => _session = s),
      );
    }
    return _AdminActivityList(
      session: session,
      configProblems: widget.configProblems,
      onSignOut: () => setState(() => _session = null),
    );
  }
}

/// 名下活动列表。
class _AdminActivityList extends StatefulWidget {
  const _AdminActivityList({
    required this.session,
    required this.configProblems,
    required this.onSignOut,
  });

  final AdminSession session;
  final List<String> configProblems;
  final VoidCallback onSignOut;

  @override
  State<_AdminActivityList> createState() => _AdminActivityListState();
}

class _AdminActivityListState extends State<_AdminActivityList> {
  AppController<AdminDashboardData>? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) {
      return;
    }
    final AppServices services = AppScope.of(context);
    _controller = AppController<AdminDashboardData>(
      load: () => _fetch(services),
    )..load();
  }

  /// 拉取"当前进行中的活动 + 名下全部活动"。
  ///
  /// ⚠️ 一次拉两份而不是用两个控制器：管理端首页最关心的是
  /// "**现在**有没有活动在进行"，这需要把 ongoing 单独分出来。
  /// 分成两次请求会让两部分的"更新时间"不一致，现场看板会出现
  /// "上面说进行中、下面列表里没有"的矛盾。
  Future<AdminDashboardData> _fetch(AppServices services) async {
    final ApiResult<Paged<Activity>> result = await services.api.get<Paged<Activity>>(
      ActivityPaths.list,
      query: const ActivityQuery(
        onlyMine: true,
        pageSize: 50,
      ).toQueryParameters(),
      decode: (Object? data) => Paged<Activity>.fromJson(
        (data! as Map<Object?, Object?>).cast<String, dynamic>(),
        Activity.fromJson,
      ),
    );

    return switch (result) {
      ApiSuccess<Paged<Activity>>(:final Paged<Activity> value) =>
        AdminDashboardData.from(value),
      // 不吞异常：交给 AppController 转成界面状态。
      ApiFailure<Paged<Activity>>() => throw AppError.fromApi(result),
    };
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _confirmSignOut() async {
    final AppServices services = AppScope.of(context);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后需要重新输入邀请码。本机保存的活动数据不会被删除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    await services.tokens.clearAdminSession();
    if (mounted) {
      widget.onSignOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(kAdminAppName),
        actions: <Widget>[
          IconButton(
            onPressed: () => _controller?.refresh(),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
          /*
            服务器地址入口（登录后也要能改）。

            用户没有云服务器，服务端地址会变（局域网换网络就变 IP）。
            已登录的用户遇到"刷新失败"时必须能就地改地址，
            而不是只能退出登录再回登录页去改 —— 那会把排障路径拉得很长。
          */
          IconButton(
            onPressed: () async {
              final bool? saved = await showServerEndpointDialog(context);
              if (saved == true) {
                await _controller?.refresh();
              }
            },
            icon: const Icon(Icons.dns_outlined),
            tooltip: '服务器地址',
          ),
          IconButton(
            onPressed: _confirmSignOut,
            icon: const Icon(Icons.logout),
            tooltip: '退出登录',
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async => _controller?.refresh(),
          child: _buildBody(context),
        ),
      ),
      /*
        新建活动入口。

        ## 为什么用 FAB 而不是放在列表底部

        这是管理端**最高频的创建动作**，也是真机验证的前提
        （没有它就只能签种子活动）。FAB 在滚动时始终可点，
        而列表底部的按钮在长列表里要滚很久才够得着。

        ## 为什么图标是「添加」而不是「发布」

        日常动作是"建一个新活动"。发布 / 存草稿是创建时的选项
        （表单里的开关），不该占两个入口 —— 那会让用户先做一次
        无意义的选择。
      */
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreateActivity,
        icon: const Icon(Icons.add),
        label: const Text('新建活动'),
        tooltip: '新建活动',
      ),
    );
  }

  /// 打开新建活动页；创建成功后刷新工作台。
  Future<void> _openCreateActivity() async {
    final String? externalId = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (BuildContext context) => const CreateActivityPage(),
      ),
    );
    if (!mounted || externalId == null) {
      return;
    }
    // 刷新而不是本地插入：服务端才是状态权威（方案 §2）。
    // 本地插入会让"列表里有、服务端没存"这种不一致藏起来。
    await _controller?.refresh();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('活动已创建（编号 $externalId）'),
        // 给足时间让人看清编号，便于之后在列表里定位。
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final AppController<AdminDashboardData>? c = _controller;
    if (c == null) {
      return const LoadingView();
    }

    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, Widget? _) {
        final AppResult<AdminDashboardData> state = c.state;

        if (state.isLoading && !state.hasValue) {
          return const Padding(
            padding: EdgeInsets.all(Spacing.pageGutter),
            child: SkeletonList(rows: 4),
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

        final AdminDashboardData data = state.valueOrPrevious!;

        return ListView(
          padding: const EdgeInsets.all(Spacing.pageGutter),
          children: <Widget>[
            if (widget.configProblems.isNotEmpty) ...<Widget>[
              _ConfigWarning(problems: widget.configProblems),
              const SizedBox(height: Spacing.md),
            ],
            if (state.errorOrNull != null) ...<Widget>[
              StatusChip.detailed(
                visual: StatusVisual(
                  label: '刷新失败，显示的是上次数据',
                  tone: StatusTone.warning,
                  icon: Icons.cloud_off,
                  description: state.errorOrNull!.message,
                ),
              ),
              const SizedBox(height: Spacing.sm),
            ],

            // 进行中的活动单独置顶：这是发布者在活动现场最需要看的。
            if (data.ongoing.isNotEmpty) ...<Widget>[
              AppSection(
                title: '正在进行',
                subtitle: '现场需要你盯着的活动',
                child: Column(
                  children: data.ongoing
                      .map((Activity a) => _ActivityRow(
                            activity: a,
                            highlight: true,
                            onTap: () => _openActivity(a),
                          ))
                      .toList(),
                ),
              ),
              const SizedBox(height: Spacing.xl),
            ],

            AppSection(
              title: '我发布的活动',
              subtitle: '共 ${data.all.length} 个',
              child: data.all.isEmpty
                  ? const EmptyState(
                      title: '还没有发布活动',
                      message: '发布后可在此查看名单、看板与考勤汇总。',
                      icon: Icons.event_note_outlined,
                      compact: true,
                    )
                  : Column(
                      children: data.all
                          .map((Activity a) => _ActivityRow(
                                activity: a,
                                highlight: a.status == ActivityStatus.ongoing,
                                onTap: () => _openActivity(a),
                              ))
                          .toList(),
                    ),
            ),
          ],
        );
      },
    );
  }

  /// 进入活动详情（管理端工作台）。
  Future<void> _openActivity(Activity a) async {
    await Navigator.of(context).push<void>(
      appRoute(
        AdminActivityPage(activityId: a.id, initialTitle: a.title),
        name: Routes.adminActivity,
        arguments: <String, Object?>{RouteArgs.activityId: a.id},
      ),
    );
    // 返回后刷新：用户可能在里面改了状态。
    await _controller?.refreshSilently();
  }
}

/// 首页需要的数据。
class AdminDashboardData {
  const AdminDashboardData({required this.all, required this.ongoing});

  final List<Activity> all;
  final List<Activity> ongoing;

  /// 从列表响应派生。
  ///
  /// "进行中"是**派生**出来的，不是单独请求的：这样两处数据必然一致。
  factory AdminDashboardData.from(Paged<Activity> page) {
    final List<Activity> ongoing = page.items
        .where((Activity a) => a.status == ActivityStatus.ongoing)
        .toList();
    return AdminDashboardData(all: page.items, ongoing: ongoing);
  }
}

/// 活动行。
class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.activity,
    this.highlight = false,
    this.onTap,
  });

  final Activity activity;
  final bool highlight;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final StatusVisual status = StatusVisuals.ofActivity(activity.status);

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: AppCard(
        highlight: highlight,
        onTap: onTap,
        semanticLabel: '${activity.title}，${status.label}'
            '${onTap != null ? '，点击查看详情' : ''}',
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    activity.title,
                    style: text.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    '${TimeFormat.format(activity.startTime)} · '
                    '${activity.durationHours} 小时 · ${activity.location}',
                    style: text.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: Spacing.xs),
            StatusChip(visual: status, compact: true),
            if (onTap != null)
              const Icon(Icons.chevron_right, color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// 构建配置问题提示。
class _ConfigWarning extends StatelessWidget {
  const _ConfigWarning({required this.problems});

  final List<String> problems;

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
              const Icon(Icons.build_circle_outlined,
                  size: Sizes.iconMd, color: AppColors.danger),
              const SizedBox(width: Spacing.xs),
              Text(
                '构建配置有问题',
                style: text.titleSmall?.copyWith(color: AppColors.onDangerContainer),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xxs),
          ...problems.map(
            (String p) => Text(
              '· $p',
              style: text.bodySmall?.copyWith(color: AppColors.onDangerContainer),
            ),
          ),
        ],
      ),
    );
  }
}
