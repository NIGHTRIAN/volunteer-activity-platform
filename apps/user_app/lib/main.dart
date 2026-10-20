import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_platform/shared_platform.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:user_app/bootstrap.dart';
import 'package:user_app/home_page.dart';
import 'package:user_app/startup.dart';

/// 用户端入口。
///
/// 启动顺序：
///   1. 绑定 Flutter 引擎；
///   2. 建服务（API 客户端、密钥库、定位、离线队列……）；
///   3. 自检配置（Base URL 是否合规）；
///   4. 异步恢复上次授权（放在组件树里做，理由见下）；
///   5. 灌入 [AppScope] 并启动。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ServiceRoot(boot: bootstrapUserApp()));
}

/// 承载启动结果并完成异步恢复。
///
/// ## 为什么恢复授权要放在组件树里，而不是 `main()` 里 `await`
///
/// 恢复授权要读系统密钥库（`flutter_secure_storage`），这是异步且**可能失败**的
/// （密钥库不可用、系统升级后密钥失效等）。如果在 `main()` 里 await，
/// 失败时屏幕上什么都没有——用户看到一个永远白屏的 App，
/// 既不知道发生了什么，也无法自救。
///
/// 放在组件树里，就至少能显示"正在恢复…"以及失败原因与重试按钮
/// （"不死路"原则，方案 §7）。
class ServiceRoot extends StatefulWidget {
  const ServiceRoot({required this.boot, super.key});

  final BootstrapResult boot;

  @override
  State<ServiceRoot> createState() => _ServiceRootState();
}

class _ServiceRootState extends State<ServiceRoot> {
  late Future<StartupState> _startup;

  @override
  void initState() {
    super.initState();
    _startup = _restoreAuth(widget.boot.services, widget.boot.queueStore, widget.boot.serverEndpointStore, widget.boot.offlineDemoStore);
  }

  void _retry() {
    setState(() {
      _startup = _restoreAuth(widget.boot.services, widget.boot.queueStore, widget.boot.serverEndpointStore, widget.boot.offlineDemoStore);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      services: widget.boot.services,
      child: MaterialApp(
        title: kUserAppName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(),
        home: FutureBuilder<StartupState>(
          future: _startup,
          builder: (BuildContext context, AsyncSnapshot<StartupState> snap) {
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
              return const Scaffold(
                body: LoadingView(message: '正在恢复登录状态…'),
              );
            }
            return PlatformIntroGate(
              child: AppShell(
              child: UserHomePage(
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

/// 恢复志愿者授权。
///
/// ## 两条刻意的处理
///
/// 1. **授权过期一律当作未登录**：不要显示"已登录但什么都点不动"的界面。
///    用户面对一个处处报错的主页，比面对绑定页更难理解。
/// 2. **设备指纹不符就清掉授权并说明原因**：换手机后必须重新绑定
///    （方案 §5.2 把授权绑到设备上）。如果不主动清理，
///    每次请求都会拿 40301，而用户完全不知道自己该做什么。
Future<StartupState> _restoreAuth(
  AppServices services,
  QueueStore queueStore,
  ServerEndpointStore serverEndpointStore,
  OfflineDemoStore offlineDemoStore,
) async {
  // ── 恢复运行时服务器地址（必须最先做）────────────────────────────
  //
  // 用户没有云服务器，服务端地址是他自己填的、会变的。
  // 必须在**任何网络请求之前**恢复，否则第一次请求会打到编译期默认地址
  // （真机上通常是 127.0.0.1，必然失败），用户会看到"连不上服务器"，
  // 而他刚刚在设置里填的地址明明是对的。
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

  final VolunteerGrant? grant = await services.tokens.readVolunteerGrant();
  if (grant == null) {
    return const StartupState.signedOut();
  }

  // 授权本身带过期时间，先在本地判一次（省一次网络往返）。
  if (!grant.expiresAt.isAfter(services.clock.now())) {
    await services.tokens.clearVolunteerGrant();
    return const StartupState.signedOut(notice: '本次活动授权已过期，请重新绑定。');
  }

  final String deviceId = await services.device.deviceId();
  if (deviceId != grant.deviceId) {
    await services.tokens.clearVolunteerGrant();
    return const StartupState.signedOut(
      notice: '检测到更换了设备，请重新用邀请码绑定。',
    );
  }

  // ── 恢复上次没传完的离线证据 ─────────────────────────────────────
  //
  // 必须在进主页之前恢复：主页一构建就会尝试自动补传，
  // 那时队列必须是"已经装好上次的东西"的状态，否则会以为队列是空的，
  // 而用户看到的是"记录页空空如也 + 服务端也没有"。
  //
  // `restore()` 解析失败只返回 false 并保持空队列，不会抛异常 ——
  // 一个坏的队列文件不该让 App 起不来。
  final String? rawQueue = await queueStore.load();
  if (rawQueue != null) {
    services.queue.restore(rawQueue);
  }

  return StartupState.signedIn(grant);
}
