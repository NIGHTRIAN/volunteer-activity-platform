import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 离线队列的磁盘存储。
///
/// ## 为什么需要（真机测试发现的丢数据）
///
/// `OfflineQueue` 本身是纯 Dart、不碰磁盘，靠 `persist()` / `restore()`
/// 与宿主交换 JSON。但宿主**从来没调用过这两个方法** —— 队列只活在内存里。
///
/// 结果就是：用户离线签到，界面明确写着「**已保存到本机**」，
/// 可他随手划掉 App（或 Android 回收进程）之后，证据就没了。
/// 他以为已经交上去了，直到事后被判定缺席才发现。
///
/// **虚假的成功提示比直接报错更糟**：报错会让人补救，假成功不会。
///
/// ## 为什么放这里而不是 shared_core
///
/// `shared_core` 要保持零 Flutter 依赖（可在纯 Dart 测试里跑）。
/// 文件系统访问需要 `path_provider`，属于平台能力，因此落在 `shared_platform`。
///
/// ## 写入策略
///
/// 先写 `.tmp` 再 `rename`（同目录内 rename 是原子的）：
/// 避免写到一半被系统杀掉，留下半个 JSON 让下次启动解析失败。
/// 读失败/写失败一律**不抛异常** —— 队列是尽力而为的兜底，
/// 不能因为它坏了就让 App 起不来。
class QueueStore {
  QueueStore({this.fileName = 'offline-queue.json'});

  /// 文件名。测试可注入不同名字以隔离。
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

  /// 读取上次保存的队列 JSON。没有文件或读取失败时返回 `null`。
  Future<String?> load() async {
    try {
      final File file = await _resolve();
      if (!await file.exists()) {
        return null;
      }
      final String raw = await file.readAsString();
      return raw.isEmpty ? null : raw;
    } catch (_) {
      return null;
    }
  }

  /// 保存队列 JSON。失败时静默（内存里的队列仍然可用）。
  Future<void> save(String raw) async {
    try {
      final File file = await _resolve();
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(raw, flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // 落盘失败不阻断使用：本机仍然持有内存队列，
      // 只是它熬不过进程被杀。下次变更会再试。
    }
  }

  /// 删除已保存的队列（解绑 / 清空时用）。
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
