import 'package:flutter/foundation.dart';
import 'package:shared_core/shared_core.dart';

/// 启动时确定的管理端登录状态。
@immutable
class AdminStartupState {
  const AdminStartupState._({this.session, this.notice});

  /// 未登录：显示邀请码登录页。
  const AdminStartupState.signedOut({String? notice}) : this._(notice: notice);

  /// 已登录：显示活动管理主页。
  const AdminStartupState.signedIn(AdminSession session) : this._(session: session);

  final AdminSession? session;

  /// 需要向用户说明的一次性提示（例如"登录已过期"）。
  final String? notice;

  bool get isSignedIn => session != null;
}
