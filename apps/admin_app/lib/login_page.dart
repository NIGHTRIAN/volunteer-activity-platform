import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/shared_ui.dart';

/// 管理端登录页（邀请码 + 设备指纹）。
///
/// ## 契约要点（网页方案 §6.3）
///
/// `POST /auth/admin/login` `{ inviteCode, deviceId }` → `{ token, ownerId, ... }`
///
/// 令牌**绑定到设备指纹**：换设备需重新登录。
///
/// ## 文案取向
///
/// 「邀请码」这个词对发布者来说是陌生的。方案 §2 说明它的用途是
/// "把默认邀请码被谁拿到的影响面压到最小"，所以界面上要讲清楚
/// **这是什么、从哪来**，而不是只放一个输入框。
class AdminLoginPage extends StatefulWidget {
  const AdminLoginPage({
    required this.onSignedIn,
    this.notice,
    this.configProblems = const <String>[],
    super.key,
  });

  final ValueChanged<AdminSession> onSignedIn;
  final String? notice;
  final List<String> configProblems;

  @override
  State<AdminLoginPage> createState() => _AdminLoginPageState();
}

class _AdminLoginPageState extends State<AdminLoginPage> {
  final TextEditingController _code = TextEditingController();
  final FocusNode _focus = FocusNode();

  bool _loading = false;
  AppError? _error;

  @override
  void dispose() {
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String code = _code.text.trim();
    if (code.isEmpty) {
      setState(() {
        _error = AppError.local(
          title: '请输入邀请码',
          message: '邀请码由系统管理员发放。',
          canRetry: false,
        );
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final AppServices services = AppScope.of(context);
    final String deviceId = await services.device.deviceId();

    final ApiResult<AdminSession> result = await services.api.post<AdminSession>(
      AuthPaths.adminLogin,
      // 登录是匿名请求：此时还没有令牌。
      authorized: false,
      body: <String, Object?>{
        'inviteCode': code,
        'deviceId': deviceId,
      },
      // 登录失败（邀请码错、锁定）都是业务性结果，重试没有意义，
      // 而且连续重试会触发服务端的锁定策略（42901）。
      retryable: false,
      decode: (Object? data) => AdminSession.fromJson(
        (data! as Map<Object?, Object?>).cast<String, dynamic>(),
      ),
    );

    if (!mounted) {
      return;
    }

    switch (result) {
      case ApiSuccess<AdminSession>(:final AdminSession value):
        // 存进安全存储。**只有这一条写路径**（方案 §3）。
        await services.tokens.saveAdminSession(value);
        await services.tokens.saveDeviceId(deviceId);
        if (!mounted) {
          return;
        }
        setState(() => _loading = false);
        widget.onSignedIn(value);
      case ApiFailure<AdminSession>():
        setState(() {
          _loading = false;
          _error = AppError.fromApi(result);
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: Sizes.maxContentWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SizedBox(height: Spacing.xxl),
                  const Icon(
                    Icons.volunteer_activism_outlined,
                    size: 56,
                    color: AppColors.seed,
                  ),
                  const SizedBox(height: Spacing.md),
                  Text(
                    kAdminAppName,
                    textAlign: TextAlign.center,
                    style: text.headlineMedium,
                  ),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    kAdminAppTagline,
                    textAlign: TextAlign.center,
                    style: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: Spacing.xxl),

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

                  TextField(
                    controller: _code,
                    focusNode: _focus,
                    autofocus: true,
                    enabled: !_loading,
                    keyboardType: TextInputType.number,
                    // 只允许数字，并限制长度：邀请码是定长数字，
                    // 让用户没法输入明显无效的内容，比事后报错友好。
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(12),
                    ],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(
                      labelText: '邀请码',
                      hintText: '请输入管理员发给你的邀请码',
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    '邀请码由系统管理员发放，首次登录后本设备会被记住，'
                    '后续无需重复输入。更换设备需重新登录。',
                    style: text.bodySmall,
                  ),

                  if (_error != null) ...<Widget>[
                    const SizedBox(height: Spacing.md),
                    _ErrorBanner(error: _error!),
                  ],

                  const SizedBox(height: Spacing.lg),
                  AppButton(
                    label: '登录',
                    loading: _loading,
                    loadingLabel: '正在登录…',
                    onPressed: _loading ? null : _submit,
                  ),
                  const SizedBox(height: Spacing.lg),
                  Text(
                    kPrivacySummary,
                    textAlign: TextAlign.center,
                    style: text.labelSmall,
                  ),
                  const SizedBox(height: Spacing.sm),
                  /*
                    服务器地址入口放在登录页首屏。

                    用户**没有云服务器**，服务端跑在他自己电脑上；
                    装好 App 打开就是这一页。若这里没有改地址的入口，
                    表现形式会是"登录失败"，很容易被误判成邀请码错了，
                    白白排查很久 —— 这正是真机测试里踩过的坑。
                  */
                  // 切换服务器 / 演示模式后重建本页，否则地址与提示要等重启才更新。
              ServerEndpointEntry(onChanged: () => setState(() {})),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 错误提示条。
///
/// 单独做而不是用 SnackBar：登录失败时用户需要**边看提示边改输入**，
/// 而 SnackBar 几秒后消失，用户还没读完就没了。
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
        color: AppColors.warningContainer,
        borderRadius: BorderRadius.all(Radius.circular(Radii.md)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.build_circle_outlined,
                  size: Sizes.iconMd, color: AppColors.warning),
              const SizedBox(width: Spacing.xs),
              Text(
                '构建配置有问题（开发提示）',
                style: text.titleSmall?.copyWith(color: AppColors.onWarningContainer),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xxs),
          ...problems.map(
            (String p) => Text(
              '· $p',
              style: text.bodySmall?.copyWith(color: AppColors.onWarningContainer),
            ),
          ),
        ],
      ),
    );
  }
}
