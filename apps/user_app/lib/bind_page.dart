import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/shared_ui.dart';

/// 绑定页：学号 + 一次性邀请码（方案 §5.2）。
///
/// ## 契约（网页方案 §6.3）
///
/// `POST /auth/bind` `{ activityId, userNo, inviteCode, name?, phoneSuffix?, deviceId }`
/// → `{ token, activityId, userNo, name, expiresAt, ... }`
///
/// ## 权限影响（方案 §7）
///
/// 授权**绑定到设备指纹**：换设备需重新绑定。
/// 这样"一次性邀请码被转发到别的手机"就失去了意义 —— 服务端会把
/// 设备不符判为越权（40301）。这是本平台不再需要动态签到码的前提之一。
///
/// ## 关于「二次校验」的交互取舍
///
/// 方案 §4.3 要求姓名 / 手机号后四位做二次校验（防冒名签到）。
/// 但服务端的实现是：**两项都不提供时跳过校验**，提供了才比对，都不匹配才拒绝。
///
/// 因此界面把它们做成**可选**并明确标注"选填"：
///   * 填了 → 服务端会核对，不匹配会当场拒绝（阻止冒名）；
///   * 不填 → 也能绑定成功，风险由发布者现场核对承担。
///
/// 为什么不强制必填：这两个字段本来就来自发布者登记的名单，
/// 让学生为了绑定再去问一遍自己的手机号后四位，会把"扫码即用"的体验毁掉。
/// 而且真正需要拦的场景（有人拿别人的码来签）在**签到环节**还有
/// 位置围栏与设备绑定两层把关，不靠这一项。
class BindPage extends StatefulWidget {
  const BindPage({
    required this.onBound,
    this.notice,
    this.configProblems = const <String>[],
    this.initialUserNo,
    super.key,
  });

  final ValueChanged<VolunteerGrant> onBound;

  /// 需要向用户说明的一次性提示（例如"换了设备"）。
  final String? notice;

  /// 构建配置自检发现的问题（开发期可见）。
  final List<String> configProblems;

  /// 预填学号（从二维码/链接带入时用）。
  final String? initialUserNo;

  @override
  State<BindPage> createState() => _BindPageState();
}

class _BindPageState extends State<BindPage> {
  final TextEditingController _activityId = TextEditingController();
  final TextEditingController _userNo = TextEditingController();
  final TextEditingController _inviteCode = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _phoneSuffix = TextEditingController();

  bool _loading = false;
  AppError? _error;

  /// 出现二次校验不匹配时，把这两个字段高亮出来。
  bool _highlightCrossCheck = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialUserNo != null) {
      _userNo.text = widget.initialUserNo!;
    }
  }

  @override
  void dispose() {
    _activityId.dispose();
    _userNo.dispose();
    _inviteCode.dispose();
    _name.dispose();
    _phoneSuffix.dispose();
    super.dispose();
  }

  /// 展示本机保存的参与记录（不依赖当前是否已绑定）。
  Future<void> _showLocalHistory() async {
    final AppServices services = AppScope.of(context);
    final ParticipationHistory history = await services.participation.load();
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(
          history.isEmpty ? '还没有参与记录' : '我参与过的活动（${history.length}）',
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: history.isEmpty
              ? const Text(
                  '绑定并完成签到后，记录会保存在本机。\n'
                  '以后换活动、解除绑定都不会丢，随时可以回来看。',
                )
              : ListView(
                  shrinkWrap: true,
                  children: history.sortedByRecent
                      .map((ParticipationRecord r) => ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              r.hasCheckin
                                  ? Icons.how_to_reg_outlined
                                  : Icons.event_busy_outlined,
                              size: Sizes.iconMd,
                            ),
                            title: Text(
                              r.activityTitle.isEmpty
                                  ? '活动 ${r.activityId}'
                                  : r.activityTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              <String>[
                                r.checkinStatusLabel,
                                if (r.score != null) '评分 ${r.score}',
                                if (r.userNo.isNotEmpty) '学号 ${r.userNo}',
                              ].join(' · '),
                            ),
                          ))
                      .toList(),
                ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
  /// 从剪贴板读取一段邀请信息并自动填表。
  ///
  /// 解析失败时**不清空已有内容**，只提示"没识别到" ——
  /// 用户可能已经手填了一部分，清掉会让他重来。
  Future<void> _pasteInvite() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final InviteShare? share = InviteShare.tryParse(data?.text);

    if (share == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('没识别到邀请信息。请确认复制的内容里有「活动编号」「学号」「邀请码」三项。'),
          duration: Duration(seconds: 4),
        ),
      );
      return;
    }

    setState(() {
      _activityId.text = share.activityId;
      _userNo.text = share.userNo;
      _inviteCode.text = share.inviteCode;
      // 姓名只在确实是"本人姓名"时才填；它同时用于二次校验，
      // 填错会被服务端拒（提示"姓名或手机号后四位不匹配"），所以有才填。
      if (share.studentName != null && share.studentName!.trim().isNotEmpty) {
        _name.text = share.studentName!.trim();
      }
    });

    messenger.showSnackBar(
      SnackBar(
        content: Text('已自动填入：${share.activityId} · ${share.userNo}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _submit() async {
    final String activityId = _activityId.text.trim();
    final String userNo = _userNo.text.trim();
    final String inviteCode = _inviteCode.text.trim();

    // 本地最小校验：只拦明显漏填的，不做任何业务判定。
    // 业务判定（邀请码是否有效、是否在名单）一律由服务端决定（方案 §2）。
    final String? missing = activityId.isEmpty
        ? '活动编号'
        : userNo.isEmpty
            ? '学号'
            : inviteCode.isEmpty
                ? '邀请码'
                : null;
    if (missing != null) {
      setState(() {
        _error = AppError.local(
          title: '请填写$missing',
          message: '这些信息由活动发布者提供。',
          canRetry: false,
        );
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _highlightCrossCheck = false;
    });

    final AppServices services = AppScope.of(context);
    final String deviceId = await services.device.deviceId();

    final String name = _name.text.trim();
    final String suffix = _phoneSuffix.text.trim();

    final ApiResult<VolunteerGrant> result = await services.api.post<VolunteerGrant>(
      AuthPaths.bind,
      // 绑定是匿名请求：此时还没有令牌。
      authorized: false,
      body: <String, Object?>{
        'activityId': activityId,
        'userNo': userNo,
        'inviteCode': inviteCode,
        'deviceId': deviceId,
        // 选填：填了服务端才核对（见类文档的说明）。
        if (name.isNotEmpty) 'name': name,
        if (suffix.isNotEmpty) 'phoneSuffix': suffix,
      },
      // 邀请码错误 / 不在名单都是业务结果，重试没有意义；
      // 连续重试还会触发服务端限流（42901）。
      retryable: false,
      decode: (Object? data) => VolunteerGrant.fromJson(
        (data! as Map<Object?, Object?>).cast<String, dynamic>(),
      ),
    );

    if (!mounted) {
      return;
    }

    switch (result) {
      case ApiSuccess<VolunteerGrant>(:final VolunteerGrant value):
        await services.tokens.saveVolunteerGrant(value);
        await services.tokens.saveDeviceId(deviceId);
        if (!mounted) {
          return;
        }
        setState(() => _loading = false);
        widget.onBound(value);

      case ApiFailure<VolunteerGrant>():
        setState(() {
          _loading = false;
          _error = AppError.fromApi(result);
          // 二次校验不匹配：把对应字段高亮，让用户知道该改哪里。
          //
          // ⚠️ 判定依据是**字段级错误**而不是错误码。
          //
          // 契约只授权了 8 个码值，`40301` 同时代表"越权 / 不在名单 /
          // 二次校验失败 / 设备不符"——按码值判断会把"不在名单"
          // 也误认为"需要核对身份"，于是让用户去填两个根本无关的字段。
          //
          // 服务端在二次校验失败时会下发 `field: 'name'`，用它更准确。
          _highlightCrossCheck = result.fieldErrors
              .any((FieldError e) => e.field == 'name' || e.field == 'phoneSuffix');
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('绑定活动')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Spacing.pageGutter),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: Sizes.maxContentWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (widget.configProblems.isNotEmpty) ...<Widget>[
                    _ConfigWarning(problems: widget.configProblems),
                    const SizedBox(height: Spacing.md),
                  ],

                  if (widget.notice != null) ...<Widget>[
                    StatusChip.detailed(
                      visual: StatusVisual(
                        label: '提示',
                        tone: StatusTone.warning,
                        icon: Icons.info_outline,
                        description: widget.notice,
                      ),
                    ),
                    const SizedBox(height: Spacing.md),
                  ],

                  Text(
                    '发布者会给你活动编号、学号与一次性邀请码。',
                    style: text.bodyMedium,
                  ),
                  const SizedBox(height: Spacing.sm),

                  /*
                    一键粘贴。

                    真机反馈：志愿者要对着聊天记录往三个框里分别填，
                    极容易填串（活动编号填进学号框 → 报"活动不存在"）。
                    发布者点复制得到的是**一整段**带标签的文本，
                    这里读剪贴板解析后自动填好三个字段，用户只看一眼对不对。

                    解析规则在 `InviteShare`（两端共用，有 13 项测试）。
                    解析不出来就老实提示"没识别到"，而不是猜 —— 猜错更麻烦。
                  */
                  AppButton(
                    label: '粘贴邀请信息（自动填写）',
                    icon: Icons.content_paste_go,
                    variant: AppButtonVariant.secondary,
                    onPressed: _loading ? null : _pasteInvite,
                  ),
                  const SizedBox(height: Spacing.lg),

                  _Field(
                    controller: _activityId,
                    label: '活动编号',
                    hint: '例如 act-xxxxxxxx',
                    icon: Icons.event_outlined,
                    enabled: !_loading,
                  ),
                  const SizedBox(height: Spacing.sm),
                  _Field(
                    controller: _userNo,
                    label: '学号 / 工号',
                    hint: '请输入本人学号',
                    icon: Icons.badge_outlined,
                    enabled: !_loading,
                    // 学号是字母数字，不做纯数字限制（工号可能含字母）。
                    formatters: <TextInputFormatter>[
                      LengthLimitingTextInputFormatter(20),
                    ],
                  ),
                  const SizedBox(height: Spacing.sm),
                  _Field(
                    controller: _inviteCode,
                    label: '一次性邀请码',
                    hint: '发布者单独发给你的那串字符',
                    icon: Icons.vpn_key_outlined,
                    enabled: !_loading,
                    formatters: <TextInputFormatter>[
                      LengthLimitingTextInputFormatter(16),
                    ],
                  ),

                  // 二次校验（选填）。见类文档里关于"为什么不强制必填"的说明。
                  const SizedBox(height: Spacing.md),
                  Text(
                    '选填：核对身份',
                    style: text.titleSmall,
                  ),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    '填写后发布者可核对是否本人；不填也能绑定。'
                    '若与名单登记的不一致，会被拒绝并提示。',
                    style: text.bodySmall,
                  ),
                  if (_highlightCrossCheck) ...<Widget>[
                    const SizedBox(height: Spacing.xs),
                    Container(
                      padding: const EdgeInsets.all(Spacing.sm),
                      decoration: const BoxDecoration(
                        color: AppColors.warningContainer,
                        borderRadius: BorderRadius.all(Radius.circular(Radii.md)),
                      ),
                      child: Text(
                        '与名单登记的不一致。请改成报名时的姓名与手机号后四位，'
                        '或留空由发布者现场为你确认——填错不影响你参加活动。',
                        style: text.bodySmall
                            ?.copyWith(color: AppColors.onWarningContainer),
                      ),
                    ),
                  ],
                  const SizedBox(height: Spacing.sm),
                  _Field(
                    controller: _name,
                    label: '姓名（选填）',
                    hint: '与报名时一致',
                    icon: Icons.person_outline,
                    enabled: !_loading,
                  ),
                  const SizedBox(height: Spacing.sm),
                  _Field(
                    controller: _phoneSuffix,
                    label: '手机号后四位（选填）',
                    hint: '4 位数字',
                    icon: Icons.phone_android_outlined,
                    enabled: !_loading,
                    keyboardType: TextInputType.number,
                    formatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(4),
                    ],
                  ),

                  if (_error != null) ...<Widget>[
                    const SizedBox(height: Spacing.md),
                    _ErrorBanner(error: _error!),
                  ],

                  const SizedBox(height: Spacing.lg),
                  AppButton(
                    label: '绑定并进入',
                    loading: _loading,
                    loadingLabel: '正在绑定…',
                    onPressed: _loading ? null : _submit,
                  ),
                  const SizedBox(height: Spacing.md),
                  Text(
                    '绑定后本设备会被记住，活动期间无需重复输入。'
                    '换设备需重新绑定。',
                    textAlign: TextAlign.center,
                    style: text.bodySmall,
                  ),
                  const SizedBox(height: Spacing.sm),
                  /*
                    ⚠️ 这里**不能加 `const`**。

                    曾写成 `const _DemoHint()`，结果是：切到演示模式后提示不出现、
                    切回服务器模式后提示赖着不走，**必须重启 App 才正确**。

                    根因不在提示本身，而在 Flutter 的更新机制：
                    `const` 实例每次 rebuild 都是同一个对象，
                    `Element.updateChild` 遇到 `child.widget == newWidget`
                    （Widget 的 `==` 默认是同一性）会**直接跳过重建**，
                    于是 `_DemoHint.build()` 根本没被执行，
                    它里面的 FutureBuilder 自然不会重新读状态。

                    迷惑性在于：`setState` 确实调用了、父组件确实重建了，
                    只有这一个子树被静默跳过。
                  */
                  _DemoHint(),
                  const SizedBox(height: Spacing.xs),
                  /*
                    服务器地址入口放在绑定页，而不是藏进设置里。

                    理由：用户**没有云服务器**，服务端跑在他自己电脑上。
                    第一次装好 App、打开就是这一页 —— 如果这里没有改地址的入口，
                    他只能面对一个永远"连不上"的界面，却不知道该改什么。

                    放在首屏也是诚实：地址是这套系统里**必须由用户提供**的一项，
                    不该假装它已经配好了。
                  */
                  // 切换服务器 / 演示模式后必须重建本页：
                  // 不重建的话「演示数据」提示与地址展示都要等重启才更新，
                  // 用户会以为按钮没生效。
                  ServerEndpointEntry(onChanged: () => setState(() {})),

                  /*
                    没绑定任何活动时，也要能回看以前参加过的活动。

                    真机报障：参加完一个活动、要去下一个活动时，必须先解除绑定；
                    而解除绑定后连"我上次参加了什么、签上了没有"都看不到了。
                    记录已经存在本机（见 ParticipationStore），这里给一个入口。
                  */
                  const SizedBox(height: Spacing.xs),
                  TextButton.icon(
                    onPressed: _showLocalHistory,
                    icon: const Icon(Icons.history, size: Sizes.iconSm),
                    label: const Text('我参与过的活动（本机记录）'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 统一风格的输入框。
class _Field extends StatelessWidget {  const _Field({
    required this.controller,
    required this.label,
    required this.icon,
    this.hint,
    this.enabled = true,
    this.keyboardType,
    this.formatters,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final IconData icon;
  final bool enabled;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? formatters;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: keyboardType,
      inputFormatters: formatters,
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
      ),
    );
  }
}

/// 构建配置问题提示（开发期可见）。
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

/// 错误提示条。
///
/// 与登录页同款：不用 SnackBar，因为用户需要**边看提示边改输入**，
/// 而 SnackBar 几秒后消失，人还没读完就没了。
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

/// 演示模式下的绑定提示。
///
/// ## 为什么需要
///
/// 演示模式下**两端 App 的数据互相独立**（Android 沙箱隔离）：
/// 管理端生成的活动与邀请码，用户端看不到。
/// 所以种子数据里预置了一份固定的活动与邀请码，直接显示在绑定页 ——
/// 验收者照着填就能进，不必先理解这套数据隔离。
///
/// ## 为什么用 FutureBuilder 而不是缓存
///
/// 一开始把读到的提示缓存在 `didChangeDependencies` 里，结果真机上
/// 出现"切到演示模式后提示仍然不出现"——因为 `didChangeDependencies`
/// 只在依赖变化时触发，而切换模式并不会让 `AppScope` 变化。
/// 改成每次 build 都读一遍（文件很小，代价可忽略），行为即可预期。
class _DemoHint extends StatelessWidget {
  const _DemoHint();

  @override
  Widget build(BuildContext context) {
    final AppServices services = AppScope.of(context);
    if (services.api.transport == null) {
      return const SizedBox.shrink(); // 连的是真服务器，不显示
    }
    return FutureBuilder<String?>(
      future: services.offlineDemo.load(),
      builder: (BuildContext context, AsyncSnapshot<String?> snap) {
        if (!snap.hasData && snap.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }
        final OfflineDemoState s = OfflineDemoState.fromJsonString(snap.data);
        final Map<String, Object?>? act = s.activities.firstOrNull;
        if (act == null) {
          return const SizedBox.shrink();
        }
        final Map<String, Object?>? invite = s.invites
            .where((Map<String, Object?> i) => i['activityId'] == act['id'])
            .firstOrNull;
        final StatusVisual v = StatusVisual(label: '', tone: StatusTone.info);
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Spacing.sm),
          decoration: BoxDecoration(
            color: v.background,
            borderRadius: Radii.cardRadius,
          ),
          child: Text(
            '演示数据：点上面的「粘贴邀请信息」会自动填好。\n'
            '活动编号 ${act['id']}　'
            '学号 ${invite?['userNo'] ?? OfflineDemoState.demoUserNo}\n'
            '邀请码 ${invite?['code'] ?? OfflineDemoState.demoInviteCode}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: v.onBackground),
          ),
        );
      },
    );
  }
}