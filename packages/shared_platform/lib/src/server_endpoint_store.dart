import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 运行时服务器地址的本地存储。
///
/// ## 为什么需要（用户没有服务器）
///
/// 服务端地址会变，而且只能在运行时知道：
///   * 服务端跑在用户自己电脑上 → 局域网 IP，换网络就变（DHCP）；
///   * 以后租了服务器 → 又换一次域名。
///
/// 只靠 `--dart-define` 在打包时写死的话，每换一次都得重新出包，
/// 普通用户根本做不到。所以地址要能在 App 内改，**并且记住**——
/// 否则每次冷启动都回到编译期默认，等于白改。
///
/// ## 为什么不用密钥库
///
/// 地址不是凭证（里面没有令牌、没有密码）。`flutter_secure_storage`
/// 每次读写都要过 Keystore，冷启动会明显变慢；而这里只需要一个短字符串。
/// 用应用私有目录里的普通文件就够 —— 其他应用读不到。
///
/// ## 写入策略
///
/// 与 `QueueStore` 一致：先写 `.tmp` 再 `rename`（同目录内原子），
/// 避免写到一半被杀留下半个文件。读/写失败一律不抛异常 ——
/// 地址读不出来就退回编译期默认，App 仍然能起来。
class ServerEndpointStore {
  ServerEndpointStore({this.fileName = 'server-endpoint.txt'});

  final String fileName;

  File? _cached;

  Future<File> _resolve() async {
    final File? cached = _cached;
    if (cached != null) {
      return cached;
    }
    final Directory dir = await getApplicationSupportDirectory();
    final File file = File('${dir.path}${Platform.pathSeparator}$fileName');
    _cached = file;
    return file;
  }

  /// 读取已保存的地址。没有文件或读取失败时返回 `null`（= 用编译期默认）。
  Future<String?> load() async {
    try {
      final File file = await _resolve();
      if (!await file.exists()) {
        return null;
      }
      final String raw = (await file.readAsString()).trim();
      return raw.isEmpty ? null : raw;
    } catch (_) {
      return null;
    }
  }

  /// 保存地址。传 `null` 或空串表示清除（回到编译期默认）。
  Future<void> save(String? rawUrl) async {
    try {
      final File file = await _resolve();
      final String value = (rawUrl ?? '').trim();
      if (value.isEmpty) {
        if (await file.exists()) {
          await file.delete();
        }
        return;
      }
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(value, flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // 落盘失败不阻断：本次运行仍然用内存里的值，只是重启后回到默认。
    }
  }

  Future<void> clear() async {
    try {
      final File file = await _resolve();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // 忽略
    }
  }
}
