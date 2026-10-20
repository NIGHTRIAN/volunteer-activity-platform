import 'dart:convert';

import 'package:flutter/services.dart';

/// 名单导入：选文件 + 解析成「一行一行一列的字符串」。
///
/// ## 为什么要有这个
///
/// 发布者手上的名单来自报名表（Excel）。原来的导入方式只有
/// "从 Excel 里复制一片单元格，粘贴到文本框"，痛点很实在：
///
///   * 手机上**没法同时在 Excel 和 App 之间复制**（切来切去容易丢剪贴板）；
///   * 表格有 300 行时，复制粘贴很容易漏掉中间几行；
///   * 带标题行、带空白列时，粘贴进来位置就是错。
///
/// 所以补一个"直接选文件"的交互。
///
/// ## 分工
///
/// * **原生侧**（`MainActivity.kt`）只做两件不含业务逻辑的事：
///   打开系统文件选择器；.xlsx 是 zip，把里面的 XML 取出来。
/// * **Dart 侧**（本文件）做真正的表格解析 —— 因为这里能写成纯函数、
///   能用真实 XML 做单元测试。
///
/// ## 不支持 .xls
///
/// 老的 `.xls` 是 OLE2 二进制格式，解析量远大于 xlsx。原生侧会直接
/// 提示"请另存为 .xlsx 或 CSV"，而不是给一个含糊的失败。
class SpreadsheetImport {
  const SpreadsheetImport._();

  static const MethodChannel _channel = MethodChannel('volunteer/spreadsheet');

  /// 打开系统文件选择器并读取内容。
  ///
  /// 返回 `null` 表示**用户取消了**（不是错误，调用方不该弹错误提示）。
  /// 失败时抛 [SpreadsheetImportException]，其 `message` 可直接展示给用户。
  static Future<SpreadsheetFile?> pick() async {
    Map<String, Object?>? raw;
    try {
      raw = await _channel.invokeMapMethod<String, Object?>('pickSpreadsheet');
    } on MissingPluginException {
      throw const SpreadsheetImportException(
        '当前版本不支持选择文件（该功能只在管理端可用）。'
        '你可以先把表格复制粘贴到下面的输入框。',
      );
    } on PlatformException catch (e) {
      throw SpreadsheetImportException(e.message ?? '读取文件失败');
    }
    if (raw == null) {
      return null;
    }
    return SpreadsheetFile(
      name: (raw['name'] as String?) ?? '未命名文件',
      kind: (raw['kind'] as String?) ?? 'text',
      text: raw['text'] as String?,
      sharedStringsXml: raw['sharedStrings'] as String?,
      sheetXml: raw['sheet'] as String?,
    );
  }

  /// 把文件内容解析成表格行。
  ///
  /// 会自动**丢掉标题行**（首行含"学号/姓名/手机号"这类表头时）。
  static List<List<String>> parseRows(
    SpreadsheetFile file, {
    bool dropHeader = true,
  }) {
    final List<List<String>> rows = switch (file.kind) {
      'xlsx' => parseXlsxSheet(
          sharedStringsXml: file.sharedStringsXml,
          sheetXml: file.sheetXml ?? '',
        ),
      _ => parseDelimitedText(file.text ?? ''),
    };
    return dropHeader ? dropHeaderRow(rows) : rows;
  }

  /// 解析 .xlsx 的一个工作表。
  ///
  /// ## 只做"够用"的解析
  ///
  /// xlsx 的单元格有多种类型，这里覆盖名单场景会遇到的：
  ///   * `t="s"` 共享字符串（最常见，文字都在 sharedStrings.xml 里）；
  ///   * `t="inlineStr"` 内联字符串；
  ///   * `t="str"` 公式结果字符串；
  ///   * 其余按数字/布尔直接取 `<v>` 文本。
  ///
  /// 日期不做特殊处理（名单里不需要日期）。
  ///
  /// **空单元格必须保留列位置**：靠 `r="C3"` 里的列字母定位。
  /// 如果简单地"按出现顺序塞"，中间有空格时姓名就会错位到手机号列 ——
  /// 这是表格解析最经典的 bug。
  static List<List<String>> parseXlsxSheet({
    String? sharedStringsXml,
    required String sheetXml,
  }) {
    final List<String> shared = _parseSharedStrings(sharedStringsXml);

    final List<List<String>> rows = <List<String>>[];
    final RegExp rowRe = RegExp(r'<row[^>]*>(.*?)</row>', dotAll: true);

    for (final RegExpMatch rm in rowRe.allMatches(sheetXml)) {
      final String rowXml = rm.group(1) ?? '';
      final Map<int, String> byColumn = <int, String>{};

      // 同时匹配"有内容"与"自闭合"两种单元格写法。
      final RegExp cellRe = RegExp(
        r'<c\s+([^>]*?)(?:/>|>(.*?)</c>)',
        dotAll: true,
      );
      int fallbackColumn = 0;
      for (final RegExpMatch cm in cellRe.allMatches(rowXml)) {
        final String attrs = cm.group(1) ?? '';
        final String body = cm.group(2) ?? '';

        final String? ref = RegExp(r'r="([A-Z]+)\d+"').firstMatch(attrs)?.group(1);
        final int column = ref != null ? _columnIndex(ref) : fallbackColumn;
        fallbackColumn = column + 1;

        final String type = RegExp(r't="([^"]+)"').firstMatch(attrs)?.group(1) ?? 'n';
        String value = '';

        if (type == 'inlineStr') {
          value = _joinTextNodes(body);
        } else {
          final String? v = RegExp(r'<v>(.*?)</v>', dotAll: true).firstMatch(body)?.group(1);
          if (v != null) {
            if (type == 's') {
              final int? idx = int.tryParse(v.trim());
              if (idx != null && idx >= 0 && idx < shared.length) {
                value = shared[idx];
              }
            } else {
              value = _unescapeXml(v);
            }
          }
        }

        if (value.trim().isNotEmpty) {
          byColumn[column] = value.trim();
        }
      }

      if (byColumn.isEmpty) {
        continue;
      }
      final int maxColumn = byColumn.keys.reduce((int a, int b) => a > b ? a : b);
      rows.add(<String>[
        for (int i = 0; i <= maxColumn; i += 1) byColumn[i] ?? '',
      ]);
    }

    return rows;
  }

  /// 解析 CSV / TSV / 粘贴文本。
  ///
  /// **宽容解析**是刻意的：让发布者为"分隔符不对"返工不合理，
  /// 真正的校验（学号格式、重复学号）由服务端做。
  static List<List<String>> parseDelimitedText(String text) {
    final List<List<String>> rows = <List<String>>[];
    for (final String line in text.split('\n')) {
      final String t = line.trim();
      if (t.isEmpty) {
        continue;
      }
      /*
        ⚠️ **空单元格必须保留**。

        CSV 里 `2026201,张三,,计算机学院` 的那个空串是"手机号这格没填"，
        是**有意义的空列**。以前这里把空串过滤掉了，结果是：
        学院顶到手机号列 → 名单里所有人的手机号都是学院名。

        这类错位在预览里就能看出来（所以预览很重要），但根子要在解析这里修。
      */
      final List<String> cells =
          t.split(RegExp(r'[\t,，;；|]')).map((String s) => s.trim()).toList();
      if (cells.any((String c) => c.isNotEmpty)) {
        rows.add(cells);
      }
    }
    return rows;
  }

  /// 首行像表头就丢掉。
  ///
  /// 报名表导出几乎都有标题行（"学号 / 姓名 / 手机号"）。不丢的话
  /// 第一行会被当成一个叫"姓名"的人导进去，之后每次看名单都觉得别扭。
  static List<List<String>> dropHeaderRow(List<List<String>> rows) {
    if (rows.isEmpty) {
      return rows;
    }
    const List<String> markers = <String>[
      '学号', '工号', '姓名', '名字', '手机', '电话', '联系方式', '部门', '序号',
      'userNo', 'name', 'phone', 'class',
    ];
    final String firstLine = rows.first.join(' ');
    final bool looksLikeHeader =
        markers.any((String m) => firstLine.toLowerCase().contains(m.toLowerCase()));
    return looksLikeHeader ? rows.sublist(1) : rows;
  }

  // ── 内部工具 ──────────────────────────────────────────────────────────

  static List<String> _parseSharedStrings(String? xml) {
    if (xml == null || xml.isEmpty) {
      return const <String>[];
    }
    final List<String> out = <String>[];
    final RegExp siRe = RegExp(r'<si>(.*?)</si>', dotAll: true);
    for (final RegExpMatch m in siRe.allMatches(xml)) {
      out.add(_joinTextNodes(m.group(1) ?? ''));
    }
    return out;
  }

  /// 取出片段里所有 `<t>` 文本并拼接（富文本会被拆成多段 `<r><t>`）。
  static String _joinTextNodes(String xml) {
    final StringBuffer b = StringBuffer();
    final RegExp tRe = RegExp(r'<t(?:\s[^>]*)?>(.*?)</t>', dotAll: true);
    for (final RegExpMatch m in tRe.allMatches(xml)) {
      b.write(_unescapeXml(m.group(1) ?? ''));
    }
    return b.toString();
  }

  static String _unescapeXml(String s) {
    return s
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#10;', '\n')
        .replaceAll('&#13;', '')
        .replaceAllMapped(
          RegExp(r'&#x([0-9A-Fa-f]+);'),
          (Match m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
        )
        .replaceAllMapped(
          RegExp(r'&#(\d+);'),
          (Match m) => String.fromCharCode(int.parse(m.group(1)!)),
        )
        // `&amp;` 必须最后替换，否则 `&amp;lt;` 会被二次解码成 `<`。
        .replaceAll('&amp;', '&');
  }

  /// 列字母 → 0 基下标：A=0, Z=25, AA=26。
  static int _columnIndex(String letters) {
    int n = 0;
    for (final int code in letters.codeUnits) {
      n = n * 26 + (code - 64);
    }
    return n - 1;
  }
}

/// 选中的文件内容。
class SpreadsheetFile {
  const SpreadsheetFile({
    required this.name,
    required this.kind,
    this.text,
    this.sharedStringsXml,
    this.sheetXml,
  });

  /// 文件名（展示用）。
  final String name;

  /// `xlsx` 或 `text`。
  final String kind;

  /// 文本文件的内容（CSV/TSV）。
  final String? text;

  /// xlsx 的共享字符串表。
  final String? sharedStringsXml;

  /// xlsx 的工作表 XML。
  final String? sheetXml;

  bool get isXlsx => kind == 'xlsx';
}

/// 导入过程中的可展示错误。
class SpreadsheetImportException implements Exception {
  const SpreadsheetImportException(this.message);

  final String message;

  @override
  String toString() => message;

  /// 便于日志里带上原始编码（避免中文乱码难以定位）。
  static String debug(Object e) => e is SpreadsheetImportException
      ? e.message
      : e.toString();
}

/// 把解析出来的行拼回"制表符分隔"文本，便于复用现有的预览/编辑交互。
String rowsToTsv(List<List<String>> rows) =>
    rows.map((List<String> r) => r.join('\t')).join('\n');

/// 从文件解析出 TSV 文本（给导入页的文本框用）。
///
/// 之所以转成文本而不是直接提交：发布者需要在提交前**看一眼**，
/// 而预览/编辑/逐行校验的交互已经存在，复用比另做一套稳。
String spreadsheetToTsv(SpreadsheetFile file) =>
    rowsToTsv(SpreadsheetImport.parseRows(file));

/// 解码工具（供测试与调试用）。
String decodeBytesForTest(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);
