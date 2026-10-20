/// 名单文本解析：把「手动输入 / 从 Excel 粘贴 / CSV 文件」得到的文本，
/// 解析成一行一行**结构明确**的名单条目。
///
/// ## 为什么要有这个模块
///
/// 真机反馈：**管理端手动输入时读取的行是错的**。
///
/// 根因是解析用的分隔符只有 `[\t,，;；]` —— **不含空格**。
/// 于是最自然的输入方式
///
/// ```
/// 2026101 张伟 13800000101
/// ```
///
/// 会被当成**一个字段**：学号变成 `2026101 张伟 13800000101`、姓名为空，
/// 服务端只能报"学号或姓名为空"，而用户看着自己明明填了三样东西 ——
/// 这类"输入对了但被解析错"的问题最难自查。
///
/// ## 设计原则
///
/// 1. **按内容判断，不按长度**：学号、姓名、学院长度都不固定，
///    绝不能靠"前 8 位是学号"这种长度假设去切。
/// 2. **多种分隔符都认**：空格、制表符、逗号、中文逗号、分号、顿号、`|`。
/// 3. **表头可识别**：报名表导出常带"学号/姓名/学院/手机号"表头，
///    按表头顺序映射列，比按位置猜可靠得多。
/// 4. **手机号不必填**：`学号 姓名` 两列也要能导入。
/// 5. **解释不清就不猜**：解析结果里带上"忽略了哪些列"等提示，
///    让用户能看懂发生了什么，而不是默默丢掉数据。
library;

/// 一条名单记录。
class RosterEntry {
  const RosterEntry({
    required this.userNo,
    required this.name,
    this.phone = '',
    this.college = '',
  });

  /// 学号 / 工号。长度不固定（2–32 位字母数字）。
  final String userNo;

  /// 姓名。长度不固定。
  final String name;

  /// 手机号。**可空**。
  final String phone;

  /// 学院 / 院系 / 班级。**可空**。
  final String college;

  /// 是否具备最小可导入条件（学号与姓名都有）。
  bool get isUsable => userNo.isNotEmpty && name.isNotEmpty;

  @override
  String toString() =>
      'RosterEntry($userNo, $name, phone: $phone, college: $college)';
}

/// 解析结果：条目 + 供界面展示的说明。
class RosterParseResult {
  const RosterParseResult({
    required this.entries,
    this.headerSkipped = false,
    this.ignoredExtraColumns = 0,
    this.skippedLines = const <String>[],
  });

  final List<RosterEntry> entries;

  /// 是否识别并跳过了表头行。
  final bool headerSkipped;

  /// 被忽略的多余列数（例如后面还带了"备注""序号"）。
  final int ignoredExtraColumns;

  /// 被判定为"不是数据行"而跳过的行（原文），便于向用户解释。
  final List<String> skippedLines;

  bool get isEmpty => entries.isEmpty;

  /// 给界面用的一句话摘要。
  String get summary {
    final StringBuffer b = StringBuffer('识别 ${entries.length} 行');
    if (headerSkipped) {
      b.write('（已跳过表头）');
    }
    if (ignoredExtraColumns > 0) {
      b.write('，忽略 $ignoredExtraColumns 列多余内容');
    }
    return b.toString();
  }
}

// ── 列名关键词（表头识别用）────────────────────────────────────────────
const List<String> _kUserNo = <String>['学号', '工号', '学籍号', '学生学号', '编号', 'userno', 'user_no', 'userid', 'user_id', 'id'];
const List<String> _kName = <String>['姓名', '名字', '学生姓名', 'name'];
const List<String> _kPhone = <String>['手机号', '手机', '电话', '联系电话', '联系方式', '手机号码', 'phone', 'mobile', 'tel'];
const List<String> _kCollege = <String>['学院', '院系', '系别', '所属学院', '单位', '部门', '班级', '专业', 'college', 'school', 'dept', 'department'];

/// 手机号形态：1 开头的 11 位，或 7–15 位纯数字（兼容固话/带区号）。
final RegExp _phoneRe = RegExp(r'^\+?\d{7,15}$');
final RegExp _cnMobileRe = RegExp(r'^1\d{10}$');

/// 只允许"序号"这类 1–3 位小整数被当作可跳过的首列。
final RegExp _serialRe = RegExp(r'^\d{1,3}$');

bool _looksLikePhone(String s) => _cnMobileRe.hasMatch(s) || _phoneRe.hasMatch(s);

bool _hasAlnum(String s) => RegExp(r'[A-Za-z0-9]').hasMatch(s);

/// 匹配列名关键词（大小写不敏感、允许前后缀空白）。
int? _columnOf(List<String> headers, List<String> keywords) {
  for (int i = 0; i < headers.length; i += 1) {
    final String h = headers[i].toLowerCase().replaceAll(RegExp(r'[\s:_-]'), '');
    if (h.isEmpty) {
      continue;
    }
    for (final String k in keywords) {
      if (h.contains(k.toLowerCase())) {
        return i;
      }
    }
  }
  return null;
}

/// 判断某一行是不是表头。
///
/// 条件：能认出**至少 2 个**关键列（学号/姓名/手机号/学院）。
/// 要求 2 个而不是 1 个，是为了避免把某个叫「姓名」的姓名（极少见）当表头。
bool _isHeaderRow(List<String> cells) {
  int hits = 0;
  if (_columnOf(cells, _kUserNo) != null) hits += 1;
  if (_columnOf(cells, _kName) != null) hits += 1;
  if (_columnOf(cells, _kPhone) != null) hits += 1;
  if (_columnOf(cells, _kCollege) != null) hits += 1;
  return hits >= 2;
}

/// 把一行切成字段。
///
/// ## 为什么按"行里有没有真分隔符"决定是否保留空列
///
/// 这是名单导入最容易错的一步：
///
/// * **制表符 / 逗号 / 分号**是**列分隔符** —— 它们之间的空串是**有意义的空单元格**。
///   `2026201,张三,,计算机学院` 里的空串表示"手机号这一格没填"。
///   如果把空串过滤掉，学院就会**顶到手机号那一列**（列错位）。
/// * **空格**只是**视觉对齐** —— `2026101   张伟` 中间几个空格不该产生空字段。
///
/// 所以：行里有真分隔符时按真分隔符切并**保留空串**；否则按空白合并切。
List<String> splitRow(String line) {
  final String trimmed = line.trim();
  if (trimmed.isEmpty) {
    return const <String>[];
  }
  // ① 有制表符 → 制表符是列分隔符，保留空列
  if (trimmed.contains('\t')) {
    return trimmed.split('\t').map((String s) => s.trim()).toList();
  }
  // ② 有逗号/分号/顿号/竖线 → 同上，保留空列
  if (RegExp(r'[,，;；、|]').hasMatch(trimmed)) {
    return trimmed
        .split(RegExp(r'[,，;；、|]'))
        .map((String s) => s.trim())
        .toList();
  }
  // ③ 只有空白分隔 → 合并连续空白，不产生空字段
  return trimmed
      .split(RegExp(r'\s+'))
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();
}

/// 解析一段文本为名单条目。
///
/// 支持：
///   * `学号 姓名`（手机号/学院可省）
///   * `学号 姓名 手机号`
///   * `学号 姓名 学院`
///   * `学号 姓名 手机号 学院` / `学号 姓名 学院 手机号`
///   * 带表头的任意列顺序
///   * 首列是「序号」的情况（`1 2026101 张伟`）
RosterParseResult parseRosterText(String text) {
  final List<RosterEntry> entries = <RosterEntry>[];
  final List<String> skipped = <String>[];
  bool headerSkipped = false;
  int ignoredExtra = 0;

  // 列映射（仅表头模式下有效）
  int? iUserNo;
  int? iName;
  int? iPhone;
  int? iCollege;

  for (final String rawLine in text.split('\n')) {
    final String line = rawLine.trim();
    if (line.isEmpty) {
      continue;
    }
    final List<String> cells = splitRow(line);
    if (cells.isEmpty) {
      continue;
    }

    // ① 表头行：识别一次，之后按表头顺序取列
    if (!headerSkipped && _isHeaderRow(cells)) {
      headerSkipped = true;
      iUserNo = _columnOf(cells, _kUserNo);
      iName = _columnOf(cells, _kName);
      iPhone = _columnOf(cells, _kPhone);
      iCollege = _columnOf(cells, _kCollege);
      continue;
    }

    // ② 表头模式：严格按表头映射
    String userNo;
    String name;
    String phone = '';
    String college = '';

    if (iUserNo != null && iName != null) {
      userNo = _at(cells, iUserNo);
      name = _at(cells, iName);
      if (iPhone != null) {
        phone = _at(cells, iPhone);
      }
      if (iCollege != null) {
        college = _at(cells, iCollege);
      }
      // 表头里没有手机号/学院，但行尾多出一列：按内容归位
      _fillByContent(cells, iUserNo, iName, iPhone, iCollege,
          (String p) => phone = p, (String c) => college = c);
    } else {
      // ③ 无表头：按位置 + 内容判断（**不看长度**，只看像不像手机号）
      final List<String> rest = List<String>.of(cells);
      // 首列是 1–3 位小数字、且第二列像学号 → 视为「序号」，丢掉
      if (rest.length >= 3 &&
          _serialRe.hasMatch(rest[0]) &&
          rest[1].length >= 2 &&
          _hasAlnum(rest[1])) {
        rest.removeAt(0);
      }
      if (rest.isEmpty) {
        skipped.add(line);
        continue;
      }
      userNo = rest[0];
      name = rest.length >= 2 ? rest[1] : '';
      final List<String> tail = rest.length >= 3 ? rest.sublist(2) : <String>[];
      for (final String cell in tail) {
        if (phone.isEmpty && _looksLikePhone(cell)) {
          phone = cell;
        } else if (college.isEmpty) {
          college = cell;
        } else {
          ignoredExtra += 1;
        }
      }
    }

    // ④ 明显不是数据行：首列没有字母数字（如「共 20 人」「备注：…」）
    if (userNo.isEmpty || !_hasAlnum(userNo)) {
      skipped.add(line);
      continue;
    }

    entries.add(RosterEntry(
      userNo: userNo,
      name: name,
      phone: phone,
      college: college,
    ));
  }

  return RosterParseResult(
    entries: entries,
    headerSkipped: headerSkipped,
    ignoredExtraColumns: ignoredExtra,
    skippedLines: skipped,
  );
}

String _at(List<String> cells, int index) =>
    index >= 0 && index < cells.length ? cells[index] : '';

/// 表头模式下，把没被表头覆盖到的额外列按内容补到手机号/学院。
void _fillByContent(
  List<String> cells,
  int iUserNo,
  int iName,
  int? iPhone,
  int? iCollege,
  void Function(String) setPhone,
  void Function(String) setCollege,
) {
  final Set<int> used = <int>{iUserNo, iName};
  if (iPhone != null) {
    used.add(iPhone);
  }
  if (iCollege != null) {
    used.add(iCollege);
  }
  for (int i = 0; i < cells.length; i += 1) {
    if (used.contains(i)) {
      continue;
    }
    final String v = cells[i];
    if (v.isEmpty) {
      continue;
    }
    if (iPhone == null && _looksLikePhone(v)) {
      setPhone(v);
      continue;
    }
    if (iCollege == null) {
      setCollege(v);
    }
  }
}

/// 把条目转成**固定列序**的行：`[学号, 姓名, 手机号, 学院]`（缺失为空串）。
///
/// 客户端统一在这里把"用户看到的任意顺序"归一化，
/// 服务端只按位置取，不做文本猜测 —— 解析逻辑只有一份，可单测。
List<List<String>> rosterToRows(List<RosterEntry> entries) => entries
    .map((RosterEntry e) => <String>[e.userNo, e.name, e.phone, e.college])
    .toList();

/// 条目 → 制表符分隔文本（回填到输入框，便于用户核对后再提交）。
String rosterToTsv(List<RosterEntry> entries) => rosterToRows(entries)
    .map((List<String> r) => r.join('\t'))
    .join('\n');
