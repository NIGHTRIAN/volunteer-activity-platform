import 'package:flutter/foundation.dart';
import 'package:shared_core/shared_core.dart';

/// 启动时确定的登录状态。
@immutable
class StartupState {
  const StartupState._({this.grant, this.notice});

  /// 未登录（或授权已失效）：显示绑定页。
  const StartupState.signedOut({String? notice}) : this._(notice: notice);

  /// 已登录：显示主页。
  const StartupState.signedIn(VolunteerGrant grant) : this._(grant: grant);

  final VolunteerGrant? grant;

  /// 需要向用户说明的一次性提示（例如"换了设备"）。
  ///
  /// 这类提示必须在**进入绑定页时**就说清楚。否则用户只会看到
  /// "又让我绑定一次"，以为是 App 出错。
  final String? notice;

  bool get isSignedIn => grant != null;
}
