import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 「本机演示模式」的状态存储。
///
/// ## 两件事要记住
///
/// 1. **是否处于演示模式** —— 一个标记文件；
/// 2. **演示数据本身** —— [OfflineDemoState] 的 JSON（活动、名单、签到、抽查）。
///
/// 为什么必须持久化：演示时别人会反复开关 App、划掉重进。
/// 如果每次启动都回到种子初始状态，刚建的活动、刚签的到全没了，
/// 演示根本讲不下去。
///
/// ## 为什么用文件而不是密钥库
///
/// 演示数据里没有真实凭证（都是示例姓名与脱敏手机号），
/// 用应用私有目录的普通文件即可；`flutter_secure_storage`
/// 每次读写都要过 Keystore，冷启动会明显变慢。
///
/// 写入仍是「先写 `.tmp` 再 rename」的原子写法，
/// 避免写到一半被系统杀掉留下半个 JSON。
class OfflineDemoStore {
  OfflineDemoStore({
    this.stateFileName = 'offline-demo-state.json',
    this.flagFileName = 'offline-demo.flag',
  });

  final String stateFileName;
  final String flagFileName;

  Directory? _dir;

  Future<Directory> _dirPath() async {
    final Directory? cached = _dir;
    if (cached != null) {
      return cached;
    }
    final Directory d = await getApplicationSupportDirectory();
    _dir = d;
    return d;
  }

  Future<File> _stateFile() async {
    final Directory d = await _dirPath();
    return File('${d.path}${Platform.pathSeparator}$stateFileName');
  }

  Future<File> _flagFile() async {
    final Directory d = await _dirPath();
    return File('${d.path}${Platform.pathSeparator}$flagFileName');
  }

  /// 是否处于演示模式。
  Future<bool> isDemoMode() async {
    try {
      return await (await _flagFile()).exists();
    } catch (_) {
      return false;
    }
  }

  /// 打开/关闭演示模式。
  Future<void> setDemoMode(bool enabled) async {
    try {
      final File f = await _flagFile();
      if (enabled) {
        await f.writeAsString('1', flush: true);
      } else if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {
      // 开关写不进去时本次运行仍然生效（内存里的 transport 已切换）
    }
  }

  /// 读取演示数据 JSON。
  Future<String?> load() async {
    try {
      final File f = await _stateFile();
      if (!await f.exists()) {
        return null;
      }
      final String raw = await f.readAsString();
      return raw.isEmpty ? null : raw;
    } catch (_) {
      return null;
    }
  }

  /// 保存演示数据 JSON（原子写入）。
  Future<void> save(String json) async {
    try {
      final File f = await _stateFile();
      final File tmp = File('${f.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(f.path);
    } catch (_) {
      // 落盘失败不阻断演示：内存里的状态仍然可用
    }
  }

  /// 清空演示数据（回到种子初始状态）。
  Future<void> clear() async {
    try {
      final File f = await _stateFile();
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {
      // 忽略
    }
  }
}
