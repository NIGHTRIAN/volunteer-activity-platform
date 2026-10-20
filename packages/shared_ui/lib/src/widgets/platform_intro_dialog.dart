import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/src/app/app_scope.dart';
import 'package:shared_ui/src/status_visuals.dart';
import 'package:shared_ui/src/tokens.dart';
import 'package:shared_ui/src/widgets/app_button.dart';

/// 「关于本平台」公告弹窗 —— **讲清 App / 网页 / 服务器 三者的关系**。
///
/// ## 为什么需要这个弹窗
///
/// 这套平台由三部分组成，但用户（以及验收者）最容易产生的困惑是：
///
///   * "我在手机上建的活动，为什么网页上看不到？"
///   * "为什么没有服务器也能用？那数据是真的吗？"
///   * "签到到底谁说了算？"
///
/// 这三件事**不解释清楚，后面所有功能都会被误解**：
/// 有人会以为演示数据是真实记录，有人会以为网页能签到，
/// 还有人会以为 App 自己就能判定签到是否有效。
///
/// 所以第一次打开 App 就把它讲明白，并且**随时可以再看**。
///
/// ## 内容口径（必须与实现一致）
///
/// * 判定权**只在服务器**；没有服务器时用本机演示引擎顶上，
///   且演示数据不外传；
/// * 网页端是**只读**（浏览 / 导出），签到与复核只在 App 里做；
/// * 三者是**同一套平台的三个部分**，不是三个独立产品。
class PlatformIntroDialog extends StatefulWidget {
  const PlatformIntroDialog({
    required this.isDemoMode,
    required this.serverUrl,
    this.showDontRemind = true,
    super.key,
  });

  /// 当前是否处于本机演示模式。
  final bool isDemoMode;

  /// 当前服务器地址（演示模式下仍显示，便于说明"接上后会用它"）。
  final String serverUrl;

  /// 是否显示"不再提示"勾选（从菜单主动打开时不显示）。
  final bool showDontRemind;

  @override
  State<PlatformIntroDialog> createState() => _PlatformIntroDialogState();
}

class _PlatformIntroDialogState extends State<PlatformIntroDialog> {
  bool _dontRemind = false;

  /// 复制演示凭据。
  ///
  /// 测试人员最常见的卡点就是"演示模式该填什么"。与其让人对着屏幕抄
  /// （`demo-act-library` 这种编号根本抄不了），不如给一个复制按钮：
  /// 复制出来的是一段能被绑定页「粘贴邀请信息」直接解析的文本。
  Future<void> _copyDemoHint() async {
    // 构造可以是 const，`toText()` 不行 —— 所以拆成两行。
    const InviteShare share = InviteShare(
      activityId: OfflineDemoState.demoActivityId,
      userNo: OfflineDemoState.demoUserNo,
      inviteCode: OfflineDemoState.demoInviteCode,
      activityTitle: OfflineDemoState.demoActivityTitle,
      studentName: OfflineDemoState.demoStudentName,
    );
    final String text = share.toText();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('演示凭据已复制。到绑定页点「粘贴邀请信息」即可自动填入。'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return AlertDialog(
      title: const Text('怎么开始用'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            /*
              ## 为什么先讲"怎么试"而不是先讲架构

              真机测试反馈很直接：**引导做得不够**。原来的弹窗先讲三部分关系，
              测试人员读完还是不知道该点哪里 —— 尤其"绑定要填哪三样东西"
              和"演示模式下该填什么"这两步，几乎每个人都要问一次。

              所以顺序改成：先给可照做的步骤，再讲清关系（关系仍然重要，
              否则会误以为演示数据是真的）。

              三部分的关系压缩成一段说清，不再占三张卡片。
            */
            Text(
              widget.isDemoMode
                  ? '当前是「本机演示模式」：数据只在这台手机上，不会上传，'
                      '也不会与网页或另一台手机同步。'
                  : '已连接服务器：${widget.serverUrl}',
              style: text.bodySmall,
            ),
            const SizedBox(height: Spacing.md),

            // ① 志愿者怎么试
            const _Section(
              icon: Icons.person_outline,
              tone: StatusTone.info,
              title: '你是志愿者（去参加活动的人）',
              lines: <String>[
                '1. 找发布者要三样：活动编号、学号、邀请码',
                '2. 在绑定页点「粘贴邀请信息（自动填写）」——'
                    '发布者发来的整段文字会一键填好',
                '3. 进首页点「去签到」→「开始签到」',
                '4. 活动进行中留意「在岗」标签，到点要确认一次',
              ],
            ),
            const SizedBox(height: Spacing.sm),

            // ② 发布者怎么试
            const _Section(
              icon: Icons.groups_outlined,
              tone: StatusTone.success,
              title: '你是发布者（组织活动的人）',
              lines: <String>[
                '1. 登录（默认邀请码 1111）',
                '2. 「新建活动」→ 点「用当前位置」→ **点「用当前网络」** → 发布',
                '3. 「名单」→ 加人（或「从 Excel / CSV 文件导入」）',
                '4. 「生成邀请码」→ 点复制，把整段发给本人',
                '5. 「现场看板」看谁签到了，「待确认」的点进去选通过/驳回',
              ],
            ),
            const SizedBox(height: Spacing.xxs),
            Text(
              '第 2 步的「用当前网络」最容易漏：不配的话志愿者每次签到都会变成'
              '「待确认」，你得一条条手工通过。',
              style: text.labelSmall,
            ),
            const SizedBox(height: Spacing.md),

            Divider(height: Spacing.xl, color: Theme.of(context).dividerColor),

            // ③ 三部分关系（压缩版，仍然要说清楚）
            const _Section(
              icon: Icons.hub_outlined,
              tone: StatusTone.neutral,
              title: '这三部分是什么关系',
              lines: <String>[
                '手机 App：现场用。只有 App 能签到与复核（需要定位证据）',
                '网页端：电脑上浏览、筛选、导出（只读，不能签到）',
                '服务器：数据中枢，也是"这次签到算不算数"的最终判定方',
                'App 只负责采集证据并上报，不自己下结论。',
              ],
            ),

            if (widget.isDemoMode) ...<Widget>[
              const SizedBox(height: Spacing.sm),
              AppButton(
                label: '复制演示凭据',
                icon: Icons.copy_all,
                variant: AppButtonVariant.secondary,
                onPressed: _copyDemoHint,
              ),
              const SizedBox(height: Spacing.xxs),
              Text(
                '演示模式下：管理端邀请码 1111；'
                '用户端绑定用 demo-act-library / 2021001 / DEMO0001。'
                '复制后会得到一段可直接粘贴的文字。',
                style: text.labelSmall,
              ),
            ],
            const SizedBox(height: Spacing.md),

            // 一句话点题
            Text(
              '要点：判定权在服务器。演示模式真实执行评分规则，'
              '但结果仅用于演示，不能当作正式记录。',
              style: text.labelSmall,
            ),

            if (widget.showDontRemind) ...<Widget>[
              const SizedBox(height: Spacing.sm),
              InkWell(
                onTap: () => setState(() => _dontRemind = !_dontRemind),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: _dontRemind,
                        onChanged: (bool? v) =>
                            setState(() => _dontRemind = v ?? false),
                      ),
                    ),
                    const SizedBox(width: Spacing.xs),
                    Expanded(
                      child: Text('不再自动提示（可随时从「服务器地址」再打开）',
                          style: text.labelSmall),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        AppButton(
          label: '知道了',
          expand: false,
          onPressed: () => Navigator.of(context).pop(_dontRemind),
        ),
      ],
    );
  }
}

/// 三个组件各一段：图标 + 标题 + 若干条说明。
class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.tone,
    required this.title,
    required this.lines,
  });

  final IconData icon;
  final StatusTone tone;
  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final StatusVisual v = StatusVisual(label: '', tone: tone);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: v.background,
        borderRadius: Radii.cardRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: Sizes.iconSm, color: v.onBackground),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Text(
                  title,
                  style: text.titleSmall?.copyWith(color: v.onBackground),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xxs),
          for (final String line in lines)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '· $line',
                style: text.labelSmall?.copyWith(color: v.onBackground),
              ),
            ),
        ],
      ),
    );
  }
}

/// 首次启动时弹一次；已经确认过就不再打扰。
///
/// [force] 为真时无条件弹（用于"关于本平台"入口）。
Future<void> showPlatformIntro(
  BuildContext context, {
  bool force = false,
}) async {
  final AppServices services = AppScope.of(context);
  const String flagKey = 'platform-intro-seen';

  if (!force && await services.flags.isSet(flagKey)) {
    return;
  }
  if (!context.mounted) {
    return;
  }

  final bool? dontRemind = await showDialog<bool>(
    context: context,
    barrierDismissible: force,
    builder: (BuildContext ctx) => PlatformIntroDialog(
      isDemoMode: services.api.transport != null,
      serverUrl: services.api.effectiveBaseUrl,
      showDontRemind: !force,
    ),
  );

  // 只有勾了"不再提示"才落标记：否则每次打开都提醒一次，
  // 用户迟早会烦——但也不能默认就不提醒（那等于没解释过）。
  if (dontRemind == true) {
    await services.flags.set(flagKey);
  }
}

/// 首帧之后弹一次平台说明。
///
/// 为什么用「首帧之后」而不是在 `initState` 里直接 `showDialog`：
/// `showDialog` 需要一棵已经挂载好的 `Navigator`，在 `initState`
/// 期间树还没建完，直接调会抛 "Navigator not found"。
/// `addPostFrameCallback` 保证在布局完成后才弹。
class PlatformIntroGate extends StatefulWidget {
  const PlatformIntroGate({required this.child, super.key});

  final Widget child;

  @override
  State<PlatformIntroGate> createState() => _PlatformIntroGateState();
}

class _PlatformIntroGateState extends State<PlatformIntroGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      // 不 await：弹窗是"附加说明"，不该阻塞主界面渲染。
      showPlatformIntro(context);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
