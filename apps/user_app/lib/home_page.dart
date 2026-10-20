import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_platform/shared_platform.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:user_app/attendance_page.dart';
import 'package:user_app/bind_page.dart';
import 'package:user_app/checkin_availability.dart';
import 'package:user_app/checkin_page.dart';
import 'package:user_app/records_page.dart';
import 'package:user_app/startup.dart';

/// 用户端主页。
///
/// 两种形态：
///   * **未登录** → [BindPage]（学号 + 一次性邀请码）；
///   * **已登录** → 活动列表（本轮实现）→ 详情 / 签到 / 在岗确认（A3 后续）。
class UserHomePage extends StatefulWidget {
  const UserHomePage({
    required this.startup,
    this.configProblems = const <String>[],
    super.key,
  });

  final StartupState startup;
  final List<String> configProblems;

  @override
  State<UserHomePage> createState() => _UserHomePageState();
}

class _UserHomePageState extends State<UserHomePage> {
  /// 未登录时为 `null`；绑定成功后写入。
  VolunteerGrant? _grant;

  @override
  void initState() {
    super.initState();
    _grant = widget.startup.grant;
  }

  @override
  Widget build(BuildContext context) {
    final VolunteerGrant? grant = _grant;
    if (grant == null) {
      return BindPage(
        notice: widget.startup.notice,
        configProblems: widget.configProblems,
        onBound: (VolunteerGrant g) => setState(() => _grant = g),
      );
    }
    return _ActivityList(
      grant: grant,
      configProblems: widget.configProblems,
      onSignOut: () => setState(() => _grant = null),
    );
  }
}

/// 已绑定志愿者看到的主界面。
///
/// 三个标签：
///   * **活动** —— 活动信息与签到入口；
///   * **在岗** —— 待确认的在岗抽查（带角标，现场要能一眼看到）；
///   * **记录** —— 签到/抽查记录与待上传队列。
///
/// 为什么用底部标签而不是把所有内容堆在一个长页面上：
/// 在岗抽查有**时间压力**（几分钟内要响应），必须让用户一步到位；
/// 而"记录"是低频查看的，不该占据首屏。
class _ActivityList extends StatefulWidget {
  const _ActivityList({
    required this.grant,
    required this.configProblems,
    required this.onSignOut,
  });

  final VolunteerGrant grant;
  final List<String> configProblems;
  final VoidCallback onSignOut;

  @override
  State<_ActivityList> createState() => _ActivityListState();
}

class _ActivityListState extends State<_ActivityList> {
  AppController<Activity>? _activity;

  int _tab = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_activity != null) {
      return;
    }
    final AppServices services = AppScope.of(context);
    _activity = AppController<Activity>(
      load: () => _fetch(services),
    )..load();
    // 打开 App 就是"刚才没网、现在有网了"最常见的时刻，顺手补传。
    unawaited(_autoFlushQueue(services));
  }

  /// 自动补传本机暂存的签到 / 在岗证据。
  ///
  /// ## 为什么必须补这个
  ///
  /// 离线入队时界面承诺的是「**联网后自动上传**」。
  /// 真机测试发现：`queue.flush()` 此前**只在「我的记录 → 立即重试」里被调用**，
  /// 没有任何自动触发点 —— 用户不主动进记录页点按钮，证据就永远留在本机，
  /// 而界面还在告诉他"会自动上传"。**承诺与行为不一致，比直接说"请手动重试"更糟**：
  /// 用户会以为已经交上去了，直到事后被判缺席才发现。
  ///
  /// ## 触发时机
  ///
  /// 1. 进入主页（= 打开 App 且已有授权）—— 最典型的"刚才没网，现在有网了"；
  /// 2. 点右上角刷新之后 —— 用户主动确认网络可用，此时补传成功率最高。
  ///
  /// ## 失败要静默
  ///
  /// 补传是尽力而为：弹一堆错误只会打扰用户。
  /// 「记录」页的角标与「立即重试」仍然是兜底入口。
  Future<void> _autoFlushQueue(AppServices services) async {
    final String activityId = widget.grant.activityId;
    if (services.queue.outstandingCountFor(activityId) <= 0) {
      return;
    }
    // 不显式命名 ConnectivityState：它来自 shared_platform，本文件没导入。
    // 用内联判断避免为了一个布尔值多引一个包。
    if (!(await services.connectivity.state()).isOnline) {
      return;
    }
    if (!mounted) {
      return;
    }

    final int before = services.queue.outstandingCountFor(activityId);
    try {
      await services.queue.flush();
    } catch (_) {
      // 补传失败不影响主流程：队列里还在，用户可以在「记录」页重试。
      return;
    }
    if (!mounted) {
      return;
    }
    final int after = services.queue.outstandingCountFor(activityId);
    if (after < before) {
      // 真的传上去了才重建：让「记录」角标与签到状态立刻反映最新结果。
      setState(() {});
      await _activity?.refreshSilently();
    }
  }

  /// 用户点刷新：先拉活动状态，再尝试补传离线证据。
  Future<void> _refreshAll(AppServices services) async {
    await _activity?.refresh();
    if (!mounted) {
      return;
    }
    await _autoFlushQueue(services);
  }

  /// 拉取本人被授权的那个活动。
  ///
  /// ⚠️ 只用 `grant.activityId` 请求详情，**不列全部活动**：
  /// 志愿者端是"活动级授权"（方案 §5.2），他只能看到自己被授权的活动。
  /// 如果这里改成列全部再过滤，会把不该看到的活动拉进客户端内存 ——
  /// 服务端会拒绝，但那是"事后补救"，不如一开始就不请求。
  Future<Activity> _fetch(AppServices services) async {
    final ApiResult<Activity> result = await services.api.get<Activity>(
      ActivityPaths.detail(widget.grant.activityId),
      decode: (Object? data) => Activity.fromJson(
        (data! as Map<Object?, Object?>).cast<String, dynamic>(),
      ),
    );

    return switch (result) {
      ApiSuccess<Activity>(:final Activity value) => value,
      // 不吞异常：交给 AppController 转成界面状态。
      ApiFailure<Activity>() => throw AppError.fromApi(result),
    };
  }

  @override
  void dispose() {
    _activity?.dispose();
    super.dispose();
  }

  Future<void> _signOut() async {
    final AppServices services = AppScope.of(context);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('解除绑定'),
        content: const Text(
          '解除后需要重新输入邀请码才能再次进入活动。\n\n'
          '· 已上传的记录仍然在服务端；\n'
          '· **你参与过的活动记录会保留在本机**，解绑不会丢，'
          '可在绑定页「我参与过的活动」里回看；\n'
          '· 只有**尚未上传成功的签到证据**会被清除，无法恢复。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('解除'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    await services.tokens.clearVolunteerGrant();
    // 队列里的证据属于这个活动，解绑后无法再补传（没有令牌了）。
    services.queue.clearFor(widget.grant.activityId);
    if (mounted) {
      widget.onSignOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 队列长度驱动"记录"标签上的角标。
    // 读队列当前值是安全的：入队与补传都会让本页重建。
    final AppServices services = AppScope.of(context);
    final int outstanding = services.queue.outstandingCountFor(widget.grant.activityId);

    return Scaffold(
      appBar: AppBar(
        title: const Text(kUserAppName),
        actions: <Widget>[
          IconButton(
            // 刷新时顺手补传离线证据：用户点刷新通常意味着"我发现网络好了"。
            onPressed: () => _refreshAll(AppScope.of(context)),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
          /*
            服务器地址入口（登录后也要能改）。

            用户没有云服务器，地址会变（局域网换网络就变 IP）。
            志愿者如果遇到"刷新失败"，必须能就地改地址；
            让他先解绑再回绑定页改，很可能连邀请码都找不到了。
          */
          IconButton(
            onPressed: () async {
              // 先取好 services，再 await；否则 await 之后再用 context 会跨异步间隙。
              final AppServices services = AppScope.of(context);
              final bool? saved = await showServerEndpointDialog(context);
              if (saved == true) {
                await _refreshAll(services);
              }
            },
            icon: const Icon(Icons.dns_outlined),
            tooltip: '服务器地址',
          ),
          IconButton(
            onPressed: _signOut,
            icon: const Icon(Icons.link_off),
            tooltip: '解除绑定',
          ),
        ],
      ),
      body: SafeArea(
        /*
          ⚠️ 这里**不能**用 `IndexedStack`。

          真机报障：签到成功后再看「记录」页，仍然显示"尚无签到记录"，
          必须手动下拉刷新才出现 —— 因为 IndexedStack 会在首页构建时
          就把三个 tab **全部建好**，记录页拿着启动那一刻的数据一直不更新。
          （记录页的请求只跑一次，之后切 tab 只是切显示。）

          改成只构建当前 tab：切过去就重新加载，看到的永远是最新状态。
          代价是切回来会重新请求一次（记录页 2 个请求），这在移动端可接受，
          比"显示过期数据"轻得多。
        */
        child: switch (_tab) {
          0 => RefreshIndicator(
              onRefresh: () async => _activity?.refresh(),
              child: _buildActivityTab(context),
            ),
          1 => AttendancePage(
              activityId: widget.grant.activityId,
              activityTitle: _activity?.value?.title,
            ),
          _ => RecordsPage(
              activityId: widget.grant.activityId,
              activityTitle: _activity?.value?.title,
            ),
        },
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (int i) => setState(() => _tab = i),
        destinations: <Widget>[
          const NavigationDestination(
            icon: Icon(Icons.event_outlined),
            selectedIcon: Icon(Icons.event),
            label: '活动',
          ),
          const NavigationDestination(
            icon: Icon(Icons.touch_app_outlined),
            selectedIcon: Icon(Icons.touch_app),
            label: '在岗',
          ),
          NavigationDestination(
            icon: Badge(
              // 有待上传证据时给出可见提示：这是"证据有没有传上去"
              // 这条要求最轻量的一次提醒（详细情况在记录页里）。
              isLabelVisible: outstanding > 0,
              label: Text('$outstanding'),
              child: const Icon(Icons.receipt_long_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: outstanding > 0,
              label: Text('$outstanding'),
              child: const Icon(Icons.receipt_long),
            ),
            label: '记录',
          ),
        ],
      ),
    );
  }

  Widget _buildActivityTab(BuildContext context) {
    final AppController<Activity>? c = _activity;
    if (c == null) {
      return const LoadingView();
    }

    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, Widget? _) {
        final AppResult<Activity> state = c.state;

        if (state.isLoading && !state.hasValue) {
          return const Padding(
            padding: EdgeInsets.all(Spacing.pageGutter),
            child: SkeletonList(rows: 3, height: 120),
          );
        }
        if (state.errorOrNull != null && !state.hasValue) {
          final AppError e = state.errorOrNull!;

          /*
            活动"没了"（被删除 / 过了 7 天留存期）时要给一条出路。

            真机测试遇到的死路：志愿者打开 App，只看到
            「内容不存在 / 活动不存在或已过留存期」，
            页面上没有任何按钮 —— 唯一能自救的入口是右上角那个
            **不显眼的解绑图标**（链环断开）。多数人不会去点它，
            只会认为"App 坏了"。

            `canRetry` 对这类错误是 false（重试必然还是 404），
            所以原先连重试按钮都没有，纯死路。
            这里补一个明确的「换一个活动」按钮，走与解绑相同的流程。
          */
          final bool activityGone = !e.canRetry &&
              ((e.diagnostic ?? '').contains('40401') ||
                  e.message.contains('不存在') ||
                  e.message.contains('留存期'));

          return ListView(
            children: <Widget>[
              SizedBox(height: MediaQuery.sizeOf(context).height * 0.15),
              ErrorView(
                title: e.title,
                message: e.message,
                detail: e.diagnostic,
                onRetry: e.canRetry ? c.refresh : null,
              ),
              if (activityGone) ...<Widget>[
                const SizedBox(height: Spacing.md),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.pageGutter),
                  child: AppButton(
                    label: '换一个活动（重新绑定）',
                    icon: Icons.link,
                    // 与右上角"解除绑定"同一个流程：确认 → 清授权 → 回绑定页。
                    onPressed: _signOut,
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.pageGutter),
                  child: Text(
                    '需要用发布者新给你的邀请码重新绑定。'
                    '如果活动只是结束了，你的记录仍可在有效期内查看。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ],
          );
        }

        final Activity a = state.valueOrPrevious!;

        // 签到入口的显示条件由 `checkinAvailability` 统一判定
        // （按签到时间窗，不只看 status —— 详见该函数的说明）。
        final CheckinAvailability availability =
            checkinAvailability(a, DateTime.now());

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

            AppCard(
              // 可签到时高亮，让"现在该做这件事"一眼可见。
              highlight: availability.canCheckin,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Text(a.title, style: Theme.of(context).textTheme.titleLarge),
                      ),
                      const SizedBox(width: Spacing.xs),
                      StatusChip(
                        visual: StatusVisuals.ofActivity(a.status),
                        compact: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.sm),
                  InfoRow(
                    label: '时间',
                    value: '${TimeFormat.format(a.startTime)} ~ '
                        '${TimeFormat.format(a.endTime)}',
                    icon: Icons.schedule,
                  ),
                  InfoRow(label: '地点', value: a.location, icon: Icons.place_outlined),
                  InfoRow(
                    label: '时长',
                    value: '${a.durationHours} 小时',
                    icon: Icons.timer_outlined,
                  ),
                  if (a.summary.isNotEmpty) ...<Widget>[
                    const SizedBox(height: Spacing.xs),
                    Text(a.summary, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ],
              ),
            ),
            const SizedBox(height: Spacing.md),

            // 签到入口与说明。
            //
            // ## 为什么不按 `status == ongoing` 判断（真机测试抓到的 bug）
            //
            // 服务端目前**不会**自动把 `published` 转成 `ongoing`
            // （见 docs/open-issues-app.md O-3）。也就是说活动到了开始时刻，
            // 状态仍然是 `published` —— 而这里原先只看状态，于是：
            //
            //   * 界面一直显示"活动尚未开始"；
            //   * **签到按钮永远不出现**，志愿者根本没法签到。
            //
            // 这在模拟器上不会暴露（测试数据里状态是手工设好的），
            // 只有在真机上按真实时间走一遍才会发现。
            //
            // ## 现在的判断口径
            //
            // 按**签到时间窗**判断（与服务端同一口径：开始前 N 分钟 ~
            // 结束后 M 分钟），并用 `status` 只排除已终结的活动。
            //
            // 这不违反"服务端才是判定权威"（方案 §2）：
            // 这里仅决定**要不要显示入口**，真正的签到判定
            // 仍完全在服务端，窗口外提交会被拒。
            if (availability.canCheckin)
              AppButton(
                label: '去签到',
                icon: Icons.my_location,
                onPressed: () => _openCheckin(context, a),
              )
            else
              _Hint(
                icon: availability.icon,
                text: availability.message,
                tone: availability.tone,
              ),

            // 演示模式专属：把签到点挪到"当前位置"。
            //
            // ## 为什么需要
            //
            // 演示数据里的签到点是固定的（南湖校区图书馆）。验收者几乎不可能
            // 正好站在那里，于是只能看到"超出签到范围 → 驳回"。
            // 驳回本身正确，但**演示看不到成功路径** ——
            // 而"自动通过"恰恰是这套系统最值得看的一环。
            //
            // 所以给演示模式一个明确的辅助动作：一键把签到点设到当前位置，
            // 并顺带写入当前网段（否则围栏 40 + 采样 10 = 50，仍差 10 分）。
            //
            // 它只在演示模式出现，文案明确写"仅演示"——
            // 连真服务器时不存在任何"改判定条件"的入口。
            if (AppScope.of(context).api.transport != null) ...<Widget>[
              const SizedBox(height: Spacing.md),
              _DemoRecenterButton(
                activity: a,
                onDone: () => _activity?.refreshSilently(),
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _openCheckin(BuildContext context, Activity a) async {
    await Navigator.of(context).push<void>(
      appSlideRoute(
        CheckinPage(
          activity: a,
          // 签到后回到本页时刷新，让状态标签立刻更新。
          onDone: () => _activity?.refreshSilently(),
        ),
        name: Routes.userCheckin,
        arguments: <String, Object?>{RouteArgs.activityId: a.id},
      ),
    );
    // 从签到页返回后也刷一次：用户可能在里面重试过。
    await _activity?.refreshSilently();
  }
}

/// 中性提示块。
class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text, this.tone = StatusTone.info});

  final IconData icon;
  final String text;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: StatusChip.detailed(
        visual: StatusVisual(label: '说明', tone: tone, icon: icon, description: text),
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

/// 演示模式：把演示活动的签到点设为"当前位置"。
///
/// 直接改的是**内存里的演示状态**（`OfflineDemoTransport.state`），
/// 而不是另读一份 JSON 再写回 —— 否则改的是副本，
/// 正在跑的引擎看不到，现象是"点了没反应"。
///
/// 同时写入当前网段前缀：不写的话只有围栏 40 + 采样 10 = 50 分，
/// 仍然转人工，"自动通过"这条路径还是演示不出来。
class _DemoRecenterButton extends StatefulWidget {
  const _DemoRecenterButton({required this.activity, required this.onDone});

  final Activity activity;
  final VoidCallback onDone;

  @override
  State<_DemoRecenterButton> createState() => _DemoRecenterButtonState();
}

class _DemoRecenterButtonState extends State<_DemoRecenterButton> {
  bool _busy = false;
  String? _note;

  Future<void> _recenter() async {
    final AppServices services = AppScope.of(context);
    setState(() {
      _busy = true;
      _note = null;
    });

    final ApiTransport? transport = services.api.transport;
    if (transport is! OfflineDemoTransport) {
      setState(() {
        _busy = false;
        _note = '当前不是演示模式。';
      });
      return;
    }

    try {
      final LocationPermissionState perm = await services.location.ensurePermission();
      if (perm == LocationPermissionState.denied ||
          perm == LocationPermissionState.deniedForever) {
        if (!mounted) {
          return;
        }
        setState(() {
          _busy = false;
          _note = '需要定位权限才能把签到点设到当前位置。';
        });
        return;
      }

      final PositionFix fix = await services.location.getCurrentFix();
      final String? ip = await services.connectivity.localIp();

      final List<Map<String, Object?>> acts = transport.state.activities;
      final int idx = acts.indexWhere(
        (Map<String, Object?> x) => x['id'] == widget.activity.id,
      );
      if (idx < 0) {
        if (!mounted) {
          return;
        }
        setState(() {
          _busy = false;
          _note = '演示数据里找不到这个活动。';
        });
        return;
      }

      final List<String> prefixes = <String>[];
      if (ip != null) {
        final List<String> parts = ip.split('.');
        if (parts.length == 4) {
          prefixes.add('${parts[0]}.${parts[1]}.');
        }
      }

      acts[idx]['geoLat'] = fix.point.lat;
      acts[idx]['geoLng'] = fix.point.lng;
      acts[idx]['checkinRadius'] = 300.0;
      if (prefixes.isNotEmpty) {
        acts[idx]['campusIpPrefixes'] = prefixes;
      }
      transport.state.save();

      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _note = '已把签到点移到当前位置'
            '${prefixes.isEmpty ? '' : '，并记录网段 ${prefixes.first}'}。'
            '现在去签到应能自动通过。';
      });
      widget.onDone();
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _note = '定位失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AppButton(
          label: '演示：把签到点设为当前位置',
          icon: Icons.place_outlined,
          variant: AppButtonVariant.secondary,
          loading: _busy,
          loadingLabel: '正在定位…',
          onPressed: _busy ? null : _recenter,
        ),
        const SizedBox(height: Spacing.xxs),
        Text(
          _note ?? '仅演示模式可见：演示活动的签到点是固定的，'
              '人不在那里就签不上。点一下把它移到你所在的位置。',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }
}