import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_platform/shared_platform.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:admin_app/bootstrap.dart';
import 'package:admin_app/home_page.dart';
import 'package:admin_app/startup.dart';

/// 管理端入口。
///
/// 与用户端同构（见 `user_app/lib/main.dart` 的说明）：恢复登录状态放在
/// 组件树里，失败时能看到原因与重试，而不是白屏。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(AdminRoot(boot: bootstrapAdminApp()));
}

/// 承载启动结果并完成异步恢复。
class AdminRoot extends StatefulWidget {
  const AdminRoot({required this.boot, super.key});

  final BootstrapResult boot;

  @override
  State<AdminRoot> createState() => _AdminRootState();
}

class _AdminRootState extends State<AdminRoot> {
  late Future<AdminStartupState> _startup;

  @override
  void initState() {
    super.initState();
    _startup = _restore(widget.boot.services, widget.boot.serverEndpointStore, widget.boot.offlineDemoStore);
  }

  void _retry() {
    setState(() {
      _startup = _restore(widget.boot.services, widget.boot.serverEndpointStore, widget.boot.offlineDemoStore);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      services: widget.boot.services,
      child: MaterialApp(
        title: kAdminAppName,
        debugShowCheckedModeBanner: false,
        // 管理端信息密集，用紧凑密度（见 AppTheme.build 的说明）。
        theme: AppTheme.build(compact: true),
        home: FutureBuilder<AdminStartupState>(
          future: _startup,
          builder: (BuildContext context, AsyncSnapshot<AdminStartupState> snap) {
            if (snap.hasError) {
              return Scaffold(
                body: ErrorView(
                  title: '启动失败',
                  message: '${snap.error}',
                  onRetry: _retry,
                ),
              );
            }
            if (!snap.hasData) {
              return const Scaffold(body: LoadingView(message: '正在恢复登录…'));
            }
            return PlatformIntroGate(
              child: AppShell(
              child: AdminHomePage(
                startup: snap.data!,
                configProblems: widget.boot.configProblems,
              ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 恢复管理端会话。
///
/// ## 关键规则（方案 §5.2）
///
/// 管理端令牌在**名下活动全部进入终态 24 小时后失效**。
/// 这里只做本地判断；服务端仍会独立校验——客户端判断**不作为安全边界**，
/// 它只是为了少一次必然失败的请求，以及早点告诉用户该重新登录。
///
/// 另一条必须处理的：**设备指纹不符**。令牌绑定到设备上，
/// 换个设备就必须重新用邀请码登录，否则每个请求都会 40301。
Future<AdminStartupState> _restore(
  AppServices services,
  ServerEndpointStore serverEndpointStore,
  OfflineDemoStore offlineDemoStore,
) async {
  // ── 恢复运行时服务器地址（必须最先做）────────────────────────────
  //
  // 用户没有云服务器，地址是他自己填的、会变的。必须在任何网络请求前恢复，
  // 否则第一次请求会打到编译期默认地址，用户看到"登录失败"会误以为是邀请码错。
  // ── 演示模式（没有服务器时也能完整演示）──────────────────────────────
  //
  // 用户没有云服务器。为了让 App 能直接装到手机上给别人验收，
  // 提供了一个**本机演示引擎**：它在报文层替换掉网络，
  // 界面与判定逻辑完全复用（见 `ApiTransport` 的说明）。
  //
  // 必须在任何网络请求之前切换，否则首次请求会打到一个不存在的地址。
  if (await offlineDemoStore.isDemoMode()) {
    final OfflineDemoState demo =
        OfflineDemoState.fromJsonString(await offlineDemoStore.load());
    // 任何写操作后异步落盘：演示时别人会反复开关 App，
    // 每次启动都回到种子状态的话，刚建的活动/刚签的到全没了。
    demo.onChanged = () {
      unawaited(offlineDemoStore.save(demo.toJsonString()));
    };
    // 演示活动的时间窗按"首次进入演示模式的那一刻"算出来，隔天再打开就过期了，
    // 表现为「去签到」按钮不出现（按时间窗判定）。启动时平移一次即可。
    demo.rollDemoWindowIfStale();
    services.api.transport = OfflineDemoTransport(state: demo);
  }
  final String? savedEndpoint = await serverEndpointStore.load();
  if (savedEndpoint != null) {
    services.api.setBaseUrlOverride(savedEndpoint);
  }

  final AdminSession? session = await services.tokens.readAdminSession();
  if (session == null) {
    return const AdminStartupState.signedOut();
  }

  final String deviceId = await services.device.deviceId();
  if (deviceId != session.deviceId) {
    // 设备变了：清掉会话并说明原因，
    // 否则用户会看到"处处 40301"却完全不知道问题在哪。
    await services.tokens.clearAdminSession();
    return const AdminStartupState.signedOut(
      notice: '检测到更换了设备，请重新用邀请码登录。',
    );
  }

  return AdminStartupState.signedIn(session);
}
